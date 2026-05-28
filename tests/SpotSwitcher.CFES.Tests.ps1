$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$env:SPOTSWITCHER_SKIP_MAIN = '1'
. (Join-Path $repoRoot 'Switch-AzureVmSpotPriority.ps1')

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-ContainsText {
    param(
        [string]$Text,
        [string]$ExpectedFragment,
        [string]$Message
    )

    if ($Text -notlike "*$ExpectedFragment*") {
        throw "$Message`nMissing fragment: $ExpectedFragment`nText: $Text"
    }
}

$payload = New-CfesEmailPayload `
    -To 'person@example.com' `
    -Subject 'Subject' `
    -Text 'Plain text body' `
    -Html '<p>Optional HTML body</p>' `
    -EventName 'test.event'

$request = New-CfesSignedRequest `
    -Payload $payload `
    -Endpoint 'https://cloudflare-email-sender.toby-vanroojen.workers.dev/v1/send' `
    -ClientId 'spotswitcher' `
    -Secret 'test-secret' `
    -Timestamp 1710000000 `
    -Nonce '00000000-0000-4000-8000-000000000000'

$expectedBody = '{"to":"person@example.com","subject":"Subject","text":"Plain text body","html":"<p>Optional HTML body</p>","metadata":{"project":"SpotSwitcher","event":"test.event"}}'
Assert-Equal $expectedBody $request.RawJsonBody 'CFES signs the exact JSON body that is sent.'
Assert-Equal 'application/json' $request.Headers['content-type'] 'CFES request uses the required content type header.'
Assert-Equal 'spotswitcher' $request.Headers['X-CFES-Client'] 'CFES request includes the configured client id.'
Assert-Equal '1710000000' $request.Headers['X-CFES-Timestamp'] 'CFES request includes the Unix timestamp.'
Assert-Equal '00000000-0000-4000-8000-000000000000' $request.Headers['X-CFES-Nonce'] 'CFES request includes the nonce.'
Assert-Equal 'sha256=7a2cacfaf0d293f599b9235e78464e5d6ccab71d3d7c659c1e40144468830202' $request.Headers['X-CFES-Signature'] 'CFES request includes the expected HMAC signature.'

$samplePlan = [pscustomobject]@{
    account   = [pscustomobject]@{
        name = 'Test subscription'
        id   = 'sub-0000'
    }
    source    = [pscustomobject]@{
        vm         = [pscustomobject]@{
            name          = 'vm-demo'
            resourceGroup = 'rg-demo'
        }
        powerState = [pscustomobject]@{
            restoreSummary = 'running remains running'
        }
    }
    decisions = [pscustomobject]@{
        direction = 'ToSpot'
        targetSku = 'Standard_D4ads_v6'
    }
}

$script:sentNotifications = @()
$transport = {
    param($Payload, $EventName)
    $script:sentNotifications += [pscustomobject]@{
        Payload   = $Payload
        EventName = $EventName
    }
    [pscustomobject]@{ StatusCode = 202 }
}

[void](Send-SpotSwitcherNotification `
        -Kind ConversionCompleted `
        -Recipients @('ops@example.com') `
        -Plan $samplePlan `
        -SavedPlanPath '/tmp/spotswitcher.plan.json' `
        -Stage 'conversion completed' `
        -Transport $transport)

Assert-Equal 1 $script:sentNotifications.Count 'A conversion-completed notification sends one CFES request per recipient.'
$sent = $script:sentNotifications[0]
Assert-Equal 'conversion.completed' $sent.EventName 'Notification transport receives the conversion-completed event.'
Assert-Equal 'ops@example.com' $sent.Payload.to 'Notification payload uses the selected recipient.'
Assert-Equal '[SpotSwitcher] Conversion completed for vm-demo' $sent.Payload.subject 'Notification payload uses the expected subject.'
Assert-Equal 'SpotSwitcher' $sent.Payload.metadata.project 'Notification metadata keeps the app-owned project name.'
Assert-Equal 'conversion.completed' $sent.Payload.metadata.event 'Notification metadata keeps the app-owned event name.'
Assert-ContainsText $sent.Payload.text 'VM: vm-demo' 'Notification text includes the VM name.'
Assert-ContainsText $sent.Payload.text 'Target SKU: Standard_D4ads_v6' 'Notification text includes the app-side conversion choice.'

Write-Host 'SpotSwitcher CFES tests passed.'
