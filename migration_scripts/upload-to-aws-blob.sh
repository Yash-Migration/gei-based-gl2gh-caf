#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIG (same style as your Azure script)
# ============================================================
API_BASE_URL="${GH_API_URL}"   # user requested base URL (DR/github.com)
GITHUB_API_VERSION="2022-11-28"
SAS_EXPIRY_HOURS="${SAS_EXPIRY_HOURS:-24}" # default 24 hours

# ============================================================
# REQUIRED ENV VARS (GitHub + AWS)
# ============================================================
required_vars=("GH_ORG" "TARGET_GH_REPO" "GH_PAT" "GH_API_URL" "AWS_REGION" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_BUCKET_NAME")

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: Required environment variable $var is not set"
    exit 1
  fi
done

# Dependencies (keep same expectation as Azure: curl + jq)
for bin in curl jq date; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Error: Required command '$bin' is not installed"
    exit 1
  fi
done

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

upload_archive_to_aws_s3() {
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
  
  local bucket="${AWS_BUCKET_NAME}"
  local region="${AWS_REGION}"
  local s3_key="${org_id}/${archive_name}"

  local expires="$((SAS_EXPIRY_HOURS * 3600))"

  echo "Uploading to AWS S3..."
  echo "  Bucket   : ${bucket}"
  echo "  Object   : ${s3_key}"
  echo "  Region   : ${region}"

  # ------------------------------------------------------------
  # Option A: AWS CLI (preferred if available)
  # ------------------------------------------------------------
  if command -v aws >/dev/null 2>&1; then
    # Upload
    aws s3 cp "${archive_file}" "s3://${bucket}/${s3_key}" --region "${region}"

    echo "Upload complete."
    echo "Generating pre-signed GET URL..."
    PRESIGNED_URL="$(aws s3 presign "s3://${bucket}/${s3_key}" --expires-in "${expires}" --region "${region}")"
    export PRESIGNED_URL

  # ------------------------------------------------------------
  # Option B: python3 + boto3 (if awscli not installed)
  # ------------------------------------------------------------
  elif command -v python3 >/dev/null 2>&1; then
    # Ensure boto3 exists
    if ! python3 -c "import boto3" >/dev/null 2>&1; then
      echo "Error: aws cli not found and python3 'boto3' module is not installed."
      echo "Install either AWS CLI or boto3 to upload to S3."
      exit 1
    fi

    PRESIGNED_URL="$(
      python3 - <<PY
import os, boto3

bucket = os.environ["AWS_BUCKET_NAME"]
region = os.environ["AWS_REGION"]
access_key = os.environ["AWS_ACCESS_KEY_ID"]
secret_key = os.environ["AWS_SECRET_ACCESS_KEY"]
session_token = os.environ.get("AWS_SESSION_TOKEN")
archive_file = "${archive_file}"
s3_key = "${s3_key}"
expires = int(${expires})

kwargs = dict(
    region_name=region,
    aws_access_key_id=access_key,
    aws_secret_access_key=secret_key,
)
if session_token:
    kwargs["aws_session_token"] = session_token

s3 = boto3.client("s3", **kwargs)

# Upload
s3.upload_file(archive_file, bucket, s3_key)

# Presigned GET URL
url = s3.generate_presigned_url(
    ClientMethod="get_object",
    Params={"Bucket": bucket, "Key": s3_key},
    ExpiresIn=expires
)
print(url)
PY
    )"
    export PRESIGNED_URL
    echo "Upload complete."
    echo "Generating pre-signed GET URL..."

  else
    echo "Error: Neither 'aws' CLI nor 'python3' is available to upload to S3."
    exit 1
  fi

  echo "PRESIGNED_URL=${PRESIGNED_URL}"
  echo "Archive Upload URL: ${PRESIGNED_URL}"
  echo "PRESIGNED_URL=$PRESIGNED_URL" >>"$GITHUB_ENV"

}
main() {
  get_org_id "$GH_ORG" "$GH_PAT"
  upload_archive_to_aws_s3 "$ORG_ID" "$TARGET_GH_REPO"
}

main "$@"
