# Security Policy

## Supported version

SpotSwitcher is distributed from the `main` branch of this repository. Use the
latest script from the official repository:

```powershell
iwr https://raw.githubusercontent.com/vanRoojen-LLC/SpotSwitcher/main/Switch-AzureVmSpotPriority.ps1 -OutFile ./Switch-AzureVmSpotPriority.ps1; ./Switch-AzureVmSpotPriority.ps1
```

## Reporting a vulnerability

Report suspected security issues privately through the SpotSwitcher support
form at https://spotswitcher.app/support#contact. Please include the affected
script version or commit, the Azure CLI and PowerShell versions, reproduction
steps, expected impact, and any safe sample output that helps confirm the issue.

Do not send Azure credentials, private keys, access tokens, passwords, full
tenant IDs, full subscription IDs, or customer-sensitive VM data. If a report
requires real Azure resource identifiers, redact them enough that the issue can
still be understood without exposing your environment.

## Operational security notes

SpotSwitcher runs under the current Azure identity and calls Azure CLI for the
resources you choose. By default, it does not send VM inventory, tenant data,
plan files, or telemetry to vanRoojen LLC. If optional email notifications are
configured, SpotSwitcher sends only the app-owned notification payload to Toby's
shared Cloudflare Email Sender Worker and never sends the saved plan contents or
the CFES HMAC secret.

Saved plan files can contain Azure resource IDs and operational configuration
metadata. The script redacts VM user data, `osProfile.customData`, and VM
extension settings before saving a plan, but plan files should still be handled
as operational change records.
