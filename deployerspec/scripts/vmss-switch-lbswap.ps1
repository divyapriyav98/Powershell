Param (
    [Parameter(Mandatory=$true)]
    [string]$step,
    [Parameter(Mandatory=$true)]
    [string]$subscriptionId,
    [Parameter(Mandatory=$true)]
    [string]$resourceGroupName,
    [Parameter(Mandatory=$true)]
    [string]$lbName
)

# Publish-PipelineVariables -provisioningVariable 'subscriptionId' -provisioningVariableValue $subscriptionId
Write-Host "DEBUG: Subscription ID = '$subscriptionId'"
Write-Host "DEBUG: Resource Group Name = '$resourceGroupName'"
Write-Host "DEBUG: Load Balancer Name = '$lbName'"

if (-not $subscriptionId -or $subscriptionId -eq "") {
    Write-Error "Error: Subscription ID is missing! Ensure it is passed correctly."
    exit 1
}

$drainWaitSeconds = 10
Set-AzContext -SubscriptionId $subscriptionId

switch ($step) {
    "A" {
        # === STEP A: Discover Load Balancer Rules & Backend Pools ===
        Write-Host "`n=== Step A: Discovering Load Balancer Rules & Backend Pools Dynamically ==="
        $lb = Get-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName
        $rules = $lb.LoadBalancingRules
        $backendPools = $lb.BackendAddressPools

        Write-Host "Step A: - Found $($rules.Count) load balancing rules"
        $rulesCopy = @($rules)  # Take a static copy of rules 

        foreach ($rule in $rulesCopy) {
            Write-Host "Step A: - Rule: $($rule.Name)"
        }

        Write-Host "Step A: - Found $($backendPools.Count) backend address pools"
        foreach ($pool in $backendPools) {
            Write-Host "Step A: - Backend Pool: $($pool.Name)"
        }
        # Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/rules.txt" -Value $rules
        # Convert rules and backend pools to JSON and save them
        $rules | ConvertTo-Json | Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/rules.json"
        # $backendPools | ConvertTo-Json | Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/backendPools.json"
    }

    "B" {
        # === STEP B: Discover 2 backend pools (Pool1 & Pool2 dynamically) ===
        Write-Host "`n=== Step B: Discovering Backend Pools (dynamically) ==="
        $lb = Get-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName
        $backendPools = $lb.BackendAddressPools
        $backendPool1 = $backendPools[0]
        $backendPool2 = $backendPools[1]
        Write-Host "Step B: - backendPool1 = $($backendPool1.Name)"
        Write-Host "Step B: - backendPool2 = $($backendPool2.Name)"
        $backendPools | ConvertTo-Json | Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/backendPools.json"
        $backendPool1 | ConvertTo-Json | Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/backendPool1.json"
        $backendPool2 | ConvertTo-Json | Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/backendPool2.json"
        
        # Persist values for next step (optional)
#         Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/backendPools.txt" -Value $backendPools
            

    }

    "C" {
        # === STEP C: Determine current mapping (store per-rule) ===
        Write-Host "`n=== Step C: Determining Current Rule to Backend Pool Mapping ==="
        $ruleToOriginalBackend = @{}
        # Read the JSON files from the artifact staging directory
        # $rulesJson = Get-Content "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/rules.json" -Raw
        $backendPoolsJson = Get-Content "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/backendPools.json" -Raw
        $backendPool1Json = Get-Content "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/backendPool1.json" -Raw
        $backendPool2Json = Get-Content "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/backendPool2.json" -Raw

        
 
        # Convert from JSON to PowerShell objects
        # $rules = $rulesJson | ConvertFrom-Json
        $backendPools = $backendPoolsJson | ConvertFrom-Json
        $backendPool1 = $backendPool1Json | ConvertFrom-Json
        $backendPool2 = $backendPool2Json | ConvertFrom-Json
        $lb = Get-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName
        $rules = $lb.LoadBalancingRules
        $rulesCopy = @($rules) 
        $backendPools = $lb.BackendAddressPools # Take a static copy of rules 
        # === Debugging: Output Backend Pools ===
        Write-Host "`nStep C: - Backend Pools (loaded from JSON):"
        foreach ($pool in $backendPools) {
          Write-Host "Backend Pool Name: $($pool.Name), ID: $($pool.Id)"
        }
        foreach ($rule in $rulesCopy) {
           # === Debugging: Output Rule's Backend Pool ID ===
           Write-Host "`nStep C: - Checking Rule '$($rule.Name)' with Backend Pool ID: $($rule.BackendAddressPool.Id)"
           $currentPool = ($backendPools | Where-Object { $_.Id -eq $rule.BackendAddressPool.Id }).Name
           $ruleToOriginalBackend[$rule.Name] = $currentPool
           Write-Host "Step C: - Rule '$($rule.Name)' → Backend Pool '$currentPool'"
        }
        # === Determine active pool based on first rule, for deterministic alternation ===
        $firstRule = $rulesCopy[0]
        $currentPoolName = $ruleToOriginalBackend[$firstRule.Name]
 
        if ($currentPoolName -eq $backendPool1.Name) {
          $activePoolName = $backendPool2.Name
          $drainPoolName = $backendPool1.Name
        } else {
        $activePoolName = $backendPool1.Name
        $drainPoolName = $backendPool2.Name
        }
 
        Write-Host "`nCurrent active = $activePoolName → Toggling to $drainPoolName"
 
        $activePoolObj = $backendPools | Where-Object { $_.Name -eq $activePoolName }
        $drainPoolObj = $backendPools | Where-Object { $_.Name -eq $drainPoolName }
        $ruleToOriginalBackend | ConvertTo-Json | Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/ruleToOriginalBackend.json"
        $activePoolObj | ConvertTo-Json | Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/activePoolObj.json"
        $activePoolName | ConvertTo-Json | Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/activePoolName.json"
        $drainPoolName | ConvertTo-Json | Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/drainPoolName.json"
        $currentPool | ConvertTo-Json | Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/currentPool.json"
        Write-Host "##vso[task.setvariable variable=backendPool1]$backendPool1"
        Write-Host "Active backend pool is: $backendPool1"
        Write-Host "##vso[task.setvariable variable=backendPool2]$backendPool2"
        Write-Host "Active backend pool is: $backendPool2"
        # Save VMSS → Pool map to file for Step F1
        # === STEP C EXTENSION: Determine VMSS to current backend pool mapping ===
 
# === STEP C EXTENSION: Determine VMSS to current backend pool mapping ===
Write-Host "`n=== Step C Extension: Mapping VMSS to Backend Pools ==="

$vmssList = Get-AzVmss -ResourceGroupName $resourceGroupName
$vmssToPoolMap = @{}

foreach ($vmss in $vmssList) {
    $nicConfig = $vmss.VirtualMachineProfile.NetworkProfile.NetworkInterfaceConfigurations[0]
    $ipConfig = $nicConfig.IpConfigurations[0]
    $backendPoolId = $ipConfig.LoadBalancerBackendAddressPools[0].Id

    $poolName = ($backendPools | Where-Object { $_.Id -eq $backendPoolId }).Name
    $vmssToPoolMap[$vmss.Name] = $poolName

    Write-Host "VMSS '$($vmss.Name)' → Pool '$poolName'"
}

# Save VMSS → Pool map to file for Step F1
$vmssToPoolMap | ConvertTo-Json | Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/vmssToPoolMap.json"
# Convert the map to JSON string
$vmssToPoolMapJson = $vmssToPoolMap | ConvertTo-Json -Compress

# Save to file (optional)
$vmssToPoolMapJson | Set-Content -Path "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/vmssToPoolMap.json"

# Set pipeline variable
Write-Host "##vso[task.setvariable variable=vmssToPoolMapJson]$vmssToPoolMapJson"

    }    
 

    "D" {
        # === STEP D: Temporarily point all rules to ACTIVE pool (to drain drainPool) ===
        $activePoolObjjson = Get-Content "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/activePoolObj.json" -Raw
        $activePoolNamejson = Get-Content "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/activePoolName.json" -Raw
        $drainPoolNamejson = Get-Content "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/drainPoolName.json" -Raw
        $activePoolObj = $activePoolObjjson | ConvertFrom-Json
        $activePoolName = $activePoolNamejson | ConvertFrom-Json
        $drainPoolName = $drainPoolNamejson | ConvertFrom-Json
        Write-Host "`n=== Step D: Temporarily pointing all rules to active pool '$activePoolName' (to drain '$drainPoolName') ==="
        $lb = Get-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName
        $rules = $lb.LoadBalancingRules
        $backendPools = $lb.BackendAddressPools
        $rulesCopy = @($rules)  # Take a static copy of rules


        # Check if the active pool object is in the correct format
        Write-Host "`nActive Pool Object (from JSON): $(ConvertTo-Json $activePoolObj)" 
        # Make sure the active pool is a valid PSBackendAddressPool object (not an array)
        $activePoolObj = $backendPools | Where-Object { $_.Name -eq $activePoolName } | Select-Object -First 1 
        # Debugging output
        Write-Host "`nActive Pool Object: $(ConvertTo-Json $activePoolObj)"


        foreach ($rule in $rulesCopy) {
            $frontend = $lb.FrontendIpConfigurations | Where-Object { $_.Id -eq $rule.FrontendIpConfiguration.Id }
            $probe = $lb.Probes | Where-Object { $_.Id -eq $rule.Probe.Id }

            Write-Host "Step D: - Redirecting Rule '$($rule.Name)' to Active Pool '$activePoolName'"
            Set-AzLoadBalancerRuleConfig -LoadBalancer $lb -Name $rule.Name `
                -Protocol $rule.Protocol -FrontendPort $rule.FrontendPort -BackendPort $rule.BackendPort `
                -FrontendIpConfiguration $frontend -BackendAddressPool $activePoolObj `
                -Probe $probe -IdleTimeoutInMinutes $rule.IdleTimeoutInMinutes `
                -LoadDistribution $rule.LoadDistribution -EnableFloatingIP:$rule.EnableFloatingIP
        }
        Set-AzLoadBalancer -LoadBalancer $lb
        # Find backend pool from LB
        Write-Host "`n Load balancer rules switched successfully."
 
        # After swapping the rules
# Assuming $activePoolName is the one both rules now point to
Write-Host "##vso[task.setvariable variable=activePoolName]$activePoolName"
Write-Host "Active backend pool is: $activePoolName"
      
    }

    "E" {
        # === STEP E: Wait for traffic drain ===
        Write-Host "`n=== Step E: Waiting for 30 seconds to allow traffic drain ==="
        Start-Sleep -Seconds 30
        $lb = Get-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName
        $rules = $lb.LoadBalancingRules
        $backendPools = $lb.BackendAddressPools
        $rulesCopy = @($rules)
        foreach ($rule in $rulesCopy) {
          $backendPool = $backendPools | Where-Object { $_.Id -eq $rule.BackendAddressPool.Id }
          Write-Host "` Checking Rule '$($rule.Name)' with Backend Pool ID: $($backendPool.Name)"
        } 
    }

    "F" {
        Write-Host "`n=== Step F: Restoring rules to original backend from Step C ==="
        $lb = Get-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName
        $rules = $lb.LoadBalancingRules
        $backendPools = $lb.BackendAddressPools
        $rulesCopy = @($rules)  # Take a static copy of rules    
 
# Load original mapping (Step C)
$originalMappings = Get-Content "$env:BUILD_ARTIFACTSTAGINGDIRECTORY/ruleToOriginalBackend.json" -Raw | ConvertFrom-Json
 
foreach ($rule in $rulesCopy) {
    $ruleName = $rule.Name
    $currentPoolName = $rule.BackendAddressPool.Id.Split('/')[-1]
    $originalPoolName = $originalMappings.$ruleName
    $newPoolName = ($originalPoolName -eq $backendPools[0].Name) ? $backendPools[1].Name : $backendPools[0].Name
 
    if (-not $originalPoolName) {
        Write-Warning "No original mapping found for rule '$ruleName'. Skipping."
        continue
    }
 
    if ($currentPoolName -eq $newPoolName) {
        Write-Host "Rule '$ruleName' is already on original pool '$newPoolName'. Skipping."
        continue
    }
 
    $newBackendPool = $backendPools | Where-Object { $_.Name -eq $newPoolName }
    $frontend = $lb.FrontendIpConfigurations | Where-Object { $_.Id -eq $rule.FrontendIpConfiguration.Id }
    $probe = $lb.Probes | Where-Object { $_.Id -eq $rule.Probe.Id }
 
    Write-Host "Restoring Rule '$ruleName': from '$currentPoolName' → '$newPoolName'"
 
    Set-AzLoadBalancerRuleConfig -LoadBalancer $lb -Name $ruleName `
        -Protocol $rule.Protocol -FrontendPort $rule.FrontendPort -BackendPort $rule.BackendPort `
        -FrontendIpConfiguration $frontend -BackendAddressPool $newBackendPool `
        -Probe $probe -IdleTimeoutInMinutes $rule.IdleTimeoutInMinutes `
        -LoadDistribution $rule.LoadDistribution -EnableFloatingIP:$rule.EnableFloatingIP
}
 
Set-AzLoadBalancer -LoadBalancer $lb
Write-Host "`n=== Step F: Final Rule to Backend Pool Mapping (Post-Restore) ==="
foreach ($rule in $lb.LoadBalancingRules) {
    $poolName = $rule.BackendAddressPool.Id.Split('/')[-1]
    Write-Host "Rule '$($rule.Name)' → Backend Pool '$poolName'"
}
# === Add this section below ===
 
# Extract backend pool IDs
$backendPool1Id = $backendPools[0].Id
$backendPool2Id = $backendPools[1].Id
$backendPool1Name = $backendPools[0].Name
$backendPool2Name = $backendPools[1].Name
 
# Set as pipeline variables
Write-Host "##vso[task.setvariable variable=backendPool1Id]$backendPool1Id"
Write-Host "##vso[task.setvariable variable=backendPool2Id]$backendPool2Id"
Write-Host "##vso[task.setvariable variable=backendPool1Name]$backendPool1Name"
Write-Host "##vso[task.setvariable variable=backendPool2Name]$backendPool2Name"
 
Write-Host "`n==> Exported backend pool IDs:"
Write-Host "backendPool1Id: $backendPool1Id"
Write-Host "backendPool2Id: $backendPool2Id"
      
    }


    "G" {
        # === STEP G: Verify Final Config ===
        Write-Host "`n=== Step G: Verifying Final Configuration ==="
        $lb = Get-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName
        $rules = $lb.LoadBalancingRules
        $backendPools = $lb.BackendAddressPools

        foreach ($rule in $lb.LoadBalancingRules) {
            $backendPool = ($backendPools | Where-Object { $_.Id -eq $rule.BackendAddressPool.Id }).Name
            Write-Host "Step G: - Rule '$($rule.Name)' → Backend Pool '$backendPool'"
        }

        Write-Host "`n Toggle complete → New active environment = $drainPoolName"
    }

    default {
        Write-Error "Invalid step specified!"
        exit 1
    }
}

