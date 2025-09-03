# VMSS Deploy Service ADO Pipeline

## Summary

This Azure DevOps ADO Pipeline is a comprehensive VMSS (Virtual Machine Scale Set) deployment and management solution that supports multiple deployment actions including canary promotions, live promotions, rollbacks, and testing. The ADO Pipeline orchestrates the complete lifecycle of VMSS deployments through a sophisticated workflow that includes OSB (Operations Support Bundle) manifest processing, VM image building, vulnerability scanning, deployment actions, and testing. It supports blue-green deployment strategies, automated image updates, load balancer swapping, and comprehensive security scanning with Dynatrace and Prisma integration.

**Key Operations:**
- OSB manifest deserialization and action determination
- Conditional execution based on deployment actions (promote_canary, shift_canary, promote_live, rollback, test)
- Custom VM image building with Azure Image Builder
- Comprehensive vulnerability scanning with InSpec and Prisma Cloud
- VMSS image updates and autoscaling operations
- Blue-green deployment with load balancer swapping
- Rollback capabilities for failed deployments
- Alert management and scheduled query configuration

---

## Parameters

| Name | Description | Default Value | Optional/Required | Condition |
|------|-------------|---------------|-------------------|-----------|
| `serviceSpecification` | Complex object containing complete service deployment specification including VMSS configuration, alerts, scheduled queries, and deployment parameters | No default | Required | Used across all stages and templates |

### **ServiceSpecification Object Structure** 
The `serviceSpecification` parameter is a complex object containing:
- **VMSS Configuration**: Scale set definitions, sizing, networking
- **Image Specifications**: Source images, customization requirements
- **Alert Configuration**: Email notifications, monitoring settings
- **Scheduled Queries**: Log analytics queries and schedules
- **Deployment Actions**: Action type (promote_canary, shift_canary, promote_live, rollback, test)
- **Environment Settings**: Tier-specific configurations (dev, work, nonp, prod)

---

## Variables

### **Static ADO Pipeline Variables**

| Name | Description | Value/Usage |
|------|-------------|-------------|
| `azure_svc_connection` | Azure service connection for authentication | `abt-devops-agents-work-sp` |
| `osbOutputSecretName` | Dynamic secret name for OSB processing outputs | `az-$(System.DefinitionId)-$(Build.BuildId)` |
| `imageTemplateName` | Template name for custom image builds | `rhel8-novmtools-$(Build.BuildId)` |
| `imageVersion` | Version format for created VM images | `1.0.$(Build.BuildId)` |
| `AZURE_CORE_OUTPUT` | Azure CLI output format control | `none` (suppresses CLI output) |

### **Variable Groups**
- **`ImageBuilder`**: Contains shared variables for image building operations
- **`templates/vmss-shared-variables.yml`**: Template-based shared variables across stages

### **Stage-Level Variables (Dynamic)**

| Stage | Variable | Description | Source |
|-------|----------|-------------|---------|
| `VulnerabilityScan` | `VM_NEWIMAGE_ID` | Resource ID of newly built VM image | Output from `BuildVM_Image.BuildImage.BuildImageVersion.newImageGalleryResourceID` |

---

## ADO Pipeline Structure

### **Triggers and Configuration**
- **Manual Trigger**: `trigger: none` (manual execution only)
- **PR Trigger**: `pr: none` (disabled for PR builds)
- **Agent Pool**: `abt-provisoner-service-work-agents` (with commented tier-based pool selection)
- **ADO Pipeline Name**: `VMSS_Deployer_$(System.DefinitionId)_$(Build.BuildId)`

### **External Resources**
- **Repository 1**: `azdo-yaml-templates` (Git repository for shared VMSS templates)
  - Branch: `feature/vmss-deploy-service`
- **Repository 2**: `imageBuilderRepo` (az-bm-vmss-img-builder)
  - Branch: `refs/heads/dev/mohian`

---

## Stages, Jobs, and Tasks

### **Stage 1: OSBpreprocessing**
- **Display Name**: "OSB Processing"  
- **Purpose**: Deserializes and processes the OSB manifest to determine deployment actions

#### **Job 1.1: OSBPreprocessJob**
- **Display Name**: "OSB Preprocess Job"
- **Purpose**: Processes service specification and determines ADO Pipeline execution path

##### **Task 1.1.1: DeserializeOSB**
- **Task Type**: `PowerShell@2`
- **Display Name**: "Deserialize OSB Manifest"
- **Script Type**: File-based PowerShell

**Purpose**: Converts service specification object to ADO Pipeline variables and determines deployment action.

**Configuration**:
```yaml
filePath: $(Build.SourcesDirectory)/azure-ADO Pipelines/scripts/vmss-deployer-manifest.ps1
arguments: "-osbManifest '${{ConvertToJson(parameters.serviceSpecification)}}' -osbOutputSecretName '$(osbOutputSecretName)'"
pwsh: true
showWarnings: true
```

**Environment Variables**:
- `SYSTEM_ACCESSTOKEN`: `$(System.AccessToken)`

**Outputs Set**:
- `mcAction`: Deployment action type (promote_canary, shift_canary, promote_live, rollback, test)
- Additional OSB-derived variables for downstream stages

---

### **Stage 2: rollback**
- **Display Name**: "Rollback VMSS"
- **Dependencies**: `OSBpreprocessing`
- **Condition**: Action equals 'rollback'
- **Variables**: Uses `templates/vmss-shared-variables.yml`

#### **Job 2.1: Template-based Rollback Job**
- **Template**: `templates/vmss/vmss-upgrade-swap.yml@azdo-yaml-templates`
- **Purpose**: Performs VMSS rollback operations with load balancer swapping

**Template Parameters**:
- `condition`: `and(succeeded(), eq(stageDependencies.OSBpreprocessing.OSBPreprocessJob.outputs['DeserializeOSB.mcAction'], 'rollback'))`
- `SCRIPT_PATH`: `$(Build.SourcesDirectory)/azure-ADO Pipelines/scripts/vmss-switch-lbswap.ps1`
- `serviceSpecification`: Full service specification object
- `vmssAlerts`: JSON-converted alert email configuration
- `vmssScheduledQueries`: JSON-converted scheduled queries configuration

---

### **Stage 3: BuildVM_Image**
- **Display Name**: "Build VM Image"
- **Dependencies**: `OSBpreprocessing`
- **Condition**: Action is promote_canary, shift_canary, or promote_live
- **Variables**: Uses `templates/vmss-shared-variables.yml`

#### **Job 3.1: Template-based Image Builder Job**
- **Template**: `templates/vmss/vmss-img-builder.yml@azdo-yaml-templates`
- **Job Name**: `BuildImage`
- **Purpose**: Creates custom VM images with Azure Image Builder

**Template Parameters**:
- `condition`: `and(succeeded(), or(eq(...'promote_canary'), eq(...'shift_canary'), eq(...'promote_live')))`

**Outputs Generated**:
- `BuildImageVersion.newImageGalleryResourceID`: Resource ID of created image

---

### **Stage 4: VulnerabilityScan**
- **Display Name**: "VulnerabilityScan"
- **Dependencies**: `OSBpreprocessing`, `BuildVM_Image`
- **Condition**: Action is promote_canary, shift_canary, or promote_live

#### **Job 4.1: Combined Security Scan Job**
- **Template**: `templates/vmss/scan-vul-inspect.yml@azdo-yaml-templates`
- **Job Name**: `CombinedSecurityScan`
- **Purpose**: Comprehensive security scanning including vulnerability assessment and compliance checks

**Template Parameters**:

| Parameter | Description | Value |
|-----------|-------------|-------|
| `enable_dynatrace` | Enable Dynatrace monitoring integration | `true` |
| `azureSubscription` | Azure service connection | `$(azure_svc_connection)` |
| `vmName` | Temporary VM name for security testing | `security-test-vm-$(Build.BuildId)` |
| `resourceGroup` | Target resource group | `$(resourceGroup)` |
| `location` | Azure region | `$(location)` |
| `adminUsername` | VM admin username | `mcazureuser` |
| `imageid` | Image ID to scan | `$(VM_NEWIMAGE_ID)` |
| `subnetId` | Subnet for security test VM | `$(vmImageSubnetId)` |
| `vmSize` | VM size for security testing | `Standard_DS2_v2` |
| `subscriptionId` | Target subscription | `$(subscriptionId)` |
| `inspecRpmName` | InSpec RPM package name | `inspec-5.18.14-1.el8.x86_64.rpm` |
| `inspecRpmUrl` | Artifactory URL for InSpec package | `https://artifacts.eastus.az.mastercard.int/artifactory/...` |
| `inspecTestFiles` | InSpec test files to execute | `7.1_network_security.rb 3.3_root_path.rb` |
| `prismaFqdn` | Prisma Cloud FQDN for scanning | `combined-security-test-vm-24211.2uvibf0gxalutblwws5qgz4poe.bx.internal.cloudapp.net` |
| `dynatraceUrl` | Dynatrace communication endpoint | `https://dynatrace.dev.logging.work.eastus.az.mastercard.int:443/communication` |

**Security Scanning Components**:
- **InSpec Compliance**: Network security and root path compliance checks
- **Prisma Cloud**: Vulnerability scanning and cloud security assessment
- **Dynatrace Integration**: Performance and security monitoring

---

### **Stage 5: DeployerActions**
- **Display Name**: "Deployer Actions"
- **Dependencies**: `OSBpreprocessing`, `BuildVM_Image`
- **Condition**: Action is promote_canary, shift_canary, or promote_live
- **Variables**: Uses `templates/vmss-shared-variables.yml`

#### **Job 5.1: Image Update and Autoscale Job**
- **Template**: `templates/vmss/vmss-imageupdate-autoscale.yml@azdo-yaml-templates`
- **Job Name**: `UpdateImage`
- **Purpose**: Updates VMSS with new image and handles autoscaling configuration

#### **Job 5.2: Blue-Green Deployment Job**
- **Template**: `templates/vmss/vmss-upgrade-swap.yml@azdo-yaml-templates`
- **Job Name**: `BlueGreenDeploy`
- **Dependencies**: `UpdateImage`
- **Purpose**: Performs VMSS upgrade and load balancer swap operations

**Template Parameters**:
- `SCRIPT_PATH`: `$(Build.SourcesDirectory)/azure-ADO Pipelines/scripts/vmss-switch-lbswap.ps1`
- `dependsOn`: `UpdateImage`
- `condition`: Same as stage condition (promote actions)

**Operations Performed**:
- VMSS instance upgrades
- Load balancer backend pool swapping
- Alert configuration management
- Health check validation

---

### **Stage 6: test**
- **Display Name**: "Test VMSS"
- **Dependencies**: `OSBpreprocessing`
- **Condition**: Action equals 'test'
- **Variables**: Uses `templates/vmss-shared-variables.yml`

#### **Job 6.1: TestJob**
- **Display Name**: "Test Job"
- **Purpose**: Executes testing operations for VMSS validation

##### **Task 6.1.1: Run Test**
- **Task Type**: `script`
- **Display Name**: "Run Test"
- **Purpose**: Simple test execution placeholder

**Script**: `echo "Performing test for $(vmss)"`

---

## ADO Pipeline Flow

### **Execution Decision Tree**:

```
1. ADO Pipeline Triggered (Manual)
   ↓
2. Stage: OSBpreprocessing
   ↓ [Determines mcAction]
3. Conditional Stage Execution:
   
   If mcAction == 'rollback':
   ├── Stage: rollback
   └── END
   
   If mcAction == 'test':
   ├── Stage: test
   └── END
   
   If mcAction ∈ ['promote_canary', 'shift_canary', 'promote_live']:
   ├── Stage: BuildVM_Image
   ├── Stage: VulnerabilityScan (depends on BuildVM_Image)
   ├── Stage: DeployerActions (depends on BuildVM_Image)
   │   ├── Job: UpdateImage
   │   └── Job: BlueGreenDeploy (depends on UpdateImage)
   └── END
```

### **Data Flow Architecture**:

```
ServiceSpecification Parameter
         ↓
   OSB Manifest Processing
         ↓
   Action Determination (mcAction)
         ↓
┌─────────────────┬──────────────────┬────────────────────┐
│   Rollback      │      Test        │   Promote Actions  │
│                 │                  │                    │
│ Load Balancer   │   Simple Test    │  Image Building    │
│ Swap Back       │   Execution      │        ↓           │
│                 │                  │  Security Scanning │
│                 │                  │        ↓           │
│                 │                  │  Image Update      │
│                 │                  │        ↓           │
│                 │                  │  Blue-Green Deploy │
└─────────────────┴──────────────────┴────────────────────┘
```

### **Stage Dependencies and Flow**:

1. **OSBpreprocessing**: Always executes first
2. **Parallel Conditional Execution**:
   - **rollback**: Independent execution for rollback scenarios
   - **test**: Independent execution for testing scenarios
   - **Promote ADO Pipeline**: Sequential execution for deployment scenarios
     - **BuildVM_Image**: Creates custom VM images
     - **VulnerabilityScan**: Security validation (parallel to DeployerActions)
     - **DeployerActions**: Deployment operations with internal job dependencies

### **Template Integration**:

All major operations use external templates from `azdo-yaml-templates` repository:
- **Image Building**: `vmss-img-builder.yml`
- **Security Scanning**: `scan-vul-inspect.yml`
- **Image Updates**: `vmss-imageupdate-autoscale.yml`
- **Blue-Green Deployment**: `vmss-upgrade-swap.yml`

### **Variable Inheritance**:

- **Global Variables**: Available across all stages
- **Shared Templates**: `vmss-shared-variables.yml` provides stage-specific variables
- **Stage Dependencies**: Output variables flow between dependent stages
- **Template Parameters**: Complex objects passed to template jobs

---

## Dependencies

### **External Components**:
- **Azure Image Builder**: Custom VM image creation
- **Azure Compute Gallery**: Image storage and versioning
- **Load Balancer**: Blue-green deployment traffic switching
- **InSpec**: Compliance testing framework
- **Prisma Cloud**: Security scanning platform
- **Dynatrace**: Monitoring and observability
- **Artifactory**: Package and artifact storage
