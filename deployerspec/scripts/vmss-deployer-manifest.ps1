<#
.SYNOPSIS
    This script processes an OSB (Oracle Service Bus) manifest and performs various operations based on the manifest data for deployer services.

.DESCRIPTION
    The script takes an OSB manifest as input and performs the following tasks:
    1. Converts the OSB manifest payload to a PowerShell object.
    2. Extracts relevant information from the manifest, such as the resource parameter, subscription ID, key vault URL, environment, app name, and location.
    3. Check null and empty string to share/publish the variable to pipeline.
    5. Publishes provisioning global variables to the stage/job level. Use vmss-shared-variables.yml to consume/share/reuse published variable.

.PARAMETER osbManifest
    The OSB manifest in JSON format.

.EXAMPLE
    ProcessOSBManifest.ps1 -osbManifest '{"serviceSpecification": {...}}'

.NOTES
    This script requires PowerShell version 5.1 or later.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$osbManifest,
    [Parameter(Mandatory = $true)]
    [string]$osbOutputSecretName
)



Function Publish-PipelineVariables {
    param (
        [Parameter(Mandatory = $true)]
        [string]$provisioningVariable,
        [Parameter(Mandatory = $true)]
        $provisioningVariableValue
    )

    # Serialize complex objects (arrays, hashtables, PSCustomObjects, enumerables) to JSON so
    # Azure DevOps variable does not show @{...}=System.Object[] and lose structure.
    if ($null -ne $provisioningVariableValue -and (
            $provisioningVariableValue -is [array] -or
            $provisioningVariableValue -is [hashtable] -or
            ($provisioningVariableValue -is [System.Collections.IEnumerable] -and -not ($provisioningVariableValue -is [string])) -or
            $provisioningVariableValue -is [pscustomobject]
        )) {
        try {
            # Use sufficient depth for nested objects (e.g. alerts.emails, scheduled_queries.queries)
            $stringValue = $provisioningVariableValue | ConvertTo-Json -Depth 20 -Compress
        }
        catch {
            Write-Warning "Failed JSON serialization for variable [$provisioningVariable]. Falling back to string. Error: $($_.Exception.Message)"
            $stringValue = [string]$provisioningVariableValue
        }
    }
    else {
        $stringValue = [string]$provisioningVariableValue
    }

    Write-Host ("Publishing variable [{0}] with value [{1}] to pipeline environment" -f $provisioningVariable, $stringValue)
    Write-Host ("##vso[task.setvariable variable={0}]{1}" -f "$($provisioningVariable);issecret=false;isOutput=true", $stringValue)
}

Write-Host "Pipeline ID and RunID to store output to KeyVault: $osbOutputSecretName"
$paramsData = @{}
try {
    # Process OSB Manifest payload as PowerShell Object
    $osbManifestObject = $osbManifest | ConvertFrom-Json
    Write-Host "OSB Manifest Object: "
    $osbManifestObject
    $serviceSpecification = $osbManifestObject


    # Get SubscriptionId
    $subscriptionId = $serviceSpecification.provisioningTarget.subscriptionId
    $paramsData.Add("subscriptionId", $subscriptionId) | Out-Null
    Write-Host "SubscriptionId from OSB: $($subscriptionId)"
    Write-Host "##vso[task.setvariable variable=subscriptionId;isOutput=true]$subscriptionId"

    # Get OSB output Keyvault URl, RG and KV's subscription ID
    $keyVaultUrl = New-Object System.uri($serviceSpecification.osb.keyVaultUrl)
    Write-Host "OSB output keyVaultUrl: $($keyVaultUrl)"
    $osbkv = $keyVaultUrl.Host.Split('.')[0]
    Write-Host "OSB output KeyVault Name Trimed: $($osbkv)"

    $paramsData.Add("osbOutputKeyvault", $osbkv) | Out-Null

    $osbOutputKeyvaultSubscriptionId = $serviceSpecification.osb.subscriptionId
    $paramsData.Add("osbOutputKeyvaultSubscriptionId", $osbOutputKeyvaultSubscriptionId) | Out-Null
    Write-Host "OSB output KeyvaultSubscriptionId: $($osbOutputKeyvaultSubscriptionId)"

    $osbOutputKeyvaultRgName = $serviceSpecification.osb.resourceGroup
    $paramsData.Add("osbOutputKeyvaultRgName", $osbOutputKeyvaultRgName) | Out-Null
    Write-Host "OSB output KeyvaultRgName: $($osbOutputKeyvaultRgName)"

    # Get Bicep Parameters and extract environment and AppName
    $vmssparameters = $serviceSpecification.parameters
    Write-Host "VMSSp Params from OSB servicespecification:"
    $vmssparameters
    ############# added new vmss paramters #######################
    $vmss = $vmssparameters.vmss
    $mcAction = $vmssparameters.action
    $bootstrapScript = $vmssparameters.bootstrap_script
    $serviceArtifacts = $vmssparameters.service_artifacts
    $serviceSetupScript = $vmssparameters.service_setup_script
    $vmssresourceGroup = $vmssparameters.resourceGroup
    $galleryName = $vmssparameters.galleryName
    $gallerySubscriptionId = $vmssparameters.gallerySubscriptionId
    $galleryResourceGroup = $vmssparameters.galleryResourceGroup
    $galleryImageDefinitionName = $vmssparameters.galleryImageDefinitionName
    $shortTierName = $vmssparameters.shortTierName
    $storageAccount = $vmssparameters.storageAccount
    $storageContainerName = $vmssparameters.storageContainerName
    $baseImagePublisher = $vmssparameters.baseImagePublisher
    $baseImageOffer = $vmssparameters.baseImageOffer
    $baseImageSku = $vmssparameters.baseImageSku
    $baseImageVersion = $vmssparameters.baseImageVersion
    $baseSourceImageType = $vmssparameters.baseSourceImageType
    $imageTemplateName = $vmssparameters.imageTemplateName
    $imageVersion = $vmssparameters.imageVersion
    $userAssignedIdentityName = $vmssparameters.userAssignedIdentityName
    $hostingEnvironment = $vmssparameters.hostingEnvironment
    $applicationEnvironment = $vmssparameters.applicationEnvironment
    $imageDefinition = $vmssparameters.imageDefinition
    $newCapacity = $vmssparameters.newCapacity

    $vmImageSubnetId = $vmssparameters.vmImageSubnetId
    $vmssAlerts = $vmssparameters.alerts
    $vmssScheduledQueries = $vmssparameters.scheduled_queries

    # Extract resource group name from subnet resource ID and set vNetResourceGroupName
    $vNetResourceGroupName = $null
    if ($vmImageSubnetId -and ($vmImageSubnetId -match "/resourceGroups/([^/]+)/")) {
        $vNetResourceGroupName = $matches[1]
        Write-Host "Extracted vNetResourceGroupName: $vNetResourceGroupName"
    } else {
        Write-Host "Could not extract vNetResourceGroupName from vmImageSubnetId."
    }


    ############# ended new vmss paramters #######################
    
    $environment = $vmssparameters.environment
    $appName = $vmssparameters.appName
    $location = $vmssparameters.location
    $tiername = $vmssparameters.tiername
    $shortTierName = $vmssparameters.shortTierName
    $shortEnvironmentName = $vmssparameters.shortEnvironmentName

    #####vmss test added ###
    # Detect empty/null variables
    # 🔻 ADD THIS BLOCK RIGHT BELOW your final `$vmssparameters = ...` section
    $variablesToPublish = @{
        "subscriptionId"             = $subscriptionId
        "environment"                = $environment
        "appName"                    = $appName
        "location"                   = $location
        "tiername"                   = $tiername
        "shortTierName"              = $shortTierName
        "shortEnvironmentName"       = $shortEnvironmentName
        "hostingEnvironment"         = $hostingEnvironment
        "applicationEnvironment"     = $applicationEnvironment
        "vmss"                       = $vmss
        "mcAction"                   = $mcAction
        "bootstrapScript"            = $bootstrapScript
        "serviceArtifacts"           = $serviceArtifacts
        "serviceSetupScript"         = $serviceSetupScript
        "resourceGroup"              = $vmssresourceGroup
        "galleryName"                = $galleryName
        "galleryResourceGroup"       = $galleryResourceGroup
        "gallerySubscriptionId"      = $gallerySubscriptionId
        "galleryImageDefinitionName" = $galleryImageDefinitionName
        "storageAccount"             = $storageAccount
        "storageContainerName"       = if ($null -eq $storageContainerName -or [string]::IsNullOrWhiteSpace($storageContainerName)) { "vmsscontainer" } else { $storageContainerName }
        "baseImagePublisher"         = $baseImagePublisher
        "baseImageOffer"             = $baseImageOffer
        "baseImageSku"               = $baseImageSku
        "baseImageVersion"           = $baseImageVersion
        "baseSourceImageType"        = if ($null -eq $baseSourceImageType -or [string]::IsNullOrWhiteSpace($baseSourceImageType)) { "SharedImageGalleryr" } else { $baseSourceImageType } # PlatformImage or SharedImageGallery
        "imageTemplateName"          = $imageTemplateName
        "imageVersion"               = $imageVersion
        "userAssignedIdentityName"   = $userAssignedIdentityName
        "imageDefinition"            = $imageDefinition
        "newCapacity"                = $newCapacity
        "vmImageSubnetId"            = $vmImageSubnetId
        "vNetResourceGroupName"      = $vNetResourceGroupName
        "vmssAlerts"                 = $vmssAlerts
        "vmssScheduledQueries"       = $vmssScheduledQueries
    }

    foreach ($kvp in $variablesToPublish.GetEnumerator()) {
        if ($null -ne $kvp.Value -and -not([string]::IsNullOrWhiteSpace($kvp.Value))) {
            $valueToPublish = $kvp.Value
            if ($valueToPublish -is [string]) {
                $valueToPublish = $valueToPublish.Trim()
            }
            Publish-PipelineVariables -provisioningVariable $kvp.Key -provisioningVariableValue $valueToPublish
        }
        else {
            Write-Host "Skipping [$($kvp.Key)] because it's empty or null."
        }
    }
}
catch {
    Write-Host "Exception occurred while deserializing the OSB Manifest"
    $osbManifest
    Write-Error "Error: $($_.Exception.Message)"
    Write-Error "StackTrace: $($_.Exception.StackTrace)"
    exit 1
}
