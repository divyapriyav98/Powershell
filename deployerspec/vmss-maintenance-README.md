# VMSS Maintenance ADO Pipeline

## Summary

This Azure DevOps ADO Pipeline performs maintenance operations on Virtual Machine Scale Sets (VMSS) by identifying instances marked for upgrade and applying the latest image versions from Azure Compute Gallery. The ADO Pipeline queries VMSS resources tagged with `VMSSUpgrade=True`, retrieves the latest image versions from the associated galleries, updates the VMSS with new images, and scales them out to trigger instance updates. It handles both marketplace and custom images appropriately and supports cross-subscription scenarios where images and VMSS reside in different subscriptions.

**Key Operations:**
- Queries VMSS resources with `VMSSUpgrade=True` tag
- Retrieves latest image versions from Azure Compute Gallery
- Handles cross-subscription image and VMSS scenarios  
- Updates VMSS with latest image versions
- Differentiates between marketplace and custom image handling
- Scales out VMSS to trigger instance updates with new images
- Resets upgrade tags after processing

---
## Parameters

| Name | Description | Default Value | Optional/Required | Condition |
|------|-------------|---------------|-------------------|-----------|
| `subscriptionId` | Azure subscription ID containing target VMSS resources | `bd341354-d4c1-4de2-996f-6228b587337c` | Optional | Used across all Azure CLI operations |

---
## Variables

| Name | Description | Value/Usage |
|------|-------------|-------------|
| `azure_svc_connection` | Azure service connection for authentication | `abt-devops-agents-work-sp` |
| `osbOutputSecretName` | Dynamic secret name for ADO Pipeline outputs | `az-$(System.DefinitionId)-$(Build.BuildId)` |
| `imageTemplateName` | Template name for image builds | `rhel8-novmtools-$(Build.BuildId)` |
| `imageVersion` | Version format for created images | `1.0.$(Build.BuildId)` |
| `userAssignedIdentityName` | User-assigned identity for VM operations | `id-vmss-builder-$(Build.BuildId)` |
| `GALLERY_NAME` | Shared image gallery name | `workeastussharedgallery` |
| `GALLERY_RG` | Resource group containing the gallery | `rg-work-eastus-sharedgallery` |
| `IMAGE_DEFINITION_NAME` | Image definition name in the gallery | `mc_rhel8_java8` |
| `gallery_subscription_id` | Subscription ID containing the image gallery | `58ac996b-18bf-4b6b-913b-6d963ee15fb3` |
| `scaleUpCount` | Number of instances to add during scaling | `1` |

### **Runtime Variables (Dynamic)**

| Name | Description | Source | Usage |
|------|-------------|--------|-------|
| `vmss_list` | Tab-separated list of VMSS name and resource group pairs | Set by query task | Processing target VMSS |
| `image_rg` | Resource group containing the image | Extracted from VMSS configuration | Image operations |
| `image_name` | Image definition name | Extracted from VMSS configuration | Gallery queries |
| `gallery_name` | Gallery name | Extracted from VMSS configuration | Image version retrieval |
| `image_subscription_id` | Subscription containing the image | Extracted from image ID | Context switching |

---

## ADO Pipeline Structure

### **Triggers and Configuration**
- **Manual Trigger**: `trigger: none` (manual execution only)
- **PR Trigger**: `pr: none` (disabled for PR builds) 
- **Agent Pool**: `abt-provisoner-service-work-agents`
- **ADO Pipeline Name**: `VMSS_Deployer_$(System.DefinitionId)_$(Build.BuildId)`

### **External Resources**
- **Repository**: `azdo-yaml-templates` (Git repository for shared templates)
- **Branch**: `feature/vmss-deploy-service`

---

## Stages, Jobs, and Tasks

### **Stage 1: VMSSMaintenance**
- **Display Name**: "VMSS Maintenance"
- **Purpose**: Orchestrates the complete VMSS upgrade workflow

#### **Job 1: QueryVMSS**
- **Display Name**: "Query VMSS Upgrade List"
- **Purpose**: Identifies and processes VMSS instances marked for maintenance

##### **Task 1.1: List VMSS with Upgrade Tag**
- **Task Type**: `AzureCLI@2`
- **Display Name**: "List VMSS with tag 'VMSSupgrade=true'"
- **Script Type**: `bash`
- **Script Location**: Inline script

**Purpose**: Queries subscription for VMSS resources tagged for upgrade and validates subscription context.

**Script Operations**:

1. **Subscription Context Setup**:
   ```bash
   subscriptionId="${{ parameters.subscriptionId }}"
   az account set --subscription "$subscriptionId"
   az account show --query "{Name:name, ID:id}" -o table
   ```

2. **VMSS Discovery**:
   ```bash
   # List all VMSS in subscription
   az vmss list --subscription "$subscriptionId" -o table
   
   # Filter VMSS with upgrade tag
   az vmss list --query "[?tags.VMSSUpgrade=='True'].[name, resourceGroup]" -o table
   ```

3. **Results Processing**:
   ```bash
   vmss_list=$(az vmss list --subscription "$subscriptionId" --query "[?tags.VMSSUpgrade=='true'].[name, resourceGroup]" -o tsv)
   
   if [ -z "$vmss_list" ]; then
       echo "No VMSS found with tag 'VMSSUpgrade=True'."
   else
       echo "Found VMSS to upgrade:"
       echo "$vmss_list"
   fi
   ```

**Variables Set**:
- `vmss_list`: Tab-separated values of VMSS name and resource group pairs

**Configuration**:
- `failOnStandardError: true` - ADO Pipeline fails on script errors

---

##### **Task 1.2: Upgrade VMSS with Latest Images**
- **Task Type**: `AzureCLI@2`
- **Display Name**: "Upgrade VMSS with Image from Gallery and Update Tag"
- **Script Type**: `bash`
- **Script Location**: Inline script

**Purpose**: Main processing task that upgrades each identified VMSS with latest image versions.

**Script Operations**:

1. **Re-query Target VMSS**:
   ```bash
   vmss_list=$(az vmss list --subscription "${{ parameters.subscriptionId }}" --query "[?tags.VMSSUpgrade=='True'].[name, resourceGroup]" -o tsv)
   ```

2. **VMSS Processing Loop**:
   ```bash
   echo "$vmss_list" | while IFS=$'\t' read -r vmss_name resource_group; do
       # Process each VMSS individually
   done
   ```

3. **Image Reference Analysis**:
   ```bash
   # Get current image reference from VMSS
   image_reference=$(az vmss show --resource-group "$resource_group" --name "$vmss_name" --query "virtualMachineProfile.storageProfile.imageReference" -o json)
   
   # Extract image details using jq
   image_rg=$(echo "$image_reference" | jq -r '.id | split("/") | .[4]')
   image_name=$(echo "$image_reference" | jq -r '.id | split("/") | .[10]')
   gallery_name=$(echo "$image_reference" | jq -r '.id | split("/") | .[8]')
   image_subscription_id=$(echo "$image_reference" | jq -r '.id | split("/") | .[2]')
   ```

4. **Cross-Subscription Context Switching**:
   ```bash
   # Switch to image subscription
   az account set --subscription "$image_subscription_id"
   
   # Find latest image version
   latest_image_version_id=$(az sig image-version list --gallery-name "$gallery_name" --gallery-image-definition "$image_name" --resource-group "$image_rg" --query "sort_by(@, &publishingProfile.publishedDate)[-1].id" -o tsv)
   
   # Switch back to VMSS subscription  
   az account set --subscription "${{ parameters.subscriptionId }}"
   ```

5. **Image Type Detection and Update**:
   ```bash
   is_marketplace_image=$(echo "$image_reference" | jq -r '.id | test("/subscriptions/.*/resourceGroups/.*/providers/Microsoft.Compute/images/.*/versions/.+")')
   
   if [ "$is_marketplace_image" = "true" ]; then
       # Marketplace image - Standard upgrade
       az vmss update --name "$vmss_name" --resource-group "$resource_group" --set virtualMachineProfile.storageProfile.imageReference.id="$latest_image_version_id"
   else
       # Custom image - Remove plan information
       az vmss update --name "$vmss_name" --resource-group "$resource_group" --set virtualMachineProfile.storageProfile.imageReference.id="$latest_image_version_id" plan=null
   fi
   ```

6. **VMSS Scaling Operation**:
   ```bash
   # Get current capacity
   currentCapacity=$(az vmss list-instances --resource-group "$resource_group" --name "$vmss_name" --query "length(@)" -o tsv)
   
   # Calculate new capacity
   newCapacity=$((currentCapacity + $(scaleUpCount)))
   
   # Scale VMSS
   az vmss scale --resource-group "$resource_group" --name "$vmss_name" --new-capacity $newCapacity
   ```

7. **Tag Management** (Currently commented):
   ```bash
   # Reset upgrade tag (commented out)
   # az vmss update --name "$vmss_name" --resource-group "$resource_group" --set tags.VMSSUpgrade=false
   ```

**Environment Variables Used**:
- `gallery_subscription_id`: `$(gallery_subscription_id)`
- `scaleUpCount`: `$(scaleUpCount)`

**Error Handling**:
- `set -euo pipefail` - Strict error handling
- Validates VMSS entries before processing
- Skips VMSS without valid image references
- Continues processing remaining VMSS if individual operations fail

---

## ADO Pipeline Flow

### **Execution Sequence**:

```
1. ADO Pipeline Triggered (Manual)
   ↓
2. Stage: VMSSMaintenance
   ↓
3. Job: QueryVMSS
   ↓
4. Task: List VMSS with Upgrade Tag
   a. Set subscription context
   b. Query all VMSS in subscription  
   c. Filter VMSS with VMSSUpgrade=True tag
   d. Set vmss_list variable
   ↓
5. Task: Upgrade VMSS with Latest Images
   For each VMSS in vmss_list:
   a. Get current image reference
   b. Extract image details (RG, name, gallery, subscription)
   c. Switch to image subscription context
   d. Find latest published image version
   e. Switch back to VMSS subscription
   f. Determine image type (marketplace vs custom)
   g. Update VMSS with latest image version
   h. Scale out VMSS to trigger instance refresh
   i. [TODO] Reset VMSSUpgrade tag to false
```

### **Data Flow Architecture**:

```
Azure Subscription (VMSS)
         ↓
   Tag-based Query (VMSSUpgrade=True)
         ↓
   VMSS Configuration Analysis
         ↓
Azure Subscription (Images) ←→ Context Switch
         ↓
   Latest Image Version Discovery
         ↓
Azure Subscription (VMSS) ←→ Context Switch Back  
         ↓
   VMSS Image Update + Scaling
         ↓
   Instance Refresh Trigger
```

### **Cross-Subscription Handling**:

1. **Primary Subscription**: Contains target VMSS resources
2. **Image Subscription**: Contains Azure Compute Gallery with images
3. **Context Switching**: Automatic switching between subscriptions for operations
4. **Service Principal**: Must have access to both subscriptions

### **Error Recovery and Validation**:

- **Subscription Validation**: Verifies subscription access before operations
- **VMSS Validation**: Checks for valid VMSS entries and image references
- **Image Validation**: Ensures image versions exist before attempting updates
- **Graceful Failure**: Continues processing remaining VMSS if individual operations fail
- **Detailed Logging**: Comprehensive output for troubleshooting

---

## Dependencies

- **Azure CLI**: All operations use Azure CLI commands with `jq` for JSON processing
- **Service Principal**: `abt-devops-agents-work-sp` with cross-subscription access
- **Azure Compute Gallery**: Source for latest image versions
- **VMSS Tagging**: Requires `VMSSUpgrade=True` tag on target VMSS
- **External Repository**: `azdo-yaml-templates` for shared ADO Pipeline components
