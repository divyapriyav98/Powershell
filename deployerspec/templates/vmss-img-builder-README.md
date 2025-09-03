# VMSS Image Builder ADO Pipeline

## Summary

This Azure DevOps template ADO Pipeline automates the creation of custom Virtual Machine Scale Set (VMSS) images using Azure Image Builder (AIB) and Shared Image Gallery (SIG). The ADO Pipeline provides a comprehensive image building solution that handles identity management, artifact staging, source image detection, and automated image template generation. It supports both Marketplace-based and custom SIG images as source, automatically detects plan information for licensing compliance, and stages application artifacts into storage accounts for image customization.

**Key Operations:**
- Creates and manages Azure Image Builder identities with appropriate RBAC permissions
- Downloads and stages artifacts from external URLs to Azure Storage for image customization
- Detects source image types (Marketplace vs. SIG) and extracts plan information for licensing compliance
- Generates comprehensive AIB templates with customization scripts and file transfers
- Executes Image Builder workflows to produce versioned images in Shared Image Gallery
- Outputs new image resource IDs for downstream ADO Pipeline consumption

---

## Parameters

| Name | Type | Default Value | Required | Description |
|------|------|---------------|----------|-------------|
| `condition` | string | `'succeeded()'` | No | Controls whether the BuildImage job runs. Supports ADO condition expressions |
| `galleryName` | string | `workeastussharedgallery` | No | Azure Compute Gallery name used to publish image versions |
| `galleryResourceGroup` | string | `rg-work-eastus-sharedgallery` | No | Resource group containing the Azure Compute Gallery |
| `galleryImageDefinitionName` | string | `imagebuildertest` | No | Gallery image definition name for the target image |
| `subscriptionId` | string | `58ac996b-18bf-4b6b-913b-6d963ee15fb3` | No | Subscription ID for AIB resource creation |
| `gallerySubscriptionId` | string | `58ac996b-18bf-4b6b-913b-6d963ee15fb3` | No | Subscription ID for the Shared Image Gallery (defaults to subscriptionId) |
| `storageContainerName` | string | `imagebuilderartifacts` | No | Storage container name for artifact staging |
| `baseImagePublisher` | string | `Mastercard` | No | Base image publisher for Marketplace images |
| `baseImageOffer` | string | `mc_rhel8_fake` | No | Base image offer for Marketplace images |
| `baseImageSku` | string | `mc_rhel8_java8` | No | Base image SKU for Marketplace images |
| `baseImageVersion` | string | `latest` | No | Base image version for Marketplace images |
| `sourceImageVersionId` | string | `''` | No | Explicit source Shared Image Version ID (if building from specific SIG version) |

---

## Variables

### **Required ADO Pipeline Variables**

| Name | Description | Usage |
|------|-------------|-------|
| `azure_svc_connection` | Azure service connection name | Used by all AzureCLI@2 tasks for authentication |
| `resourceGroup` | AIB resource group | Target resource group for Image Builder resources |
| `galleryResourceGroup` | Gallery resource group | Resource group containing Shared Image Gallery |
| `storageAccount` | Storage account name | Used for artifact staging and customization |
| `userAssignedIdentityName` | Managed identity name | User-assigned identity for AIB operations |
| `location` | Azure region | Region for resource creation and image building |
| `imageTemplateName` | Image template name | Name for the Azure Image Builder template |
| `imageDefinition` | Image definition name | Gallery image definition identifier |
| `vmImageSubnetId` | Subnet resource ID | Subnet for AIB VM during build process |

### **Optional ADO Pipeline Variables**

| Name | Description | Default Behavior |
|------|-------------|------------------|
| `serviceArtifacts` | Space-separated list of artifact URLs | If empty, no artifacts are downloaded |
| `serviceSetupScript` | Space-separated list of setup script URLs | If empty, no setup scripts are processed |
| `vNetResourceGroupName` | VNet resource group name | Used for network-related RBAC assignments |

### **Dynamic Variables Set by ADO Pipeline**

| Name | Description | Set By Task |
|------|-------------|-------------|
| `identityResourceId` | Resource ID of managed identity | Create Resources and AIB Identity |
| `identityPrincipalId` | Principal ID of managed identity | Create Resources and AIB Identity |
| `<FILENAME>_BLOB_URL` | Blob URL for uploaded artifacts | Download and Upload Artifacts (dynamic per file) |
| `hasPlan` | Boolean indicating plan information presence | Detect Source Image Type |
| `planName` | Marketplace plan name | Detect Source Image Type |
| `planProduct` | Marketplace plan product | Detect Source Image Type |
| `planPublisher` | Marketplace plan publisher | Detect Source Image Type |
| `sourceImageTypeForTemplate` | Source type for AIB template | Detect Source Image Type |
| `sourceImageVersionId` | Computed source image version ID | Detect Source Image Type |
| `effectiveBaseImagePublisher` | Discovered base image publisher | Detect Source Image Type |
| `effectiveBaseImageOffer` | Discovered base image offer | Detect Source Image Type |
| `effectiveBaseImageSku` | Discovered base image SKU | Detect Source Image Type |
| `newImageGalleryResourceID` | Resource ID of newly created image | Create and Run Image Builder Template |

---

## ADO Pipeline Structure

### **Job Configuration**
- **Job Name**: `BuildImage`
- **Display Name**: "Build VMSS Image"
- **Timeout**: 180 minutes
- **Condition**: `${{ parameters.condition }}` (default: `succeeded()`)
- **Agent Pool**: Inherited from calling ADO Pipeline

---

## Tasks

### **Task 1: Create Resources and AIB Identity**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Validates and retrieves user-assigned managed identity information required for AIB operations

**Operations**:
- Retrieves principal ID and resource ID of existing managed identity
- Validates identity exists in specified resource group
- Fails ADO Pipeline if identity is not found

**Configuration Variables Used**:
- `userAssignedIdentityName`: Target identity name
- `resourceGroup`: AIB resource group
- `location`: Azure region
- `subscriptionId`: Target subscription
- `storageAccount`: Storage account name (for logging)

**Output Variables Set**:
- `identityResourceId`: Full ARM resource ID of the managed identity
- `identityPrincipalId`: Object ID of the identity for RBAC assignments

**Error Handling**: Exits with error code 1 if identity Principal ID cannot be retrieved

---

### **Task 2: Assign Roles & Verify Permissions**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Configures RBAC permissions and validates access for the AIB identity

**RBAC Assignments**:
- **Contributor** role on AIB resource group scope
- **Contributor** role on Gallery resource group scope  
- **Storage Blob Data Reader** role on Storage Account scope
- **Reader** role on source image scope
- **Virtual Machine Contributor** role on VNet resource group scope

**Network Configuration**:
- Updates storage account network rules to allow access
- Sets default action to "Allow" for storage account

**Verification Process**:
- Waits 120 seconds for role assignment propagation
- Tests storage access using managed identity authentication
- Validates permissions by listing storage containers

**Configuration Variables Used**:
- `identityPrincipalId`: From previous task
- `resourceGroup`: AIB resource group
- `galleryResourceGroup`: Gallery resource group
- `subscriptionId`: Target subscription
- `gallerySubscriptionId`: Gallery subscription
- `storageAccount`: Storage account name
- `galleryName`: Gallery name
- `imageDefinition`: Image definition name
- `vNetResourceGroupName`: VNet resource group

**Error Handling**: Fails ADO Pipeline if managed identity cannot access storage account after role assignment

---

### **Task 3: Download and Upload Artifacts**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Downloads external artifacts and uploads them to Azure Storage for image customization

**Artifact Processing**:
1. **Container Management**: Creates storage container if it doesn't exist
2. **Artifact Download**: Downloads files from provided URLs using curl
3. **Storage Upload**: Uploads files to specified storage container
4. **URL Generation**: Creates blob URLs for each uploaded artifact
5. **Variable Setting**: Sets ADO Pipeline variables with blob URLs for downstream consumption

**Input Processing**:
- Processes `serviceArtifacts`: Space-separated list of artifact URLs
- Processes `serviceSetupScript`: Space-separated list of script URLs
- Converts space-separated strings to JSON arrays for processing

**Configuration Variables Used**:
- `storageAccount`: Target storage account
- `storageContainerName`: Container for artifacts
- `resourceGroup`: Storage account resource group
- `subscriptionId`: Target subscription
- `serviceArtifacts`: External artifact URLs
- `serviceSetupScript`: External script URLs

**Output Variables Set** (Dynamic):
For each uploaded file, creates a variable named `<UPPERCASE_FILENAME_WITH_DOTS_AND_DASHES_REPLACED>_BLOB_URL`

**Artifact Tracking**: Creates `artifact_urls.json` file with metadata for all processed artifacts

**Error Handling**: Fails ADO Pipeline if any artifact download or upload fails

---

### **Task 4: Detect Source Image Type**
- **Task Type**: `AzureCLI@2`
- **Task Name**: `DetectSourceImageInfo`
- **Purpose**: Analyzes source image to determine type, plan information, and build appropriate AIB template parameters

**Source Image Analysis**:
1. **Gallery Definition Inspection**: Retrieves image definition metadata from SIG
2. **Plan Detection**: Extracts plan information for Marketplace-originated images
3. **Source Type Determination**: Decides between `PlatformImage` and `SharedImageGallery` source types
4. **Publisher Validation**: Validates publisher information against known patterns

**Publisher-Specific Logic**:

**Marketplace Plan Detection**:
- **Explicit Plan**: Uses plan information from image definition if available
- **Mastercard Images**: Special handling for Mastercard-published images
- **Standard Marketplace**: Recognizes common Marketplace publishers
- **Custom Images**: Handles truly custom SIG images without Marketplace origin

**Plan Information Sources**:
- Direct plan fields from image definition
- Publisher/offer/SKU extraction from image identifier
- Hardcoded values for specific image types (e.g., RHEL8)

**Source Type Decision Logic**:
- Checks if original Marketplace image still exists
- Uses `PlatformImage` if Marketplace image is available
- Falls back to `SharedImageGallery` if Marketplace image not found
- Preserves plan information for licensing compliance

**Configuration Variables Used**:
- `galleryResourceGroup`: Gallery resource group
- `galleryName`: Gallery name
- `galleryImageDefinitionName`: Image definition name
- `gallerySubscriptionId`: Gallery subscription
- `baseImageVersion`: Base image version
- `location`: Azure region

**Output Variables Set**:
- `hasPlan`: Boolean indicating presence of plan information
- `planName`: Marketplace plan name
- `planProduct`: Marketplace plan product
- `planPublisher`: Marketplace plan publisher
- `sourceImageTypeForTemplate`: `PlatformImage` or `SharedImageGallery`
- `sourceImageVersionId`: Computed SIG version resource ID
- `effectiveBaseImagePublisher`: Discovered publisher
- `effectiveBaseImageOffer`: Discovered offer
- `effectiveBaseImageSku`: Discovered SKU

**Special Handling**: RHEL images get hardcoded plan values for compliance:
- `planName`: `rh-rhel8`
- `planProduct`: `rh-rhel`
- `planPublisher`: `redhat`

---

### **Task 5: Create and Run Image Builder Template**
- **Task Type**: `AzureCLI@2`
- **Task Name**: `BuildImageVersion`
- **Purpose**: Generates AIB template JSON and executes Image Builder workflow

**Template Generation Process**:

#### **1. Variable Preparation**
- Consolidates all configuration variables
- Sets hardcoded values for specific image types
- Prepares artifact information from previous tasks

#### **2. Customize Section Building**
**File Customizers**:
- Creates `File` customizers for each uploaded artifact
- Downloads files to `/tmp/` directory on build VM
- Uses blob URLs from storage account

**Shell Customizers**:
- Creates `Shell` customizers for script execution
- Sets execute permissions on script files
- Executes scripts with sudo privileges
- Processes setup scripts in order

#### **3. Source Block Generation**
**SharedImageGallery Source**:
- Uses existing SIG version as source
- Includes plan information if detected
- References computed `sourceImageVersionId`

**PlatformImage Source**:
- Uses Marketplace image as source
- Includes plan information for licensing
- Uses publisher/offer/SKU/version parameters

#### **4. Plan Information Injection**
- Always creates plan information when available
- Uses explicit plan data if detected
- Falls back to identifier fields as default
- Ensures licensing compliance for Marketplace-originated images

#### **5. Template Assembly**
- Builds complete AIB template JSON
- Configures VM profile with Standard_DS2_v2 size
- Sets VNet configuration using `vmImageSubnetId`
- Configures distribution to Shared Image Gallery
- Sets build timeout to 120 minutes
- Adds build metadata and tags

**Configuration Variables Used**:
- `identityResourceId`: Managed identity resource ID
- `subscriptionId`: Target subscription
- `gallerySubscriptionId`: Gallery subscription
- `resourceGroup`: AIB resource group
- `galleryResourceGroup`: Gallery resource group
- `location`: Azure region
- `galleryName`: Gallery name
- `galleryImageDefinitionName`: Image definition name
- `imageTemplateName`: Template name
- `vmImageSubnetId`: Build subnet
- All variables from previous tasks (plan info, source type, etc.)

**AIB Operations**:
1. **Template Creation**: `az image builder create` with generated JSON
2. **Build Execution**: `az image builder run` to start build process
3. **Output Setting**: Sets `newImageGalleryResourceID` as job output

**Output Variables Set**:
- `newImageGalleryResourceID` (with `isOutput=true`): Full ARM resource ID of created image version

**Template Structure**:
```json
{
  "type": "Microsoft.VirtualMachineImages/imageTemplates",
  "apiVersion": "2024-02-01",
  "name": "<templateName>",
  "location": "<location>",
  "identity": {
    "type": "UserAssigned",
    "userAssignedIdentities": {
      "<identityResourceId>": {}
    }
  },
  "properties": {
    "source": { /* PlatformImage or SharedImageVersion */ },
    "customize": [ /* File and Shell customizers */ ],
    "distribute": [ /* SharedImage distribution */ ],
    "vmProfile": {
      "vmSize": "Standard_DS2_v2",
      "vnetConfig": {
        "subnetId": "<vmImageSubnetId>"
      }
    },
    "buildTimeoutInMinutes": 120,
    "planInfo": { /* Plan information if available */ }
  }
}
```

**Error Handling**: ADO Pipeline fails if template creation or build execution fails

---

## ADO Pipeline Flow

### **Linear Execution Flow**:

```
1. Validate AIB Identity
   ↓
2. Configure RBAC & Permissions
   ↓ [120-second wait for propagation]
3. Download & Stage Artifacts
   ↓
4. Analyze Source Image
   ↓ [Detect plan info & source type]
5. Generate & Execute AIB Template
   ↓
6. Output New Image Resource ID
```

### **Source Image Detection Logic**:

```
Image Definition Analysis
         ↓
    Plan Detection
         ↓
┌─────────────────────┐
│   Publisher Check   │
├─────────────────────┤
│ • Explicit Plan     │
│ • Mastercard Images │
│ • Standard MP       │
│ • Custom SIG        │
└─────────────────────┘
         ↓
┌─────────────────────┐
│  Marketplace Check  │
├─────────────────────┤
│ Original Image      │
│ Still Available?    │
└─────────────────────┘
         ↓
    Source Type Decision
    ┌──────────────────┐      ┌────────────────────┐
    │  PlatformImage   │  OR  │ SharedImageGallery │
    │  (if MP exists)  │      │  (if MP missing)   │
    └──────────────────┘      └────────────────────┘
```

### **Artifact Processing Workflow**:

```
External URLs
      ↓
  Download Files
      ↓
  Upload to Storage
      ↓
  Generate Blob URLs
      ↓
  Set ADO Pipeline Variables
      ↓
┌─────────────────────┐
│   AIB Template      │
├─────────────────────┤
│ • File Customizers  │
│ • Shell Customizers │
│ • Source Config     │
│ • Plan Information  │
└─────────────────────┘
      ↓
  Execute Image Build
      ↓
  New SIG Image Version
```

### **Template Generation Process**:

```
Artifact Information + Source Analysis + Plan Detection
                        ↓
              Template JSON Generation
                        ↓
    ┌─────────────────────────────────────────────────┐
    │                AIB Template                     │
    ├─────────────────────────────────────────────────┤
    │ Source: PlatformImage OR SharedImageVersion     │
    │ Customize: Files + Shell Scripts                │
    │ Distribute: Shared Image Gallery                │
    │ VM Profile: Standard_DS2_v2 + VNet              │
    │ Plan Info: Marketplace compliance               │
    └─────────────────────────────────────────────────┘
                        ↓
              Azure Image Builder Execution
                        ↓
               New Image Version Output
```

### **Permission Flow**:

```
User-Assigned Identity
         ↓
    RBAC Assignment
    ├── AIB Resource Group (Contributor)
    ├── Gallery Resource Group (Contributor)
    ├── Storage Account (Storage Blob Data Reader)
    ├── Source Image (Reader)
    └── VNet Resource Group (VM Contributor)
         ↓
    Network Configuration
    ├── Storage Account (Allow access)
    └── Wait for propagation (120s)
         ↓
    Permission Verification
    └── Test storage access
```

---

## Dependencies

### **External Dependencies**:
- **Azure Image Builder**: Core service for image creation
- **Shared Image Gallery**: Image storage and versioning
- **Azure Storage**: Artifact staging and customization
- **User-Assigned Managed Identity**: Authentication for AIB
- **Virtual Network**: Build-time VM networking
- **External Artifact Sources**: URLs for customization files and scripts

### **Required Azure Resources**:
- User-assigned managed identity (pre-existing)
- Storage account for artifact staging
- Shared Image Gallery with image definition
- Virtual network and subnet for AIB VM
- Source image (Marketplace or existing SIG version)

### **RBAC Requirements**:
- **AIB Resource Group**: Contributor access for template management
- **Gallery Resource Group**: Contributor access for image publishing
- **Storage Account**: Storage Blob Data Reader for artifact access
- **Source Image**: Reader access for base image
- **VNet**: Virtual Machine Contributor for network access

### **Network Requirements**:
- **Subnet Access**: AIB VM requires subnet connectivity
- **Internet Access**: Download external artifacts
- **Azure Services**: Access to ARM APIs and storage services
- **Storage Account**: Network rules allowing AIB identity access

