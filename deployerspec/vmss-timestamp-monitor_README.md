# VMSS Timestamp Monitor Pipeline

## Summary

This Azure DevOps pipeline monitors Virtual Machine Scale Sets (VMSS) based on timestamp tags and performs automated maintenance operations. The pipeline identifies VMSS instances older than 7 days using a `VMSSCreatedOn` tag, updates them with current timestamps, upgrades their images to the latest versions, and scales them out. It also identifies old Virtual Machines for monitoring purposes.

**Key Operations:**
- Identifies VMSS and VMs older than 7 days based on tags
- Updates VMSS tags with current timestamp
- Upgrades VMSS to latest image versions from Azure Compute Gallery
- Scales out VMSS by adding additional instances
- Handles both marketplace and custom images appropriately

---

## Parameters

| Name | Description | Default Value | Optional/Required | Condition |
|------|-------------|---------------|-------------------|-----------|
| `subscriptionId` | Azure subscription ID where resources are located | `bd341354-d4c1-4de2-996f-6228b587337c` | Optional | Used across all Azure CLI tasks |

---

## Variables

| Name | Description | Value/Usage |
|------|-------------|-------------|
| `azure_svc_connection` | Azure service connection name for authentication | `abt-devops-agents-work-sp` |
| `osbOutputSecretName` | Dynamic secret name using system variables | `az-$(System.DefinitionId)-$(Build.BuildId)` |
| `tagName` | Tag name used to identify VMSS creation timestamp | `VMSSCreatedOn` |
| `oldVmssList` | Runtime variable storing comma-separated list of old VMSS | Set dynamically by tasks |
| `vm_list` | Runtime variable storing information about old VMs | Set dynamically by tasks |

---

## Pipeline Structure

### **Pool Configuration**
- **Agent Pool**: `abt-provisoner-service-work-agents`
- **Trigger**: Manual only (none)
- **PR Trigger**: Disabled (none)

---

## Steps and Tasks

### **Step 1: Identify Old VMSS**
- **Task Type**: `AzureCLI@2`
- **Name**: `IdentifyOldVMSS`
- **Display Name**: "Identify VMSS that are 7 days old"

**Purpose**: Scans subscription for VMSS resources with `VMSSCreatedOn` tags older than 7 days.

**Script Logic**:
```bash
# Sets 7-day threshold timestamp
threshold=$(date -d "-7 days" +%s)

# Queries VMSS resources with specified tag
az resource list --resource-type "Microsoft.Compute/virtualMachineScaleSets" --query "[?tags.$tagName]"

# Processes each VMSS to check timestamp
# Builds comma-separated list of old VMSS names and resource groups
```

**Variables Set**:
- `oldVmssList`: Format `vmss1:rg1,vmss2:rg2,...`

**Environment Variables Used**:
- `tagName`: `$(tagName)`

---

### **Step 2: List Old VMs**
- **Task Type**: `AzureCLI@2`
- **Name**: `ListVMs`
- **Display Name**: Default

**Purpose**: Identifies Virtual Machines with `VMSSCreatedOn` tags older than 7 days for monitoring.

**Script Logic**:
```bash
# Calculates threshold date (7 days ago)
thresholdDate=$(date -d "7 days ago" '+%Y-%m-%dT%H:%M:%SZ')

# Queries VMs with VMSSCreatedOn tag using jq for date comparison
az vm list --query "[?tags.VMSSCreatedOn!=null]" | jq filtering
```

**Variables Set**:
- `vm_list`: Information about VMs older than threshold

**Environment Variables Used**:
- `thresholdDate`: `$(thresholdDate)`

---

### **Step 3: Make Script Executable**
- **Task Type**: `script`
- **Display Name**: "Make Dummy Script Executable"

**Purpose**: Sets executable permissions on dummy certificate script.

**Command**: `chmod +x '$(Build.SourcesDirectory)/azure-pipelines/scripts/dummy-certs.sh'`

---

### **Step 4: Run Dummy Script**
- **Task Type**: `script`
- **Display Name**: "Run Dummy Certs Script from File"

**Purpose**: Executes dummy certificate script (likely for testing or placeholder purposes).

**Command**: `'$(Build.SourcesDirectory)/azure-pipelines/scripts/dummy-certs.sh'`

---

### **Step 5: Update VMSS and Scale Out**
- **Task Type**: `AzureCLI@2`
- **Display Name**: "Step 3: Update VMSS with current date and Latest Image and Scale Out"

**Purpose**: Main processing step that updates, upgrades, and scales identified old VMSS instances.

**Script Operations**:

1. **Tag Update**:
   ```bash
   az vmss update --name "$vmss_name" --resource-group "$rg_name" --set tags.VMSSCreatedOn="$current_date"
   ```

2. **Image Analysis**:
   ```bash
   # Extract image reference details
   image_reference=$(az vmss show --query "virtualMachineProfile.storageProfile.imageReference")
   # Parse subscription, resource group, gallery, and image name
   ```

3. **Latest Version Lookup**:
   ```bash
   # Find latest published image version
   az sig image-version list --gallery-name "$gallery_name" --gallery-image-definition "$image_name"
   ```

4. **Image Upgrade**:
   - **Marketplace Images**: Standard upgrade process
   - **Custom Images**: Removes plan information before upgrade
   ```bash
   if [ "$is_marketplace_image" = "true" ]; then
       # Standard upgrade
   else
       # Remove plan info for custom images
       az vmss update --set plan=null
   fi
   ```

5. **Scaling Operation**:
   ```bash
   # Get current capacity and add 1 instance
   currentCapacity=$(az vmss list-instances --query "length(@)")
   newCapacity=$((currentCapacity + scaleUpCount))
   az vmss scale --new-capacity "$newCapacity"
   ```

**Variables Used**:
- `scaleUpCount`: Set to `1` (hardcoded increment)
- `current_date`: Today's date in YYYY-MM-DD format

**Environment Variables Used**:
- `oldVmssList`: `$(oldVmssList)` - List from Step 1

---

## Pipeline Flow

### **Execution Sequence**:

```
1. Pipeline Triggered (Manual)
   ↓
2. Identify Old VMSS (7+ days old)
   ↓ [Sets: oldVmssList]
3. List Old VMs (7+ days old)
   ↓ [Sets: vm_list]
4. Make Dummy Script Executable
   ↓
5. Run Dummy Certs Script
   ↓
6. Process Each Old VMSS:
   a. Update timestamp tag
   b. Get current image reference
   c. Switch to image subscription context
   d. Find latest image version
   e. Switch back to target subscription
   f. Update VMSS with latest image
   g. Scale out VMSS (+1 instance)
```

### **Data Flow**:
- **Input**: `subscriptionId` parameter
- **Discovery**: VMSS/VM resources with `VMSSCreatedOn` tags
- **Processing**: Image upgrades and scaling for identified resources
- **Output**: Updated and scaled VMSS instances

### **Error Handling**:
- Skip VMSS with invalid date formats
- Skip VMSS without image references
- Skip VMSS without published image versions
- Continue processing remaining VMSS if individual operations fail

### **Cross-Subscription Support**:
The pipeline handles scenarios where:
- VMSS exists in target subscription
- Image gallery exists in different subscription
- Automatic context switching between subscriptions


