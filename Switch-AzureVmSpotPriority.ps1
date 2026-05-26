<#
.SYNOPSIS
Wizard-driven Azure CLI script to switch an Azure VM between Regular and Spot.

.DESCRIPTION
SpotSwitcher is designed for Azure Cloud Shell PowerShell.

With no parameters, it discovers the active Azure context, lets you choose a
subscription, lets you choose a source VM from discovered VMs, infers the valid
conversion direction from the source VM, and prompts for every required decision
with numbered choices.

Direction is inferred from the live source VM:
  - Regular/null priority -> ToSpot
  - Spot/Low priority    -> ToRegular

The script uses Azure CLI and recreates only the VM resource wrapper. It keeps
the existing managed OS disk, managed data disks, NICs, tags, VM size choice,
Trusted Launch settings, license type, boot diagnostics, and identities where
Azure CLI can safely reapply them.

Default mode is Plan, which performs discovery and writes a plan file without
mutating Azure resources. Execute mode requires an exact confirmation unless
-Force is supplied for unattended automation.

.EXAMPLE
./Switch-AzureVmSpotPriority.ps1

Run the full interactive wizard in plan-only mode by default.

.EXAMPLE
./Switch-AzureVmSpotPriority.ps1 -Mode Execute -ResourceGroupName SOUTHCENTRAL-CORE.RG -VmName DC-SouthCentral

Discover the VM, infer the direction, prompt for missing choices, preview the
commands, then require exact confirmation before executing.

.EXAMPLE
./Switch-AzureVmSpotPriority.ps1 -Mode Execute -NonInteractive -Force `
  -Subscription azse-ga-sub `
  -ResourceGroupName SOUTHCENTRAL-CORE.RG `
  -VmName DC-SouthCentral `
  -Direction ToSpot `
  -TargetSku Standard_D4ads_v6 `
  -EvictionPolicy Deallocate `
  -MaxPrice -1 `
  -PinPrivateIps Yes `
  -CreateSnapshots Yes

Run unattended with explicit choices.
#>

[CmdletBinding()]
param(
    [string]$Subscription,
    [string]$ResourceGroupName,
    [string]$VmName,

    [ValidateSet('Plan', 'Execute')]
    [string]$Mode,

    [ValidateSet('Auto', 'ToSpot', 'ToRegular')]
    [string]$Direction = 'Auto',

    [string]$TargetSku,

    [ValidateSet('Deallocate', 'Delete')]
    [string]$EvictionPolicy,

    [string]$MaxPrice,

    [ValidateSet('Auto', 'Yes', 'No')]
    [string]$PinPrivateIps = 'Auto',

    [ValidateSet('Auto', 'Yes', 'No')]
    [string]$CreateSnapshots = 'Auto',

    [ValidateSet('Auto', 'Yes', 'No')]
    [string]$ValidateSku = 'Auto',

    [ValidateSet('Auto', 'Yes', 'No')]
    [string]$DropAvailabilitySetForSpot = 'Auto',

    [string]$PlanPath,
    [switch]$NonInteractive,
    [switch]$Force,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Show-Usage {
    Write-Host @'
SpotSwitcher - Azure VM Regular <-> Spot conversion wizard

Interactive:
  ./Switch-AzureVmSpotPriority.ps1

Interactive execution:
  ./Switch-AzureVmSpotPriority.ps1 -Mode Execute

Unattended execution:
  ./Switch-AzureVmSpotPriority.ps1 -Mode Execute -NonInteractive -Force `
    -Subscription <sub> -ResourceGroupName <rg> -VmName <vm> `
    -Direction ToSpot -TargetSku <sku> -EvictionPolicy Deallocate -MaxPrice -1 `
    -PinPrivateIps Yes -CreateSnapshots Yes -ValidateSku No `
    -DropAvailabilitySetForSpot No

Direction is based on the source VM:
  Regular/null priority -> ToSpot
  Spot/Low priority    -> ToRegular

Safety defaults:
  - Plan mode is read-only and writes a plan file.
  - Execute mode sets OS disk, data disks, and NIC deleteOption to Detach.
  - Dynamic private IPs can be pinned to static before wrapper deletion.
  - Incremental snapshots can be created after deallocation.
  - Availability-set membership is preserved for regular VMs, but must be
    intentionally dropped when converting to Spot because Azure does not support
    Spot VMs in availability sets.
  - Execute mode requires exact typed confirmation unless -Force is supplied.
'@
}

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text ==" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Gray
}

function Write-WarningLine {
    param([string]$Text)
    Write-Host "WARNING: $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Text)
    throw $Text
}

function Format-AzCommand {
    param([string[]]$Arguments)

    $escaped = foreach ($arg in $Arguments) {
        if ($null -eq $arg) {
            "''"
        }
        elseif ($arg -match "[\s'`"``$&|;<>()]") {
            "'" + ($arg -replace "'", "''") + "'"
        }
        else {
            $arg
        }
    }

    return 'az ' + ($escaped -join ' ')
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowEmpty
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if ($exitCode -ne 0) {
        throw "Azure CLI command failed: $(Format-AzCommand $Arguments)`n$text"
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        if ($AllowEmpty) {
            return $null
        }
        throw "Azure CLI command returned no JSON: $(Format-AzCommand $Arguments)"
    }

    return ($text | ConvertFrom-Json -Depth 100)
}

function Invoke-AzText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$Description
    )

    if ($Description) {
        Write-Info $Description
    }

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if ($exitCode -ne 0) {
        throw "Azure CLI command failed: $(Format-AzCommand $Arguments)`n$text"
    }

    return $text
}

function New-AzCommand {
    param(
        [string]$Description,
        [string[]]$Arguments
    )

    [pscustomobject]@{
        Description = $Description
        Arguments   = @($Arguments)
    }
}

function Invoke-CommandList {
    param(
        [object[]]$Commands,
        [bool]$Execute
    )

    foreach ($command in $Commands) {
        Write-Host ''
        Write-Host $command.Description -ForegroundColor Green
        Write-Host (Format-AzCommand $command.Arguments)

        if ($Execute) {
            $output = & az @($command.Arguments) 2>&1
            $exitCode = $LASTEXITCODE
            $text = ($output | Out-String).Trim()

            if ($text) {
                Write-Host $text
            }

            if ($exitCode -ne 0) {
                throw "Command failed: $(Format-AzCommand $command.Arguments)"
            }
        }
    }
}

function Read-RequiredText {
    param(
        [string]$Prompt,
        [string]$ExistingValue
    )

    if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
        return $ExistingValue
    }

    if ($NonInteractive) {
        Write-Fail "$Prompt is required in non-interactive mode."
    }

    do {
        $value = Read-Host $Prompt
    } while ([string]::IsNullOrWhiteSpace($value))

    return $value.Trim()
}

function Read-MenuChoice {
    param(
        [string]$Title,
        [object[]]$Options,
        [int]$Default = 1
    )

    if ($Options.Count -lt 1) {
        Write-Fail "Menu '$Title' has no options."
    }

    if ($NonInteractive) {
        return $Options[$Default - 1].Value
    }

    Write-Section $Title
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $number = $i + 1
        $option = $Options[$i]
        $defaultMarker = ''
        if ($number -eq $Default) {
            $defaultMarker = ' [default]'
        }

        Write-Host ("  {0}. {1}{2}" -f $number, $option.Label, $defaultMarker) -ForegroundColor White
        if ($option.Description) {
            Write-Host ("     {0}" -f $option.Description) -ForegroundColor DarkGray
        }
    }

    while ($true) {
        $answer = Read-Host "Choose 1-$($Options.Count)"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Options[$Default - 1].Value
        }

        $parsed = 0
        if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $Options.Count) {
            return $Options[$parsed - 1].Value
        }

        Write-WarningLine "Enter a number from 1 to $($Options.Count), or press Enter for the default."
    }
}

function Confirm-Exact {
    param([string]$Phrase)

    if ($Force) {
        Write-WarningLine "-Force supplied. Skipping exact typed confirmation."
        return
    }

    if ($NonInteractive) {
        Write-Fail "Execute mode requires -Force when -NonInteractive is supplied."
    }

    Write-Host ''
    Write-WarningLine "This is the final safety gate."
    Write-Host "Type exactly this phrase to continue:" -ForegroundColor Yellow
    Write-Host $Phrase -ForegroundColor White
    $answer = Read-Host "Confirmation"

    if ($answer -cne $Phrase) {
        Write-Fail "Confirmation did not match. No destructive changes were made at this step."
    }
}

function Get-ResourceGroupFromId {
    param([string]$Id)

    if ($Id -match '/resourceGroups/([^/]+)/') {
        return $Matches[1]
    }

    return $null
}

function Test-SameResourceId {
    param(
        [string]$Left,
        [string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    $normalizedLeft = $Left.TrimEnd([char]'/')
    $normalizedRight = $Right.TrimEnd([char]'/')
    return [string]::Equals($normalizedLeft, $normalizedRight, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-PrimaryNicId {
    param($Vm)

    $nicRefs = @($Vm.networkProfile.networkInterfaces)
    foreach ($nicRef in $nicRefs) {
        if ($nicRef.primary -eq $true -or [string]$nicRef.primary -eq 'True') {
            return [string]$nicRef.id
        }
    }

    if ($nicRefs.Count -gt 0) {
        return [string]$nicRefs[0].id
    }

    return $null
}

function Get-NicIdsInPrimaryOrder {
    param($Vm)

    $nicRefs = @($Vm.networkProfile.networkInterfaces)
    $primaryNicId = Get-PrimaryNicId -Vm $Vm
    $orderedNicIds = @()

    if ($primaryNicId) {
        $orderedNicIds += $primaryNicId
    }

    foreach ($nicRef in $nicRefs) {
        $nicId = [string]$nicRef.id
        if (-not (Test-SameResourceId -Left $nicId -Right $primaryNicId)) {
            $orderedNicIds += $nicId
        }
    }

    return $orderedNicIds
}

function Get-PlanRoot {
    $cloudDrive = Join-Path $HOME 'clouddrive'
    if (Test-Path $cloudDrive) {
        return (Join-Path $cloudDrive 'SpotSwitcherPlans')
    }

    return (Join-Path (Get-Location) 'SpotSwitcherPlans')
}

function Get-TagsAsArguments {
    param($Tags)

    $tagArgs = @()
    if ($null -eq $Tags) {
        return $tagArgs
    }

    foreach ($prop in $Tags.PSObject.Properties) {
        if ($null -ne $prop.Value) {
            $tagArgs += "$($prop.Name)=$($prop.Value)"
        }
    }

    return $tagArgs
}

function Get-EffectivePriority {
    param($Vm)

    if ($Vm.priority) {
        return [string]$Vm.priority
    }

    return 'Regular'
}

function Select-RunMode {
    if ($Mode) {
        return $Mode
    }

    if ($NonInteractive) {
        return 'Plan'
    }

    return Read-MenuChoice `
        -Title 'Run mode' `
        -Default 1 `
        -Options @(
            [pscustomobject]@{
                Label       = 'Plan only'
                Description = 'Read-only discovery, saved plan, and command preview. Recommended first.'
                Value       = 'Plan'
            },
            [pscustomobject]@{
                Label       = 'Execute conversion'
                Description = 'Run the inferred Regular -> Spot or Spot -> Regular wrapper recreation after confirmation.'
                Value       = 'Execute'
            }
        )
}

function Select-Subscription {
    if ($Subscription) {
        Invoke-AzText -Arguments @('account', 'set', '--subscription', $Subscription) -Description "Selecting subscription '$Subscription'." | Out-Null
    }

    $account = Invoke-AzJson -Arguments @('account', 'show', '-o', 'json')
    Write-Section 'Azure context'
    Write-Host ("Active subscription: {0} ({1})" -f $account.name, $account.id)
    Write-Host ("Tenant: {0}" -f $account.tenantId)
    if ($account.user -and $account.user.name) {
        Write-Host ("User: {0}" -f $account.user.name)
    }

    if (-not $Subscription -and -not $NonInteractive) {
        $choice = Read-MenuChoice `
            -Title 'Subscription choice' `
            -Default 1 `
            -Options @(
                [pscustomobject]@{
                    Label       = 'Use current subscription'
                    Description = 'Continue with the active Azure CLI context shown above.'
                    Value       = 'current'
                },
                [pscustomobject]@{
                    Label       = 'Choose another subscription'
                    Description = 'List visible subscriptions and switch before continuing.'
                    Value       = 'switch'
                }
            )

        if ($choice -eq 'switch') {
            $subs = @(Invoke-AzJson -Arguments @('account', 'list', '--query', '[].{name:name,id:id,isDefault:isDefault}', '-o', 'json'))
            $options = foreach ($sub in $subs) {
                [pscustomobject]@{
                    Label       = $sub.name
                    Description = $sub.id
                    Value       = $sub.id
                }
            }

            $selected = Read-MenuChoice -Title 'Available subscriptions' -Options $options -Default 1
            Invoke-AzText -Arguments @('account', 'set', '--subscription', $selected) -Description 'Switching subscription.' | Out-Null
            $account = Invoke-AzJson -Arguments @('account', 'show', '-o', 'json')
            Write-Host ("Now active: {0} ({1})" -f $account.name, $account.id)
        }
    }

    return $account
}

function Select-TargetVm {
    if ($ResourceGroupName -and $VmName) {
        return [pscustomobject]@{
            resourceGroup = $ResourceGroupName
            name          = $VmName
        }
    }

    if ($NonInteractive) {
        Write-Fail 'ResourceGroupName and VmName are required in non-interactive mode.'
    }

    $vms = @(Invoke-AzJson -Arguments @(
            'vm', 'list', '-d',
            '--query', '[].{name:name,resourceGroup:resourceGroup,location:location,powerState:powerState,priority:priority,size:hardwareProfile.vmSize,os:storageProfile.osDisk.osType,privateIps:privateIps}',
            '-o', 'json'
        ))

    if ($vms.Count -eq 0) {
        Write-Fail 'No VMs were found in the active subscription.'
    }

    $options = foreach ($vm in ($vms | Sort-Object resourceGroup, name)) {
        $priority = if ($vm.priority) { $vm.priority } else { 'Regular' }
        $next = if ($priority -in @('Spot', 'Low')) { 'ToRegular' } else { 'ToSpot' }
        [pscustomobject]@{
            Label       = "$($vm.resourceGroup) / $($vm.name)"
            Description = "$($vm.location), $($vm.size), $($vm.os), $($vm.powerState), priority=$priority, inferred=$next, IPs=$($vm.privateIps)"
            Value       = $vm
        }
    }

    $options += [pscustomobject]@{
        Label       = 'Enter VM manually'
        Description = 'Type the resource group and VM name yourself.'
        Value       = '__manual__'
    }

    $selected = Read-MenuChoice -Title 'Source VM' -Options $options -Default 1
    if ($selected -eq '__manual__') {
        return [pscustomobject]@{
            resourceGroup = Read-RequiredText -Prompt 'Resource group name' -ExistingValue $ResourceGroupName
            name          = Read-RequiredText -Prompt 'VM name' -ExistingValue $VmName
        }
    }

    return [pscustomobject]@{
        resourceGroup = $selected.resourceGroup
        name          = $selected.name
    }
}

function Get-VmInventory {
    param(
        [string]$ResourceGroup,
        [string]$Name
    )

    Write-Section 'Inventory'
    Write-Info 'Reading VM, NIC, disk, extension, and instance-view data.'

    $vm = Invoke-AzJson -Arguments @('vm', 'show', '-g', $ResourceGroup, '-n', $Name, '-o', 'json')
    $instanceView = Invoke-AzJson -Arguments @('vm', 'get-instance-view', '-g', $ResourceGroup, '-n', $Name, '-o', 'json')
    $extensions = @(Invoke-AzJson -Arguments @('vm', 'extension', 'list', '-g', $ResourceGroup, '--vm-name', $Name, '-o', 'json'))

    $nics = @()
    foreach ($nicRef in @($vm.networkProfile.networkInterfaces)) {
        $nics += Invoke-AzJson -Arguments @('network', 'nic', 'show', '--ids', $nicRef.id, '-o', 'json')
    }

    $osDiskId = $vm.storageProfile.osDisk.managedDisk.id
    if (-not $osDiskId) {
        Write-Fail 'Only managed OS disks are supported. This VM does not expose storageProfile.osDisk.managedDisk.id.'
    }

    if ($vm.storageProfile.osDisk.diffDiskSettings) {
        Write-Fail 'Ephemeral OS disks are not supported because there is no detachable OS disk to preserve.'
    }

    $osDisk = Invoke-AzJson -Arguments @('disk', 'show', '--ids', $osDiskId, '-o', 'json')

    $dataDisks = @()
    foreach ($disk in @($vm.storageProfile.dataDisks | Sort-Object lun)) {
        if (-not $disk.managedDisk.id) {
            Write-Fail "Data disk LUN $($disk.lun) is not a managed disk. Unmanaged data disks are not supported."
        }
        $dataDisks += Invoke-AzJson -Arguments @('disk', 'show', '--ids', $disk.managedDisk.id, '-o', 'json')
    }

    return [pscustomobject]@{
        vm           = $vm
        instanceView = $instanceView
        extensions   = $extensions
        nics         = $nics
        osDisk       = $osDisk
        dataDisks    = $dataDisks
    }
}

function Show-InventorySummary {
    param($Inventory)

    $vm = $Inventory.vm
    $priority = Get-EffectivePriority -Vm $vm
    $power = (@($Inventory.instanceView.instanceView.statuses) | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1).displayStatus
    $availabilitySetId = if ($vm.availabilitySet -and $vm.availabilitySet.id) { $vm.availabilitySet.id } else { '<none>' }
    $primaryNicId = Get-PrimaryNicId -Vm $vm

    Write-Section 'VM summary'
    Write-Host ("Name:        {0}" -f $vm.name)
    Write-Host ("Resource RG: {0}" -f $vm.resourceGroup)
    Write-Host ("Location:    {0}" -f $vm.location)
    Write-Host ("Power:       {0}" -f $power)
    Write-Host ("Priority:    {0}" -f $priority)
    Write-Host ("Size:        {0}" -f $vm.hardwareProfile.vmSize)
    Write-Host ("OS:          {0}" -f $vm.storageProfile.osDisk.osType)
    Write-Host ("OS disk:     {0}" -f $vm.storageProfile.osDisk.managedDisk.id)
    Write-Host ("OS delete:   {0}" -f $vm.storageProfile.osDisk.deleteOption)
    Write-Host ("NIC count:   {0}" -f @($Inventory.nics).Count)
    Write-Host ("Data disks:  {0}" -f @($vm.storageProfile.dataDisks).Count)
    Write-Host ("Extensions:  {0}" -f @($Inventory.extensions).Count)
    Write-Host ("Avail. set:  {0}" -f $availabilitySetId)
    if ($primaryNicId) {
        Write-Host ("Primary NIC: {0}" -f $primaryNicId)
    }

    foreach ($nic in @($Inventory.nics)) {
        $primaryMarker = if (Test-SameResourceId -Left $nic.id -Right $primaryNicId) { 'primary' } else { 'secondary' }
        foreach ($ipConfig in @($nic.ipConfigurations)) {
            Write-Host ("NIC:         {0} / {1} / {2} ({3}, {4})" -f $nic.name, $ipConfig.name, $ipConfig.privateIPAddress, $ipConfig.privateIPAllocationMethod, $primaryMarker)
        }
    }

    if ($vm.storageProfile.osDisk.deleteOption -ne 'Detach') {
        Write-WarningLine "OS disk deleteOption is '$($vm.storageProfile.osDisk.deleteOption)'. Execute mode will change it to Detach first."
    }

    foreach ($nicRef in @($vm.networkProfile.networkInterfaces)) {
        if ($nicRef.deleteOption -ne 'Detach') {
            Write-WarningLine "NIC reference '$($nicRef.id)' deleteOption is '$($nicRef.deleteOption)'. Execute mode will change it to Detach first."
        }
    }

    if (@($Inventory.extensions).Count -gt 0) {
        Write-WarningLine 'VM extensions are inventoried but not automatically reinstalled because protected settings are not recoverable from Azure.'
    }
}

function Select-Direction {
    param($Inventory)

    $priority = Get-EffectivePriority -Vm $Inventory.vm
    $inferred = if ($priority -in @('Spot', 'Low')) { 'ToRegular' } else { 'ToSpot' }

    if ($Direction -ne 'Auto' -and $Direction -ne $inferred) {
        Write-Fail "Requested Direction '$Direction' does not match source VM priority '$priority'. Correct direction is '$inferred'."
    }

    if ($Direction -ne 'Auto') {
        return $Direction
    }

    if ($NonInteractive) {
        return $inferred
    }

    $label = if ($inferred -eq 'ToSpot') { 'Convert Regular VM to Spot' } else { 'Convert Spot VM to Regular' }
    $description = if ($inferred -eq 'ToSpot') {
        "Source priority is '$priority', so the valid direction is Regular -> Spot."
    }
    else {
        "Source priority is '$priority', so the valid direction is Spot -> Regular."
    }

    return Read-MenuChoice `
        -Title 'Conversion direction' `
        -Default 1 `
        -Options @(
            [pscustomobject]@{
                Label       = $label
                Description = $description
                Value       = $inferred
            },
            [pscustomobject]@{
                Label       = 'Stop without building commands'
                Description = 'Exit now. No Azure resources will be changed.'
                Value       = 'Cancel'
            }
        )
}

function Select-TargetSku {
    param(
        $Vm,
        [string]$ResolvedDirection
    )

    if ($TargetSku) {
        return $TargetSku
    }

    $currentSize = $Vm.hardwareProfile.vmSize
    $title = if ($ResolvedDirection -eq 'ToSpot') { 'Spot VM SKU' } else { 'Regular VM SKU' }
    $browseDescription = if ($ResolvedDirection -eq 'ToSpot') {
        'Browse unrestricted Spot-capable SKUs in this region.'
    }
    else {
        'Browse unrestricted VM SKUs in this region.'
    }

    $choice = Read-MenuChoice `
        -Title $title `
        -Default 1 `
        -Options @(
            [pscustomobject]@{
                Label       = "Keep current size: $currentSize"
                Description = 'Recommended when you want the smallest wrapper change.'
                Value       = 'current'
            },
            [pscustomobject]@{
                Label       = 'Browse discovered SKUs'
                Description = $browseDescription
                Value       = 'browse'
            },
            [pscustomobject]@{
                Label       = 'Enter a different SKU manually'
                Description = 'Example: Standard_D4s_v5 or Standard_D4ads_v6.'
                Value       = 'manual'
            }
        )

    if ($choice -eq 'current') {
        return $currentSize
    }

    if ($choice -eq 'manual') {
        return (Read-RequiredText -Prompt 'Target VM size' -ExistingValue $null)
    }

    $filter = ''
    if (-not $NonInteractive) {
        $filter = Read-Host 'Filter SKU names, or press Enter for the first 30 matches'
    }

    $query = if ($ResolvedDirection -eq 'ToSpot') {
        "[?resourceType=='virtualMachines' && capabilities[?name=='LowPriorityCapable' && value=='True']].{name:name,restrictions:restrictions}"
    }
    else {
        "[?resourceType=='virtualMachines'].{name:name,restrictions:restrictions}"
    }

    $skus = @(Invoke-AzJson -Arguments @('vm', 'list-skus', '--location', $Vm.location, '--all', '--query', $query, '-o', 'json'))
    if (-not [string]::IsNullOrWhiteSpace($filter)) {
        $skus = @($skus | Where-Object { $_.name -like "*$filter*" })
    }

    $skus = @($skus | Where-Object { -not $_.restrictions -or $_.restrictions.Count -eq 0 } | Sort-Object name | Select-Object -First 30)
    if ($skus.Count -eq 0) {
        Write-WarningLine 'No matching unrestricted SKUs were returned. Falling back to manual entry.'
        return (Read-RequiredText -Prompt 'Target VM size' -ExistingValue $null)
    }

    $options = foreach ($sku in $skus) {
        [pscustomobject]@{
            Label       = $sku.name
            Description = 'Returned by az vm list-skus for this region without restrictions.'
            Value       = $sku.name
        }
    }

    return (Read-MenuChoice -Title "Choose $title" -Options $options -Default 1)
}

function Test-TargetSku {
    param(
        [string]$Location,
        [string]$Size,
        [string]$ResolvedDirection
    )

    try {
        $query = "[?name=='$Size'].{name:name,restrictions:restrictions,lowPriority:capabilities[?name=='LowPriorityCapable'].value | [0]}"
        $matches = @(Invoke-AzJson -Arguments @('vm', 'list-skus', '--location', $Location, '--size', $Size, '--all', '--query', $query, '-o', 'json'))
        if ($matches.Count -eq 0) {
            Write-WarningLine "Could not confirm SKU '$Size' in $Location."
            return
        }

        $sku = $matches[0]
        if ($ResolvedDirection -eq 'ToSpot' -and $sku.lowPriority -ne 'True') {
            Write-WarningLine "SKU '$Size' did not report LowPriorityCapable=True. Spot creation may fail."
        }

        if ($sku.restrictions -and $sku.restrictions.Count -gt 0) {
            Write-WarningLine "SKU '$Size' has restrictions in $Location. Creation may fail."
        }
        else {
            Write-Info "SKU preflight: $Size returned with no restrictions."
        }
    }
    catch {
        Write-WarningLine "SKU preflight failed but the plan can still be generated: $($_.Exception.Message)"
    }
}

function Resolve-SkuValidation {
    if ($ValidateSku -eq 'Yes') {
        return $true
    }

    if ($ValidateSku -eq 'No') {
        return $false
    }

    if ($NonInteractive) {
        return $false
    }

    return Read-MenuChoice `
        -Title 'SKU validation' `
        -Default 1 `
        -Options @(
            [pscustomobject]@{
                Label       = 'Skip live SKU validation'
                Description = 'Fastest. Azure will still validate the SKU during create. Recommended unless you want an extra capability check.'
                Value       = $false
            },
            [pscustomobject]@{
                Label       = 'Run live SKU validation'
                Description = 'Calls az vm list-skus for the chosen size. Can take a while in some tenants.'
                Value       = $true
            }
        )
}

function Get-DynamicPrivateIpConfigs {
    param([object[]]$Nics)

    $dynamic = @()
    foreach ($nic in @($Nics)) {
        foreach ($ipConfig in @($nic.ipConfigurations)) {
            if ($ipConfig.privateIPAddress -and $ipConfig.privateIPAllocationMethod -ne 'Static') {
                $dynamic += [pscustomobject]@{
                    nicName       = $nic.name
                    nicResourceId = $nic.id
                    nicRg         = $nic.resourceGroup
                    ipConfigName  = $ipConfig.name
                    privateIp     = $ipConfig.privateIPAddress
                }
            }
        }
    }

    return $dynamic
}

function Resolve-YesNo {
    param(
        [string]$Value,
        [bool]$DefaultWhenAuto,
        [string]$Title,
        [string]$YesLabel,
        [string]$YesDescription,
        [string]$NoLabel,
        [string]$NoDescription
    )

    if ($Value -eq 'Yes') {
        return $true
    }

    if ($Value -eq 'No') {
        return $false
    }

    if ($NonInteractive) {
        return $DefaultWhenAuto
    }

    $defaultIndex = if ($DefaultWhenAuto) { 1 } else { 2 }
    return Read-MenuChoice `
        -Title $Title `
        -Default $defaultIndex `
        -Options @(
            [pscustomobject]@{
                Label       = $YesLabel
                Description = $YesDescription
                Value       = $true
            },
            [pscustomobject]@{
                Label       = $NoLabel
                Description = $NoDescription
                Value       = $false
            }
        )
}

function Resolve-AvailabilitySetAction {
    param(
        $Vm,
        [string]$ResolvedDirection
    )

    $availabilitySetId = $null
    if ($Vm.availabilitySet -and $Vm.availabilitySet.id) {
        $availabilitySetId = [string]$Vm.availabilitySet.id
    }

    if (-not $availabilitySetId) {
        return 'None'
    }

    if ($ResolvedDirection -ne 'ToSpot') {
        return 'Preserve'
    }

    Write-WarningLine "Source VM is in an availability set: $availabilitySetId"
    Write-WarningLine 'Azure Spot VMs cannot be created in availability sets.'

    if ($DropAvailabilitySetForSpot -eq 'Yes') {
        Write-WarningLine 'The recreated Spot VM will intentionally omit availability-set membership.'
        return 'DropForSpot'
    }

    if ($DropAvailabilitySetForSpot -eq 'No') {
        Write-Fail 'Cannot convert this VM to Spot while preserving availability-set membership.'
    }

    if ($NonInteractive) {
        Write-Fail 'Source VM is in an availability set. Rerun with -DropAvailabilitySetForSpot Yes to intentionally omit availability-set membership, or choose a VM outside an availability set.'
    }

    $dropAvailabilitySet = Read-MenuChoice `
        -Title 'Availability set handling' `
        -Default 2 `
        -Options @(
            [pscustomobject]@{
                Label       = 'Recreate without availability set'
                Description = 'Required if this VM must become Spot; availability-set membership will be intentionally dropped.'
                Value       = $true
            },
            [pscustomobject]@{
                Label       = 'Stop without building commands'
                Description = 'Keep the VM in its availability set and leave Azure unchanged.'
                Value       = $false
            }
        )

    if ($dropAvailabilitySet -eq $true) {
        return 'DropForSpot'
    }

    Write-Fail 'Stopped because Spot VMs cannot preserve availability-set membership.'
}

function Select-Decisions {
    param(
        $Inventory,
        [string]$ResolvedDirection
    )

    $vm = $Inventory.vm
    $availabilitySetAction = Resolve-AvailabilitySetAction -Vm $vm -ResolvedDirection $ResolvedDirection
    $targetSkuValue = Select-TargetSku -Vm $vm -ResolvedDirection $ResolvedDirection
    if (Resolve-SkuValidation) {
        Test-TargetSku -Location $vm.location -Size $targetSkuValue -ResolvedDirection $ResolvedDirection
    }

    $resolvedEvictionPolicy = $null
    $resolvedMaxPrice = $null
    if ($ResolvedDirection -eq 'ToSpot') {
        $resolvedEvictionPolicy = if ($EvictionPolicy) {
            $EvictionPolicy
        }
        else {
            Read-MenuChoice `
                -Title 'Spot eviction policy' `
                -Default 1 `
                -Options @(
                    [pscustomobject]@{
                        Label       = 'Deallocate'
                        Description = 'Recommended for stateful VMs. Preserves disks and NICs on eviction.'
                        Value       = 'Deallocate'
                    },
                    [pscustomobject]@{
                        Label       = 'Delete'
                        Description = 'Deletes the VM on eviction. Only choose this for disposable VMs.'
                        Value       = 'Delete'
                    }
                )
        }

        $resolvedMaxPrice = if ($MaxPrice) {
            $MaxPrice
        }
        else {
            $maxPriceChoice = Read-MenuChoice `
                -Title 'Spot max price' `
                -Default 1 `
                -Options @(
                    [pscustomobject]@{
                        Label       = '-1'
                        Description = 'Recommended. Do not evict for price reasons, only capacity.'
                        Value       = '-1'
                    },
                    [pscustomobject]@{
                        Label       = 'Enter custom max price'
                        Description = 'Dollar amount per hour. Azure may evict when Spot price exceeds this.'
                        Value       = 'custom'
                    }
                )

            if ($maxPriceChoice -eq 'custom') {
                Read-RequiredText -Prompt 'Max price, such as 0.25' -ExistingValue $null
            }
            else {
                $maxPriceChoice
            }
        }
    }

    $dynamicIpConfigs = @(Get-DynamicPrivateIpConfigs -Nics $Inventory.nics)
    $pinPrivateIpsValue = $false
    if ($dynamicIpConfigs.Count -gt 0) {
        $pinPrivateIpsValue = Resolve-YesNo `
            -Value $PinPrivateIps `
            -DefaultWhenAuto $true `
            -Title 'Private IP handling' `
            -YesLabel 'Pin current dynamic private IPs to static' `
            -YesDescription 'Recommended for reliable failback and DNS-sensitive workloads.' `
            -NoLabel 'Leave private IP allocation unchanged' `
            -NoDescription 'Azure usually keeps a NIC IP, but static allocation is safer during wrapper surgery.'
    }

    $createSnapshotsValue = Resolve-YesNo `
        -Value $CreateSnapshots `
        -DefaultWhenAuto $true `
        -Title 'Snapshot insurance' `
        -YesLabel 'Create incremental disk snapshots after deallocation' `
        -YesDescription 'Recommended. Same-disk recreation remains primary; snapshots are extra insurance.' `
        -NoLabel 'Skip snapshots' `
        -NoDescription 'Fastest path, but removes the extra disk-level recovery option.'

    return [pscustomobject]@{
        direction        = $ResolvedDirection
        targetSku        = $targetSkuValue
        evictionPolicy   = $resolvedEvictionPolicy
        maxPrice         = $resolvedMaxPrice
        pinPrivateIps    = [bool]$pinPrivateIpsValue
        createSnapshots  = [bool]$createSnapshotsValue
        dynamicIpConfigs = $dynamicIpConfigs
        availabilitySetAction = $availabilitySetAction
    }
}

function New-Plan {
    param(
        $Account,
        $Inventory,
        $Decisions
    )

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $vm = $Inventory.vm

    [ordered]@{
        planVersion = 2
        generatedAt = (Get-Date).ToString('o')
        planId = "$($vm.name)-$($Decisions.direction)-$stamp"
        subscription = @{
            id = $Account.id
            name = $Account.name
            tenantId = $Account.tenantId
        }
        source = @{
            vm = $Inventory.vm
            instanceView = $Inventory.instanceView
            extensions = $Inventory.extensions
            nics = $Inventory.nics
            osDisk = $Inventory.osDisk
            dataDisks = $Inventory.dataDisks
        }
        decisions = $Decisions
    }
}

function Save-Plan {
    param($Plan)

    if ($PlanPath) {
        $path = [System.IO.Path]::GetFullPath($PlanPath)
        $dir = Split-Path -Parent $path
    }
    else {
        $dir = Get-PlanRoot
        $path = Join-Path $dir "$($Plan.planId).plan.json"
    }

    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Plan | ConvertTo-Json -Depth 100 | Set-Content -Path $path -Encoding utf8
    Write-Section 'Saved plan'
    Write-Host $path -ForegroundColor White
    return $path
}

function Get-CreateVmArgs {
    param($Plan)

    $vm = $Plan.source.vm
    $decisions = $Plan.decisions
    $osType = ([string]$vm.storageProfile.osDisk.osType).ToLowerInvariant()

    $args = @(
        'vm', 'create',
        '-g', $vm.resourceGroup,
        '-n', $vm.name,
        '--location', $vm.location,
        '--size', $decisions.targetSku,
        '--attach-os-disk', $vm.storageProfile.osDisk.managedDisk.id,
        '--os-type', $osType,
        '--os-disk-caching', $vm.storageProfile.osDisk.caching,
        '--os-disk-delete-option', 'Detach',
        '--nics'
    )

    foreach ($nicId in @(Get-NicIdsInPrimaryOrder -Vm $vm)) {
        $args += $nicId
    }

    $args += @('--nic-delete-option', 'Detach')

    if ($decisions.direction -eq 'ToSpot') {
        $args += @(
            '--priority', 'Spot',
            '--eviction-policy', $decisions.evictionPolicy,
            '--max-price', ([string]$decisions.maxPrice)
        )
    }
    else {
        $args += @('--priority', 'Regular')
    }

    if ($vm.zones -and @($vm.zones).Count -gt 0) {
        $args += '--zone'
        $args += @($vm.zones)
    }

    if ($vm.availabilitySet -and $vm.availabilitySet.id -and $decisions.availabilitySetAction -eq 'Preserve') {
        $args += @('--availability-set', $vm.availabilitySet.id)
    }

    if ($vm.proximityPlacementGroup -and $vm.proximityPlacementGroup.id) {
        $args += @('--ppg', $vm.proximityPlacementGroup.id)
    }

    if ($vm.licenseType) {
        $args += @('--license-type', $vm.licenseType)
    }

    if ($vm.securityProfile -and $vm.securityProfile.securityType) {
        $args += @('--security-type', $vm.securityProfile.securityType)

        if ($vm.securityProfile.uefiSettings) {
            if ($null -ne $vm.securityProfile.uefiSettings.secureBootEnabled) {
                $args += @('--enable-secure-boot', ([string]$vm.securityProfile.uefiSettings.secureBootEnabled).ToLowerInvariant())
            }
            if ($null -ne $vm.securityProfile.uefiSettings.vTpmEnabled) {
                $args += @('--enable-vtpm', ([string]$vm.securityProfile.uefiSettings.vTpmEnabled).ToLowerInvariant())
            }
        }
    }

    if ($vm.additionalCapabilities -and $vm.additionalCapabilities.ultraSsdEnabled -eq $true) {
        $args += @('--ultra-ssd-enabled', 'true')
    }

    $tagArgs = @(Get-TagsAsArguments -Tags $vm.tags)
    if ($tagArgs.Count -gt 0) {
        $args += '--tags'
        $args += $tagArgs
    }

    return $args
}

function Get-PrepareCommands {
    param($Plan)

    $commands = @()
    $vm = $Plan.source.vm

    $setExpressions = @('storageProfile.osDisk.deleteOption=Detach')
    for ($i = 0; $i -lt @($vm.networkProfile.networkInterfaces).Count; $i++) {
        $setExpressions += "networkProfile.networkInterfaces[$i].deleteOption=Detach"
    }

    for ($i = 0; $i -lt @($vm.storageProfile.dataDisks).Count; $i++) {
        $setExpressions += "storageProfile.dataDisks[$i].deleteOption=Detach"
    }

    $commands += New-AzCommand -Description 'Set disk and NIC delete options to Detach.' -Arguments (@(
            'vm', 'update',
            '-g', $vm.resourceGroup,
            '-n', $vm.name,
            '--set'
        ) + $setExpressions)

    if ($Plan.decisions.pinPrivateIps -eq $true) {
        foreach ($ip in @($Plan.decisions.dynamicIpConfigs)) {
            $commands += New-AzCommand -Description "Pin $($ip.nicName)/$($ip.ipConfigName) private IP to static $($ip.privateIp)." -Arguments @(
                'network', 'nic', 'ip-config', 'update',
                '-g', $ip.nicRg,
                '--nic-name', $ip.nicName,
                '-n', $ip.ipConfigName,
                '--private-ip-address', $ip.privateIp
            )
        }
    }

    return $commands
}

function Get-SnapshotCommands {
    param($Plan)

    $commands = @()
    if ($Plan.decisions.createSnapshots -ne $true) {
        return $commands
    }

    $vm = $Plan.source.vm
    $snapshotTagArgs = @(
        "sourceVm=$($vm.name)",
        "sourceResourceGroup=$($vm.resourceGroup)",
        "spotSwitcherPlanId=$($Plan.planId)"
    )

    $osDisk = $Plan.source.osDisk
    $osDiskRg = if ($osDisk.resourceGroup) { $osDisk.resourceGroup } else { Get-ResourceGroupFromId -Id $osDisk.id }
    $commands += New-AzCommand -Description 'Create incremental snapshot of the OS disk.' -Arguments (@(
            'snapshot', 'create',
            '-g', $osDiskRg,
            '-n', "$($vm.name)-os-pre-switch-$($Plan.planId)",
            '--source', $osDisk.id,
            '--incremental', 'true',
            '--tags'
        ) + $snapshotTagArgs)

    foreach ($disk in @($Plan.source.dataDisks)) {
        $diskRg = if ($disk.resourceGroup) { $disk.resourceGroup } else { Get-ResourceGroupFromId -Id $disk.id }
        $commands += New-AzCommand -Description "Create incremental snapshot of data disk $($disk.name)." -Arguments (@(
                'snapshot', 'create',
                '-g', $diskRg,
                '-n', "$($vm.name)-data-$($disk.name)-pre-switch-$($Plan.planId)",
                '--source', $disk.id,
                '--incremental', 'true',
                '--tags'
            ) + $snapshotTagArgs)
    }

    return $commands
}

function Get-PostCreateCommands {
    param($Plan)

    $commands = @()
    $vm = $Plan.source.vm
    $nicIds = @(Get-NicIdsInPrimaryOrder -Vm $vm)
    $primaryNicId = Get-PrimaryNicId -Vm $vm

    foreach ($disk in @($vm.storageProfile.dataDisks | Sort-Object lun)) {
        $args = @(
            'vm', 'disk', 'attach',
            '-g', $vm.resourceGroup,
            '--vm-name', $vm.name,
            '--disk-ids', $disk.managedDisk.id,
            '--lun', ([string]$disk.lun)
        )

        if ($disk.caching) {
            $args += @('--caching', $disk.caching)
        }

        if ($null -ne $disk.writeAcceleratorEnabled) {
            $args += @('--enable-write-accelerator', ([string]$disk.writeAcceleratorEnabled).ToLowerInvariant())
        }

        $commands += New-AzCommand -Description "Reattach data disk LUN $($disk.lun)." -Arguments $args
    }

    if (@($vm.storageProfile.dataDisks).Count -gt 0) {
        $setExpressions = @()
        for ($i = 0; $i -lt @($vm.storageProfile.dataDisks).Count; $i++) {
            $setExpressions += "storageProfile.dataDisks[$i].deleteOption=Detach"
        }

        $commands += New-AzCommand -Description 'Set reattached data disk delete options to Detach.' -Arguments (@(
                'vm', 'update',
                '-g', $vm.resourceGroup,
                '-n', $vm.name,
                '--set'
            ) + $setExpressions)
    }

    if ($primaryNicId -and $nicIds.Count -gt 1) {
        $commands += New-AzCommand -Description 'Restore primary NIC selection.' -Arguments (@(
                'vm', 'nic', 'set',
                '-g', $vm.resourceGroup,
                '--vm-name', $vm.name,
                '--nics'
            ) + $nicIds + @(
                '--primary-nic', $primaryNicId
            ))
    }

    if ($vm.identity -and $vm.identity.type) {
        $identityType = [string]$vm.identity.type
        if ($identityType -like '*SystemAssigned*') {
            $commands += New-AzCommand -Description 'Restore system-assigned managed identity.' -Arguments @(
                'vm', 'identity', 'assign',
                '-g', $vm.resourceGroup,
                '-n', $vm.name
            )
        }

        if ($identityType -like '*UserAssigned*' -and $vm.identity.userAssignedIdentities) {
            $identityIds = @($vm.identity.userAssignedIdentities.PSObject.Properties.Name)
            if ($identityIds.Count -gt 0) {
                $args = @(
                    'vm', 'identity', 'assign',
                    '-g', $vm.resourceGroup,
                    '-n', $vm.name,
                    '--identities'
                ) + $identityIds
                $commands += New-AzCommand -Description 'Restore user-assigned managed identities.' -Arguments $args
            }
        }
    }

    if ($vm.diagnosticsProfile -and $vm.diagnosticsProfile.bootDiagnostics -and $vm.diagnosticsProfile.bootDiagnostics.enabled -eq $true) {
        $args = @(
            'vm', 'boot-diagnostics', 'enable',
            '-g', $vm.resourceGroup,
            '-n', $vm.name
        )
        if ($vm.diagnosticsProfile.bootDiagnostics.storageUri) {
            $args += @('--storage', $vm.diagnosticsProfile.bootDiagnostics.storageUri)
        }

        $commands += New-AzCommand -Description 'Restore boot diagnostics setting.' -Arguments $args
    }

    if (@($Plan.source.extensions).Count -gt 0) {
        $commands += New-AzCommand -Description 'Review extensions manually; protected settings cannot be recovered from Azure inventory.' -Arguments @(
            'vm', 'extension', 'list',
            '-g', $vm.resourceGroup,
            '--vm-name', $vm.name,
            '-o', 'table'
        )
    }

    return $commands
}

function Get-SwitchCommands {
    param($Plan)

    $vm = $Plan.source.vm
    $targetLabel = if ($Plan.decisions.direction -eq 'ToSpot') { 'Spot' } else { 'Regular' }

    $commands = @()
    $commands += Get-PrepareCommands -Plan $Plan
    $commands += New-AzCommand -Description 'Deallocate the VM before snapshot/delete/recreate.' -Arguments @(
        'vm', 'deallocate',
        '-g', $vm.resourceGroup,
        '-n', $vm.name
    )
    $commands += Get-SnapshotCommands -Plan $Plan
    $commands += New-AzCommand -Description 'Delete only the VM resource wrapper.' -Arguments @(
        'vm', 'delete',
        '-g', $vm.resourceGroup,
        '-n', $vm.name,
        '--yes'
    )
    $commands += New-AzCommand -Description 'Wait until the VM resource wrapper is deleted.' -Arguments @(
        'vm', 'wait',
        '-g', $vm.resourceGroup,
        '-n', $vm.name,
        '--deleted'
    )
    $commands += New-AzCommand -Description "Recreate the VM as $targetLabel from the preserved OS disk and NICs." -Arguments (Get-CreateVmArgs -Plan $Plan)
    $commands += Get-PostCreateCommands -Plan $Plan

    return $commands
}

function Show-CommandPreview {
    param([object[]]$Commands)

    Write-Section 'Command preview'
    foreach ($command in $Commands) {
        Write-Host ''
        Write-Host $command.Description -ForegroundColor Green
        Write-Host (Format-AzCommand $command.Arguments)
    }
}

function Show-DecisionSummary {
    param($Plan)

    Write-Section 'Decision summary'
    Write-Host ("Direction:        {0}" -f $Plan.decisions.direction)
    Write-Host ("Target SKU:       {0}" -f $Plan.decisions.targetSku)
    if ($Plan.decisions.direction -eq 'ToSpot') {
        Write-Host ("Eviction policy:  {0}" -f $Plan.decisions.evictionPolicy)
        Write-Host ("Max price:        {0}" -f $Plan.decisions.maxPrice)
    }
    $availabilitySetSummary = switch ($Plan.decisions.availabilitySetAction) {
        'Preserve' { 'Preserve original membership'; break }
        'DropForSpot' { 'Drop because Spot VMs cannot use availability sets'; break }
        default { 'None' }
    }
    Write-Host ("Availability set: {0}" -f $availabilitySetSummary)
    Write-Host ("Pin private IPs:  {0}" -f $Plan.decisions.pinPrivateIps)
    Write-Host ("Snapshots:        {0}" -f $Plan.decisions.createSnapshots)
}

function Invoke-Main {
    if ($Help) {
        Show-Usage
        return
    }

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Fail 'Azure CLI was not found. Run this in Azure Cloud Shell or install az.'
    }

    $selectedMode = Select-RunMode
    $account = Select-Subscription
    $target = Select-TargetVm
    $inventory = Get-VmInventory -ResourceGroup $target.resourceGroup -Name $target.name
    Show-InventorySummary -Inventory $inventory

    $resolvedDirection = Select-Direction -Inventory $inventory
    if ($resolvedDirection -eq 'Cancel') {
        Write-Section 'Stopped'
        Write-Host 'No Azure resources were changed.'
        return
    }

    $decisions = Select-Decisions -Inventory $inventory -ResolvedDirection $resolvedDirection
    $plan = New-Plan -Account $account -Inventory $inventory -Decisions $decisions
    $savedPlanPath = Save-Plan -Plan $plan
    Show-DecisionSummary -Plan $plan

    $commands = @(Get-SwitchCommands -Plan $plan)
    Show-CommandPreview -Commands $commands

    if ($selectedMode -eq 'Plan') {
        Write-Section 'Plan only'
        Write-Host 'No changes were made.'
        Write-Host "Saved plan: $savedPlanPath"
        return
    }

    $targetLabel = if ($resolvedDirection -eq 'ToSpot') { 'SPOT' } else { 'REGULAR' }
    Confirm-Exact -Phrase "CONVERT $($plan.source.vm.name) TO $targetLabel"
    Invoke-CommandList -Commands $commands -Execute $true

    Write-Section 'Post-check'
    Invoke-AzText -Arguments @(
        'vm', 'show',
        '-g', $plan.source.vm.resourceGroup,
        '-n', $plan.source.vm.name,
        '--query', '{priority:priority,evictionPolicy:evictionPolicy,vmSize:hardwareProfile.vmSize,availabilitySet:availabilitySet.id,osDisk:storageProfile.osDisk.managedDisk.id,nics:networkProfile.networkInterfaces[].{id:id,primary:primary},tags:tags}',
        '-o', 'json'
    ) -Description 'Reading recreated VM summary.'

    Write-Section 'Done'
    Write-Host "Conversion completed. Saved plan: $savedPlanPath"
}

Invoke-Main
