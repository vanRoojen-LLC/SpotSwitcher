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
Trusted Launch settings, marketplace plan, compatible dedicated host/capacity
reservation placement, license type, boot diagnostics, direct VM locks,
diagnostic settings, maintenance assignments, VM applications, and identities
where Azure CLI can safely reapply them. It also returns stable source power
states: running, stopped, or deallocated.

Default mode is Plan, which performs discovery, writes a plan file, previews the
commands, and then asks whether to execute that just-built plan. Execute mode
requires an exact confirmation unless -Force is supplied for unattended
automation.

The opening menu can also clean up incremental snapshots created by SpotSwitcher.
Cleanup lists matching snapshots first and requires exact confirmation before
deleting them.

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
  -CreateSnapshots Yes `
  -DropAvailabilitySetForSpot No `
  -DropReservedPlacementForSpot No

Run unattended with explicit choices.

.EXAMPLE
./Switch-AzureVmSpotPriority.ps1 -CleanupSnapshots

List snapshots created by SpotSwitcher in the active subscription, then require
exact confirmation before deleting them.
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

    [ValidateRange(0, 4096)]
    [int]$TargetCores = 0,

    [ValidateRange(0, 1048576)]
    [double]$TargetMemoryGB = 0,

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

    [ValidateSet('Auto', 'Yes', 'No')]
    [string]$DropReservedPlacementForSpot = 'Auto',

    [string]$PlanPath,
    [switch]$CleanupSnapshots,

    [ValidateRange(1, 1440)]
    [int]$PowerStateWaitTimeoutMinutes = 30,

    [ValidateRange(5, 300)]
    [int]$PowerStatePollSeconds = 15,

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

Snapshot cleanup:
  ./Switch-AzureVmSpotPriority.ps1 -CleanupSnapshots

Interactive execution:
  ./Switch-AzureVmSpotPriority.ps1 -Mode Execute

Unattended execution:
  ./Switch-AzureVmSpotPriority.ps1 -Mode Execute -NonInteractive -Force `
    -Subscription <sub> -ResourceGroupName <rg> -VmName <vm> `
    -Direction ToSpot -TargetSku <sku> -EvictionPolicy Deallocate -MaxPrice -1 `
    -PinPrivateIps Yes -CreateSnapshots Yes -ValidateSku No `
    -DropAvailabilitySetForSpot No -DropReservedPlacementForSpot No

Interactive SKU selection:
  - If -TargetSku is omitted, the wizard uses the source VM vCPU/RAM shape by
    default before running the slower Azure SKU metadata lookup.
  - Candidate SKUs are filtered to the source VM architecture when Azure reports
    CpuArchitectureType, so x64 VMs are not offered Arm64 sizes and vice versa.
  - Candidate SKUs are also filtered for source VM attachment/platform needs:
    data disks, NIC count, accelerated networking, Premium/Ultra storage,
    encryption at host, OS disk size, Hyper-V generation, and source zone.
  - Use -TargetCores and -TargetMemoryGB to override that exact hardware shape.

Direction is based on the source VM:
  Regular/null priority -> ToSpot
  Spot/Low priority    -> ToRegular

Safety defaults:
  - Plan mode is read-only until you explicitly choose to execute the previewed
    plan and pass the exact confirmation prompt.
  - Snapshot cleanup lists only snapshots with SpotSwitcher markers before
    requiring exact confirmation for deletion.
  - Execute mode sets OS disk, data disks, and NIC deleteOption to Detach.
  - Dynamic private IPs can be pinned to static before wrapper deletion.
  - Incremental snapshots can be created after deallocation.
  - Source VM tags are captured in the saved plan and reapplied to the recreated
    VM. Tags on existing disks and NICs remain on those resources.
  - Stable source power states are restored after recreation: running remains
    running, stopped is stopped, and deallocated is deallocated.
  - Transitional source power states are waited on until the VM reaches a stable
    state. Tune with -PowerStateWaitTimeoutMinutes and -PowerStatePollSeconds.
  - Availability-set membership is preserved for regular VMs, but must be
    intentionally dropped when converting to Spot because Azure does not support
    Spot VMs in availability sets.
  - Dedicated host, host group, or capacity reservation placement is preserved
    for regular VM recreation, but must be intentionally dropped for Spot
    conversion because Spot uses spare capacity rather than reserved placement.
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

function Invoke-AzProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,
        [string]$Description,
        [int]$ProgressIntervalSeconds = 30,
        [switch]$EnableQuietDynamicExtensionInstall
    )

    if ($Description) {
        Write-Info $Description
    }
    Write-Info "Running: $(Format-AzCommand $Arguments)"
    Write-Info "Timeout: $TimeoutSeconds seconds."
    if ($EnableQuietDynamicExtensionInstall) {
        Write-Info 'Azure CLI dynamic extension install is enabled without prompt for this command.'
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'az'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($arg in $Arguments) {
        [void]$psi.ArgumentList.Add($arg)
    }

    if ($EnableQuietDynamicExtensionInstall) {
        $psi.Environment['AZURE_EXTENSION_USE_DYNAMIC_INSTALL'] = 'yes_without_prompt'
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $deadline = [DateTimeOffset]::Now.AddSeconds([math]::Max(1, $TimeoutSeconds))
        $lastProgressAt = [DateTimeOffset]::Now
        $exited = $false
        while ([DateTimeOffset]::Now -lt $deadline) {
            if ($process.WaitForExit(1000)) {
                $exited = $true
                break
            }

            $elapsedSeconds = [int]([DateTimeOffset]::Now - $lastProgressAt).TotalSeconds
            if ($ProgressIntervalSeconds -gt 0 -and $elapsedSeconds -ge $ProgressIntervalSeconds) {
                $totalElapsedSeconds = [int]([DateTimeOffset]::Now - ($deadline.AddSeconds(-1 * [math]::Max(1, $TimeoutSeconds)))).TotalSeconds
                Write-Info "Still waiting on Azure CLI after $totalElapsedSeconds seconds."
                $lastProgressAt = [DateTimeOffset]::Now
            }
        }

        if (-not $exited) {
            try {
                $process.Kill($true)
            }
            catch {
                try {
                    $process.Kill()
                }
                catch {
                    # Best-effort process cleanup before surfacing timeout.
                }
            }
            try {
                [void]$process.WaitForExit(5000)
            }
            catch {
            }

            $partialStdOut = ''
            $partialStdErr = ''
            try {
                $partialStdOut = $stdoutTask.GetAwaiter().GetResult()
            }
            catch {
            }
            try {
                $partialStdErr = $stderrTask.GetAwaiter().GetResult()
            }
            catch {
            }

            $partialText = (($partialStdOut, $partialStdErr) -join "`n").Trim()
            if (-not [string]::IsNullOrWhiteSpace($partialText)) {
                Write-WarningLine "Azure CLI output before timeout:`n$partialText"
            }

            throw "Azure CLI command timed out after $TimeoutSeconds seconds: $(Format-AzCommand $Arguments)"
        }

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowEmpty,
        [int]$TimeoutSeconds = 0,
        [string]$Description,
        [switch]$EnableQuietDynamicExtensionInstall
    )

    if ($TimeoutSeconds -gt 0) {
        $result = Invoke-AzProcessWithTimeout -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds -Description $Description -EnableQuietDynamicExtensionInstall:$EnableQuietDynamicExtensionInstall
        $exitCode = $result.ExitCode
        $text = ([string]$result.StdOut).Trim()
        $diagnosticText = ([string]$result.StdErr).Trim()
    }
    else {
        if ($Description) {
            Write-Info $Description
        }
        $output = & az @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($output | Out-String).Trim()
        $diagnosticText = $text
    }

    if ($exitCode -ne 0) {
        $details = if ([string]::IsNullOrWhiteSpace($diagnosticText)) { $text } else { $diagnosticText }
        throw "Azure CLI command failed: $(Format-AzCommand $Arguments)`n$details"
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        if ($AllowEmpty) {
            return $null
        }
        $details = if ([string]::IsNullOrWhiteSpace($diagnosticText)) { '' } else { "`n$diagnosticText" }
        throw "Azure CLI command returned no JSON: $(Format-AzCommand $Arguments)$details"
    }

    return ($text | ConvertFrom-Json -Depth 100)
}

function Invoke-AzJsonOptional {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$Description,
        [string]$WarningLabel,
        [int]$TimeoutSeconds = 60,
        [switch]$EnableQuietDynamicExtensionInstall
    )

    try {
        $result = Invoke-AzJson `
            -Arguments $Arguments `
            -AllowEmpty `
            -TimeoutSeconds $TimeoutSeconds `
            -Description $Description `
            -EnableQuietDynamicExtensionInstall:$EnableQuietDynamicExtensionInstall
        if ($null -eq $result) {
            return @()
        }

        return @($result)
    }
    catch {
        $label = if ($WarningLabel) { $WarningLabel } else { Format-AzCommand $Arguments }
        Write-WarningLine "$label could not be inventoried automatically: $($_.Exception.Message)"
        return @()
    }
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

function New-AzureResourceName {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Parts,
        [int]$MaxLength = 80
    )

    $raw = ($Parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '-'
    $safe = ($raw -replace '[^A-Za-z0-9_.-]', '-').Trim('-_.')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'spotswitcher-resource'
    }

    if ($safe.Length -le $MaxLength) {
        return $safe
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($safe))
    }
    finally {
        $sha.Dispose()
    }

    $hash = -join ($hashBytes[0..3] | ForEach-Object { $_.ToString('x2') })
    $suffix = "-$hash"
    $prefixLength = [math]::Max(1, $MaxLength - $suffix.Length)
    $prefix = $safe.Substring(0, $prefixLength).Trim('-_.')
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        $prefix = 'spotswitcher'
    }

    return ($prefix + $suffix)
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

    function Complete-Choice {
        param($Option)

        Write-Info ("Selected: {0}" -f $Option.Label)
        if ($Option.WaitDescription) {
            Write-WarningLine $Option.WaitDescription
        }

        return $Option.Value
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
            return (Complete-Choice -Option $Options[$Default - 1])
        }

        $parsed = 0
        if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $Options.Count) {
            return (Complete-Choice -Option $Options[$parsed - 1])
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
        Write-Fail "This operation requires -Force when -NonInteractive is supplied."
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

function Get-TagValue {
    param(
        $Tags,
        [string]$Name
    )

    if ($null -eq $Tags) {
        return $null
    }

    if ($Tags -is [System.Collections.IDictionary]) {
        if ($Tags.Contains($Name)) {
            return [string]$Tags[$Name]
        }
        return $null
    }

    $property = $Tags.PSObject.Properties[$Name]
    if ($property) {
        return [string]$property.Value
    }

    return $null
}

function Test-SpotSwitcherSnapshotName {
    param([string]$Name)

    return ($Name -match '-To(Spot|Regular)-\d{8}-\d{6}(-|$)')
}

function ConvertTo-SpotSwitcherSnapshotRecord {
    param($Snapshot)

    $planId = Get-TagValue -Tags $Snapshot.tags -Name 'spotSwitcherPlanId'
    $sourceVm = Get-TagValue -Tags $Snapshot.tags -Name 'sourceVm'
    $sourceResourceGroup = Get-TagValue -Tags $Snapshot.tags -Name 'sourceResourceGroup'
    $hasSpotSwitcherTags = (
        -not [string]::IsNullOrWhiteSpace($planId) -and
        -not [string]::IsNullOrWhiteSpace($sourceVm) -and
        -not [string]::IsNullOrWhiteSpace($sourceResourceGroup)
    )

    if (-not $hasSpotSwitcherTags) {
        return $null
    }

    $nameMatches = Test-SpotSwitcherSnapshotName -Name $Snapshot.name
    $diskSizeGb = $Snapshot.diskSizeGb
    if ($null -eq $diskSizeGb) {
        $diskSizeGb = $Snapshot.diskSizeGB
    }

    return [pscustomobject]@{
        id                  = $Snapshot.id
        name                = $Snapshot.name
        resourceGroup       = $Snapshot.resourceGroup
        location            = $Snapshot.location
        timeCreated         = $Snapshot.timeCreated
        diskSizeGb          = $diskSizeGb
        incremental         = $Snapshot.incremental
        sourceVm            = $sourceVm
        sourceResourceGroup = $sourceResourceGroup
        spotSwitcherPlanId  = $planId
        nameMatchesPattern  = [bool]$nameMatches
    }
}

function Get-SpotSwitcherSnapshotCleanupInventory {
    Write-Info 'Reading Azure snapshots in the active subscription.'
    Write-Info 'SpotSwitcher will only delete snapshots carrying its snapshot tags.'

    $snapshots = @(Invoke-AzJson `
            -Arguments @(
                'snapshot', 'list',
                '--query', '[].{id:id,name:name,resourceGroup:resourceGroup,location:location,timeCreated:timeCreated,diskSizeGb:diskSizeGb,incremental:incremental,tags:tags}',
                '-o', 'json'
            ) `
            -Description 'Snapshot lookup can take 10-60 seconds in subscriptions with many snapshots.' `
            -TimeoutSeconds 120)

    $deleteCandidates = @()
    $nameOnlyCandidates = @()
    foreach ($snapshot in $snapshots) {
        $record = ConvertTo-SpotSwitcherSnapshotRecord -Snapshot $snapshot
        if ($record) {
            $deleteCandidates += $record
            continue
        }

        if (Test-SpotSwitcherSnapshotName -Name $snapshot.name) {
            $nameOnlyCandidates += [pscustomobject]@{
                name          = $snapshot.name
                resourceGroup = $snapshot.resourceGroup
                location      = $snapshot.location
                timeCreated   = $snapshot.timeCreated
            }
        }
    }

    return [pscustomobject]@{
        deleteCandidates   = @($deleteCandidates | Sort-Object sourceResourceGroup, sourceVm, spotSwitcherPlanId, name)
        nameOnlyCandidates = @($nameOnlyCandidates | Sort-Object resourceGroup, name)
    }
}

function Show-SpotSwitcherSnapshotList {
    param(
        [object[]]$Snapshots,
        [object[]]$NameOnlyCandidates
    )

    Write-Section 'Snapshots to delete'
    if ($Snapshots.Count -eq 0) {
        Write-Host 'No snapshots with SpotSwitcher cleanup tags were found.'
    }
    else {
        Write-Host ("SpotSwitcher found {0} tagged snapshot(s) to delete:" -f $Snapshots.Count) -ForegroundColor White
        foreach ($snapshot in $Snapshots) {
            $created = if ($snapshot.timeCreated) { $snapshot.timeCreated } else { 'unknown created time' }
            $size = if ($null -ne $snapshot.diskSizeGb) { "$($snapshot.diskSizeGb) GiB" } else { 'unknown size' }
            $incremental = if ($null -ne $snapshot.incremental) { $snapshot.incremental } else { 'unknown' }
            $namePatternText = if ($snapshot.nameMatchesPattern) { 'name matches SpotSwitcher pattern' } else { 'tag match only' }

            Write-Host ''
            Write-Host ("  - {0}" -f $snapshot.name) -ForegroundColor White
            Write-Host ("    Resource group: {0}; location: {1}; created: {2}" -f $snapshot.resourceGroup, $snapshot.location, $created) -ForegroundColor Gray
            Write-Host ("    Source VM: {0}/{1}; plan: {2}" -f $snapshot.sourceResourceGroup, $snapshot.sourceVm, $snapshot.spotSwitcherPlanId) -ForegroundColor Gray
            Write-Host ("    Snapshot: {0}; incremental: {1}; match: {2}" -f $size, $incremental, $namePatternText) -ForegroundColor Gray
        }
    }

    if ($NameOnlyCandidates.Count -gt 0) {
        Write-Section 'Name-only matches skipped'
        Write-WarningLine ("Found {0} snapshot name(s) that look like SpotSwitcher output but are missing the required SpotSwitcher tags." -f $NameOnlyCandidates.Count)
        Write-Host 'They will not be deleted automatically. Review them manually if you expected older untagged snapshots.' -ForegroundColor Gray
        foreach ($snapshot in $NameOnlyCandidates) {
            Write-Host ("  - {0}/{1} ({2}, {3})" -f $snapshot.resourceGroup, $snapshot.name, $snapshot.location, $snapshot.timeCreated) -ForegroundColor Gray
        }
    }
}

function Invoke-SpotSwitcherSnapshotCleanup {
    param($Account)

    Write-Section 'SpotSwitcher snapshot cleanup'
    Write-Host ("Subscription: {0} ({1})" -f $Account.name, $Account.id)
    Write-WarningLine 'Cleanup deletes only snapshots tagged with sourceVm, sourceResourceGroup, and spotSwitcherPlanId.'

    $inventory = Get-SpotSwitcherSnapshotCleanupInventory
    $snapshots = @($inventory.deleteCandidates)
    $nameOnlyCandidates = @($inventory.nameOnlyCandidates)
    Show-SpotSwitcherSnapshotList -Snapshots $snapshots -NameOnlyCandidates $nameOnlyCandidates

    if ($snapshots.Count -eq 0) {
        Write-Section 'Cleanup complete'
        Write-Host 'No Azure resources were changed.'
        return
    }

    Confirm-Exact -Phrase "DELETE $($snapshots.Count) SPOTSWITCHER SNAPSHOTS"

    $commands = foreach ($snapshot in $snapshots) {
        New-AzCommand -Description "Delete snapshot $($snapshot.resourceGroup)/$($snapshot.name)." -Arguments @(
            'snapshot', 'delete',
            '--ids', $snapshot.id
        )
    }

    Invoke-CommandList -Commands @($commands) -Execute $true

    Write-Section 'Cleanup complete'
    Write-Host ("Deleted {0} SpotSwitcher snapshot(s)." -f $snapshots.Count)
}

function Get-ResourceGroupFromId {
    param([string]$Id)

    if ($Id -match '/resourceGroups/([^/]+)/') {
        return $Matches[1]
    }

    return $null
}

function Get-SubscriptionIdFromId {
    param([string]$Id)

    if ($Id -match '/subscriptions/([^/]+)/') {
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

function ConvertTo-TagPairs {
    param($Tags)

    $pairs = @()
    if ($null -eq $Tags) {
        return $pairs
    }

    if ($Tags -is [System.Collections.IDictionary]) {
        foreach ($key in @($Tags.Keys | Sort-Object)) {
            if ($null -ne $Tags[$key]) {
                $pairs += [pscustomobject]@{
                    Name  = [string]$key
                    Value = [string]$Tags[$key]
                }
            }
        }
        return $pairs
    }

    foreach ($prop in @($Tags.PSObject.Properties | Sort-Object Name)) {
        if ($null -ne $prop.Value) {
            $pairs += [pscustomobject]@{
                Name  = [string]$prop.Name
                Value = [string]$prop.Value
            }
        }
    }

    return $pairs
}

function ConvertTo-TagObject {
    param($Tags)

    $tagObject = [ordered]@{}
    foreach ($tag in @(ConvertTo-TagPairs -Tags $Tags)) {
        $tagObject[$tag.Name] = $tag.Value
    }

    return [pscustomobject]$tagObject
}

function Get-PlanSourceTags {
    param($Plan)

    if ($Plan.source -is [System.Collections.IDictionary] -and $Plan.source.Contains('tags')) {
        return $Plan.source['tags']
    }

    if ($Plan.source.PSObject.Properties['tags']) {
        return $Plan.source.tags
    }

    return $Plan.source.vm.tags
}

function Get-TagsAsArguments {
    param($Tags)

    $tagArgs = @()
    foreach ($tag in @(ConvertTo-TagPairs -Tags $Tags)) {
        $tagArgs += "$($tag.Name)=$($tag.Value)"
    }

    return $tagArgs
}

function ConvertTo-CompactJsonArrayArgument {
    param($Value)

    $items = @($Value)
    if ($items.Count -eq 0) {
        return '[]'
    }

    $jsonItems = foreach ($item in $items) {
        $item | ConvertTo-Json -Depth 100 -Compress
    }

    return '[' + ($jsonItems -join ',') + ']'
}

function ConvertTo-NormalizedResourceId {
    param([string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return ''
    }

    return $Id.TrimEnd('/').ToLowerInvariant()
}

function Get-DirectScopeLocks {
    param(
        [object[]]$Locks,
        [string]$ScopeId
    )

    $normalizedScope = ConvertTo-NormalizedResourceId -Id $ScopeId
    if ([string]::IsNullOrWhiteSpace($normalizedScope)) {
        return @()
    }

    $directPrefix = "$normalizedScope/providers/microsoft.authorization/locks/"
    return @($Locks | Where-Object {
            $lockId = ConvertTo-NormalizedResourceId -Id $_.id
            $lockId.StartsWith($directPrefix)
        })
}

function Get-PlanSourceCollection {
    param(
        $Plan,
        [string]$Name
    )

    if ($Plan.source -is [System.Collections.IDictionary] -and $Plan.source.Contains($Name)) {
        return @($Plan.source[$Name])
    }

    if ($Plan.source.PSObject.Properties[$Name]) {
        return @($Plan.source.$Name)
    }

    return @()
}

function ConvertTo-IntOrNull {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $parsed = 0
    if ([int]::TryParse(([string]$Value), [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function Get-EffectivePriority {
    param($Vm)

    if ($Vm.priority) {
        return [string]$Vm.priority
    }

    return 'Regular'
}

function Get-VmPowerStateStatus {
    param($InstanceView)

    return (@($InstanceView.instanceView.statuses) | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1)
}

function Get-VmPowerStateCode {
    param($InstanceView)

    $status = Get-VmPowerStateStatus -InstanceView $InstanceView
    if ($status -and $status.code) {
        return [string]$status.code
    }

    return 'PowerState/unknown'
}

function Get-VmPowerStateDisplay {
    param($InstanceView)

    $status = Get-VmPowerStateStatus -InstanceView $InstanceView
    if ($status -and $status.displayStatus) {
        return [string]$status.displayStatus
    }

    return (Get-VmPowerStateCode -InstanceView $InstanceView)
}

function Test-StableVmPowerState {
    param([string]$PowerStateCode)

    return @('PowerState/running', 'PowerState/stopped', 'PowerState/deallocated') -contains $PowerStateCode
}

function Wait-ForStableSourcePowerState {
    param($Inventory)

    $powerStateCode = Get-VmPowerStateCode -InstanceView $Inventory.instanceView
    if (Test-StableVmPowerState -PowerStateCode $powerStateCode) {
        return $Inventory
    }

    $vm = $Inventory.vm
    $deadline = [DateTimeOffset]::Now.AddMinutes($PowerStateWaitTimeoutMinutes)

    Write-Section 'Power state wait'
    Write-WarningLine "Source VM power state is '$powerStateCode'. SpotSwitcher will wait for running, stopped, or deallocated before planning conversion."
    Write-Info "Timeout: $PowerStateWaitTimeoutMinutes minute(s). Poll interval: $PowerStatePollSeconds second(s)."

    while ([DateTimeOffset]::Now -lt $deadline) {
        $display = Get-VmPowerStateDisplay -InstanceView $Inventory.instanceView
        $code = Get-VmPowerStateCode -InstanceView $Inventory.instanceView
        Write-Info "Current power state: $display ($code). Checking again in $PowerStatePollSeconds seconds."
        Start-Sleep -Seconds $PowerStatePollSeconds

        $Inventory.instanceView = Invoke-AzJson `
            -Arguments @('vm', 'get-instance-view', '-g', $vm.resourceGroup, '-n', $vm.name, '-o', 'json') `
            -Description 'Checking current VM power state.'

        $powerStateCode = Get-VmPowerStateCode -InstanceView $Inventory.instanceView
        if (Test-StableVmPowerState -PowerStateCode $powerStateCode) {
            $display = Get-VmPowerStateDisplay -InstanceView $Inventory.instanceView
            Write-Info "Source VM reached stable power state: $display ($powerStateCode)."
            return $Inventory
        }
    }

    $finalCode = Get-VmPowerStateCode -InstanceView $Inventory.instanceView
    Write-Fail "Timed out after $PowerStateWaitTimeoutMinutes minute(s) waiting for source VM to reach running, stopped, or deallocated. Last power state: '$finalCode'."
}

function Get-PowerStateRestoreSummary {
    param([string]$PowerStateCode)

    switch ($PowerStateCode) {
        'PowerState/running' { return 'recreated VM remains running after az vm create' }
        'PowerState/stopped' { return 'az vm stop after recreation' }
        'PowerState/deallocated' { return 'az vm deallocate after recreation' }
        default { return 'unsupported source power state' }
    }
}

function Get-SkuCapabilityValue {
    param(
        $Sku,
        [string]$Name
    )

    if ($Name -eq 'Family') {
        $familyProperty = $Sku.PSObject.Properties['family']
        if ($familyProperty -and -not [string]::IsNullOrWhiteSpace([string]$familyProperty.Value)) {
            return [string]$familyProperty.Value
        }
    }

    $capability = @($Sku.capabilities | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
    if ($capability.Count -gt 0) {
        return $capability[0].value
    }

    return $null
}

function Get-QuotaText {
    param($Usage)

    $parts = @()
    if ($Usage.name -and $Usage.name.value) {
        $parts += [string]$Usage.name.value
    }
    if ($Usage.name -and $Usage.name.localizedValue) {
        $parts += [string]$Usage.name.localizedValue
    }
    if ($Usage.properties -and $Usage.properties.name -and $Usage.properties.name.value) {
        $parts += [string]$Usage.properties.name.value
    }
    if ($Usage.properties -and $Usage.properties.name -and $Usage.properties.name.localizedValue) {
        $parts += [string]$Usage.properties.name.localizedValue
    }
    if ($Usage.resourceName) {
        $parts += [string]$Usage.resourceName
    }

    return ($parts -join ' ')
}

function Get-NormalizedQuotaText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    return ($Text.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Test-QuotaTextIsSpot {
    param([string]$NormalizedText)

    return ($NormalizedText -match 'spot' -or $NormalizedText -match 'lowpriority')
}

function Get-FirstObjectValue {
    param(
        $Object,
        [string[]]$Paths
    )

    foreach ($path in $Paths) {
        $current = $Object
        $found = $true
        foreach ($part in ($path -split '\.')) {
            if ($null -eq $current) {
                $found = $false
                break
            }

            $property = $current.PSObject.Properties[$part]
            if ($null -eq $property) {
                $found = $false
                break
            }

            $current = $property.Value
        }

        if ($found -and $null -ne $current) {
            return $current
        }
    }

    return $null
}

function Expand-ResultItems {
    param($Result)

    $items = @()
    foreach ($item in @($Result)) {
        $valueProperty = $item.PSObject.Properties['value']
        if ($valueProperty -and $null -ne $valueProperty.Value -and $valueProperty.Value -isnot [string]) {
            $items += @($valueProperty.Value)
        }
        else {
            $items += $item
        }
    }

    return $items
}

function Get-QuotaResourceName {
    param($Item)

    $value = Get-FirstObjectValue -Object $Item -Paths @(
        'name.value',
        'properties.name.value',
        'resourceName',
        'name'
    )

    if ($null -eq $value) {
        return $null
    }

    return [string]$value
}

function Get-QuotaLocalizedName {
    param($Item)

    $value = Get-FirstObjectValue -Object $Item -Paths @(
        'name.localizedValue',
        'properties.name.localizedValue',
        'localizedName',
        'displayName'
    )

    if ($null -eq $value) {
        return $null
    }

    return [string]$value
}

function Get-QuotaCurrentValue {
    param($Item)

    return ConvertTo-IntOrNull -Value (Get-FirstObjectValue -Object $Item -Paths @(
            'currentValue',
            'properties.currentValue',
            'properties.usage.value',
            'properties.usages.value',
            'usage.value',
            'usages.value'
        ))
}

function Get-QuotaLimitValue {
    param($Item)

    return ConvertTo-IntOrNull -Value (Get-FirstObjectValue -Object $Item -Paths @(
            'limit',
            'properties.limit.value',
            'properties.limit',
            'limit.value'
        ))
}

function New-QuotaUsageRecord {
    param(
        [string]$Name,
        [string]$LocalizedName,
        [int]$CurrentValue,
        [int]$Limit,
        [string]$Source
    )

    [pscustomobject]@{
        name         = [pscustomobject]@{
            value          = $Name
            localizedValue = $LocalizedName
        }
        currentValue = $CurrentValue
        limit        = $Limit
        source       = $Source
    }
}

function Convert-QuotaExtensionUsage {
    param(
        $UsageResult,
        $LimitResult
    )

    $usageItems = @(Expand-ResultItems -Result $UsageResult)
    $limitItems = @(Expand-ResultItems -Result $LimitResult)
    $limitsByName = @{}

    foreach ($limitItem in $limitItems) {
        $name = Get-QuotaResourceName -Item $limitItem
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $limitsByName[(Get-NormalizedQuotaText -Text $name)] = $limitItem
    }

    $records = @()
    foreach ($usageItem in $usageItems) {
        $name = Get-QuotaResourceName -Item $usageItem
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $normalizedName = Get-NormalizedQuotaText -Text $name
        $limitItem = $limitsByName[$normalizedName]
        $currentValue = Get-QuotaCurrentValue -Item $usageItem
        $limitValue = Get-QuotaLimitValue -Item $usageItem
        if ($null -eq $limitValue -and $limitItem) {
            $limitValue = Get-QuotaLimitValue -Item $limitItem
        }

        if ($null -eq $currentValue -or $null -eq $limitValue) {
            continue
        }

        $localizedName = Get-QuotaLocalizedName -Item $usageItem
        if ([string]::IsNullOrWhiteSpace($localizedName) -and $limitItem) {
            $localizedName = Get-QuotaLocalizedName -Item $limitItem
        }

        $records += New-QuotaUsageRecord -Name $name -LocalizedName $localizedName -CurrentValue $currentValue -Limit $limitValue -Source 'QuotaApi'
    }

    return $records
}

function Convert-ComputeUsage {
    param($UsageResult)

    $records = @()
    foreach ($usageItem in @(Expand-ResultItems -Result $UsageResult)) {
        $name = Get-QuotaResourceName -Item $usageItem
        $currentValue = Get-QuotaCurrentValue -Item $usageItem
        $limitValue = Get-QuotaLimitValue -Item $usageItem
        if ([string]::IsNullOrWhiteSpace($name) -or $null -eq $currentValue -or $null -eq $limitValue) {
            continue
        }

        $records += New-QuotaUsageRecord -Name $name -LocalizedName (Get-QuotaLocalizedName -Item $usageItem) -CurrentValue $currentValue -Limit $limitValue -Source 'ComputeUsageApi'
    }

    return $records
}

function Find-QuotaUsage {
    param(
        [object[]]$Usages,
        [string]$Family,
        [switch]$Regional,
        [switch]$Spot
    )

    $normalizedFamily = Get-NormalizedQuotaText -Text $Family
    foreach ($usage in @($Usages)) {
        $normalized = Get-NormalizedQuotaText -Text (Get-QuotaText -Usage $usage)
        if ($normalized -notmatch 'vcpu|cores') {
            continue
        }

        $isSpotQuota = Test-QuotaTextIsSpot -NormalizedText $normalized
        if ($Spot -and -not $isSpotQuota) {
            continue
        }

        if (-not $Spot -and $isSpotQuota) {
            continue
        }

        if ($Regional) {
            if ($normalized -match 'totalregional' -or ($normalized -match 'regional' -and $normalized -match 'total')) {
                return $usage
            }
            continue
        }

        if ($normalizedFamily -and $normalized -like "*$normalizedFamily*") {
            return $usage
        }
    }

    return $null
}

function Get-RemainingQuota {
    param(
        $Usage,
        [int]$Credit = 0
    )

    if ($null -eq $Usage) {
        return $null
    }

    $limit = ConvertTo-IntOrNull -Value $Usage.limit
    $current = ConvertTo-IntOrNull -Value $Usage.currentValue
    if ($null -eq $limit -or $null -eq $current) {
        return $null
    }

    if ($limit -lt 0) {
        return [int]::MaxValue
    }

    return [math]::Max(0, ($limit - $current + $Credit))
}

function Get-QuotaUsage {
    param(
        [string]$Location,
        [string]$SubscriptionId
    )

    Write-Info "Reading regional quota usage for $Location."
    $quotaApiTimeoutSeconds = 45
    $legacyQuotaTimeoutSeconds = 30
    Write-WarningLine "Quota lookup is read-only. SpotSwitcher gives the Azure Quota API $quotaApiTimeoutSeconds seconds before falling back to legacy compute usage."
    Write-WarningLine 'If this is the first quota run in Cloud Shell, Azure CLI may install the quota extension non-interactively.'
    $records = @()

    if ($SubscriptionId) {
        $scope = "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location"
        try {
            $usageResult = Invoke-AzJson -Arguments @('quota', 'usage', 'list', '--scope', $scope, '-o', 'json') -TimeoutSeconds $quotaApiTimeoutSeconds -Description 'Quota API step 1 of 2: reading current quota usage.' -EnableQuietDynamicExtensionInstall
            $limitResult = Invoke-AzJson -Arguments @('quota', 'list', '--scope', $scope, '-o', 'json') -TimeoutSeconds $quotaApiTimeoutSeconds -Description 'Quota API step 2 of 2: reading quota limits.' -EnableQuietDynamicExtensionInstall
            $records = @(Convert-QuotaExtensionUsage -UsageResult $usageResult -LimitResult $limitResult)
            if ($records.Count -gt 0) {
                Write-Info "Quota API returned $($records.Count) compute quota rows."
                return $records
            }

            Write-WarningLine 'Quota API returned no parseable compute quota rows; falling back to legacy compute usage.'
        }
        catch {
            Write-WarningLine "Quota API lookup failed; falling back to legacy compute usage. $($_.Exception.Message)"
        }
    }
    else {
        Write-WarningLine 'Could not infer subscription id from the VM resource id; falling back to legacy compute usage.'
    }

    try {
        Write-WarningLine "Trying legacy compute usage with a $legacyQuotaTimeoutSeconds second timeout."
        $legacyUsage = Invoke-AzJson -Arguments @('vm', 'list-usage', '--location', $Location, '-o', 'json') -TimeoutSeconds $legacyQuotaTimeoutSeconds -Description 'Legacy quota fallback: reading compute usage.'
        $records = @(Convert-ComputeUsage -UsageResult $legacyUsage)
        if ($records.Count -gt 0) {
            Write-WarningLine 'Legacy compute usage usually reports regional/family vCPU quota but may not expose Spot quota.'
            return $records
        }

        Write-WarningLine 'Legacy compute usage returned no parseable quota rows.'
        return @()
    }
    catch {
        Write-WarningLine "Quota lookup failed; SKU options will remain visible with quota marked unknown. $($_.Exception.Message)"
        return @()
    }
}

function Test-SkuQuota {
    param(
        $Sku,
        [object[]]$Usages,
        [string]$ResolvedDirection,
        $SourceSku,
        $SourceVm
    )

    $vcpus = ConvertTo-IntOrNull -Value (Get-SkuCapabilityValue -Sku $Sku -Name 'vCPUs')
    $family = [string](Get-SkuCapabilityValue -Sku $Sku -Name 'Family')
    $sourceVcpus = ConvertTo-IntOrNull -Value (Get-SkuCapabilityValue -Sku $SourceSku -Name 'vCPUs')
    $sourceFamily = [string](Get-SkuCapabilityValue -Sku $SourceSku -Name 'Family')
    $sourcePriority = Get-EffectivePriority -Vm $SourceVm
    $details = @()
    $unknown = $false

    if ($null -eq $vcpus) {
        return [pscustomobject]@{
            Allowed     = $true
            Unknown     = $true
            Description = 'Quota unknown: SKU vCPU count was not reported.'
        }
    }

    if ($ResolvedDirection -eq 'ToSpot') {
        $spotRegionalUsage = Find-QuotaUsage -Usages $Usages -Regional -Spot
        $spotRemaining = Get-RemainingQuota -Usage $spotRegionalUsage
        if ($null -eq $spotRemaining) {
            $unknown = $true
            $details += 'Spot regional quota unknown'
        }
        elseif ($spotRemaining -lt $vcpus) {
            return [pscustomobject]@{
                Allowed     = $false
                Unknown     = $false
                Description = "Needs $vcpus vCPUs; Spot regional quota has $spotRemaining remaining."
            }
        }
        else {
            $details += "Spot regional quota has $spotRemaining remaining"
        }
    }
    else {
        $regionalUsage = Find-QuotaUsage -Usages $Usages -Regional
        $regionalRemaining = Get-RemainingQuota -Usage $regionalUsage
        if ($null -eq $regionalRemaining) {
            $unknown = $true
            $details += 'Regional vCPU quota unknown'
        }
        elseif ($regionalRemaining -lt $vcpus) {
            return [pscustomobject]@{
                Allowed     = $false
                Unknown     = $false
                Description = "Needs $vcpus vCPUs; regional quota has $regionalRemaining remaining."
            }
        }
        else {
            $details += "Regional quota has $regionalRemaining remaining"
        }
    }

    if ([string]::IsNullOrWhiteSpace($family)) {
        $unknown = $true
        $details += 'family quota unknown'
    }
    else {
        $familyUsage = if ($ResolvedDirection -eq 'ToSpot') {
            $spotFamilyUsage = Find-QuotaUsage -Usages $Usages -Family $family -Spot
            if ($spotFamilyUsage) {
                $spotFamilyUsage
            }
            else {
                Find-QuotaUsage -Usages $Usages -Family $family
            }
        }
        else {
            Find-QuotaUsage -Usages $Usages -Family $family
        }

        $credit = 0
        if ($ResolvedDirection -eq 'ToSpot' -and $sourcePriority -notin @('Spot', 'Low') -and $sourceFamily -eq $family -and $null -ne $sourceVcpus) {
            $credit = $sourceVcpus
        }

        $familyRemaining = Get-RemainingQuota -Usage $familyUsage -Credit $credit
        if ($null -eq $familyRemaining) {
            $unknown = $true
            $details += "$family quota unknown"
        }
        elseif ($familyRemaining -lt $vcpus) {
            return [pscustomobject]@{
                Allowed     = $false
                Unknown     = $false
                Description = "Needs $vcpus vCPUs; $family quota has $familyRemaining remaining."
            }
        }
        else {
            $details += "$family quota has $familyRemaining remaining"
        }
    }

    return [pscustomobject]@{
        Allowed     = $true
        Unknown     = $unknown
        Description = "vCPUs=$vcpus; " + ($details -join '; ')
    }
}

function Test-SkuUnrestricted {
    param(
        $Sku,
        $SourceVm
    )

    foreach ($restriction in @($Sku.restrictions)) {
        $restrictionType = [string]$restriction.type
        if ($restrictionType -eq 'Zone') {
            $sourceZones = @($SourceVm.zones | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            if ($sourceZones.Count -eq 0) {
                continue
            }

            $restrictedZones = @($restriction.restrictionInfo.zones | ForEach-Object { [string]$_ })
            if ($restrictedZones.Count -gt 0 -and @($sourceZones | Where-Object { $restrictedZones -contains [string]$_ }).Count -eq 0) {
                continue
            }
        }

        return $false
    }

    return $true
}

function Test-SkuMatchesDirection {
    param(
        $Sku,
        [string]$ResolvedDirection
    )

    if ($ResolvedDirection -ne 'ToSpot') {
        return $true
    }

    return (Get-SkuCapabilityValue -Sku $Sku -Name 'LowPriorityCapable') -eq 'True'
}

function Get-SkuArchitecture {
    param($Sku)

    $architecture = [string](Get-SkuCapabilityValue -Sku $Sku -Name 'CpuArchitectureType')
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        return $null
    }

    if ($architecture -match '^arm') {
        return 'Arm64'
    }

    if ($architecture -match '^(x64|amd64)$') {
        return 'x64'
    }

    return $architecture
}

function Get-SkuBoolCapability {
    param(
        $Sku,
        [string]$Name
    )

    $value = [string](Get-SkuCapabilityValue -Sku $Sku -Name $Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return ($value -eq 'True')
}

function Test-SkuSupportsHyperVGeneration {
    param(
        $Sku,
        [string]$Generation
    )

    if ([string]::IsNullOrWhiteSpace($Generation)) {
        return $true
    }

    $supported = [string](Get-SkuCapabilityValue -Sku $Sku -Name 'HyperVGenerations')
    if ([string]::IsNullOrWhiteSpace($supported)) {
        return $true
    }

    return (@($supported -split ',' | ForEach-Object { $_.Trim() }) -contains $Generation)
}

function ConvertTo-DoubleOrNull {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $parsed = 0.0
    if ([double]::TryParse(([string]$Value), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function Get-SkuSimilarityScore {
    param(
        $Sku,
        $SourceSku
    )

    $family = [string](Get-SkuCapabilityValue -Sku $Sku -Name 'Family')
    $sourceFamily = [string](Get-SkuCapabilityValue -Sku $SourceSku -Name 'Family')
    $vcpus = ConvertTo-IntOrNull -Value (Get-SkuCapabilityValue -Sku $Sku -Name 'vCPUs')
    $sourceVcpus = ConvertTo-IntOrNull -Value (Get-SkuCapabilityValue -Sku $SourceSku -Name 'vCPUs')
    $memory = ConvertTo-DoubleOrNull -Value (Get-SkuCapabilityValue -Sku $Sku -Name 'MemoryGB')
    $sourceMemory = ConvertTo-DoubleOrNull -Value (Get-SkuCapabilityValue -Sku $SourceSku -Name 'MemoryGB')

    $score = 0.0
    if ($family -ne $sourceFamily) {
        $score += 1000000
    }

    if ($null -ne $vcpus -and $null -ne $sourceVcpus) {
        $score += ([math]::Abs($vcpus - $sourceVcpus) * 1000)
    }
    else {
        $score += 100000
    }

    if ($null -ne $memory -and $null -ne $sourceMemory) {
        $score += ([math]::Abs($memory - $sourceMemory) * 10)
    }
    else {
        $score += 10000
    }

    return $score
}

function Format-MemoryGB {
    param([double]$MemoryGB)

    return $MemoryGB.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Convert-MemoryMBToGB {
    param($MemoryMB)

    $memory = ConvertTo-IntOrNull -Value $MemoryMB
    if ($null -eq $memory) {
        return $null
    }

    return [math]::Round(($memory / 1024.0), 2)
}

function Convert-MemoryGBToMB {
    param([double]$MemoryGB)

    return [int][math]::Round(($MemoryGB * 1024), 0)
}

function Get-RegionalVmSizes {
    param([string]$Location)

    Write-Info 'Reading Azure VM size list for exact CPU/RAM matching.'
    Write-WarningLine 'This lightweight lookup narrows candidate names before the slower SKU metadata call.'
    return @(Invoke-AzJson -Arguments @(
            'vm', 'list-sizes',
            '--location', $Location,
            '-o', 'json'
        ) -TimeoutSeconds 30 -Description 'Reading VM sizes for the selected region.')
}

function Read-TargetHardwareShape {
    param(
        [string]$CurrentSize,
        $SourceSize
    )

    $defaultCores = ConvertTo-IntOrNull -Value $SourceSize.numberOfCores
    $defaultMemoryGB = Convert-MemoryMBToGB -MemoryMB $SourceSize.memoryInMB
    $usingOverride = ($TargetCores -gt 0 -or $TargetMemoryGB -gt 0)

    if ($TargetCores -gt 0) {
        $cores = $TargetCores
    }
    elseif ($null -ne $defaultCores) {
        $cores = $defaultCores
    }
    else {
        if ($NonInteractive) {
            Write-Fail 'TargetCores is required in non-interactive mode when the source VM size is not in az vm list-sizes.'
        }

        while ($true) {
            $prompt = if ($null -ne $defaultCores) { "Target vCPU count [default $defaultCores]" } else { 'Target vCPU count' }
            $answer = Read-Host $prompt
            if ([string]::IsNullOrWhiteSpace($answer) -and $null -ne $defaultCores) {
                $cores = $defaultCores
                break
            }

            $parsed = 0
            if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -gt 0) {
                $cores = $parsed
                break
            }

            Write-WarningLine 'Enter a whole-number vCPU count, for example 2 or 4.'
        }
    }

    if ($TargetMemoryGB -gt 0) {
        $memoryGB = $TargetMemoryGB
    }
    elseif ($null -ne $defaultMemoryGB) {
        $memoryGB = $defaultMemoryGB
    }
    else {
        if ($NonInteractive) {
            Write-Fail 'TargetMemoryGB is required in non-interactive mode when the source VM size is not in az vm list-sizes.'
        }

        while ($true) {
            $defaultText = if ($null -ne $defaultMemoryGB) { Format-MemoryGB -MemoryGB $defaultMemoryGB } else { $null }
            $prompt = if ($defaultText) { "Target RAM in GiB [default $defaultText]" } else { 'Target RAM in GiB' }
            $answer = Read-Host $prompt
            if ([string]::IsNullOrWhiteSpace($answer) -and $null -ne $defaultMemoryGB) {
                $memoryGB = $defaultMemoryGB
                break
            }

            $parsed = 0.0
            if ([double]::TryParse($answer, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -gt 0) {
                $memoryGB = $parsed
                break
            }

            Write-WarningLine 'Enter a fixed RAM value in GiB, for example 8 or 16.'
        }
    }

    $memoryText = Format-MemoryGB -MemoryGB $memoryGB
    if ($usingOverride) {
        Write-Info "Target shape override: $cores vCPU / $memoryText GiB RAM."
    }
    else {
        Write-Info "Using source VM shape: $cores vCPU / $memoryText GiB RAM."
    }
    Write-WarningLine 'Only VM sizes with this exact vCPU and RAM shape will be considered before quota/SKU checks.'

    return [pscustomobject]@{
        Cores    = $cores
        MemoryGB = $memoryGB
        MemoryMB = Convert-MemoryGBToMB -MemoryGB $memoryGB
    }
}

function Get-CandidateVmSizeNames {
    param(
        [object[]]$Sizes,
        [int]$Cores,
        [int]$MemoryMB
    )

    return @($Sizes |
        Where-Object {
            (ConvertTo-IntOrNull -Value $_.numberOfCores) -eq $Cores -and
            (ConvertTo-IntOrNull -Value $_.memoryInMB) -eq $MemoryMB
        } |
        Select-Object -ExpandProperty name -Unique |
        Sort-Object)
}

function Get-SkuCatalog {
    param(
        [string]$Location,
        [string[]]$SizeNames
    )

    $query = "[?resourceType=='virtualMachines'].{name:name,family:family,restrictions:restrictions,capabilities:capabilities}"
    $description = 'Reading Azure VM SKU catalog for the selected region.'
    if ($SizeNames -and $SizeNames.Count -gt 0) {
        $uniqueNames = @($SizeNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $nameJson = ConvertTo-Json @($uniqueNames) -Compress
        $tick = [char]96
        $query = "[?resourceType=='virtualMachines' && contains($tick$nameJson$tick, name)].{name:name,family:family,restrictions:restrictions,capabilities:capabilities}"
        $description = "Reading Azure VM SKU metadata for $($uniqueNames.Count) exact CPU/RAM candidate size name(s)."
    }

    Write-Info $description
    Write-WarningLine 'The SKU metadata lookup is the slower Azure call. SpotSwitcher will print progress every 30 seconds if Azure CLI stalls.'
    return @(Invoke-AzJson -Arguments @(
            'vm', 'list-skus',
            '--location', $Location,
            '--resource-type', 'virtualMachines',
            '--all',
            '--query', $query,
            '-o', 'json'
        ) -TimeoutSeconds 180 -Description $description)
}

function Test-DiskUsesPremiumStorage {
    param($Disk)

    if (-not $Disk -or -not $Disk.sku -or [string]::IsNullOrWhiteSpace([string]$Disk.sku.name)) {
        return $false
    }

    return ([string]$Disk.sku.name) -match '^Premium'
}

function Test-DiskUsesUltraStorage {
    param($Disk)

    if (-not $Disk -or -not $Disk.sku -or [string]::IsNullOrWhiteSpace([string]$Disk.sku.name)) {
        return $false
    }

    return ([string]$Disk.sku.name) -match '^Ultra'
}

function Get-SourceSkuRequirements {
    param(
        $Inventory,
        $SourceSku
    )

    $vm = $Inventory.vm
    $osDisk = $Inventory.osDisk
    $dataDisks = @($Inventory.dataDisks)
    $nics = @($Inventory.nics)
    $dataDiskRefs = @($vm.storageProfile.dataDisks)
    $nicRefs = @($vm.networkProfile.networkInterfaces)

    $osDiskSizeGB = ConvertTo-IntOrNull -Value $osDisk.diskSizeGB
    $osDiskSizeMB = if ($null -ne $osDiskSizeGB) { $osDiskSizeGB * 1024 } else { $null }
    $hyperVGeneration = if ($osDisk -and $osDisk.hyperVGeneration) { [string]$osDisk.hyperVGeneration } else { $null }
    if ([string]::IsNullOrWhiteSpace($hyperVGeneration) -and $vm.securityProfile -and $vm.securityProfile.securityType -eq 'TrustedLaunch') {
        $hyperVGeneration = 'V2'
    }

    $usesPremiumStorage = (Test-DiskUsesPremiumStorage -Disk $osDisk)
    $usesUltraStorage = ($vm.additionalCapabilities -and $vm.additionalCapabilities.ultraSsdEnabled -eq $true)
    foreach ($disk in $dataDisks) {
        if (Test-DiskUsesPremiumStorage -Disk $disk) {
            $usesPremiumStorage = $true
        }
        if (Test-DiskUsesUltraStorage -Disk $disk) {
            $usesUltraStorage = $true
        }
    }

    [pscustomobject]@{
        Architecture                  = Get-SkuArchitecture -Sku $SourceSku
        DataDiskCount                 = $dataDiskRefs.Count
        NicCount                      = $nicRefs.Count
        RequiresAcceleratedNetworking = (@($nics | Where-Object { $_.enableAcceleratedNetworking -eq $true }).Count -gt 0)
        RequiresPremiumStorage        = [bool]$usesPremiumStorage
        RequiresUltraStorage          = [bool]$usesUltraStorage
        RequiresEncryptionAtHost      = ($vm.securityProfile -and $vm.securityProfile.encryptionAtHost -eq $true)
        HyperVGeneration              = $hyperVGeneration
        OsDiskSizeMB                  = $osDiskSizeMB
    }
}

function Get-SkuRequirementFailures {
    param(
        $Sku,
        $Requirements
    )

    $failures = @()

    if ($Requirements.Architecture) {
        $candidateArchitecture = Get-SkuArchitecture -Sku $Sku
        if ($candidateArchitecture -and $candidateArchitecture -ne $Requirements.Architecture) {
            $failures += "architecture $candidateArchitecture does not match source $($Requirements.Architecture)"
        }
    }

    $maxDataDiskCount = ConvertTo-IntOrNull -Value (Get-SkuCapabilityValue -Sku $Sku -Name 'MaxDataDiskCount')
    if ($null -ne $maxDataDiskCount -and $maxDataDiskCount -lt $Requirements.DataDiskCount) {
        $failures += "supports $maxDataDiskCount data disk(s), source has $($Requirements.DataDiskCount)"
    }

    $maxNetworkInterfaces = ConvertTo-IntOrNull -Value (Get-SkuCapabilityValue -Sku $Sku -Name 'MaxNetworkInterfaces')
    if ($null -ne $maxNetworkInterfaces -and $maxNetworkInterfaces -lt $Requirements.NicCount) {
        $failures += "supports $maxNetworkInterfaces NIC(s), source has $($Requirements.NicCount)"
    }

    $maxOsVhdSizeMB = ConvertTo-IntOrNull -Value (Get-SkuCapabilityValue -Sku $Sku -Name 'OSVhdSizeMB')
    if ($null -ne $Requirements.OsDiskSizeMB -and $null -ne $maxOsVhdSizeMB -and $maxOsVhdSizeMB -lt $Requirements.OsDiskSizeMB) {
        $failures += "OS disk limit is $maxOsVhdSizeMB MB, source OS disk is $($Requirements.OsDiskSizeMB) MB"
    }

    if ($Requirements.RequiresAcceleratedNetworking -and (Get-SkuBoolCapability -Sku $Sku -Name 'AcceleratedNetworkingEnabled') -eq $false) {
        $failures += 'does not support accelerated networking used by source NICs'
    }

    if ($Requirements.RequiresPremiumStorage -and (Get-SkuBoolCapability -Sku $Sku -Name 'PremiumIO') -eq $false) {
        $failures += 'does not support Premium disk storage used by source disks'
    }

    if ($Requirements.RequiresUltraStorage -and (Get-SkuBoolCapability -Sku $Sku -Name 'UltraSSDAvailable') -eq $false) {
        $failures += 'does not support Ultra SSD used by source disks or VM capabilities'
    }

    if ($Requirements.RequiresEncryptionAtHost -and (Get-SkuBoolCapability -Sku $Sku -Name 'EncryptionAtHostSupported') -eq $false) {
        $failures += 'does not support encryption at host used by source VM'
    }

    if (-not (Test-SkuSupportsHyperVGeneration -Sku $Sku -Generation $Requirements.HyperVGeneration)) {
        $failures += "does not support Hyper-V generation $($Requirements.HyperVGeneration)"
    }

    return $failures
}

function Get-SourceCompatibleSkus {
    param(
        [object[]]$Skus,
        $Requirements
    )

    $compatible = @()
    $failureCounts = @{}
    foreach ($sku in @($Skus)) {
        $failures = @(Get-SkuRequirementFailures -Sku $sku -Requirements $Requirements)
        if ($failures.Count -eq 0) {
            $compatible += $sku
            continue
        }

        foreach ($failure in $failures) {
            if (-not $failureCounts.ContainsKey($failure)) {
                $failureCounts[$failure] = 0
            }
            $failureCounts[$failure]++
        }
    }

    $hiddenCount = @($Skus).Count - $compatible.Count
    if ($hiddenCount -gt 0) {
        Write-WarningLine "Hid $hiddenCount SKU option(s) that do not match source VM attachment or platform requirements."
        foreach ($reason in ($failureCounts.Keys | Sort-Object)) {
            Write-WarningLine "  $($failureCounts[$reason]) hidden: $reason"
        }
    }

    return $compatible
}

function Get-QuotaEligibleSkus {
    param(
        [object[]]$Skus,
        [object[]]$Usages,
        [string]$ResolvedDirection,
        $SourceSku,
        $SourceVm
    )

    $eligible = @()
    $blockedCount = 0
    $unknownCount = 0

    foreach ($sku in @($Skus)) {
        if (-not (Test-SkuUnrestricted -Sku $sku -SourceVm $SourceVm)) {
            continue
        }

        if (-not (Test-SkuMatchesDirection -Sku $sku -ResolvedDirection $ResolvedDirection)) {
            continue
        }

        $quota = Test-SkuQuota -Sku $sku -Usages $Usages -ResolvedDirection $ResolvedDirection -SourceSku $SourceSku -SourceVm $SourceVm
        $quotaConfidence = if ($quota.Unknown) { 1 } else { 0 }
        if (-not $quota.Allowed) {
            $blockedCount++
            continue
        }

        if ($quota.Unknown) {
            $unknownCount++
        }

        $eligible += [pscustomobject]@{
            name             = $sku.name
            sku              = $sku
            quotaDescription = $quota.Description
            quotaConfidence  = $quotaConfidence
            score            = Get-SkuSimilarityScore -Sku $sku -SourceSku $SourceSku
        }
    }

    if ($blockedCount -gt 0) {
        Write-WarningLine "Hid $blockedCount SKU option(s) that appear to exceed available quota."
    }

    if ($unknownCount -gt 0) {
        Write-WarningLine "Kept $unknownCount SKU option(s) visible because quota could not be matched confidently."
    }

    return @($eligible | Sort-Object quotaConfidence, score, name)
}

function Select-PagedSku {
    param(
        [string]$Title,
        [object[]]$Candidates
    )

    $pageSize = 5
    $offset = 0

    while ($true) {
        $page = @($Candidates | Select-Object -Skip $offset -First $pageSize)
        $options = foreach ($candidate in $page) {
            [pscustomobject]@{
                Label       = $candidate.name
                Description = $candidate.quotaDescription
                Value       = $candidate.name
            }
        }

        if (($offset + $pageSize) -lt $Candidates.Count) {
            $options += [pscustomobject]@{
                Label       = 'Show 5 more'
                Description = "Showing $($offset + 1)-$($offset + $page.Count) of $($Candidates.Count)."
                Value       = '__more__'
            }
        }

        $options += [pscustomobject]@{
            Label       = 'Enter a SKU manually'
            Description = 'Use this if the SKU you want is not listed or quota matching was inconclusive.'
            Value       = '__manual__'
        }

        $selected = Read-MenuChoice -Title $Title -Options $options -Default 1
        if ($selected -eq '__more__') {
            $offset += $pageSize
            continue
        }

        if ($selected -eq '__manual__') {
            return (Read-RequiredText -Prompt 'Target VM size' -ExistingValue $null)
        }

        return $selected
    }
}

function Select-StartupAction {
    if ($CleanupSnapshots) {
        return 'CleanupSnapshots'
    }

    if ($NonInteractive) {
        return 'ConvertVm'
    }

    return Read-MenuChoice `
        -Title 'What do you want to do?' `
        -Default 1 `
        -Options @(
            [pscustomobject]@{
                Label           = 'Switch a VM between Regular and Spot'
                Description     = 'Build a conversion plan, then optionally execute it after exact confirmation.'
                WaitDescription = 'Next you choose plan-only or execute mode. Azure resources are still unchanged.'
                Value           = 'ConvertVm'
            },
            [pscustomobject]@{
                Label           = 'Clean up SpotSwitcher snapshots'
                Description     = 'List tagged incremental snapshots created by this script, then confirm before deleting them.'
                WaitDescription = 'Next SpotSwitcher reads snapshots in the active subscription. No snapshots are deleted until the exact confirmation prompt.'
                Value           = 'CleanupSnapshots'
            },
            [pscustomobject]@{
                Label       = 'Stop without changes'
                Description = 'Exit now. No Azure resources will be changed.'
                Value       = 'Stop'
            }
        )
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
                Label           = 'Execute conversion'
                Description     = 'Run the inferred Regular -> Spot or Spot -> Regular wrapper recreation after confirmation.'
                WaitDescription = 'Next steps still do discovery and command preview first; Azure is not changed until the final exact confirmation.'
                Value           = 'Execute'
            }
        )
}

function Select-Subscription {
    param(
        [string]$NextStepDescription = 'Next you choose how to identify the VM. Browsing VMs may take 10-60 seconds in larger subscriptions; manual entry avoids that list call.'
    )

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
                    Label           = 'Use current subscription'
                    Description     = 'Continue with the active Azure CLI context shown above.'
                    WaitDescription = $NextStepDescription
                    Value           = 'current'
                },
                [pscustomobject]@{
                    Label           = 'Choose another subscription'
                    Description     = 'List visible subscriptions and switch before continuing.'
                    WaitDescription = 'Listing subscriptions is usually quick, but Cloud Shell can pause briefly while Azure CLI refreshes account data.'
                    Value           = 'switch'
                }
            )

        if ($choice -eq 'switch') {
            Write-Info 'Reading visible subscriptions from Azure CLI.'
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

    $lookupMode = Read-MenuChoice `
        -Title 'Source VM lookup' `
        -Default 1 `
        -Options @(
            [pscustomobject]@{
                Label           = 'Browse VMs in current subscription'
                Description     = 'Lists VM resource records first; detailed power, NIC, and disk inventory is read after you choose one.'
                WaitDescription = 'The next Azure CLI call lists VM resources. It is usually quick, but large subscriptions can take a minute or more.'
                Value           = 'browse'
            },
            [pscustomobject]@{
                Label       = 'Enter VM manually'
                Description = 'Fastest path when you already know the resource group and VM name.'
                Value       = 'manual'
            }
        )

    if ($lookupMode -eq 'manual') {
        return [pscustomobject]@{
            resourceGroup = Read-RequiredText -Prompt 'Resource group name' -ExistingValue $ResourceGroupName
            name          = Read-RequiredText -Prompt 'VM name' -ExistingValue $VmName
        }
    }

    Write-Section 'VM discovery'
    Write-Info 'Reading VM list from the active subscription. Large subscriptions can take a moment.'
    $vms = @(Invoke-AzJson -Arguments @(
            'vm', 'list',
            '--query', '[].{name:name,resourceGroup:resourceGroup,location:location,priority:priority,size:hardwareProfile.vmSize,os:storageProfile.osDisk.osType}',
            '-o', 'json'
        ))

    if ($vms.Count -eq 0) {
        Write-Fail 'No VMs were found in the active subscription.'
    }

    $options = foreach ($vm in ($vms | Sort-Object resourceGroup, name)) {
        $priority = if ($vm.priority) { $vm.priority } else { 'Regular' }
        $next = if ($priority -in @('Spot', 'Low')) { 'ToRegular' } else { 'ToSpot' }
        [pscustomobject]@{
            Label           = "$($vm.resourceGroup) / $($vm.name)"
            Description     = "$($vm.location), $($vm.size), $($vm.os), priority=$priority, inferred=$next"
            WaitDescription = 'Next the script reads detailed VM inventory: instance view, NICs, disks, and extensions. That can take 30-90 seconds.'
            Value           = $vm
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
    Write-WarningLine 'This is the most detailed discovery step. Cloud Shell may pause for 30-90 seconds while Azure CLI reads related resources.'

    $vm = Invoke-AzJson -Arguments @('vm', 'show', '-g', $ResourceGroup, '-n', $Name, '-o', 'json')
    $instanceView = Invoke-AzJson -Arguments @('vm', 'get-instance-view', '-g', $ResourceGroup, '-n', $Name, '-o', 'json')
    $extensions = @(Invoke-AzJson -Arguments @('vm', 'extension', 'list', '-g', $ResourceGroup, '--vm-name', $Name, '-o', 'json'))
    $vmLocksRaw = @(Invoke-AzJsonOptional `
            -Arguments @('lock', 'list', '--scope', $vm.id, '-o', 'json') `
            -Description 'Reading direct VM management locks.' `
            -WarningLabel 'VM lock inventory')
    $vmLocks = @(Get-DirectScopeLocks -Locks $vmLocksRaw -ScopeId $vm.id)
    $diagnosticSettings = @(Invoke-AzJsonOptional `
            -Arguments @('monitor', 'diagnostic-settings', 'list', '--resource', $vm.id, '-o', 'json') `
            -Description 'Reading VM-scoped Azure Monitor diagnostic settings.' `
            -WarningLabel 'Diagnostic settings inventory')
    $maintenanceAssignments = @(Invoke-AzJsonOptional `
            -Arguments @('maintenance', 'assignment', 'list', '--provider-name', 'Microsoft.Compute', '--resource-group', $ResourceGroup, '--resource-name', $Name, '--resource-type', 'virtualMachines', '-o', 'json') `
            -Description 'Reading VM maintenance configuration assignments.' `
            -WarningLabel 'Maintenance assignment inventory' `
            -TimeoutSeconds 90 `
            -EnableQuietDynamicExtensionInstall)
    $backupProtection = @(Invoke-AzJsonOptional `
            -Arguments @('backup', 'protection', 'check-vm', '--resource-group', $ResourceGroup, '--vm', $vm.id, '-o', 'json') `
            -Description 'Checking Azure Backup protection state.' `
            -WarningLabel 'Azure Backup protection check' `
            -TimeoutSeconds 90)
    $policyAssignments = @(Invoke-AzJsonOptional `
            -Arguments @('policy', 'assignment', 'list', '--scope', $vm.id, '-o', 'json') `
            -Description 'Reading VM-scoped Azure Policy assignments.' `
            -WarningLabel 'Azure Policy assignment inventory')
    $policyExemptions = @(Invoke-AzJsonOptional `
            -Arguments @('policy', 'exemption', 'list', '--scope', $vm.id, '-o', 'json') `
            -Description 'Reading VM-scoped Azure Policy exemptions.' `
            -WarningLabel 'Azure Policy exemption inventory')

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
        vmLocks      = $vmLocks
        inheritedLocks = @($vmLocksRaw | Where-Object { @($vmLocks.id) -notcontains $_.id })
        diagnosticSettings = $diagnosticSettings
        maintenanceAssignments = $maintenanceAssignments
        backupProtection = $backupProtection
        policyAssignments = $policyAssignments
        policyExemptions = $policyExemptions
        nics         = $nics
        osDisk       = $osDisk
        dataDisks    = $dataDisks
    }
}

function Show-InventorySummary {
    param($Inventory)

    $vm = $Inventory.vm
    $priority = Get-EffectivePriority -Vm $vm
    $power = Get-VmPowerStateDisplay -InstanceView $Inventory.instanceView
    $powerCode = Get-VmPowerStateCode -InstanceView $Inventory.instanceView
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
    Write-Host ("VM tags:     {0}" -f @(ConvertTo-TagPairs -Tags $vm.tags).Count)
    Write-Host ("OS disk:     {0}" -f $vm.storageProfile.osDisk.managedDisk.id)
    Write-Host ("OS delete:   {0}" -f $vm.storageProfile.osDisk.deleteOption)
    Write-Host ("NIC count:   {0}" -f @($Inventory.nics).Count)
    Write-Host ("Data disks:  {0}" -f @($vm.storageProfile.dataDisks).Count)
    Write-Host ("Extensions:  {0}" -f @($Inventory.extensions).Count)
    Write-Host ("Locks:       {0}" -f @($Inventory.vmLocks).Count)
    Write-Host ("Diagnostics: {0}" -f @($Inventory.diagnosticSettings).Count)
    Write-Host ("Maintenance: {0}" -f @($Inventory.maintenanceAssignments).Count)
    Write-Host ("VM apps:     {0}" -f @($vm.applicationProfile.galleryApplications).Count)
    Write-Host ("Avail. set:  {0}" -f $availabilitySetId)
    if ($primaryNicId) {
        Write-Host ("Primary NIC: {0}" -f $primaryNicId)
    }

    if (Test-StableVmPowerState -PowerStateCode $powerCode) {
        Write-Host ("Final power: {0}" -f (Get-PowerStateRestoreSummary -PowerStateCode $powerCode))
    }
    else {
        Write-WarningLine "Source VM power state is '$powerCode'. Wait until the VM is running, stopped, or deallocated before converting."
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

    if (@($Inventory.vmLocks).Count -gt 0) {
        Write-WarningLine 'Direct VM management locks will be temporarily removed before wrapper deletion and recreated after power-state restoration.'
    }

    if (@($Inventory.inheritedLocks).Count -gt 0) {
        Write-WarningLine 'Inherited locks were detected. SpotSwitcher will not remove inherited locks; an inherited CanNotDelete or ReadOnly lock may block conversion.'
    }

    if (@($Inventory.diagnosticSettings).Count -gt 0) {
        Write-WarningLine 'VM-scoped Azure Monitor diagnostic settings will be recreated after the VM wrapper is recreated.'
    }

    if (@($Inventory.maintenanceAssignments).Count -gt 0) {
        Write-WarningLine 'VM maintenance configuration assignments will be recreated after the VM wrapper is recreated.'
    }

    if (@($Inventory.backupProtection).Count -gt 0) {
        Write-WarningLine 'Azure Backup protection was detected. SpotSwitcher saves the backup check result, but backup/protection state should be verified after recreation.'
    }

    if (@($Inventory.policyAssignments).Count -gt 0 -or @($Inventory.policyExemptions).Count -gt 0) {
        Write-WarningLine 'VM-scoped Azure Policy assignments or exemptions were detected. SpotSwitcher saves them in the plan for review but does not recreate them automatically.'
    }

    if ($vm.applicationProfile -and @($vm.applicationProfile.galleryApplications).Count -gt 0) {
        Write-WarningLine 'VM Applications will be reapplied after the VM wrapper is recreated.'
    }

    if ($vm.identity -and [string]$vm.identity.type -like '*SystemAssigned*') {
        Write-WarningLine 'System-assigned managed identity can be re-enabled, but Azure creates a new principal ID after the VM wrapper is recreated.'
    }

    if ($vm.osProfile -and @($vm.osProfile.secrets).Count -gt 0) {
        Write-WarningLine 'OS profile Key Vault secrets/certificates were detected. SpotSwitcher saves them in the VM inventory, but does not automatically re-inject them.'
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
                Label           = $label
                Description     = $description
                WaitDescription = 'Next the wizard asks for target size and safety choices. Azure resources are still unchanged.'
                Value           = $inferred
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
        $Inventory,
        [string]$ResolvedDirection
    )

    if ($TargetSku) {
        return $TargetSku
    }

    $currentSize = $Vm.hardwareProfile.vmSize
    $title = if ($ResolvedDirection -eq 'ToSpot') { 'Spot VM SKU' } else { 'Regular VM SKU' }
    $browseDescription = if ($ResolvedDirection -eq 'ToSpot') {
        'Browse unrestricted, quota-eligible Spot-capable SKUs in this region.'
    }
    else {
        'Browse unrestricted, quota-eligible VM SKUs in this region.'
    }

    $regionalSizes = @(Get-RegionalVmSizes -Location $Vm.location)
    $sourceSize = @($regionalSizes | Where-Object { $_.name -eq $currentSize } | Select-Object -First 1)
    if ($sourceSize.Count -gt 0) {
        $sourceSize = $sourceSize[0]
    }
    else {
        Write-WarningLine "Could not find source size '$currentSize' in the lightweight VM size list. Target CPU/RAM defaults may be unavailable."
        $sourceSize = $null
    }

    if (-not $NonInteractive) {
        Write-Section 'Target hardware shape'
        Write-Host ("Current size: {0}" -f $currentSize)
        if ($sourceSize) {
            $sourceMemoryGB = Convert-MemoryMBToGB -MemoryMB $sourceSize.memoryInMB
            Write-Host ("Current shape: {0} vCPU / {1} GiB RAM" -f $sourceSize.numberOfCores, (Format-MemoryGB -MemoryGB $sourceMemoryGB))
        }
    }

    $targetShape = Read-TargetHardwareShape -CurrentSize $currentSize -SourceSize $sourceSize
    $candidateSizeNames = @(Get-CandidateVmSizeNames -Sizes $regionalSizes -Cores $targetShape.Cores -MemoryMB $targetShape.MemoryMB)
    if ($candidateSizeNames.Count -eq 0) {
        Write-WarningLine "No VM sizes in $($Vm.location) exactly matched $($targetShape.Cores) vCPU / $(Format-MemoryGB -MemoryGB $targetShape.MemoryGB) GiB RAM. Falling back to manual entry."
        return (Read-RequiredText -Prompt 'Target VM size' -ExistingValue $null)
    }

    Write-Info "Found $($candidateSizeNames.Count) VM size name(s) with the exact target shape before SKU metadata lookup."

    $catalogSizeNames = @($candidateSizeNames + @($currentSize) | Sort-Object -Unique)
    $allSkus = @(Get-SkuCatalog -Location $Vm.location -SizeNames $catalogSizeNames)
    $quotaUsages = @(Get-QuotaUsage -Location $Vm.location -SubscriptionId (Get-SubscriptionIdFromId -Id $Vm.id))
    $sourceSku = @($allSkus | Where-Object { $_.name -eq $currentSize } | Select-Object -First 1)
    if ($sourceSku.Count -eq 0) {
        Write-WarningLine "Could not find source SKU '$currentSize' in the regional SKU catalog. Similarity ranking and quota checks may be less precise."
        $sourceSku = [pscustomobject]@{
            name         = $currentSize
            restrictions = @()
            capabilities = @()
        }
    }
    else {
        $sourceSku = $sourceSku[0]
    }

    $sourceRequirements = Get-SourceSkuRequirements -Inventory $Inventory -SourceSku $sourceSku
    if ($sourceRequirements.Architecture) {
        Write-Info "Source architecture: $($sourceRequirements.Architecture). Candidate SKUs must match when Azure reports architecture."
    }
    if ($sourceRequirements.DataDiskCount -gt 0) {
        Write-Info "Source has $($sourceRequirements.DataDiskCount) attached data disk(s). Candidate SKUs must support at least that many."
    }
    if ($sourceRequirements.NicCount -gt 1) {
        Write-Info "Source has $($sourceRequirements.NicCount) NIC(s). Candidate SKUs must support at least that many."
    }
    if ($sourceRequirements.RequiresAcceleratedNetworking) {
        Write-Info 'Source NICs use accelerated networking. Candidate SKUs must support it.'
    }

    $candidateNameLookup = @{}
    foreach ($candidateName in $candidateSizeNames) {
        $candidateNameLookup[$candidateName] = $true
    }
    $targetSkus = @($allSkus | Where-Object { $candidateNameLookup.ContainsKey($_.name) })
    $targetSkus = @(Get-SourceCompatibleSkus -Skus $targetSkus -Requirements $sourceRequirements)
    $eligibleSkus = @(Get-QuotaEligibleSkus -Skus $targetSkus -Usages $quotaUsages -ResolvedDirection $ResolvedDirection -SourceSku $sourceSku -SourceVm $Vm)
    $currentEligible = @($eligibleSkus | Where-Object { $_.name -eq $currentSize } | Select-Object -First 1)
    $recommendedSku = @($eligibleSkus | Select-Object -First 1)

    if ($eligibleSkus.Count -eq 0) {
        Write-WarningLine 'No unrestricted quota-eligible SKUs were found. Falling back to manual entry.'
        return (Read-RequiredText -Prompt 'Target VM size' -ExistingValue $null)
    }

    $primarySkuOption = if ($currentEligible.Count -gt 0) {
        [pscustomobject]@{
            Label       = "Keep current size: $currentSize"
            Description = "Available for the target priority. $($currentEligible[0].quotaDescription)"
            Value       = $currentSize
        }
    }
    elseif ($recommendedSku.Count -gt 0) {
        [pscustomobject]@{
            Label       = "Use closest available size: $($recommendedSku[0].name)"
            Description = "Current size '$currentSize' was not available for target priority/quota. $($recommendedSku[0].quotaDescription)"
            Value       = $recommendedSku[0].name
        }
    }
    else {
        $null
    }

    $menuOptions = @()
    if ($primarySkuOption) {
        $menuOptions += $primarySkuOption
    }

    $menuOptions += @(
        [pscustomobject]@{
            Label           = 'Browse discovered SKUs'
            Description     = $browseDescription
            WaitDescription = 'The browser shows 5 SKUs at a time so Cloud Shell stays readable.'
            Value           = 'browse'
        },
        [pscustomobject]@{
            Label       = 'Enter a different SKU manually'
            Description = 'Example: Standard_D4s_v5 or Standard_D4ads_v6.'
            Value       = 'manual'
        }
    )

    $choice = Read-MenuChoice `
        -Title $title `
        -Default 1 `
        -Options $menuOptions

    if ($choice -ne 'browse' -and $choice -ne 'manual') {
        return $choice
    }

    if ($choice -eq 'manual') {
        return (Read-RequiredText -Prompt 'Target VM size' -ExistingValue $null)
    }

    $filter = ''
    if (-not $NonInteractive) {
        $filter = Read-Host 'Filter SKU names, or press Enter for the first 5 matches'
    }

    $skus = $eligibleSkus
    if (-not [string]::IsNullOrWhiteSpace($filter)) {
        $skus = @($skus | Where-Object { $_.name -like "*$filter*" })
    }

    if ($skus.Count -eq 0) {
        Write-WarningLine 'No matching quota-eligible SKUs were returned. Falling back to manual entry.'
        return (Read-RequiredText -Prompt 'Target VM size' -ExistingValue $null)
    }

    return (Select-PagedSku -Title "Choose $title" -Candidates $skus)
}

function Test-TargetSku {
    param(
        [string]$Location,
        [string]$Size,
        [string]$ResolvedDirection
    )

    try {
        Write-Info "Validating SKU '$Size' in $Location."
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
                Label           = 'Run live SKU validation'
                Description     = 'Calls az vm list-skus for the chosen size. Can take a while in some tenants.'
                WaitDescription = 'This validation call can take up to a minute, but it catches some SKU restrictions before execution.'
                Value           = $true
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

function Get-ReservedPlacementSummary {
    param($Vm)

    $parts = @()
    if ($Vm.host -and $Vm.host.id) {
        $parts += "dedicated host: $($Vm.host.id)"
    }
    if ($Vm.hostGroup -and $Vm.hostGroup.id) {
        $parts += "dedicated host group: $($Vm.hostGroup.id)"
    }
    if ($Vm.capacityReservation -and $Vm.capacityReservation.capacityReservationGroup -and $Vm.capacityReservation.capacityReservationGroup.id) {
        $parts += "capacity reservation group: $($Vm.capacityReservation.capacityReservationGroup.id)"
    }

    return $parts
}

function Resolve-ReservedPlacementAction {
    param(
        $Vm,
        [string]$ResolvedDirection
    )

    $reservedPlacement = @(Get-ReservedPlacementSummary -Vm $Vm)
    if ($reservedPlacement.Count -eq 0) {
        return 'None'
    }

    if ($ResolvedDirection -ne 'ToSpot') {
        return 'Preserve'
    }

    Write-WarningLine 'Source VM uses reserved placement:'
    foreach ($item in $reservedPlacement) {
        Write-WarningLine "  $item"
    }
    Write-WarningLine 'Spot VMs use spare capacity and cannot reliably preserve dedicated host or capacity reservation placement.'

    if ($DropReservedPlacementForSpot -eq 'Yes') {
        Write-WarningLine 'The recreated Spot VM will intentionally omit reserved placement.'
        return 'DropForSpot'
    }

    if ($DropReservedPlacementForSpot -eq 'No') {
        Write-Fail 'Cannot convert this VM to Spot while preserving dedicated host, host group, or capacity reservation placement.'
    }

    if ($NonInteractive) {
        Write-Fail 'Source VM uses reserved placement. Rerun with -DropReservedPlacementForSpot Yes to intentionally omit it, or choose a VM without reserved placement.'
    }

    $dropReservedPlacement = Read-MenuChoice `
        -Title 'Reserved placement handling' `
        -Default 2 `
        -Options @(
            [pscustomobject]@{
                Label       = 'Recreate without reserved placement'
                Description = 'Required if this VM must become Spot; dedicated host, host group, or capacity reservation placement will be intentionally dropped.'
                Value       = $true
            },
            [pscustomobject]@{
                Label       = 'Stop without building commands'
                Description = 'Keep reserved placement unchanged and leave Azure unchanged.'
                Value       = $false
            }
        )

    if ($dropReservedPlacement -eq $true) {
        return 'DropForSpot'
    }

    Write-Fail 'Stopped because Spot conversion cannot preserve reserved placement.'
}

function Select-Decisions {
    param(
        $Inventory,
        [string]$ResolvedDirection
    )

    $vm = $Inventory.vm
    $availabilitySetAction = Resolve-AvailabilitySetAction -Vm $vm -ResolvedDirection $ResolvedDirection
    $reservedPlacementAction = Resolve-ReservedPlacementAction -Vm $vm -ResolvedDirection $ResolvedDirection
    $targetSkuValue = Select-TargetSku -Vm $vm -Inventory $Inventory -ResolvedDirection $ResolvedDirection
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
        reservedPlacementAction = $reservedPlacementAction
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
    $sourcePowerStateCode = Get-VmPowerStateCode -InstanceView $Inventory.instanceView

    [ordered]@{
        planVersion = 5
        generatedAt = (Get-Date).ToString('o')
        planId = "$($vm.name)-$($Decisions.direction)-$stamp"
        subscription = @{
            id = $Account.id
            name = $Account.name
            tenantId = $Account.tenantId
        }
        source = @{
            vm = $Inventory.vm
            tags = ConvertTo-TagObject -Tags $Inventory.vm.tags
            instanceView = $Inventory.instanceView
            extensions = $Inventory.extensions
            vmLocks = $Inventory.vmLocks
            inheritedLocks = $Inventory.inheritedLocks
            diagnosticSettings = $Inventory.diagnosticSettings
            maintenanceAssignments = $Inventory.maintenanceAssignments
            backupProtection = $Inventory.backupProtection
            policyAssignments = $Inventory.policyAssignments
            policyExemptions = $Inventory.policyExemptions
            nics = $Inventory.nics
            osDisk = $Inventory.osDisk
            dataDisks = $Inventory.dataDisks
            powerState = @{
                code = $sourcePowerStateCode
                displayStatus = Get-VmPowerStateDisplay -InstanceView $Inventory.instanceView
                restoreSummary = Get-PowerStateRestoreSummary -PowerStateCode $sourcePowerStateCode
            }
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
        '--os-disk-delete-option', 'Detach'
    )

    if ($vm.osProfile -and $vm.osProfile.computerName) {
        $args += @('--computer-name', $vm.osProfile.computerName)
    }

    $args += '--nics'
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

    if ($decisions.reservedPlacementAction -eq 'Preserve') {
        if ($vm.host -and $vm.host.id) {
            $args += @('--host', $vm.host.id)
        }
        elseif ($vm.hostGroup -and $vm.hostGroup.id) {
            $args += @('--host-group', $vm.hostGroup.id)
        }

        if ($vm.capacityReservation -and $vm.capacityReservation.capacityReservationGroup -and $vm.capacityReservation.capacityReservationGroup.id) {
            $args += @('--capacity-reservation-group', $vm.capacityReservation.capacityReservationGroup.id)
        }
    }

    if ($vm.proximityPlacementGroup -and $vm.proximityPlacementGroup.id) {
        $args += @('--ppg', $vm.proximityPlacementGroup.id)
    }

    if ($null -ne $vm.platformFaultDomain) {
        $args += @('--platform-fault-domain', ([string]$vm.platformFaultDomain))
    }

    if ($vm.licenseType) {
        $args += @('--license-type', $vm.licenseType)
    }

    if ($vm.plan) {
        if ($vm.plan.name) {
            $args += @('--plan-name', $vm.plan.name)
        }
        if ($vm.plan.product) {
            $args += @('--plan-product', $vm.plan.product)
        }
        if ($vm.plan.publisher) {
            $args += @('--plan-publisher', $vm.plan.publisher)
        }
        if ($vm.plan.promotionCode) {
            $args += @('--plan-promotion-code', $vm.plan.promotionCode)
        }
    }

    if ($vm.securityProfile -and $vm.securityProfile.securityType) {
        $args += @('--security-type', $vm.securityProfile.securityType)

        if ($null -ne $vm.securityProfile.encryptionAtHost) {
            $args += @('--encryption-at-host', ([string]$vm.securityProfile.encryptionAtHost).ToLowerInvariant())
        }

        if ($vm.securityProfile.encryptionIdentity -and $vm.securityProfile.encryptionIdentity.userAssignedIdentityResourceId) {
            $args += @('--encryption-identity', $vm.securityProfile.encryptionIdentity.userAssignedIdentityResourceId)
        }

        if ($vm.securityProfile.uefiSettings) {
            if ($null -ne $vm.securityProfile.uefiSettings.secureBootEnabled) {
                $args += @('--enable-secure-boot', ([string]$vm.securityProfile.uefiSettings.secureBootEnabled).ToLowerInvariant())
            }
            if ($null -ne $vm.securityProfile.uefiSettings.vTpmEnabled) {
                $args += @('--enable-vtpm', ([string]$vm.securityProfile.uefiSettings.vTpmEnabled).ToLowerInvariant())
            }
        }
    }

    if ($vm.storageProfile -and $vm.storageProfile.diskControllerType) {
        $args += @('--disk-controller-type', $vm.storageProfile.diskControllerType)
    }

    if ($vm.storageProfile -and $vm.storageProfile.osDisk -and $vm.storageProfile.osDisk.securityProfile -and $vm.storageProfile.osDisk.securityProfile.securityEncryptionType) {
        $args += @('--os-disk-security-encryption-type', $vm.storageProfile.osDisk.securityProfile.securityEncryptionType)
    }

    if ($vm.additionalCapabilities -and $vm.additionalCapabilities.ultraSsdEnabled -eq $true) {
        $args += @('--ultra-ssd-enabled', 'true')
    }

    if ($vm.additionalCapabilities -and $vm.additionalCapabilities.hibernationEnabled -eq $true) {
        $args += @('--enable-hibernation', 'true')
    }

    $tagArgs = @(Get-TagsAsArguments -Tags (Get-PlanSourceTags -Plan $Plan))
    if ($tagArgs.Count -gt 0) {
        $args += '--tags'
        $args += $tagArgs
    }

    return $args
}

function Get-DirectLockDeleteCommands {
    param($Plan)

    $commands = @()
    foreach ($lock in @(Get-PlanSourceCollection -Plan $Plan -Name 'vmLocks')) {
        if ($lock.id) {
            $commands += New-AzCommand -Description "Temporarily remove VM management lock '$($lock.name)'." -Arguments @(
                'lock', 'delete',
                '--ids', $lock.id
            )
        }
    }

    return $commands
}

function Get-DirectLockRestoreCommands {
    param($Plan)

    $commands = @()
    $vm = $Plan.source.vm
    foreach ($lock in @(Get-PlanSourceCollection -Plan $Plan -Name 'vmLocks')) {
        if (-not $lock.name -or -not $lock.level) {
            continue
        }

        $args = @(
            'lock', 'create',
            '--name', $lock.name,
            '--lock-type', $lock.level,
            '--resource', $vm.id
        )

        if ($lock.notes) {
            $args += @('--notes', $lock.notes)
        }

        $commands += New-AzCommand -Description "Restore VM management lock '$($lock.name)'." -Arguments $args
    }

    return $commands
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
    $osSnapshotName = New-AzureResourceName -Parts @($Plan.planId, 'os') -MaxLength 80
    $commands += New-AzCommand -Description 'Create incremental snapshot of the OS disk.' -Arguments (@(
            'snapshot', 'create',
            '-g', $osDiskRg,
            '-n', $osSnapshotName,
            '--source', $osDisk.id,
            '--incremental', 'true',
            '--tags'
        ) + $snapshotTagArgs)

    foreach ($disk in @($Plan.source.dataDisks)) {
        $diskRg = if ($disk.resourceGroup) { $disk.resourceGroup } else { Get-ResourceGroupFromId -Id $disk.id }
        $dataSnapshotName = New-AzureResourceName -Parts @($Plan.planId, 'data', "lun$($disk.lun)", $disk.name) -MaxLength 80
        $commands += New-AzCommand -Description "Create incremental snapshot of data disk $($disk.name)." -Arguments (@(
                'snapshot', 'create',
                '-g', $diskRg,
                '-n', $dataSnapshotName,
                '--source', $disk.id,
                '--incremental', 'true',
                '--tags'
            ) + $snapshotTagArgs)
    }

    return $commands
}

function Get-PowerStateRestoreCommands {
    param($Plan)

    $vm = $Plan.source.vm
    $powerStateCode = $Plan.source.powerState.code
    if ([string]::IsNullOrWhiteSpace($powerStateCode)) {
        $powerStateCode = Get-VmPowerStateCode -InstanceView $Plan.source.instanceView
    }

    switch ($powerStateCode) {
        'PowerState/running' {
            return @()
        }
        'PowerState/stopped' {
            return @(New-AzCommand -Description 'Return VM to original power state: stopped (allocated).' -Arguments @(
                    'vm', 'stop',
                    '-g', $vm.resourceGroup,
                    '-n', $vm.name
                ))
        }
        'PowerState/deallocated' {
            return @(New-AzCommand -Description 'Return VM to original power state: deallocated.' -Arguments @(
                    'vm', 'deallocate',
                    '-g', $vm.resourceGroup,
                    '-n', $vm.name
                ))
        }
        default {
            Write-Fail "Cannot restore unsupported source VM power state '$powerStateCode'."
        }
    }
}

function Get-VmApplicationRestoreCommands {
    param($Plan)

    $commands = @()
    $vm = $Plan.source.vm
    $applications = @($vm.applicationProfile.galleryApplications | Where-Object { $_.packageReferenceId })
    if ($applications.Count -eq 0) {
        return $commands
    }

    $applications = @($applications | Sort-Object @{ Expression = { if ($null -ne $_.order) { [int]$_.order } else { [int]::MaxValue } } }, packageReferenceId)
    $args = @(
        'vm', 'application', 'set',
        '-g', $vm.resourceGroup,
        '-n', $vm.name,
        '--app-version-ids'
    ) + @($applications.packageReferenceId)

    if (@($applications | Where-Object { $_.configurationReference }).Count -gt 0) {
        $args += '--app-config-overrides'
        foreach ($application in $applications) {
            if ($application.configurationReference) {
                $args += $application.configurationReference
            }
            else {
                $args += 'null'
            }
        }
    }

    if (@($applications | Where-Object { $null -ne $_.treatFailureAsDeploymentFailure }).Count -eq $applications.Count) {
        $args += '--treat-deployment-as-failure'
        foreach ($application in $applications) {
            $args += ([string]$application.treatFailureAsDeploymentFailure).ToLowerInvariant()
        }
    }

    if (@($applications | Where-Object { $null -ne $_.order }).Count -gt 0) {
        $args += '--order-applications'
    }

    $commands += New-AzCommand -Description 'Restore VM Applications.' -Arguments $args
    return $commands
}

function Get-DiagnosticSettingRestoreCommands {
    param($Plan)

    $commands = @()
    $vm = $Plan.source.vm
    foreach ($setting in @(Get-PlanSourceCollection -Plan $Plan -Name 'diagnosticSettings')) {
        if (-not $setting.name) {
            continue
        }

        $args = @(
            'monitor', 'diagnostic-settings', 'create',
            '--resource', $vm.id,
            '-n', $setting.name
        )

        if (@($setting.logs).Count -gt 0) {
            $args += @('--logs', (ConvertTo-CompactJsonArrayArgument -Value $setting.logs))
        }
        if (@($setting.metrics).Count -gt 0) {
            $args += @('--metrics', (ConvertTo-CompactJsonArrayArgument -Value $setting.metrics))
        }
        if ($setting.workspaceId) {
            $args += @('--workspace', $setting.workspaceId)
        }
        if ($setting.storageAccountId) {
            $args += @('--storage-account', $setting.storageAccountId)
        }
        if ($setting.eventHubAuthorizationRuleId) {
            $args += @('--event-hub-rule', $setting.eventHubAuthorizationRuleId)
        }
        if ($setting.eventHubName) {
            $args += @('--event-hub', $setting.eventHubName)
        }
        if ($setting.marketplacePartnerId) {
            $args += @('--marketplace-partner-id', $setting.marketplacePartnerId)
        }
        if ($setting.logAnalyticsDestinationType -eq 'Dedicated') {
            $args += @('--export-to-resource-specific', 'true')
        }

        $commands += New-AzCommand -Description "Restore diagnostic setting '$($setting.name)'." -Arguments $args
    }

    return $commands
}

function Get-MaintenanceAssignmentRestoreCommands {
    param($Plan)

    $commands = @()
    $vm = $Plan.source.vm
    foreach ($assignment in @(Get-PlanSourceCollection -Plan $Plan -Name 'maintenanceAssignments')) {
        $configurationId = $assignment.maintenanceConfigurationId
        if (-not $configurationId -and $assignment.properties -and $assignment.properties.maintenanceConfigurationId) {
            $configurationId = $assignment.properties.maintenanceConfigurationId
        }

        if (-not $assignment.name -or -not $configurationId) {
            continue
        }

        $args = @(
            'maintenance', 'assignment', 'create',
            '--provider-name', 'Microsoft.Compute',
            '--resource-group', $vm.resourceGroup,
            '--resource-name', $vm.name,
            '--resource-type', 'virtualMachines',
            '--name', $assignment.name,
            '--maintenance-configuration-id', $configurationId
        )

        if ($assignment.location) {
            $args += @('--location', $assignment.location)
        }

        $commands += New-AzCommand -Description "Restore maintenance assignment '$($assignment.name)'." -Arguments $args
    }

    return $commands
}

function Get-ReviewOnlyCommands {
    param($Plan)

    $commands = @()
    $vm = $Plan.source.vm

    if (@(Get-PlanSourceCollection -Plan $Plan -Name 'backupProtection').Count -gt 0) {
        $commands += New-AzCommand -Description 'Review Azure Backup protection after recreation.' -Arguments @(
            'backup', 'protection', 'check-vm',
            '--resource-group', $vm.resourceGroup,
            '--vm', $vm.id,
            '-o', 'json'
        )
    }

    if (@(Get-PlanSourceCollection -Plan $Plan -Name 'policyAssignments').Count -gt 0) {
        $commands += New-AzCommand -Description 'Review VM-scoped Azure Policy assignments after recreation.' -Arguments @(
            'policy', 'assignment', 'list',
            '--scope', $vm.id,
            '-o', 'table'
        )
    }

    if (@(Get-PlanSourceCollection -Plan $Plan -Name 'policyExemptions').Count -gt 0) {
        $commands += New-AzCommand -Description 'Review VM-scoped Azure Policy exemptions after recreation.' -Arguments @(
            'policy', 'exemption', 'list',
            '--scope', $vm.id,
            '-o', 'table'
        )
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
    $commands += Get-DirectLockDeleteCommands -Plan $Plan
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
    $commands += Get-VmApplicationRestoreCommands -Plan $Plan
    $commands += Get-DiagnosticSettingRestoreCommands -Plan $Plan
    $commands += Get-MaintenanceAssignmentRestoreCommands -Plan $Plan
    $commands += Get-PowerStateRestoreCommands -Plan $Plan
    $commands += Get-DirectLockRestoreCommands -Plan $Plan
    $commands += Get-ReviewOnlyCommands -Plan $Plan

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

function Resolve-ExecutePreviewedPlan {
    param(
        [string]$SavedPlanPath,
        [string]$RerunCommand
    )

    Write-Section 'Plan complete'
    Write-Host 'No Azure resources have been changed yet.'
    Write-Host "Saved plan: $SavedPlanPath"
    Write-Host "To rebuild and execute this flow later, run: $RerunCommand"

    if ($NonInteractive) {
        return $false
    }

    return Read-MenuChoice `
        -Title 'Execute previewed plan' `
        -Default 2 `
        -Options @(
            [pscustomobject]@{
                Label           = 'Execute this plan now'
                Description     = 'Run the commands shown above after the final exact confirmation prompt.'
                WaitDescription = 'Next you must type the exact confirmation phrase. Azure resources are still unchanged until that confirmation passes.'
                Value           = $true
            },
            [pscustomobject]@{
                Label       = 'Stop with saved plan'
                Description = 'Keep the saved plan and command preview. No Azure resources will be changed.'
                Value       = $false
            }
        )
}

function Show-DecisionSummary {
    param($Plan)

    Write-Section 'Decision summary'
    Write-Host ("Direction:        {0}" -f $Plan.decisions.direction)
    Write-Host ("Target SKU:       {0}" -f $Plan.decisions.targetSku)
    Write-Host ("VM tags:          Preserve {0} source tag(s)" -f @(ConvertTo-TagPairs -Tags (Get-PlanSourceTags -Plan $Plan)).Count)
    Write-Host ("Original power:   {0}" -f $Plan.source.powerState.displayStatus)
    Write-Host ("Final power:      {0}" -f $Plan.source.powerState.restoreSummary)
    if ($Plan.decisions.direction -eq 'ToSpot') {
        Write-Host ("Eviction policy:  {0}" -f $Plan.decisions.evictionPolicy)
        Write-Host ("Max price:        {0}" -f $Plan.decisions.maxPrice)
    }
    $availabilitySetSummary = switch ($Plan.decisions.availabilitySetAction) {
        'Preserve' { 'Preserve original membership'; break }
        'DropForSpot' { 'Drop because Spot VMs cannot use availability sets'; break }
        default { 'None' }
    }
    $reservedPlacementSummary = switch ($Plan.decisions.reservedPlacementAction) {
        'Preserve' { 'Preserve dedicated host/host group/capacity reservation placement'; break }
        'DropForSpot' { 'Drop because Spot cannot preserve reserved placement'; break }
        default { 'None' }
    }
    Write-Host ("Availability set: {0}" -f $availabilitySetSummary)
    Write-Host ("Reserved place:   {0}" -f $reservedPlacementSummary)
    Write-Host ("Locks:            Restore {0} direct VM lock(s)" -f @(Get-PlanSourceCollection -Plan $Plan -Name 'vmLocks').Count)
    Write-Host ("Diagnostics:      Restore {0} VM diagnostic setting(s)" -f @(Get-PlanSourceCollection -Plan $Plan -Name 'diagnosticSettings').Count)
    Write-Host ("Maintenance:      Restore {0} maintenance assignment(s)" -f @(Get-PlanSourceCollection -Plan $Plan -Name 'maintenanceAssignments').Count)
    Write-Host ("VM apps:          Restore {0} VM application(s)" -f @($Plan.source.vm.applicationProfile.galleryApplications).Count)
    Write-Host ("Backup check:     {0} saved result(s); verify protection after conversion" -f @(Get-PlanSourceCollection -Plan $Plan -Name 'backupProtection').Count)
    Write-Host ("Policy review:    {0} assignment(s), {1} exemption(s) saved for review" -f @(Get-PlanSourceCollection -Plan $Plan -Name 'policyAssignments').Count, @(Get-PlanSourceCollection -Plan $Plan -Name 'policyExemptions').Count)
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

    $startupAction = Select-StartupAction
    if ($startupAction -eq 'Stop') {
        Write-Section 'Stopped'
        Write-Host 'No Azure resources were changed.'
        return
    }

    if ($startupAction -eq 'CleanupSnapshots') {
        $account = Select-Subscription -NextStepDescription 'Next SpotSwitcher reads snapshots in the active subscription. No snapshots are deleted until the exact confirmation prompt.'
        Invoke-SpotSwitcherSnapshotCleanup -Account $account
        return
    }

    $selectedMode = Select-RunMode
    $account = Select-Subscription
    $target = Select-TargetVm
    $inventory = Get-VmInventory -ResourceGroup $target.resourceGroup -Name $target.name
    $inventory = Wait-ForStableSourcePowerState -Inventory $inventory
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

    $shouldExecute = ($selectedMode -eq 'Execute')
    if ($selectedMode -eq 'Plan') {
        $rerunCommand = './Switch-AzureVmSpotPriority.ps1 -Mode Execute'
        $shouldExecute = Resolve-ExecutePreviewedPlan -SavedPlanPath $savedPlanPath -RerunCommand $rerunCommand
        if (-not $shouldExecute) {
            Write-Section 'Plan only'
            Write-Host 'No changes were made.'
            Write-Host "Saved plan: $savedPlanPath"
            return
        }
    }

    $targetLabel = if ($resolvedDirection -eq 'ToSpot') { 'SPOT' } else { 'REGULAR' }
    Confirm-Exact -Phrase "CONVERT $($plan.source.vm.name) TO $targetLabel"
    Invoke-CommandList -Commands $commands -Execute $true

    Write-Section 'Post-check'
    Invoke-AzText -Arguments @(
        'vm', 'show',
        '-g', $plan.source.vm.resourceGroup,
        '-n', $plan.source.vm.name,
        '-d',
        '--query', '{powerState:powerState,priority:priority,evictionPolicy:evictionPolicy,vmSize:hardwareProfile.vmSize,availabilitySet:availabilitySet.id,osDisk:storageProfile.osDisk.managedDisk.id,nics:networkProfile.networkInterfaces[].{id:id,primary:primary},tags:tags}',
        '-o', 'json'
    ) -Description 'Reading recreated VM summary.'

    Write-Section 'Done'
    Write-Host "Conversion completed. Saved plan: $savedPlanPath"
}

Invoke-Main
