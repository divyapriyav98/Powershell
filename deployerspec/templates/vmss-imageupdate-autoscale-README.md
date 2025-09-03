# VMSS Image Update (date-autoscale) Pipeline


## Purpose
This pipeline updates the VM Scale Set (VMSS) model to reference a newly-built Shared Image Gallery (SIG) image version and performs an autoscale test by increasing capacity. It does not perform in-place instance upgrades in the `UpdateImage` job — it only updates the VMSS model so newly-created instances use the new image. The `ScaleOut` job then scales up instance count to exercise the new image in practice.

This template is useful as a post-image-build step (for canary or blue-green tests) where you want to temporarily add capacity running the new image before doing a rolling upgrade across existing instances.

---

## Template parameters
The pipeline declares the following template parameters (with defaults):

| Name | Type | Default Value | Required | Usage |
|------|------|---------------|----------|-------|
| `condition` | string | `'succeeded()'` | No | Controls whether the job(s) run. Example: `and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))` |
| `galleryName` | string | `workeastussharedgallery` | No | Shared Image Gallery name used to construct the image resource ID |


---

## Important pipeline variables (recommended to set)
These values are referenced by the inline scripts. Provide them as pipeline variables, variable groups, or set by preceding stages.

| Name | Required | Description |
|------|----------|-------------|
| `azure_svc_connection` | Yes | Azure DevOps service connection used by `AzureCLI@2` tasks |
| `subscriptionId` | Yes | Subscription where the VMSS resides (used by `az account set` and VMSS commands) |
| `gallerySubscriptionId` | Yes | Subscription where the Shared Image Gallery lives (used to construct the image resource ID) |
| `galleryResourceGroup` | Yes | Resource group containing the Shared Image Gallery |
| `imageDefinition` | Yes | Image definition name under the gallery (used to build the SIG image version resource id) |
| `resourceGroup` | Yes | The resource group containing the target VMSS to update/scale |
| `imageVersion` | No | The pipeline constructs `imageVersion="1.0.$(Build.BuildId)"` if not provided |
| `newCapacity` | Yes (for ScaleOut) | Number of instances to scale the VMSS to in the `ScaleOut` job (e.g., 4) |
| `location` | No | Location used by some detection/lookup commands if needed |

Notes:
- Many values are referenced by `$(...)` token expansion in the inline scripts; confirm the calling pipeline or earlier job sets them.
- The template uses `Build.BuildId` when composing `imageVersion` which ties this template to a pipeline run that has that variable (typical in CI). Override if needed.

---

## Jobs and steps
The template defines two jobs: `UpdateImage` and `ScaleOut`.

### Job: UpdateImage
Display name: `Set new image for VMSS (no upgrade yet)`
Condition: `parameters.condition` (defaults to `succeeded()`)

Purpose: Update the VMSS model to reference a new SIG image version. This changes the VMSS `virtualMachineProfile.storageProfile.imageReference.id` to the new gallery version resource ID but does not perform instance upgrades.

Step: `UpdateImage` (AzureCLI@2)
- Task: `AzureCLI@2` with inline Bash
- Inputs: `azureSubscription` uses `$(azure_svc_connection)`
- Behavior:
  - Sets the subscription: `az account set --subscription $(subscriptionId)`
  - Fetches the VMSS name dynamically: `az vmss list --subscription $(subscriptionId) --resource-group $(resourceGroup) --query "[0].name" -o tsv`
  - Computes `imageVersion` as `1.0.$(Build.BuildId)`
  - Constructs `imageResourceId`:
    `/subscriptions/$(gallerySubscriptionId)/resourceGroups/$(galleryResourceGroup)/providers/Microsoft.Compute/galleries/$(galleryName)/images/$(imageDefinition)/versions/$imageVersion`
  - Calls `az vmss update` to set the VMSS model to use the new `imageResourceId` and clears legacy image reference fields and `plan`.
- Outputs: None explicitly emitted by `##vso[task.setvariable]` in this step. The script prints `Using Image Resource ID: $imageResourceId` to logs. If you need this as a variable, consider adding `echo "##vso[task.setvariable variable=imageResourceId]$imageResourceId"`.

Important note: The `az vmss update` call updates the model only. Existing instances will continue to run the old image until you trigger an upgrade (e.g., `az vmss update-instances` or `az vmss rolling-upgrade`), or scale operations cause new instances to be created.

---

### Job: ScaleOut
DependsOn: `UpdateImage`
Display name: `Increase instance count to test new image`
Condition: `succeeded()`

Purpose: Scale the VMSS to a larger capacity so that newly-created instances will be based on the updated model (and therefore use the new image). This is a common way to validate the new image without performing in-place upgrades.

Step: `ScaleVMSS` (AzureCLI@2)
- Inputs: `azureSubscription` uses `$(azure_svc_connection)`
- Behavior:
  - Sets subscription
  - Fetches VMSS name dynamically (same approach as UpdateImage)
  - Calls `az vmss scale --resource-group $(resourceGroup) --name $vmssName --new-capacity $(newCapacity)`
- Outputs: None explicitly emitted.


## Troubleshooting
- If the `az vmss update` command fails, check:
  - The computed `imageResourceId` is valid and accessible (correct subscription and resource group).
  - The calling service principal or managed identity has permissions to update the VMSS.
  - The VMSS resource exists in `$(resourceGroup)` and the `az vmss list` call returns expected results.

- If scaling fails in `ScaleOut`, verify:
  - `newCapacity` is provided and is a valid integer.
  - The subscription has quota for the VM size; adjust quotas if necessary.

