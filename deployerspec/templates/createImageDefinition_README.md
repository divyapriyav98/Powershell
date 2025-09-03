# Azure Shared Image Gallery Image Definition Prep & Create Scripts

These two Bash scripts support replicating (or re-creating) an existing Image Definition from a *source* Shared Image Gallery (possibly in a different subscription / resource group) into a *target* Shared Image Gallery.

Scripts:
- create (prep) metadata: createImageDefinition_prep.sh
- create (execute) definition: createImageDefinition.sh

## High-Level Flow

1. Preparation (metadata discovery)
   - Input: SOURCE_IMAGE_ID (points to existing image definition).
   - Script reads source image-definition with az sig image-definition show in the source subscription.
   - Extracts required + optional metadata (publisher, offer, sku, sku architecture, features, plan, recommendations, etc.).
   - Exports variables (or writes an env file) for the creation phase.

2. Creation (idempotent)
   - Consumes exported variables (direct environment, env file, or explicit arguments).
   - Validates required arguments for creation.
   - Switches to the target subscription.
   - Skips if image definition already exists (idempotent).
   - Creates new image definition with same (or overridden) metadata.

## Source vs Target Separation

| Aspect | Source (Prep) | Target (Create) |
|--------|---------------|-----------------|
| Subscription | Derived from SOURCE_IMAGE_ID (or explicit override) | TARGET_SUBSCRIPTION |
| Resource Group | Parsed from SOURCE_IMAGE_ID | TARGET_RG |
| Gallery | Parsed from SOURCE_IMAGE_ID | TARGET_GALLERY_NAME |
| Image Definition Name | Parsed from SOURCE_IMAGE_ID (unless overridden) | IMAGE_DEFINITION_NAME (must match export) |
| Permissions Needed | Reader (and possibly Contributor) to read source definition | Contributor (to create definition) |

## Script: createImageDefinition_prep.sh

Purpose: Parse a SOURCE_IMAGE_ID, pull metadata, normalize values, optionally persist them to an env file for later use.

### Required Arguments

| Argument | Description |
|----------|-------------|
| --target-subscription | Destination subscription for the new image definition |
| --target-rg | Destination resource group |
| --target-gallery-name | Destination Shared Image Gallery name |
| --target-location | Azure region for the target gallery (must match an existing gallery region) |
| --source-image-id | Full resource ID of existing source image definition |

### Common Optional Arguments

| Argument | Reason |
|----------|--------|
| --image-definition-name | Override parsed name (default: source image name) |
| --do-rbac-assignments true|false | Best-effort Reader/Contributor assignment on source subscription/RG for PRINCIPAL_ID |
| --principal-id <id> | Managed Identity principalId (used if above is true) |
| --output-env-file <path> | Persist all discovered/exported variables for the create script |
| --description / --eula / --privacy-uri / --release-note-uri | Metadata overrides |
| --end-of-life <YYYY-MM-DD> | End-of-life date |
| --tags "k=v ..." | Space-delimited tags string |
| --plan-name / --plan-product / --plan-publisher | Marketplace plan metadata |
| --disallowed-disk-types "Premium_LRS,StandardSSD_LRS" | Comma list |
| --architecture <x64|Arm64> | Architecture (if present in source will be auto-set) |
| --accelerated-networking true|false | Override |
| --automatic-os-upgrade true|false | Override |
| --rec-vcpus-min / --rec-vcpus-max | Recommended vCPU boundaries |
| --rec-mem-min / --rec-mem-max | Recommended memory (GB) |
| --features "Name=Value Name2=Value2" | Features (space-separated tokens) |

### Example (Full Prep)

```bash
bash templates/vmss/createImageDefinition_prep.sh \
  --target-subscription 22222222-bbbb-2222-bbbb-222222222222 \
  --target-rg rg-secure-images-prod \
  --target-gallery-name secureProdGallery \
  --target-location eastus2 \
  --source-image-id /subscriptions/11111111-aaaa-1111-aaaa-111111111111/resourceGroups/rg-shared-images-eastus/providers/Microsoft.Compute/galleries/enterpriseShared/images/baseUbuntu2204 \
  --image-definition-name baseUbuntu2204-secure \
  --do-rbac-assignments false \
  --description "Hardened Ubuntu 22.04 LTS baseline with security agents" \
  --eula https://contoso.example.com/eula \
  --privacy-uri https://contoso.example.com/privacy \
  --release-note-uri https://contoso.example.com/releases/ubuntu2204-secure \
  --end-of-life 2027-04-30 \
  --tags "env=prod costcenter=CC123 owner=platform" \
  --plan-name secureUbuntu \
  --plan-product secureUbuntuSuite \
  --plan-publisher contosoSecure \
  --disallowed-disk-types Standard_LRS \
  --architecture x64 \
  --accelerated-networking true \
  --automatic-os-upgrade false \
  --rec-vcpus-min 2 \
  --rec-vcpus-max 8 \
  --rec-mem-min 4 \
  --rec-mem-max 32 \
  --features "IsSecureBootEnabled=True SupportsCloudInit=True" \
  --output-env-file /tmp/ubuntu2204_prep.env
```

Result: /tmp/ubuntu2204_prep.env contains quoted exports for all needed variables.

## Script: createImageDefinition.sh

Purpose: Create (idempotently) the image definition in the target gallery using previously prepared variables.

### Required (after resolution via env-file / args / env vars)

| Variable / Arg | Description |
|----------------|-------------|
| TARGET_SUBSCRIPTION | Destination subscription ID |
| TARGET_RG | Destination resource group |
| TARGET_GALLERY_NAME | Destination gallery |
| TARGET_LOCATION | Target location (gallery region) |
| IMAGE_DEFINITION_NAME | Name of the image definition |
| PUBLISHER | Publisher metadata |
| OFFER | Offer metadata |
| SKU | SKU metadata |
| OSTYPE | Linux or Windows |
| OSSTATE | Generalized or Specialized |
| HYPERVGEN | V1 or V2 |

If any of these are missing after parsing, the script exits with error.

### Optional Arguments (Override Values)

Same set as in prep (description, tags, plan, features, recommendations, etc.) plus:

| Argument | Description |
|----------|-------------|
| --env-file <path> | Source exported variables from prep (loaded early) |
| --dry-run | Show actions without invoking az create (still queries existing definition) |

### Example (Using Env File)

```bash
bash templates/vmss/createImageDefinition.sh \
  --env-file /tmp/ubuntu2204_prep.env
```

### Example (Override Tags + Description)

```bash
bash templates/vmss/createImageDefinition.sh \
  --env-file /tmp/ubuntu2204_prep.env \
  --tags "env=prod costcenter=CC123 owner=platform compliance=cis" \
  --description "Hardened Ubuntu 22.04 LTS baseline (CIS hardened)"
```

### Example (Direct Creation Without Prep)

(Requires you manually know the metadata.)

```bash
bash templates/vmss/createImageDefinition.sh \
  --target-subscription 22222222-bbbb-2222-bbbb-222222222222 \
  --target-rg rg-secure-images-prod \
  --target-gallery-name secureProdGallery \
  --target-location eastus2 \
  --image-definition-name baseUbuntu2204-secure \
  --publisher Canonical \
  --offer 0001-com-ubuntu-server-jammy \
  --sku 22_04-lts \
  --os-type Linux \
  --os-state Generalized \
  --hyper-v-generation V2 \
  --architecture x64 \
  --accelerated-networking true \
  --features "IsSecureBootEnabled=True SupportsCloudInit=True" \
  --rec-vcpus-min 2 --rec-vcpus-max 8 \
  --rec-mem-min 4 --rec-mem-max 32
```

### Dry Run

```bash
bash templates/vmss/createImageDefinition.sh --env-file /tmp/ubuntu2204_prep.env --dry-run
```

Shows the az command and the (would-be) output without creation.

## Idempotency

The creation script checks for an existing image definition:
```
az sig image-definition show --resource-group ... --gallery-name ... --gallery-image-definition ...
```
If found, returns existing JSON and exits 0 (safe for repeated executions in pipelines).

## RBAC Notes

- Prep script must read the source image definition. The executing principal needs Reader access (Contributor if tags/metadata require restricted fields) on:
  - Subscription scope: /subscriptions/<sourceSub> (Reader)
  - Resource group scope (if stricter): /subscriptions/<sourceSub>/resourceGroups/<sourceRG>
- Optional automatic assignments (best effort) when --do-rbac-assignments true and PRINCIPAL_ID is supplied.

## Features & Recommendations

- FEATURES_LIST is expanded unquoted: ensure tokens have no internal spaces except between Name=Value pairs.
- Recommended vCPU / Memory flags only appended if at least one boundary defined.
- Boolean flags validated to true|false before inclusion.

## Environment File Format (Excerpt)

Example /tmp/ubuntu2204_prep.env content (shortened):
```
TARGET_SUBSCRIPTION='22222222-bbbb-2222-bbbb-222222222222'
TARGET_RG='rg-secure-images-prod'
TARGET_GALLERY_NAME='secureProdGallery'
TARGET_LOCATION='eastus2'
IMAGE_DEFINITION_NAME='baseUbuntu2204-secure'
PUBLISHER='Canonical'
OFFER='0001-com-ubuntu-server-jammy'
SKU='22_04-lts'
OSTYPE='Linux'
OSSTATE='Generalized'
HYPERVGEN='V2'
FEATURES_LIST='IsSecureBootEnabled=True SupportsCloudInit=True'
...
```

You can source it manually:
```bash
. /tmp/ubuntu2204_prep.env
```

Then run the creation script with fewer arguments.

## Complete Variable Reference (with Example Values)

| Name | Example |
|------|---------|
| TARGET_SUBSCRIPTION | 22222222-bbbb-2222-bbbb-222222222222 |
| TARGET_RG | rg-secure-images-prod |
| TARGET_GALLERY_NAME | secureProdGallery |
| TARGET_LOCATION | eastus2 |
| SOURCE_IMAGE_ID | /subscriptions/11111111-.../galleries/enterpriseShared/images/baseUbuntu2204 |
| IMAGE_DEFINITION_NAME | baseUbuntu2204-secure |
| PUBLISHER | Canonical |
| OFFER | 0001-com-ubuntu-server-jammy |
| SKU | 22_04-lts |
| OSTYPE | Linux |
| OSSTATE | Generalized |
| HYPERVGEN | V2 |
| DESCRIPTION | Hardened Ubuntu 22.04 LTS baseline with security agents |
| EULA | https://contoso.example.com/eula |
| PRIVACY_URI | https://contoso.example.com/privacy |
| RELEASE_NOTE_URI | https://contoso.example.com/releases/ubuntu2204-secure |
| END_OF_LIFE | 2027-04-30 |
| TAGS | env=prod costcenter=CC123 owner=platform |
| PLAN_NAME | secureUbuntu |
| PLAN_PRODUCT | secureUbuntuSuite |
| PLAN_PUBLISHER | contosoSecure |
| DISALLOWED_DISK_TYPES | Standard_LRS |
| ARCHITECTURE | x64 |
| FEATURES_LIST | IsSecureBootEnabled=True SupportsCloudInit=True |
| REC_VCPUS_MIN | 2 |
| REC_VCPUS_MAX | 8 |
| REC_MEM_MIN | 4 |
| REC_MEM_MAX | 32 |
| ACCELERATED_NETWORKING | true |
| AUTOMATIC_OS_UPGRADE | false |
| DO_RBAC_ASSIGNMENTS | false |
| PRINCIPAL_ID | (blank unless RBAC assignment needed) |

## Troubleshooting

| Symptom | Cause | Resolution |
|---------|-------|-----------|
| ERROR: SOURCE_IMAGE_ID not in expected format | Regex mismatch | Provide full az resource ID path |
| Missing required variables | Incomplete args | Re-run with missing --target-* or metadata flags |
| RBAC failure setting source subscription | Identity lacks Reader | Grant Reader on source subscription or run with --do-rbac-assignments true (if allowed) |
| Creation skipped | Image already exists | This is expected idempotent behavior |

## Security Considerations

- Avoid storing sensitive tags or proprietary plan details in plain env files in shared locations.
- RBAC automation should be set to true only when pipeline identity has owner rights to assign roles (least privilege principle).

## Pipeline Integration Outline (Example)

1. Run prep in a secure step (optionally publishing the env file as a pipeline artifact with restricted permissions).
2. Pass env file path to creation step executed in target subscription context (same or different job).
3. Consume resulting $AZ_SCRIPTS_OUTPUT_PATH JSON for downstream VMSS image version creation.

## License / Maintenance

Internal engineering utility scripts. Keep az CLI version updated to support newer SIG fields (features / architecture). Review feature flags when Azure adds new image definition properties.
