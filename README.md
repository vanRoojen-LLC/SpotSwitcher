# SpotSwitcher

SpotSwitcher is a Cloud Shell PowerShell wizard for switching an Azure VM
between Regular and Spot by safely recreating only the VM resource wrapper.

With no parameters, it discovers subscriptions, VMs, the source VM priority,
and the choices needed for the correct direction:

- Regular or null priority -> convert to Spot
- Spot or legacy Low priority -> convert to Regular

Default mode is read-only plan generation.
After subscription selection, choose whether to browse VMs in the subscription
or enter the resource group and VM name manually. Manual entry avoids a
subscription-wide VM list call.
When converting to Spot, the SKU picker only offers the current VM size if it
is Spot-capable and appears to fit available quota. Otherwise it recommends the
closest unrestricted, quota-eligible Spot size. Browse results are shown five at
a time.

Run the latest version directly in Azure Cloud Shell PowerShell:

```powershell
iwr https://raw.githubusercontent.com/vanRoojen-LLC/SpotSwitcher/main/Switch-AzureVmSpotPriority.ps1 -OutFile ./Switch-AzureVmSpotPriority.ps1; ./Switch-AzureVmSpotPriority.ps1
```

```powershell
./Switch-AzureVmSpotPriority.ps1
```

Execute interactively after reviewing the generated command plan:

```powershell
./Switch-AzureVmSpotPriority.ps1 -Mode Execute
```

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

The script writes plan files to `~/clouddrive/SpotSwitcherPlans` in Cloud Shell
when Cloud Drive is mounted, otherwise to `./SpotSwitcherPlans`.

Azure Spot VMs cannot be created in availability sets. If a source VM is in an
availability set, SpotSwitcher prompts before intentionally dropping that
membership for a Spot conversion. In unattended mode, pass
`-DropAvailabilitySetForSpot Yes` to make that choice explicit.
