# SpotSwitcher

SpotSwitcher is a Cloud Shell PowerShell wizard for switching an Azure VM
between Regular and Spot by safely recreating only the VM resource wrapper.

Product page: <https://spotswitcher.vanroojen.com/>

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
  -ValidateSku No
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

## Product and Support

- Product site: <https://spotswitcher.vanroojen.com/>
- Privacy: <https://spotswitcher.vanroojen.com/privacy>
- Terms: <https://spotswitcher.vanroojen.com/terms>
- Support: <https://spotswitcher.vanroojen.com/support>
- LLM context: <https://spotswitcher.vanroojen.com/llms.txt>
- License: MIT

SpotSwitcher does not guarantee Azure Spot capacity, prevent Spot eviction, or
bypass Azure policy. It runs under your Azure identity and writes plan files to
your Cloud Shell storage or current working directory.
