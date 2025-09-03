# Blue-Green VMSS Load Balancer Swap Pipeline

## Purpose

This Azure DevOps pipeline (`templates/vmss/vmss-upgrade-swap.yaml`) performs a blue-green-style swap of backend pools for Virtual Machine Scale Sets (VMSS) behind an Azure Load Balancer (LB). It discovers the LB and backend pools, determines current VMSS→pool mapping, updates VMSS network interface configurations to point to the active backend pool, waits for traffic to drain, swaps LB rules, verifies configuration, and finally scales down the inactive (blue) VMSS.
This README explains the pipeline purpose, top-level parameters, and per-stage details so you can understand, configure, and run the pipeline.

---
## Top-level Parameters

The pipeline defines a small set of template parameters. These are declared at the top of `templates/bluegreen.yml`.


- `dependsOn` (string)

  - Default: `''`

  - Required: No

  - Usage: Optional job dependency expression. If provided, the job `BlueGreenDeploy` will use this value for `dependsOn`.

 

- `condition` (string)

  - Default: `succeeded()`

  - Required: No

  - Usage: Runs the job only when this expression is true. Typical value is the default `succeeded()`.

 

- `SCRIPT_PATH` (string)

  - Default: `$(Build.SourcesDirectory)/azure-pipelines/scripts/vmss-switch-lbswap.ps1`

  - Required: No (uses default script path)

  - Usage: Path to the Azure PowerShell script that contains steps A–G logic. The job invokes this script with step-specific arguments.

 

## Recommended Pipeline Variables (set in the pipeline that uses this template)

These variables are referenced by the steps and must be provided by the calling pipeline or set as library/Pipeline variables:

 

- `azure_svc_connection` (string) — Required

  - Description: Azure service connection name in Azure DevOps to use for Azure CLI and Azure PowerShell tasks.

 

- `subscriptionId` (string) — Required

  - Description: Azure subscription ID containing the target resource group and VMSS resources.

 

- `resourceGroup` (string) — Required

  - Description: Resource group that contains the Load Balancer and VMSS resources to operate on.

 

- `activePoolName` (string) — Conditionally required for inline VMSS NIC update step (STEP D0). May be set by earlier steps or passed in.

 

- `BUILD_ARTIFACTSTAGINGDIRECTORY` — Provided by Azure DevOps runtime; used for reading `vmssToPoolMap.json` in scale-down step.

 

Note: Several additional variables are produced by earlier steps in the job (see per-stage outputs below) and are consumed by later steps.

 

---

 

## Job: BlueGreenDeploy

Display name: "Run PowerShell to Switch VMSS Backends"

Condition: controlled by `parameters.condition` (defaults to `succeeded()`).

 

This job contains all steps required to perform the LB/VMSS backend pool discovery and swap. If `dependsOn` parameter is supplied, the job will set that dependency.

 

### Key behavior

- Uses Azure CLI to discover the Load Balancer and backend pools

- Uses a PowerShell script (A–G) to inspect and manipulate LB rules and mappings

- Executes inline Bash/AzureCLI tasks to update VMSS NICs and swap backend pools

- Verifies final configuration and scales down the inactive VMSS

 

### Steps / Stages inside the job

Below each step is documented with purpose, inputs, and variables it reads or produces.

 

---

 

### Step 0 — Discover LB Name Dynamically (AzureCLI@2)

- Purpose: Find the Load Balancer in `$(resourceGroup)` and discover its backend pools. Exports the first two pools and the LB name as pipeline variables.

- Task: `AzureCLI@2` (Bash inline)

- Inputs:

  - `azureSubscription`: `$(azure_svc_connection)`

- Variables read:

  - `subscriptionId`, `resourceGroup`

- Variables produced (task.setvariable):

  - `backendPool01` — name of first backend pool

  - `backendPool02` — name of second backend pool

  - `LB_NAME` — discovered load balancer name

- Notes: Exits with non-zero if no LB is found in the resource group.

 

---

 

### Step A — Discover Load Balancer Rules & Backend Pools (AzurePowerShell@5)

- Purpose: Invoke the shared script with `-step A` to gather detailed LB rule and pool information.

- Task: `AzurePowerShell@5` (ScriptPath = `${{ parameters.SCRIPT_PATH }}`)

- Inputs / Arguments:

  - `-step A -subscriptionId $(subscriptionId) -resourceGroupName $(resourceGroup) -lbName "$(LB_NAME)"`

- Variables read: `azure_svc_connection`, `subscriptionId`, `resourceGroup`, `LB_NAME`

- Variables produced: Depends on script implementation (commonly exports rule/pool IDs and mapping info via logging or `Write-Host '##vso[task.setvariable ...]'`).

 

---

 

### Step B — Discover Backend Pools (AzurePowerShell@5)

- Purpose: Additional discovery of backend pools if needed (`-step B`).

- Inputs / Arguments: `-step B -subscriptionId $(subscriptionId) -resourceGroupName $(resourceGroup) -lbName "$(LB_NAME)"`

- Variables read/produced: same as Step A; exact outputs depend on script implementation.

 

---

 

### Step C — Determine Current Mapping (AzurePowerShell@5)

- Purpose: Determine current mapping of VMSS to backend pools (`-step C`). This generates a VMSS→pool map used later for swapping backends.

- Inputs / Arguments: `-step C -subscriptionId $(subscriptionId) -resourceGroupName $(resourceGroup) -lbName "$(LB_NAME)"`

- Variables produced (typical):

  - `vmssToPoolMapJson` (string) — JSON map of VMSS name → backend pool name

  - Possibly `backendPool1Id`, `backendPool2Id`, and pool name variables

 

---

 

### Step D — Point Rules to Active Pool (AzurePowerShell@5)

- Purpose: Use the PowerShell script to point LB rules at the currently active pool (`-step D`). This prepares traffic to be routed to the intended VMSS fleet.

- Inputs / Arguments: `-step D -subscriptionId $(subscriptionId) -resourceGroupName $(resourceGroup) -lbName "$(LB_NAME)"`

 

---

 

### STEP D0 — Update VMSS NICs to active backend pool (AzureCLI@2, Bash inline)

- Purpose: For each VMSS in the target resource group, update VMSS NIC configurations to attach to the active backend pool ID.

- Inputs:

  - `azureSubscription`: `$(azure_svc_connection)`

  - Reads: `subscriptionId`, `resourceGroup`, `LB_NAME`, and `activePoolName` (provided via environment variable)

- Environment variables:

  - `activePoolName: $(activePoolName)` (consumed)

- Notes:

  - Uses `az network lb address-pool show` to obtain pool ID then loops VMSS names using `az vmss list` and updates NIC config with `az vmss update`.

 

---

 

### Step E — Wait for Traffic Drain (AzurePowerShell@5)

- Purpose: Give the active backend pool time to drain traffic before swapping rules (`-step E`).

- Inputs / Arguments: `-step E -subscriptionId $(subscriptionId) -resourceGroupName $(resourceGroup) -lbName "$(LB_NAME)"`

 

---

 

### Step F — Swap Rules to Opposite Pool (AzurePowerShell@5)

- Purpose: Swap LB rules to the opposite pool so the opposite VMSS becomes active (`-step F`).

- Inputs / Arguments: `-step F -subscriptionId $(subscriptionId) -resourceGroupName $(resourceGroup) -lbName "$(LB_NAME)"`

 

---

 

### STEP F1 — Swap VMSS Backend Pools based on original mapping (AzureCLI@2)

- Purpose: Use a JSON map (`vmssToPoolMapJson`) produced earlier to restore VMSS backend pool assignments so each VMSS is assigned to the appropriate pool after the swap.

- Inputs:

  - `azureSubscription`: `$(azure_svc_connection)`

  - Environment variables consumed:

    - `backendPool1Id`, `backendPool2Id`, `backendPool1name`, `backendPool2name`, `vmssToPoolMapJson`

- Behavior:

  - Parses `vmssToPoolMapJson`, iterates VMSS names, determines original pool and sets the VMSS NICs to the corresponding new pool ID.

  - Verifies by fetching assigned pool IDs for each VMSS and logging results.

 

---

 

### Step G — Verify Final Configuration (AzurePowerShell@5)

- Purpose: Run verification logic in the PowerShell script (`-step G`) to ensure LB rules, pool assignments, and VMSS NIC configs are correct.

- Inputs / Arguments: `-step G -subscriptionId $(subscriptionId) -resourceGroupName $(resourceGroup) -lbName "$(LB_NAME)"`

 

---

 

### STEP H — Scale down inactive (Blue) VMSS (AzureCLI@2)

- Purpose: Scale down the VMSS that is now inactive to 0 instances (conserve cost).

- Inputs:

  - Reads `vmssToPoolMap.json` from `$(BUILD_ARTIFACTSTAGINGDIRECTORY)` and finds the VMSS associated with `backendPool01`.

  - Uses `az vmss update --set sku.capacity=0` to scale down the target VMSS.

- Environment variables consumed:

  - `backendPool01` (from Step 0) and `vmssToPoolMapJson`.

 

---

 

## Expected `##vso[task.setvariable]` Outputs

 

The PowerShell script (`vmss-switch-lbswap.ps1`) and some inline tasks are expected to emit pipeline variables using `##vso[task.setvariable]`. If the script is missing or not producing these variables, downstream steps will fail. Below is a consolidated list of variables the pipeline consumes, the step that should produce them, and a short description.

 

- `backendPool01` — Step 0 (Discover LB Name Dynamically)

  - Description: Name of the first backend pool discovered in the Load Balancer. Used by scale-down step and mapping logic.

 

- `backendPool02` — Step 0 (Discover LB Name Dynamically)

  - Description: Name of the second backend pool discovered in the Load Balancer.

 

- `LB_NAME` — Step 0 (Discover LB Name Dynamically)

  - Description: Discovered Load Balancer name in the target resource group.

 

- `backendPool1Id` — Step C / Step F outputs (script)

  - Description: Resource ID of backend pool 1. Used by VMSS NIC update and swap logic.

 

- `backendPool2Id` — Step C / Step F outputs (script)

  - Description: Resource ID of backend pool 2.

 

- `backendPool1name` — Step C / Step F outputs (script)

  - Description: Friendly name of backend pool 1 (matches `backendPool01` / discovered name).

 

- `backendPool2name` — Step C / Step F outputs (script)

  - Description: Friendly name of backend pool 2.

 

- `vmssToPoolMapJson` — Step C (Determine Current Mapping)

  - Description: JSON map (string) of VMSS name → backend pool name. Example: `{"vmss-001": "backendPool01", "vmss-002": "backendPool02"}`. Consumed by STEP F1 and STEP H.

 

- `vmssToPoolMap` (file) — Step C

  - Description: Path or file artifact containing JSON mapping; the pipeline reads this from `$(BUILD_ARTIFACTSTAGINGDIRECTORY)/vmssToPoolMap.json` in STEP H.

 

- `blueVmssName` — STEP H (Scale down inactive VMSS)

  - Description: Name of the VMSS determined to be inactive (blue) and scaled down to zero. Set during STEP H to be consumed by downstream reporting or notifications.

 

Notes:

- The exact variable names and which script step sets them depend on `vmss-switch-lbswap.ps1` implementation. If you want, I can open that script and extract the exact `Write-Host '##vso[task.setvariable ...]'` lines and insert them here verbatim.

- If any variable is unset, the pipeline will either error or behave unpredictably; confirm the script writes these values using `##vso[task.setvariable variable=NAME]VALUE`.

 

## Script contract and assumptions

- The pipeline depends on a PowerShell script (`vmss-switch-lbswap.ps1`) that implements steps A–G. The README documents how the pipeline wires into that script, but the script itself must implement the expected `-step` behavior and produce pipeline variables (using `##vso[task.setvariable ...]`) as required.

- The pipeline expects `jq` to be available in the inline Bash tasks (used to parse JSON). If running on hosted agents, ensure the agent image includes `jq` or add an install step.

- The pipeline requires the Azure CLI (`az`) and Azure PowerShell modules available in tasks as used; Azure DevOps `AzureCLI@2` and `AzurePowerShell@5` tasks provide these runtimes.

 

## Troubleshooting and notes

- If discovery fails to find a Load Balancer in the resource group, Step 0 will exit with an error. Ensure `resourceGroup` points to the correct group.

- If `vmssToPoolMap.json` is not produced by the PowerShell script, later steps will fail. Confirm Step C produces the mapping and publishes it to the artifact staging directory or exports as a pipeline variable.

- When running in environments with many backend pools, adapt the discovery logic if more than two pools are present.

 
