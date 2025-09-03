# Chef InSpec and Prisma Security Scan ADO Pipeline

## Summary

This Azure DevOps ADO Pipeline provides a comprehensive security scanning solution for Shared Image Gallery (SIG) images using Chef InSpec and Prisma Cloud security tools. The ADO Pipeline creates a temporary test VM from a specified SIG image, installs multiple security scanning tools (InSpec, Prisma Cloud scanner, and Dynatrace OneAgent), executes security compliance tests, generates detailed reports, and performs cleanup operations. It's designed to validate VM images against security baselines and compliance requirements before deployment to production environments.

**Key Operations:**
- VM creation from Shared Image Gallery images for security testing
- Chef InSpec installation and compliance testing execution
- Prisma Cloud vulnerability scanning and assessment
- Dynatrace OneAgent installation for monitoring integration
- Automated test result collection and artifact publishing
- Complete environment cleanup after testing

---

## Parameters

This ADO Pipeline template does not define explicit parameters as it uses hardcoded values and variable group references. All configuration is handled through variables and variable groups.

**Note**: This is a template ADO Pipeline that would typically receive parameters when called from a parent ADO Pipeline. The current implementation uses static values that should be parameterized for reusability.

---

## Variables

### **Variable Groups**
| Group | Description | Purpose |
|-------|-------------|---------|
| `ImageBuilder` | Contains shared variables for image building and testing operations | Provides access to security scanning credentials and configuration |

### **ADO Pipeline Variables**

| Name | Description | Default Value | Usage |
|------|-------------|---------------|-------|
| `enable_dynatrace` | Controls Dynatrace OneAgent installation | `'true'` | Conditional installation of monitoring agent |

### **Hardcoded Configuration Variables**

| Name | Description | Value | Purpose |
|------|-------------|-------|---------|
| `VM_NAME` | Test VM name | `combined-security-test-vm-24211` | Identifies the temporary test VM |
| `RG` | Resource group for VM creation | `rg-imagebuilder-24211` | Target resource group |
| `LOCATION` | Azure region | `eastus` | VM deployment location |
| `ADMIN_USER` | VM administrator username | `azureuser` | VM access credentials |
| `ADMIN_PASS` | VM administrator password | `Bangladesh1972#` | VM access credentials |
| `IMAGE_ID` | Source SIG image resource ID | `/subscriptions/.../1.0.24211` | Target image for testing |
| `SUBNET_ID` | Network subnet for VM | `/subscriptions/.../snet-private` | Network configuration |
| `SUBSCRIPTION_ID` | Azure subscription | `bd341354-d4c1-4de2-996f-6228b587337c` | Target subscription |

### **Dynamic Variables**

| Name | Description | Set By | Usage |
|------|-------------|--------|-------|
| `VM_IP` | Private IP address of test VM | Create Test VM task | VM connectivity and reporting |

### **External Variables (from Variable Groups)**

| Name | Description | Source | Usage |
|------|-------------|--------|-------|
| `prisma_cloud_host` | Prisma Cloud server hostname | ImageBuilder group | Prisma agent configuration |
| `prisma_cloud_env` | Prisma Cloud environment | ImageBuilder group | Environment-specific configuration |
| `prisma_id` | Prisma Cloud user ID | ImageBuilder group | Authentication |
| `prisma_key` | Prisma Cloud API key | ImageBuilder group | Authentication |
| `prisma_api_host_cve` | Prisma CVE API endpoint | ImageBuilder group | Vulnerability scanning |
| `artifactory_user` | Artifactory username | ImageBuilder group | Package downloads |
| `artifactory_pwd` | Artifactory password | ImageBuilder group | Package authentication |

---

## ADO Pipeline Structure

### **Agent Configuration**
- **Agent Pool**: `abt-deployer-service-work-agents`
- **Execution**: Single job with sequential steps
- **Service Connection**: `abt-devops-agents-work-sp`

---

## Jobs and Tasks

### **Job: CombinedSecurityScan**
- **Display Name**: "Combined Chef InSpec and Prisma Scan on SIG Image"
- **Purpose**: Executes comprehensive security scanning on SIG images through temporary VM testing

#### **Task 1: Check Prerequisites and Prepare Artifacts**
- **Task Type**: `script`
- **Purpose**: Validates required files and prepares installation artifacts

**Operations**:
- InSpec controls directory: `$(System.DefaultWorkingDirectory)/module/ADO Pipelines/controls`
- Chef install script: `$(System.DefaultWorkingDirectory)/module/resources/install.sh`
- artifacts directory: `$(ADO Pipeline.Workspace)/artifacts`
- Copies pre-downloaded InSpec RPM if available
- Copies installation scripts to artifacts directory

**Prerequisites Checked**:
- InSpec controls directory existence
- Chef installation script availability
- Optional pre-downloaded InSpec RPM package

---

#### **Task 2: Create Test VM from SIG Image**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Creates temporary VM from specified Shared Image Gallery image

**VM Configuration**:
- **VM Size**: `Standard_DS2_v2`
- **Network**: Private subnet (no public IP)
- **Authentication**: Username/password
- **Image Source**: Shared Image Gallery version

**Output Variables**:
- `VM_IP`: Private IP address of created VM

---

#### **Task 3: Wait for VM to be Ready**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Ensures VM is fully operational before proceeding with installations

**Wait Strategy**:
- Azure CLI wait for VM creation completion
- Additional buffer time for service initialization

---

#### **Task 4: Install InSpec on VM**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Installs Chef InSpec compliance testing framework on test VM

**Installation Process**:
1. **System Dependencies**: `wget`, `ruby`, `ruby-devel`, `gcc`, `make`, `openssl-devel`
2. **InSpec Download**: RPM package from Artifactory
3. **Package Installation**: Using `rpm -ivh` command
4. **License Configuration**: Sets `CHEF_LICENSE=accept`
5. **Installation Verification**: Runs `inspec version`


**Artifactory URL**: `https://artifacts.eastus.az.mastercard.int/artifactory/archive-internal-unstable/.../inspec-5.18.14-1.el8.x86_64.rpm`

---

#### **Task 5: Install Prisma on VM**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Installs Prisma Cloud security scanning agent

**Installation Method**:
- Executes external script: `$(System.DefaultWorkingDirectory)/module/artifacts/prismainstall.sh`
- Passes authentication parameters from variable group
- Uses `az vm run-command` with script file execution

**Configuration Parameters**:
- `PRISMA_CLOUD_HOST`: Server hostname
- `PRISMA_CLOUD_ENV`: Environment identifier
- `PRISMA_CLOUD_USER`: Authentication user ID
- `PRISMA_CLOUD_PASS`: Authentication password

**Script Execution**: Uses `@prismainstall.sh` file reference with parameter substitution

---

#### **Task 6: Install Dynatrace OneAgent on VM**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Installs Dynatrace monitoring agent for observability
- **Condition**: `enable_dynatrace == 'true'`

**Installation Process**:
1. **Script Preparation**: Copies installation scripts to VM
2. **Agent Installation**: Executes OneAgent installer
3. **Directory Creation**: Sets up monitoring directories
4. **Deregistration Script**: Creates cleanup script
5. **Cron Configuration**: Sets up automated tasks

**Directory Structure**: `/opt/dynatrace/oneagent/agent/`

**Connectivity Test**: Tests connection to `https://dynatrace.dev.logging.work.eastus.az.mastercard.int:443/communication`

---

#### **Task 7: Verify Dynatrace OneAgent Installation**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Validates successful Dynatrace installation
- **Condition**: `enable_dynatrace == 'true'`

**Verification Checks**:
- **Directory Existence**: `/opt/dynatrace/oneagent/agent`
- **Script Availability**: `deregister_oneagent.sh`
- **Cron Configuration**: Scheduled task verification

---

#### **Task 8: Copy InSpec Controls to VM**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Transfers InSpec compliance test files to test VM

**File Transfer Process**:
- Creates controls directory: `/tmp/controls`
- Iterates through all `.rb` files in `$(System.DefaultWorkingDirectory)/module/ADO Pipelines/controls/`
- Uses `az vm run-command` for file copying

**Control Files Location**: `$(System.DefaultWorkingDirectory)/module/ADO Pipelines/controls/*.rb`

---

#### **Task 9: Run Chef InSpec Tests on VM**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Executes InSpec compliance tests and generates reports

**Test Execution**:
- Sets InSpec license: `CHEF_LICENSE=accept`
- Executes specific control files: `7.1_network_security.rb` and `3.3_root_path.rb`
- Generates multiple report formats

**Report Formats**:
- **CLI Output**: Console display
- **JUnit XML**: `junit2:/tmp/inspec-results.xml`
- **HTML Report**: `html:/tmp/inspec-results.html`

**Test Files**:
- `7.1_network_security.rb`: Network security compliance
- `3.3_root_path.rb`: Root path security validation

**Output Location**: `/tmp/inspec-results.*`

---

#### **Task 10: Generate Prisma Report**
- **Task Type**: `Bash@3`
- **Purpose**: Executes Prisma Cloud vulnerability scanning

**Script Execution**:
- **Script Path**: `$(System.DefaultWorkingDirectory)/module/artifacts/vminator.sh`
- **Working Directory**: `$(System.DefaultWorkingDirectory)`

**Script Parameters**:
1. `$(prisma_id)`: Prisma Cloud user ID
2. `$(prisma_key)`: Prisma Cloud API key
3. `combined-security-test-vm-24211.2uvibf0gxalutblwws5qgz4poe.bx.internal.cloudapp.net`: VM FQDN
4. `template`: Scan template identifier
5. `$(prisma_api_host_cve)`: CVE API endpoint
6. `$(artifactory_user)`: Artifactory username
7. `$(artifactory_pwd)`: Artifactory password
8. `$(System.DefaultWorkingDirectory)`: Working directory

**Scan Type**: Template-based vulnerability assessment

---

#### **Task 11: Retrieve InSpec Test Results**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Downloads test results from VM to ADO Pipeline workspace

**Result Retrieval**:
- **XML Report**: `/tmp/inspec-results.xml` → `$(ADO Pipeline.Workspace)/inspec-results.xml`
- **HTML Report**: `/tmp/inspec-results.html` → `$(ADO Pipeline.Workspace)/inspec-results.html`

**Transfer Method**:
- Uses `az vm run-command` with `cat` command
- Extracts content using JSON query: `value[0].message`
- Saves to ADO Pipeline workspace for artifact publishing

**Output Processing**: JSON output parsing with Azure CLI query functionality

---

#### **Task 12: Cleanup - Delete Test VM**
- **Task Type**: `AzureCLI@2`
- **Purpose**: Removes temporary test VM to prevent resource waste

**Cleanup Operations**:
- Deletes VM using `az vm delete` command
- Uses `--yes` flag for unattended execution
- Targets specific VM and resource group
- Confirms cleanup completion

**Resource Management**: Ensures no orphaned VMs remain after testing

---

#### **Task 13: Publish Combined Security Scan Results**
- **Task Type**: `PublishBuildArtifacts@1`
- **Purpose**: Makes test results available as ADO Pipeline artifacts

**Artifact Configuration**:
- **Source Path**: `$(ADO Pipeline.Workspace)`
- **Artifact Name**: `combined-security-results`
- **Contents**: InSpec XML/HTML reports, Prisma scan results

---

## ADO Pipeline Flow

### **Linear Execution Flow**:

```
1. Prerequisites Check
   ↓
2. VM Creation from SIG Image
   ↓
3. VM Readiness Wait
   ↓
4. InSpec Installation
   ↓
5. Prisma Installation
   ↓
6. Dynatrace Installation (Conditional)
   ↓
7. Dynatrace Verification (Conditional)
   ↓
8. Copy InSpec Controls
   ↓
9. Execute InSpec Tests
   ↓
10. Execute Prisma Scan
    ↓
11. Retrieve Test Results
    ↓
12. VM Cleanup
    ↓
13. Publish Results
```

### **Security Scanning Workflow**:

```
SIG Image Input
       ↓
   Test VM Creation
       ↓
┌─────────────────────┐
│   Security Tools    │
│   Installation      │
├─────────────────────┤
│ • InSpec Framework  │
│ • Prisma Scanner    │
│ • Dynatrace Agent   │
└─────────────────────┘
       ↓
┌─────────────────────┐
│   Compliance Tests  │
├─────────────────────┤
│ • Network Security  │
│ • Root Path Checks  │
│ • Vulnerability Scan│
└─────────────────────┘
       ↓
┌─────────────────────┐
│   Report Generation │
├─────────────────────┤
│ • InSpec XML/HTML   │
│ • Prisma CVE Report │
│ • Combined Results  │
└─────────────────────┘
       ↓
   Cleanup & Publish
```

## Dependencies

### **External Dependencies**:
- **Azure Shared Image Gallery**: Source image for testing
- **Artifactory**: InSpec package repository
- **Prisma Cloud**: Vulnerability scanning service
- **Dynatrace**: Monitoring and observability platform
- **Chef InSpec**: Compliance testing framework

### **Required Files**:
- `$(System.DefaultWorkingDirectory)/module/ADO Pipelines/controls/*.rb`: InSpec control files
- `$(System.DefaultWorkingDirectory)/module/resources/install.sh`: Chef installation script
- `$(System.DefaultWorkingDirectory)/module/artifacts/prismainstall.sh`: Prisma installation script
- `$(System.DefaultWorkingDirectory)/module/artifacts/dynatrace-install.sh`: Dynatrace installation script
- `$(System.DefaultWorkingDirectory)/module/artifacts/oneagent.sh`: Dynatrace OneAgent installer
- `$(System.DefaultWorkingDirectory)/module/artifacts/vminator.sh`: Prisma scanning script

### **Network Requirements**:
- **Private Subnet**: VM network connectivity
- **Internet Access**: Package downloads and API calls
- **Dynatrace Connectivity**: `https://dynatrace.dev.logging.work.eastus.az.mastercard.int:443`
- **Artifactory Access**: `https://artifacts.eastus.az.mastercard.int`

### **Permissions Required**:
- **Azure VM**: Create, delete, and run commands
- **Network**: Access to specified subnet
- **Storage**: Access to Shared Image Gallery
- **Service Principal**: `abt-devops-agents-work-sp` permissions

---

## Security and Compliance

### **Security Scanning Coverage**:
- **Network Security**: InSpec control `7.1_network_security.rb`
- **Root Path Security**: InSpec control `3.3_root_path.rb`
- **Vulnerability Assessment**: Prisma Cloud CVE scanning
- **Compliance Validation**: Automated baseline checks

### **Monitoring Integration**:
- **Dynatrace OneAgent**: Performance and security monitoring
- **Automated Deregistration**: Cleanup scripts for monitoring
- **Cron Scheduling**: Maintenance task automation

### **Report Generation**:
- **Multiple Formats**: XML for automation, HTML for human review
- **Artifact Publishing**: Results available for downstream processes
- **Audit Trail**: Complete testing documentation
