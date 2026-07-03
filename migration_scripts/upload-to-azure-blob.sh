#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIG
# ============================================================
API_BASE_URL="${GH_API_URL}"   # user requested base URL
GITHUB_API_VERSION="2022-11-28"
SAS_EXPIRY_HOURS="${SAS_EXPIRY_HOURS:-24}" # default 24 hours

# ============================================================
# REQUIRED ENV VARS (GitHub + archive)
# ============================================================
required_vars=("GH_ORG" "TARGET_GH_REPO" "GH_PAT" "AZ_CONTAINER")

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: Required environment variable $var is not set"
    exit 1
  fi
done

# Azure auth option A (preferred): connection string
# OR option B: account name + key
if [[ -z "${AZURE_STORAGE_CONNECTION_STRING:-}" ]]; then
  if [[ -z "${STORAGE_ACCOUNT_NAME:-}" || -z "${STORAGE_ACCOUNT_KEY:-}" ]]; then
    echo "Error: Provide either AZURE_STORAGE_CONNECTION_STRING OR (STORAGE_ACCOUNT_NAME + STORAGE_ACCOUNT_KEY)"
    exit 1
  fi
fi

# ============================================================
# FUNCTIONS
# ============================================================

get_org_id() {
  local org_slug="$1"
  local gh_pat="$2"
  local api_url="${API_BASE_URL%/}/orgs/${org_slug}"

  echo "Fetching org id from: ${api_url}"

  ORG_ID="$(
    curl -sS \
      -H "Authorization: Bearer ${gh_pat}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
      "${api_url}" | jq -r '.id'
  )"

  echo "Organization ID: ${ORG_ID}"

  if [[ -z "${ORG_ID}" || "${ORG_ID}" == "null" ]]; then
    echo "Error: Failed to get organization ID from API: ${api_url}"
    exit 1
  fi
}

upload_archive_to_azure_blob() {
  local org_id="$1"
  local repo_name="$2"


  local archive_file="${TARGET_ARCHIVE_PATH:-${repo_name}.tar.gz}"
  archive_file="$(realpath "$archive_file" 2>/dev/null || echo "$archive_file")"
  
  echo "Looking for archive file at: $archive_file"
  
  if [[ ! -f "$archive_file" ]]; then
    echo "Error: Archive file not found at $archive_file"
    exit 1
  fi
  
  local archive_name
  archive_name="$(basename "$archive_file")"
  
  # Blob "folder" prefix convention: /${org_id}/
  local blob_name="${org_id}/${archive_name}"

  echo "Uploading to Azure Blob..."
  echo "  Container : ${AZ_CONTAINER}"
  echo "  Blob name : ${blob_name}"

  if [[ -n "${AZURE_STORAGE_CONNECTION_STRING:-}" ]]; then
    az storage blob upload \
      --connection-string "$AZURE_STORAGE_CONNECTION_STRING" \
      --container-name "$AZ_CONTAINER" \
      --name "$blob_name" \
      --file "$archive_file" \
      --overwrite true \
      --output none
  else
    az storage blob upload \
      --account-name "$STORAGE_ACCOUNT_NAME" \
      --account-key "$STORAGE_ACCOUNT_KEY" \
      --container-name "$AZ_CONTAINER" \
      --name "$blob_name" \
      --file "$archive_file" \
      --overwrite true \
      --output none
  fi

  echo "Upload complete."
  echo "Generating SAS (pre-signed) URL..."

  local expiry_utc
  expiry_utc="$(date -u -d "+${SAS_EXPIRY_HOURS} hour" '+%Y-%m-%dT%H:%MZ')"
  echo "  SAS expiry: ${expiry_utc} UTC"

  local sas_token=""
  local storage_account_for_url=""

  if [[ -n "${AZURE_STORAGE_CONNECTION_STRING:-}" ]]; then
    storage_account_for_url="$(echo "$AZURE_STORAGE_CONNECTION_STRING" | tr ';' '\n' | awk -F= '$1=="AccountName"{print $2}')"
    if [[ -z "$storage_account_for_url" ]]; then
      echo "Error: Could not parse AccountName from AZURE_STORAGE_CONNECTION_STRING."
      exit 1
    fi

    sas_token="$(az storage blob generate-sas \
      --connection-string "$AZURE_STORAGE_CONNECTION_STRING" \
      --container-name "$AZ_CONTAINER" \
      --name "$blob_name" \
      --permissions r \
      --expiry "$expiry_utc" \
      --https-only \
      --output tsv)"
  else
    storage_account_for_url="$STORAGE_ACCOUNT_NAME"
    sas_token="$(az storage blob generate-sas \
      --account-name "$STORAGE_ACCOUNT_NAME" \
      --account-key "$STORAGE_ACCOUNT_KEY" \
      --container-name "$AZ_CONTAINER" \
      --name "$blob_name" \
      --permissions r \
      --expiry "$expiry_utc" \
      --https-only \
      --output tsv)"
  fi

  if [[ -z "${sas_token}" ]]; then
    echo "Error: Failed to generate SAS token."
    exit 1
  fi

  PRESIGNED_URL="https://${storage_account_for_url}.blob.core.windows.net/${AZ_CONTAINER}/${blob_name}?${sas_token}"
  export PRESIGNED_URL

  if [[ -z "$PRESIGNED_URL" || "$PRESIGNED_URL" == "null" ]]; then
        echo "Error: Failed to get valid upload URL"
        exit 1
    fi

  echo "PRESIGNED_URL=${PRESIGNED_URL}"
  echo "Archive Upload URL: ${PRESIGNED_URL}"
  echo "PRESIGNED_URL=$PRESIGNED_URL" >>"$GITHUB_ENV"
}
main() {
  get_org_id "$GH_ORG" "$GH_PAT"
  upload_archive_to_azure_blob "$ORG_ID" "$TARGET_GH_REPO"
}

main "$@"
