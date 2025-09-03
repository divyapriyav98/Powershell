# VMSS Prisma Scan Pipeline


## Purpose
This Azure DevOps pipeline (`templates/vmss-prisma-scan.yml`) creates a temporary test VM from a Shared Image Gallery (SIG) image, installs Prisma Cloud agent, runs a Prisma scan/reporting script, and produces a report. It's intended to validate SIG images with Prisma Cloud prior to promoting or publishing images.


## Pipeline metadata
- Agent pool: `abt-deployer-service-work-agents` (declared in the template)
- Variable group referenced: `ImageBuilder` (declared under `variables:`)


## Required variables (recommend setting in Pipeline variable group or as pipeline variables)
These are referenced directly by the template or by the scripts called by the template.

- `prisma_id` (string) — Required
  - Usage: Prisma Cloud user ID used by the installer and report generator.
  - Sensitive: yes (store as secret variable)

- `prisma_key` (string) — Required
  - Usage: Prisma Cloud API key / password used by installer and report generator.
  - Sensitive: yes (store as secret variable)

- `prisma_cloud_host` (string) — Required
  - Usage: Hostname or URL of Prisma Cloud console used by installer and scan scripts.

- `prisma_cloud_env` (string) — Optional but commonly required
  - Usage: Environment identifier for Prisma Cloud (depends on your setup).

- `prisma_api_host_cve` (string) — Optional
  - Usage: API host for CVE lookups used by the reporting script.

- `artifactory_user`, `artifactory_pwd` — Optional (used by report upload)
  - Usage: Credentials for artifact repository if the reporting script uploads results.
  - Sensitive: yes (store as secret variables)

- `System.DefaultWorkingDirectory` — Provided by Azure DevOps runtime and used to reference script artifacts located under `module/artifacts`.

Notes about hardcoded values in the template
- The template contains several hard-coded values (e.g., `ADMIN_PASS`, `IMAGE_ID`, subscription IDs, resource group names, subnet IDs). These should be parameterized or replaced with secure pipeline variables before reuse in other environments.


## Job: PrismaScan
Display name: `Test Prisma Scan on SIG Image`
This single-job pipeline executes two main steps: create a VM from a SIG image and install Prisma, then run a reporting script that generates the Prisma scan/report.

### Step 1 — Create Test VM from SIG Image (AzureCLI@2)
- Purpose: Provision a temporary VM from a SIG image into a private subnet (no public IP) and run the Prisma installer on it.
- Task: `AzureCLI@2` (Bash inline)
- Key inline inputs (from the script block in the template):
  - `VM_NAME` — default in template: `test-vm1-prisma`
  - `RG` (resource group) — default in template: `rg-imagebuilder-24211` (recommend parameterizing)
  - `LOCATION` — default in template: `eastus`
  - `ADMIN_USER` / `ADMIN_PASS` — administrative credentials for the VM (do NOT hardcode in production)
  - `IMAGE_ID` — SIG image resource ID (hard-coded; recommended to parameterize)
  - `SUBNET_ID` — target subnet resource ID (hard-coded; recommended to parameterize)
  - `--subscription` — subscription ID used for `az vm create`
- Variables read (pipeline variables): `prisma_cloud_host`, `prisma_cloud_env`, `prisma_id`, `prisma_key` (passed as parameters to the install script)
- Variables produced (via `##vso[task.setvariable]`):
  - `VM_IP` — the private IP address of the newly-created test VM (set in the inline script using `echo "##vso[task.setvariable variable=VM_IP]$VM_IP"`)
- Other behavior:
  - The step reads `$(System.DefaultWorkingDirectory)/module/artifacts/prismainstall.sh` and invokes it on the VM using `az vm run-command invoke` with parameters for Prisma credentials and environment.


### Step 2 — Generate Prisma Report (Bash@3)
- Purpose: Run the local `vminator.sh` script to generate a Prisma report for the test VM and optionally upload it to an artifact repository.
- Task: `Bash@3` (filePath)
- Inputs:
  - `filePath`: `$(System.DefaultWorkingDirectory)/module/artifacts/vminator.sh`
  - `arguments`: the template passes a long list of args: `$(prisma_id) $(prisma_key) <vm-hostname> template $(prisma_api_host_cve) $(artifactory_user) $(artifactory_pwd) $(System.DefaultWorkingDirectory)`
- Variables read:
  - `prisma_id`, `prisma_key`, `prisma_api_host_cve`, `artifactory_user`, `artifactory_pwd`, and `System.DefaultWorkingDirectory`
- Outputs:
  - Depends on `vminator.sh` implementation. It may produce a report file and upload it to Artifactory (credentials provided).


## Expected `##vso[task.setvariable]` outputs
From the pipeline content, these variables are set by inline scripts and consumed downstream. Ensure the PowerShell/Bash scripts write these variables using the Azure DevOps logging command format when necessary.

- `VM_IP` — set by Step 1 (Create Test VM). Description: Private IP of the test VM; consumers like the report script can reference the VM using this value.

If the scripts (`prismainstall.sh`, `vminator.sh`) set additional pipeline variables (for example a report path or an artifact URL), document those outputs in this section by editing the README after inspecting the scripts.


## Security and best practices
- NEVER commit secrets (e.g., `ADMIN_PASS`, `prisma_key`, `artifactory_pwd`) to source control. Use Azure DevOps secret variables or a KeyVault-backed variable group.
- Parameterize or move hard-coded subscription IDs, resource group names, image IDs, and subnet IDs to pipeline variables or variable groups.
- If running on hosted agents, confirm all required CLI utilities are available (Azure CLI, jq, etc.) or add an install step.


## Troubleshooting
- If VM creation fails, validate the `IMAGE_ID`, subscription, resource group, and subnet ID, and confirm the service principal has permissions to create VMs.
- If `az vm run-command invoke` fails, check that the VM Agent is present on the image and that network restrictions do not block the command execution.
- If report generation fails, run `vminator.sh` locally against a reachable test host to debug arguments and environment issues.

