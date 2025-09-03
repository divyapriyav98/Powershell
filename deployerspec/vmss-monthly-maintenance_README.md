# VMSS Monthly Maintenance ADO Pipeline

## Summary

This Azure DevOps ADO Pipeline performs monthly maintenance operations on Virtual Machine Scale Sets (VMSS) by integrating with Artifactory to fetch updated OS image templates and apply them to VMSS resources. The ADO Pipeline consists of two main phases: artifact discovery and VMSS update processing. It monitors an Artifactory repository for new VHD templates, processes them through Azure Storage, and conditionally updates VMSS instances with new image versions.

**Key Operations:**
- Accesses Artifactory repository to retrieve OS template information
- Processes VHD files through Azure Storage integration
- Conditionally updates VMSS with new image versions based on artifact availability
- Maintains processing status tracking through Azure Storage Tables
- Supports PowerShell Core scripting for cross-platform execution

---

## Parameters

This ADO Pipeline uses variables instead of parameters. All configuration through variables |

---

## Variables

| Name | Description | Value/Usage |
|------|-------------|-------------|
| `azure_svc_connection` | Azure service connection for authentication | `abt-devops-agents-work-sp` |
| `osbOutputSecretName` | Dynamic secret name for ADO Pipeline outputs | `az-$(System.DefinitionId)-$(Build.BuildId)` |
| `tagName` | Tag name for VMSS resource identification | `VMSSCreatedOn` |
| `subscriptionId` | Target Azure subscription ID | `bd341354-d4c1-4de2-996f-6228b587337c` |
| `AZURE_CORE_OUTPUT` | Azure CLI output format control | `none` (stage-level) |

### **Job-Level Variables (Dynamic)**

| Name | Description | Source | Usage |
|------|-------------|--------|-------|
| `NEW_VERSION_FOUND` | Boolean indicating if new artifacts are available | Output from `Fetch_Image_Info` task | Conditional job execution |
| `ARTIFACT_TO_PROCESS` | JSON data of artifact to be processed | Output from `Fetch_Image_Info` task | Image update processing |
| `storageAccount` | Azure storage account name for artifact processing | Output from `Fetch_Image_Info` task | Storage operations |
| `resourceGroup` | Target resource group for operations | Hardcoded: `persistent-qeslfbevq-avms-dev14-work-eastus` | Resource targeting |

---

## ADO Pipeline Structure

### **Triggers and Configuration**
- **Manual Trigger**: `trigger: none` (manual execution only)
- **PR Trigger**: `pr: none` (disabled for PR builds)
- **Agent Pool**: `abt-provisoner-service-work-agents`
- **ADO Pipeline Name**: `VMSS_Deployer_$(System.DefinitionId)_$(Build.BuildId)`

---

## Stages, Jobs, and Tasks

### **Stage 1: VMSS_Maintenance**
- **Display Name**: "VMSS MontlyMaintenance"
- **Purpose**: Orchestrates the complete maintenance workflow for VMSS resources

#### **Job 1: Access_File_in_Artifactory**
- **Display Name**: "Access_File_in_Artifactory"
- **Timeout**: 180 minutes
- **Purpose**: Connects to Artifactory repository to discover and process available OS template artifacts

##### **Task 1.1: Fetch_Image_Info**
- **Task Type**: `AzureCLI@2`
- **Display Name**: "Upload Artifactory files"
- **Script Type**: PowerShell Core (`pscore`)
- **Script Location**: External file

**Purpose**: Executes PowerShell script to interact with Artifactory and Azure Storage for artifact management.

**Configuration**:
```yaml
scriptPath: '$(Build.SourcesDirectory)/azure-ADO Pipelines/scripts/uploadfiles.ps1'
arguments: "-resourceGroup persistent-qeslfbevq-avms-dev14-work-eastus"
addSpnToEnvironment: true
```

**Environment Variables**:
- `SUBSCRIPTION_ID`: `$(subscriptionId)`
- `ARTIFACT_URLS`: `https://artifacts.eastus.az.mastercard.int/artifactory/archive-internal-stable/com/mastercard/ias/os-templates/vhd/`
- `SERVICEBOOTSTRAPNAME`: Empty string

**Outputs Set**:
- `NEW_VERSION_FOUND`: Boolean flag for conditional execution
- `ARTIFACT_TO_PROCESS`: JSON artifact data
- `storageAccountName`: Storage account for processing

---

#### **Job 2: Update_VMSS**
- **Display Name**: "Update VMSS with New Image"
- **Dependencies**: `Access_File_in_Artifactory`
- **Condition**: `and(succeeded(), eq(dependencies.Access_File_in_Artifactory.outputs['Fetch_Image_Info.NEW_VERSION_FOUND'], 'true'))`

**Purpose**: Conditionally executes VMSS updates when new artifacts are discovered.

##### **Task 2.1: Update_VM_with_NewVersion**
- **Task Type**: `AzureCLI@2`
- **Display Name**: "Update_VM_with_NewVersion"
- **Script Type**: PowerShell Core (`pscore`)
- **Script Location**: Inline script

**Purpose**: Processes discovered artifacts and updates VMSS with new image versions.

**Script Operations**:

1. **Artifact Validation**:
   ```powershell
   $artifactJson = '$(ARTIFACT_TO_PROCESS)'
   if ([string]::IsNullOrEmpty($artifactJson)) {
       # Exit with warning if no artifacts to process
   }
   ```

2. **JSON Processing**:
   ```powershell
   $artifact = $artifactJson | ConvertFrom-Json
   # Parse artifact metadata for processing
   ```

3. **Azure Storage Integration**:
   ```powershell
   $accountKey = az storage account keys list --account-name $storageAccount
   # Retrieve storage account access credentials
   ```

4. **Status Tracking**:
   ```powershell
   az storage entity merge \
       --table-name "VmssArtifactoryList" \
       --entity PartitionKey=$($artifact.PartitionKey) RowKey=$($artifact.RowKey) Processed='yes'
   ```

5. **TODO Implementation**:
   - Currently contains placeholder for actual VMSS update logic
   - Intended to apply new image versions to VMSS instances

**Variables Used**:
- `$(ARTIFACT_TO_PROCESS)`: Artifact JSON data
- `$(storageAccount)`: Storage account name
- `$(resourceGroup)`: Target resource group
- `$(subscriptionId)`: Azure subscription context

**Error Handling**:
- Validates required variables before processing
- Checks Azure CLI command exit codes
- Provides structured logging with Azure DevOps task logging format

---

## ADO Pipeline Flow

### **Execution Sequence**:

```
1. ADO Pipeline Triggered (Manual)
   ↓
2. Stage: VMSS_Maintenance
   ↓
3. Job: Access_File_in_Artifactory
   a. Execute uploadfiles.ps1 script
   b. Connect to Artifactory repository
   c. Process VHD template artifacts
   d. Set output variables:
      - NEW_VERSION_FOUND (boolean)
      - ARTIFACT_TO_PROCESS (JSON)
      - storageAccountName (string)
   ↓
4. Conditional Evaluation
   - Check if NEW_VERSION_FOUND == 'true'
   ↓
5. Job: Update_VMSS (if condition met)
   a. Parse artifact JSON data
   b. Validate storage account information
   c. Retrieve storage account keys
   d. Update artifact status to 'Processed'
   e. [TODO] Apply new image to VMSS instances
```

### **Data Flow Architecture**:

```
Artifactory Repository
         ↓
   uploadfiles.ps1
         ↓
   Azure Storage Tables
         ↓
   ADO Pipeline Variables
         ↓
   VMSS Update Process
         ↓
   Status Tracking Update
```

### **Conditional Logic**:
- **Job Dependency**: `Update_VMSS` depends on `Access_File_in_Artifactory`
- **Execution Condition**: Only runs if new artifacts are found
- **Failure Handling**: ADO Pipeline continues even if individual operations fail



## Dependencies

- **External Scripts**: `uploadfiles.ps1` in `azure-ADO Pipelines/scripts/` directory
- **Azure CLI**: All operations use Azure CLI commands
- **PowerShell Core**: Cross-platform PowerShell execution
- **Artifactory Access**: Network connectivity to Mastercard Artifactory
- **Azure Storage**: Tables for status tracking
- **Service Principal**: `abt-devops-agents-work-sp` with appropriate permissions
