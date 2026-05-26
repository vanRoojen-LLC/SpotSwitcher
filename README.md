# SpotSwitcher

SpotSwitcher is a Cloud Shell PowerShell wizard for switching an Azure VM
between Regular and Spot by safely recreating only the VM resource wrapper.

With no parameters, it discovers subscriptions, VMs, the source VM priority,
and the choices needed for the correct direction:

- Regular or null priority -> convert to Spot
- Spot or legacy Low priority -> convert to Regular

Default mode is read-only plan generation.

```powershell
./Convert-AzureVmToSpot.ps1
```

Execute interactively after reviewing the generated command plan:

```powershell
./Convert-AzureVmToSpot.ps1 -Mode Execute
```

Run unattended with explicit parameters:

```powershell
./Convert-AzureVmToSpot.ps1 `
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
