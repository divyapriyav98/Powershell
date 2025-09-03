#!/bin/bash
set -euo pipefail

# =============================================
# PREPARATION / METADATA EXTRACTION SCRIPT
# Adds argument parsing so inputs can be passed explicitly.
# Exports variables for use by createImageDefinition.sh.
# Optional: --output-env-file /path/to/file to persist variables.
# Source Image ID will be queried to extract metadata.
# SourceID: /subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery>/images/<imageDef>[/versions/<ver>]
# '/subscriptions/${imagesubscriptionId}/resourceGroups/rg-${tierName}-${location}-sharedgallery/providers/Microsoft.Compute/galleries/${tierName}${location}sharedgallery/images/${image_name}/versions/${imageVersion}'
# =============================================

show_usage() {
  cat <<'EOF'
Usage: createImageDefinition_prep.sh \
  --target-subscription <subId> \
  --target-rg <rg> \
  --target-gallery-name <name> \
  --target-location <location> \
  --source-image-id <sourceId> \
  [--image-definition-name <name>] \
  [--do-rbac-assignments true|false] \
  [--principal-id <principalId>] \
  [--shared-gallery-subscription <subId>] \
  [--shared-gallery-rg <rg>] \
  [--shared-gallery-name <galleryName>] \
  [--description <text>] [--eula <url>] [--privacy-uri <url>] [--release-note-uri <url>] \
  [--end-of-life <YYYY-MM-DD>] [--tags 'k1=v1 k2=v2'] \
  [--plan-name <name>] [--plan-product <prod>] [--plan-publisher <pub>] \
  [--disallowed-disk-types 'Premium_LRS,StandardSSD_LRS'] \
  [--architecture <Arch>] \
  [--accelerated-networking true|false] [--automatic-os-upgrade true|false] \
  [--rec-vcpus-min <n>] [--rec-vcpus-max <n>] \
  [--rec-mem-min <GB>] [--rec-mem-max <GB>] \
  [--features 'IsSecureBootEnabled=True SupportsCloudInit=True'] \
  [--output-env-file <file>] \
  [-h|--help]

Notes:
  1. SOURCE_IMAGE_ID pattern:
     /subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery>/images/<imageDef>[/versions/<ver>]
  2. Outputs exported variables to the current shell; optionally writes an env file.
EOF
}

# Defaults (environment still respected if set)
TARGET_SUBSCRIPTION="${TARGET_SUBSCRIPTION:-}"
TARGET_RG="${TARGET_RG:-}"
TARGET_GALLERY_NAME="${TARGET_GALLERY_NAME:-}"
TARGET_LOCATION="${TARGET_LOCATION:-}"
SOURCE_IMAGE_ID="${SOURCE_IMAGE_ID:-}"
IMAGE_DEFINITION_NAME="${IMAGE_DEFINITION_NAME:-}"
DO_RBAC_ASSIGNMENTS="${DO_RBAC_ASSIGNMENTS:-false}"
PRINCIPAL_ID="${PRINCIPAL_ID:-}"
SHARED_GALLERY_TARGET_SUBSCRIPTION="${SHARED_GALLERY_TARGET_SUBSCRIPTION:-}"
SHARED_RESOURCE_GROUP="${SHARED_RESOURCE_GROUP:-}"
SHARED_RESOURCE_GALLERY_NAME="${SHARED_RESOURCE_GALLERY_NAME:-}"

DESCRIPTION="${DESCRIPTION:-}"
EULA="${EULA:-}"
PRIVACY_URI="${PRIVACY_URI:-}"
RELEASE_NOTE_URI="${RELEASE_NOTE_URI:-}"
END_OF_LIFE="${END_OF_LIFE:-}"
TAGS="${TAGS:-}"
PLAN_NAME="${PLAN_NAME:-}"
PLAN_PRODUCT="${PLAN_PRODUCT:-}"
PLAN_PUBLISHER="${PLAN_PUBLISHER:-}"
DISALLOWED_DISK_TYPES="${DISALLOWED_DISK_TYPES:-}"
ARCHITECTURE="${ARCHITECTURE:-}"
ACCELERATED_NETWORKING="${ACCELERATED_NETWORKING:-}"
AUTOMATIC_OS_UPGRADE="${AUTOMATIC_OS_UPGRADE:-}"
REC_VCPUS_MIN="${REC_VCPUS_MIN:-}"
REC_VCPUS_MAX="${REC_VCPUS_MAX:-}"
REC_MEM_MIN="${REC_MEM_MIN:-}"
REC_MEM_MAX="${REC_MEM_MAX:-}"
FEATURES_LIST="${FEATURES_LIST:-}"
OUTPUT_ENV_FILE=""

# -------- Argument Parsing --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-subscription) TARGET_SUBSCRIPTION="$2"; shift 2;;
    --target-rg) TARGET_RG="$2"; shift 2;;
    --target-gallery-name) TARGET_GALLERY_NAME="$2"; shift 2;;
    --target-location) TARGET_LOCATION="$2"; shift 2;;
    --source-image-id) SOURCE_IMAGE_ID="$2"; shift 2;;
    --image-definition-name) IMAGE_DEFINITION_NAME="$2"; shift 2;;
    --do-rbac-assignments) DO_RBAC_ASSIGNMENTS="$2"; shift 2;;
    --principal-id) PRINCIPAL_ID="$2"; shift 2;;
    --shared-gallery-subscription) SHARED_GALLERY_TARGET_SUBSCRIPTION="$2"; shift 2;;
    --shared-gallery-rg) SHARED_RESOURCE_GROUP="$2"; shift 2;;
    --shared-gallery-name) SHARED_RESOURCE_GALLERY_NAME="$2"; shift 2;;
    --description) DESCRIPTION="$2"; shift 2;;
    --eula) EULA="$2"; shift 2;;
    --privacy-uri) PRIVACY_URI="$2"; shift 2;;
    --release-note-uri) RELEASE_NOTE_URI="$2"; shift 2;;
    --end-of-life) END_OF_LIFE="$2"; shift 2;;
    --tags) TAGS="$2"; shift 2;;
    --plan-name) PLAN_NAME="$2"; shift 2;;
    --plan-product) PLAN_PRODUCT="$2"; shift 2;;
    --plan-publisher) PLAN_PUBLISHER="$2"; shift 2;;
    --disallowed-disk-types) DISALLOWED_DISK_TYPES="$2"; shift 2;;
    --architecture) ARCHITECTURE="$2"; shift 2;;
    --accelerated-networking) ACCELERATED_NETWORKING="$2"; shift 2;;
    --automatic-os-upgrade) AUTOMATIC_OS_UPGRADE="$2"; shift 2;;
    --rec-vcpus-min) REC_VCPUS_MIN="$2"; shift 2;;
    --rec-vcpus-max) REC_VCPUS_MAX="$2"; shift 2;;
    --rec-mem-min) REC_MEM_MIN="$2"; shift 2;;
    --rec-mem-max) REC_MEM_MAX="$2"; shift 2;;
    --features) FEATURES_LIST="$2"; shift 2;;
    --output-env-file) OUTPUT_ENV_FILE="$2"; shift 2;;
    -h|--help) show_usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; show_usage; exit 1;;
  esac
done

# Parse shared gallery details from SOURCE_IMAGE_ID (if not explicitly supplied)
if [[ -n "${SOURCE_IMAGE_ID:-}" && "${SOURCE_IMAGE_ID}" =~ ^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Compute/galleries/([^/]+)/images/([^/]+) ]]; then
  : "${SHARED_GALLERY_TARGET_SUBSCRIPTION:=${BASH_REMATCH[1]}}"
  : "${SHARED_RESOURCE_GROUP:=${BASH_REMATCH[2]}}"
  : "${SHARED_RESOURCE_GALLERY_NAME:=${BASH_REMATCH[3]}}"
  : "${IMAGE_DEFINITION_NAME:=${BASH_REMATCH[4]}}"
elif [ -z "${SOURCE_IMAGE_ID:-}" ]; then
  echo "ERROR: --source-image-id is required." >&2
  exit 1
else
  echo "ERROR: SOURCE_IMAGE_ID not in expected format: ${SOURCE_IMAGE_ID}" >&2
  exit 1
fi

# Map TARGET_* env vars to generic names used later
RESOURCE_GROUP="${RESOURCE_GROUP:-$TARGET_RG}"
GALLERY_NAME="${GALLERY_NAME:-$TARGET_GALLERY_NAME}"
LOCATION="${LOCATION:-$TARGET_LOCATION}"

# Fail-fast validation
required_vars=(TARGET_SUBSCRIPTION TARGET_RG TARGET_GALLERY_NAME TARGET_LOCATION SOURCE_IMAGE_ID)
for v in "${required_vars[@]}"; do
  if [ -z "${!v:-}" ]; then
    echo "ERROR: Required variable $v is empty" >&2
    show_usage
    exit 1
  fi
done

# Best-effort RBAC
if [[ "${DO_RBAC_ASSIGNMENTS,,}" == "true" && -n "${PRINCIPAL_ID:-}" && -n "${SHARED_GALLERY_TARGET_SUBSCRIPTION:-}" && -n "${SHARED_RESOURCE_GROUP:-}" ]]; then
  echo "Attempting RBAC assignments for principal ${PRINCIPAL_ID}"
  {
    az role assignment create --assignee "$PRINCIPAL_ID" --role Reader --scope "/subscriptions/${SHARED_GALLERY_TARGET_SUBSCRIPTION}" >/dev/null 2>&1 || true
    az role assignment create --assignee "$PRINCIPAL_ID" --role Contributor --scope "/subscriptions/${SHARED_GALLERY_TARGET_SUBSCRIPTION}/resourceGroups/${SHARED_RESOURCE_GROUP}" >/dev/null 2>&1 || true
  } || true
fi

# Fetch source metadata
if [ -n "${SHARED_GALLERY_TARGET_SUBSCRIPTION:-}" ]; then
  echo "Setting Azure subscription to source gallery subscription $SHARED_GALLERY_TARGET_SUBSCRIPTION"
  if ! az account set --subscription "$SHARED_GALLERY_TARGET_SUBSCRIPTION" 2>/dev/null; then
    echo "ERROR: Unable to set context to source subscription $SHARED_GALLERY_TARGET_SUBSCRIPTION" >&2
    exit 2
  fi
fi

SOURCE_IMAGE_DEF=$(az sig image-definition show --ids "$SOURCE_IMAGE_ID" --query '{
    name:name,
    publisher:publisher,
    offer:offer,
    sku:sku,
    osType:osType,
    osState:osState,
    hyperVGeneration:hyperVGeneration,
    description:description,
    eula:eula,
    privacyStatementUri:privacyStatementUri,
    releaseNoteUri:releaseNoteUri,
    endOfLifeDate:endOfLifeDate,
    tags:tags,
    planName:purchasePlan.name,
    planProduct:purchasePlan.product,
    planPublisher:purchasePlan.publisher,
    disallowedDiskTypes:disallowed.diskTypes,
    architecture:architecture,
    features:features,
    recommendedVcpusMin:recommended.vCPUs.min,
    recommendedVcpusMax:recommended.vCPUs.max,
    recommendedMemoryMin:recommended.memory.min,
    recommendedMemoryMax:recommended.memory.max,
    acceleratedNetworking:acceleratedNetworking,
    automaticOSUpgrade:automaticOSUpgrade
  }' -o json) || { echo "Failed to fetch source image definition." >&2; exit 1; }

SOURCE_NAME=$(echo "$SOURCE_IMAGE_DEF" | jq -r .name)
if [ -z "${IMAGE_DEFINITION_NAME:-}" ]; then
  IMAGE_DEFINITION_NAME="$SOURCE_NAME"
fi
if [ -z "$IMAGE_DEFINITION_NAME" ]; then
  echo "ERROR: Could not determine image definition name from source metadata." >&2
  exit 1
fi

PUBLISHER=$(echo "$SOURCE_IMAGE_DEF" | jq -r .publisher)
OFFER=$(echo "$SOURCE_IMAGE_DEF" | jq -r .offer)
SKU=$(echo "$SOURCE_IMAGE_DEF" | jq -r .sku)
OSTYPE=$(echo "$SOURCE_IMAGE_DEF" | jq -r .osType)
OSSTATE=$(echo "$SOURCE_IMAGE_DEF" | jq -r .osState)
HYPERVGEN=$(echo "$SOURCE_IMAGE_DEF" | jq -r .hyperVGeneration)

missing_required=()
[ -z "$PUBLISHER" ] && missing_required+=(publisher)
[ -z "$OFFER" ] && missing_required+=(offer)
[ -z "$SKU" ] && missing_required+=(sku)
[ -z "$OSTYPE" ] && missing_required+=(osType)
[ -z "$OSSTATE" ] && missing_required+=(osState)
[ -z "$HYPERVGEN" ] && missing_required+=(hyperVGeneration)
if [ ${#missing_required[@]} -gt 0 ]; then
  echo "ERROR: Missing required source fields: ${missing_required[*]}" >&2
  exit 1
fi

DESCRIPTION=$(echo "$SOURCE_IMAGE_DEF" | jq -r .description)
EULA=$(echo "$SOURCE_IMAGE_DEF" | jq -r .eula)
PRIVACY_URI=$(echo "$SOURCE_IMAGE_DEF" | jq -r .privacyStatementUri)
RELEASE_NOTE_URI=$(echo "$SOURCE_IMAGE_DEF" | jq -r .releaseNoteUri)
END_OF_LIFE=$(echo "$SOURCE_IMAGE_DEF" | jq -r .endOfLifeDate)
TAGS=$(echo "$SOURCE_IMAGE_DEF" | jq -c .tags)
PLAN_NAME=$(echo "$SOURCE_IMAGE_DEF" | jq -r .planName)
PLAN_PRODUCT=$(echo "$SOURCE_IMAGE_DEF" | jq -r .planProduct)
PLAN_PUBLISHER=$(echo "$SOURCE_IMAGE_DEF" | jq -r .planPublisher)
DISALLOWED_DISK_TYPES=$(echo "$SOURCE_IMAGE_DEF" | jq -r '.disallowedDiskTypes | select(.!=null) | join(",")')
ARCHITECTURE=$(echo "$SOURCE_IMAGE_DEF" | jq -r .architecture)
ACCELERATED_NETWORKING=$(echo "$SOURCE_IMAGE_DEF" | jq -r .acceleratedNetworking)
AUTOMATIC_OS_UPGRADE=$(echo "$SOURCE_IMAGE_DEF" | jq -r .automaticOSUpgrade)
REC_VCPUS_MIN=$(echo "$SOURCE_IMAGE_DEF" | jq -r .recommendedVcpusMin)
REC_VCPUS_MAX=$(echo "$SOURCE_IMAGE_DEF" | jq -r .recommendedVcpusMax)
REC_MEM_MIN=$(echo "$SOURCE_IMAGE_DEF" | jq -r .recommendedMemoryMin)
REC_MEM_MAX=$(echo "$SOURCE_IMAGE_DEF" | jq -r .recommendedMemoryMax)
FEATURES_LIST=$(echo "$SOURCE_IMAGE_DEF" | jq -r '.features | select(.!=null) | map(.name + "=" + .value) | join(" ")')

for var in DESCRIPTION EULA PRIVACY_URI RELEASE_NOTE_URI END_OF_LIFE TAGS PLAN_NAME PLAN_PRODUCT PLAN_PUBLISHER DISALLOWED_DISK_TYPES ARCHITECTURE ACCELERATED_NETWORKING AUTOMATIC_OS_UPGRADE REC_VCPUS_MIN REC_VCPUS_MAX REC_MEM_MIN REC_MEM_MAX FEATURES_LIST; do
  eval "[ \"\${$var}\" = null ] && $var=\"\"" || true
  eval "[ \"\${$var}\" = \"\" ] && :"
done

# Optional user overrides already applied via arguments/env.

# Persist to env file if requested
if [ -n "$OUTPUT_ENV_FILE" ]; then
  echo "Writing variable exports to $OUTPUT_ENV_FILE"
  {
    echo "# Environment variables generated by createImageDefinition_prep.sh"
    for v in TARGET_SUBSCRIPTION TARGET_RG TARGET_GALLERY_NAME TARGET_LOCATION SOURCE_IMAGE_ID IMAGE_DEFINITION_NAME \
             DO_RBAC_ASSIGNMENTS PRINCIPAL_ID SHARED_GALLERY_TARGET_SUBSCRIPTION SHARED_RESOURCE_GROUP SHARED_RESOURCE_GALLERY_NAME \
             RESOURCE_GROUP GALLERY_NAME LOCATION PUBLISHER OFFER SKU OSTYPE OSSTATE HYPERVGEN DESCRIPTION EULA PRIVACY_URI RELEASE_NOTE_URI \
             END_OF_LIFE TAGS PLAN_NAME PLAN_PRODUCT PLAN_PUBLISHER DISALLOWED_DISK_TYPES ARCHITECTURE FEATURES_LIST REC_VCPUS_MIN REC_VCPUS_MAX \
             REC_MEM_MIN REC_MEM_MAX ACCELERATED_NETWORKING AUTOMATIC_OS_UPGRADE; do
      printf '%s=%q\n' "$v" "${!v:-}"
    done
  } > "$OUTPUT_ENV_FILE"
fi

echo "Preparation complete. IMAGE_DEFINITION_NAME='${IMAGE_DEFINITION_NAME}'"
