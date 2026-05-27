# SpotSwitcher

SpotSwitcher is a Cloud Shell PowerShell wizard for switching an Azure VM
between Regular and Spot by safely recreating only the VM resource wrapper.

Product page: <https://spotswitcher.app/>

Use SpotSwitcher when you need to convert an Azure VM to Spot, switch an Azure
Spot VM back to Regular, change Azure VM priority between Spot and non-Spot, or
generate a dry-run plan before recreating the VM wrapper with the same attached
disks and network interfaces.

With no parameters, it discovers subscriptions, VMs, the source VM priority,
and the choices needed for the correct direction:

- Regular or null priority -> convert to Spot
- Spot or legacy Low priority -> convert to Regular

The opening menu also includes a snapshot cleanup task. Cleanup lists snapshots
created by SpotSwitcher, identified by the script's snapshot tags, before asking
for exact confirmation to delete them.

Default mode is read-only plan generation, followed by a prompt to execute the
just-previewed plan. Azure resources are not changed unless you choose to
execute and pass the final exact confirmation prompt.
During conversion, SpotSwitcher records the source VM power state and restores
stable states after recreation: running VMs remain running, stopped VMs are
stopped again, and deallocated VMs are deallocated again.
It also captures the source VM tags in the saved plan and reapplies them to the
recreated VM. Existing disk and NIC tags remain on those resources because
SpotSwitcher preserves the original managed disks and NICs.
If Azure reports a transitional source state such as starting or deallocating,
SpotSwitcher warns and waits until the VM reaches a stable state before planning
the conversion.
After subscription selection, choose whether to browse VMs in the subscription
or enter the resource group and VM name manually. Manual entry avoids a
subscription-wide VM list call.
When choosing a target size, the SKU picker starts from the source VM's exact
vCPU/RAM shape unless `-TargetCores` or `-TargetMemoryGB` override it. It also
filters for source compatibility where Azure reports the data: CPU architecture,
attached data disk count, NIC count, accelerated networking, Premium/Ultra disk
support, encryption at host, OS disk size, Hyper-V generation, and source zone
availability. For Spot conversions, it only offers the current VM size if it is
Spot-capable and appears to fit available quota. Otherwise it recommends the
closest unrestricted, quota-eligible Spot size. Browse results are shown five at
a time.
Quota filtering uses the Azure CLI `quota` extension when available, then falls
back to legacy compute usage, which may not expose Spot quota.

Run the latest version directly in Azure Cloud Shell PowerShell:

```powershell
iwr https://raw.githubusercontent.com/vanRoojen-LLC/SpotSwitcher/refs/heads/main/Switch-AzureVmSpotPriority.ps1 -OutFile ./Switch-AzureVmSpotPriority.ps1; ./Switch-AzureVmSpotPriority.ps1
```

```powershell
./Switch-AzureVmSpotPriority.ps1
```

Clean up snapshots created by SpotSwitcher:

```powershell
./Switch-AzureVmSpotPriority.ps1 -CleanupSnapshots
```

Execute interactively after reviewing the generated command plan:

```powershell
./Switch-AzureVmSpotPriority.ps1 -Mode Execute
```

If you ran in default Plan mode and stopped after preview, rebuild the plan and
execute it with:

```powershell
./Switch-AzureVmSpotPriority.ps1 -Mode Execute
```

The saved JSON plan is for audit/review. SpotSwitcher executes the live
in-memory plan immediately after preview rather than replaying an older plan
file, because VM, NIC, disk, quota, and SKU state can drift.

Run unattended with explicit parameters:

```powershell
./Switch-AzureVmSpotPriority.ps1 `
  -Mode Execute `
  -NonInteractive `
  -Force `
  -Subscription "<subscription-name-or-id>" `
  -ResourceGroupName "<resource-group>" `
  -VmName "<vm-name>" `
  -Direction ToSpot `
  -TargetSku Standard_D4ads_v6 `
  -EvictionPolicy Deallocate `
  -MaxPrice -1 `
  -PinPrivateIps Yes `
  -CreateSnapshots Yes `
  -ValidateSku No `
  -DropAvailabilitySetForSpot No `
  -DropReservedPlacementForSpot No `
  -AcceptReviewOnlyItems No `
  -AcceptReservationSavingsImpact No
```

If `-TargetSku` is omitted, the source VM's exact vCPU/RAM shape is used. Pass
`-TargetCores` and `-TargetMemoryGB` to override that shape before browsing
candidate SKUs.

The script writes plan files to `~/clouddrive/SpotSwitcherPlans` in Cloud Shell
when Cloud Drive is mounted, otherwise to `./SpotSwitcherPlans`.

Azure Spot VMs cannot be created in availability sets. If a source VM is in an
availability set, SpotSwitcher prompts before intentionally dropping that
membership for a Spot conversion. In unattended mode, pass
`-DropAvailabilitySetForSpot Yes` to make that choice explicit.

## Preservation Notes

SpotSwitcher preserves the source VM tags, managed OS disk, managed data disks,
NICs, primary NIC ordering, optional static private IP pinning, selected VM
size, zones, Proximity Placement Group, marketplace plan, compatible dedicated
host or capacity reservation placement, license type, Trusted Launch settings,
encryption-at-host, disk controller type, Ultra SSD and hibernation capability,
boot diagnostics, VM-scoped Azure Monitor diagnostic settings, maintenance
configuration assignments, VM Applications, direct VM management locks,
user-assigned identities, and the stable source power state where Azure CLI can
safely reapply them.

Known Azure recreation gaps to review before execution:

- VM extensions are listed for review, but protected settings cannot be read
  back from Azure, so extensions are not automatically reinstalled.
- A system-assigned managed identity can be re-enabled, but Azure creates a new
  principal ID. Any RBAC assignments, Key Vault access policies, or app
  allow-lists tied to the old principal may need repair.
- Availability-set membership must be dropped when converting to Spot because
  Azure Spot VMs do not support availability sets.
- Dedicated host, host group, and capacity reservation placement must be
  intentionally dropped when converting to Spot.
- Azure Backup protection is detected and saved in the plan, but protection
  should be verified after recreation.
- VM-scoped Azure Policy assignments and exemptions are detected and saved in
  the plan for review, but are not automatically recreated because assignments
  can carry identity and role-assignment side effects.
- Secrets/certificates injected through `osProfile`, user data, and other less
  common VM wrapper settings should be treated as review items until
  SpotSwitcher explicitly inventories and restores them.

Reserved VM Instance savings are a billing benefit, not a VM placement setting.
For Spot conversions, SpotSwitcher checks active VM reservations visible to the
current identity. If the source VM appears to match a reservation by scope,
region, and SKU or instance-size-flexibility family, SpotSwitcher warns and
defaults to stopping so you can decide whether the Reserved Instance benefit
should be reassigned, exchanged, or otherwise handled before conversion. In
unattended mode, pass `-AcceptReservationSavingsImpact Yes` to continue after
saving the matching reservation details in the plan.

Review-only items such as extensions with protected settings, inherited locks,
Azure Backup protection, VM-scoped Azure Policy artifacts, osProfile
secrets/certificates, and user data are shown with the current settings
SpotSwitcher can safely print. In unattended mode, pass
`-AcceptReviewOnlyItems Yes` to continue after saving those notes in the plan.

## Product and Support

- Product site: <https://spotswitcher.app/>
- Privacy: <https://spotswitcher.app/privacy>
- Terms: <https://spotswitcher.app/terms>
- Support: <https://spotswitcher.app/support>
- LLM context: <https://spotswitcher.app/llms.txt>
- License: MIT

SpotSwitcher does not guarantee Azure Spot capacity, prevent Spot eviction, or
bypass Azure policy. It runs under your Azure identity and writes plan files to
your Cloud Shell storage or current working directory.
