
param (
    [string]$resourceGroup,
    [string]$storageAccount
)

$buildId = $env:BUILD_BUILDID
$TableName = "VmssArtifactoryList"

Write-Host "Setting subscription..."
az account set --subscription "$env:SUBSCRIPTION_ID"

Write-Host "Fetching storage account..."
# $storageAccount = az storage account list --resource-group $resourceGroup --query "[0].name" -o tsv
# $storageAccountId = az storage account list --resource-group $resourceGroup --query "[0].id" -o tsv
$storageAccountId = az storage account show --name $storageAccount --resource-group $resourceGroup --query "id" -o tsv

if (-not $storageAccount) {
    Write-Host "##vso[task.logissue type=error;]No storage account found in resource group $resourceGroup"
    exit 1
}

Write-Host "Storage Account: $storageAccount"
Write-Host "##vso[task.setvariable variable=storageAccountName;isOutput=true]$storageAccount"

Write-Host "Assigning roles to service principal..."

$roles = @(
    "Storage Blob Data Contributor",
    "Owner",
    "Storage Table Data Contributor"
)

foreach ($role in $roles) {
    $existing = az role assignment list --assignee $env:servicePrincipalId --role "$role" --scope "$storageAccountId" --query "[].id" -o tsv
    if (-not $existing) {
        Write-Host "Assigning role '$role'..."
        az role assignment create --assignee $env:servicePrincipalId --role "$role" --scope "$storageAccountId"
    } else {
        Write-Host "Role '$role' already assigned. Skipping."
    }
}

# Extract domain and path from ARTIFACT_URLS
$artifactUrl = $env:ARTIFACT_URLS.TrimEnd("/")
$uriParts = $artifactUrl -replace "^https://", "" -split "/", 2
$artifactDomain = $uriParts[0]
$artifactPath = $uriParts[1] -replace "^artifactory/", ""

Write-Host "Querying Artifactory API at domain: $artifactDomain"
Write-Host "Artifact path: $artifactPath"

# Call Artifactory API to list files
$artifactListResponse = Invoke-RestMethod -Method Get `
    -Uri "https://$artifactDomain/artifactory/api/storage/$artifactPath" `
    -SkipHttpErrorCheck -SkipCertificateCheck `
    -StatusCodeVariable "statusCode"

if (($statusCode -lt 200) -or ($statusCode -gt 299)) {
    Write-Host "##vso[task.logissue type=error;]Artifact retrieval failed: error code $statusCode"
    exit 1
}

# Extract and filter artifact list
$artifactList = $artifactListResponse.children
if (-not $artifactList) {
    Write-Host "##vso[task.logissue type=warning;]No artifacts found at $artifactPath"
    exit 0
}

$artifactList = $artifactList | Where-Object { $_.uri -match '\.vhd$' }

# Create table if not exists
# az storage table create `
#     --name $TableName `
#     --account-name $storageAccount `
#     --auth-mode login
$accountKey = az storage account keys list `
    --account-name $storageAccount `
    --resource-group $resourceGroup `
    --query "[0].value" -o tsv
#delete table
# az storage table delete --account-name maintenanceartifactory --name VmssArtifactoryList
$SATableName = az storage table create `
    --name $TableName `
    --account-name $storageAccount `
    --account-key $accountKey

# $tableExists = az storage table exists `
#     --name $TableName `
#     --account-name $storageAccount `
#     --account-key $accountKey `
#     --query "exists" -o tsv

# if ($tableExists -ne "true") {
#     Write-Host "##vso[task.logissue type=error;]Table $TableName does not exist or failed to create."
#     exit 1
# }
# List tables
$tableList = az storage table list --account-name $storageAccount --account-key $accountKey --query "[].name" -o tsv

# Display tables
Write-Host "`n Tables in Storage Account '$storageAccount':"
$tableList | ForEach-Object { Write-Host "- $_" }

Write-Host "The Tabe name $TableName in Storage account $storageAccount"


# Build a list of file metadata
$filesWithMetadata = @()

foreach ($file in $artifactList) {
    $fileName = $file.uri.TrimStart("/")
    $filePath = "$artifactPath/$fileName"

    $metadataResponse = Invoke-RestMethod -Method Get `
        -Uri "https://$artifactDomain/artifactory/api/storage/$filePath" `
        -SkipHttpErrorCheck -SkipCertificateCheck `
        -StatusCodeVariable "statusCode"

    if (($statusCode -lt 200) -or ($statusCode -gt 299)) {
        Write-Host "##vso[task.logissue type=warning;]Failed to fetch metadata for $fileName"
        continue
    }

    $fileSizeBytes = $metadataResponse.size
    $fileSizeMB = [math]::Round($fileSizeBytes / 1MB, 2)
    $lastModified = Get-Date $metadataResponse.lastModified

    $filesWithMetadata += [PSCustomObject]@{
        FileName     = $fileName
        FileSizeMB   = $fileSizeMB
        LastModified = $lastModified
    }
}

# Sort by LastModified descending (most recent first)
$filesWithMetadata = $filesWithMetadata | Sort-Object -Property LastModified -Descending

# Print and insert into table
foreach ($file in $filesWithMetadata) {
    $formattedDate = $file.LastModified.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Host "File: $($file.FileName) | Size: $($file.FileSizeMB) MB | Last Modified: $formattedDate"

    # 1. Build the entity as a hashtable
    $entity = @{
        PartitionKey = "Artifacts"
        RowKey       = $file.FileName
        FileName     = $file.FileName
        FileSize     = "$($file.FileSizeMB) MB"
        LastModified = $formattedDate
        Processed    = "No"
    }

    # 2. Convert to JSON and save to a temp file
    $tempFile = [System.IO.Path]::GetTempFileName() + ".json"
    # Convert to JSON
    $jsonEntity = $entity | ConvertTo-Json -Depth 3 -Compress

    # Save to temp file
    Set-Content -Path $tempFile -Value $jsonEntity -Encoding UTF8
    Write-Host "Entity JSON: $jsonEntity"

    $accountKey = az storage account keys list `
        --account-name $storageAccount `
        --resource-group $resourceGroup `
        --query "[0].value" -o tsv

    $existing = az storage entity show `
        --account-name $storageAccount `
        --account-key $accountKey `
        --table-name $TableName `
        --partition-key "Artifacts" `
        --row-key $($file.FileName) `
        --output none

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Entity already exists. Skipping insert for $($file.FileName)"
    #     az storage entity insert --account-name $storageAccount --account-key $accountKey --table-name $TableName --entity PartitionKey=Artifacts RowKey=$($file.FileName) FileName=$($file.FileName) FileSize="$($file.FileSizeMB) MB" LastModified=$formattedDate Processed=No --if-exists Replace
    }
    else {
        az storage entity insert `
            --account-name $storageAccount `
            --account-key $accountKey `
            --table-name $TableName `
            --entity `
            PartitionKey=Artifacts `
            RowKey=$($file.FileName) `
            FileName=$($file.FileName) `
            FileSize="$($file.FileSizeMB) MB" `
            LastModified=$formattedDate `
            Processed=No `
    }

}

Write-Host "List of files in table $TableName inside storageAccount $storageAccount"
az storage entity query `
    --account-name $storageAccount `
    --account-key $accountKey `
    --table-name $TableName `
    --output jsonc 
az storage entity query `
  --account-name $storageAccount `
  --account-key $accountKey `
  --table-name $TableName `
  -o table    

# Reference: Can use powershell filter as well in instead of --query (jmsquery)
#     $allArtifactsJson = az storage entity query `
#     --account-name $storageAccount `
#     --account-key $accountKey `
#     --table-name $TableName `
#     -o json
 
# $unprocessedArtifacts = ($allArtifactsJson | ConvertFrom-Json).items | Where-Object { $_.Processed -eq "No" }

# Query for unprocessed artifacts and sort them in PowerShell
$unprocessedArtifacts = az storage entity query `
    --account-name $storageAccount `
    --account-key $accountKey `
    --table-name $TableName `
    --query "items[?Processed==`'No`'].{PartitionKey:PartitionKey, RowKey:RowKey, FileName:FileName, FileSize:FileSize, LastModified:LastModified, Processed:Processed}" `
    -o json | ConvertFrom-Json

$unprocessedArtifactsJson = $unprocessedArtifacts | ConvertTo-Json -Depth 3 -Compress
Write-Host "Unprocessed Artifacts: $unprocessedArtifactsJson"

$latestUnprocessedArtifact = $null
if ($unprocessedArtifacts) {
    $latestUnprocessedArtifact = $unprocessedArtifacts |
    Sort-Object { [datetime]::Parse($_.LastModified) } -Descending |
    Select-Object -First 1
}

if (-not $latestUnprocessedArtifact) {
    Write-Host "##vso[task.logissue type=warning;]No unprocessed artifacts found."
    $ARTIFACT_TO_PROCESS = $null
}
else {
    $ARTIFACT_TO_PROCESS = $latestUnprocessedArtifact
    Write-Host "Artifact to process: $($ARTIFACT_TO_PROCESS | ConvertTo-Json -Depth 3 -Compress)"
}

if ($ARTIFACT_TO_PROCESS) {
    $artifactJson = $ARTIFACT_TO_PROCESS | ConvertTo-Json -Depth 3 -Compress
    Write-Host "##vso[task.setvariable variable=ARTIFACT_TO_PROCESS;isOutput=true]$artifactJson"
    $NEW_VERSION_FOUND = $true
    Write-Host "##vso[task.setvariable variable=NEW_VERSION_FOUND;isOutput=true]$NEW_VERSION_FOUND"
}


