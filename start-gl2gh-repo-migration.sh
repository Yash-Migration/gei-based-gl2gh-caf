#!/usr/bin/env bash
set -euo pipefail

# --- Config: set script base path and load env from config.sh ---
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
GH_HOST="$GH_HOST"

if [[ -z "$GH_HOST" ]]; then
    echo "GH_HOST is not set"
    echo "Set GH_HOST; export GH_HOST=\"github.com\" for Non-DR (or) GH_HOST=\"SUBDOMAIN.ghe.com\" for DR"
    exit 1
fi

if [[ "$GITHUB_TYPE" == "GitHub" ]]; then
    GH_SERVER_URL="https://github.com"
    GH_API_URL="https://api.github.com"

elif [[ "$GITHUB_TYPE" == "GitHubDR" ]]; then
    GH_SERVER_URL="https://${GH_HOST}"
    GH_API_URL="https://api.${GH_HOST}"
else
    echo "[ERROR] Invalid GITHUB_TYPE: $GITHUB_TYPE"
    echo "[ERROR] Valid values: GitHub | GitHubDR"
    exit 1
fi

export GH_SERVER_URL GH_API_URL

RUN_TS="$(date +'%Y%m%d_%H%M%S')"
LOG_FILE="${START_MIGRATION_LOG}_${RUN_TS}.log"
mkdir -p "${LOG_DIR}"

# Save all stdout+stderr to logfile AND still show on terminal
exec > >(tee -a "$LOG_FILE") 2>&1

mkdir -p "${ARTIFACTS_DIR}" "${MIGRATION_SCRIPTS}"

# --- Basic checks ---
if [[ ! -s "$UPLOADED_ARCHIVES" ]]; then
  echo "[ERROR] CSV file with pre-signed URL is missing/empty: $UPLOADED_ARCHIVES"
  exit 1
else
  echo "[INFO] Using CSV file: $UPLOADED_ARCHIVES"
fi

if [[ ! -x "$RUNNER_SCRIPT" ]]; then
  echo "[ERROR] Runner script not found/executable: $RUNNER_SCRIPT"
  exit 1
else
  echo "[INFO] Using runner script: $RUNNER_SCRIPT"
fi

# --- Outputs ---
MIGRATION_OUTPUT_FILE="${ARTIFACTS_DIR}/migration-outputs_${RUN_TS}.csv"
MIGRATION_FAILURE_FILE="${ARTIFACTS_DIR}/migration-failures_${RUN_TS}.csv"
MIGRATION_ENVS_FILE="${ARTIFACTS_DIR}/migration-envs_${RUN_TS}.txt"

echo "gitlab_group,gitlab_project,github_org,github_repository,gh_repo_visibility,migration_source_id,migration_id" > "${MIGRATION_OUTPUT_FILE}"
echo "gitlab_group,gitlab_project,github_org,github_repository_archive,gh_repo_visibility,migration_source_id,migration_id" > "${MIGRATION_FAILURE_FILE}"

# --- Helpers
# Remove leading/trailing double-quotes and trailing CR from a field.
dequote() {
  local field="${1:-}"
  field="${field%$'\r'}"
  field="${field%\"}"
  field="${field#\"}"
  echo "$field"
}

# Parse CSV file
parse_csv_line() {
    local line="$1"
    local -a fields=()
    local field=""
    local in_quotes=false
    local char
    local i

    for ((i=0; i<${#line}; i++)); do
        char="${line:$i:1}"

        if [[ "$char" == '"' ]]; then
            if [[ "$in_quotes" == true ]]; then
                if [[ "${line:$((i+1)):1}" == '"' ]]; then
                    field+="$char"
                    ((i++))
                else
                    in_quotes=false
                fi
            else
                in_quotes=true
            fi
            elif [[ "$char" == ',' && "$in_quotes" == false ]]; then
            fields+=("$field")
            field=""
        else
            field+="$char"
        fi
    done

    fields+=("$field")
    printf '%s\n' "${fields[@]}"
}

# Append env details for a row
append_env_details() {
  local ns="$1"; local pr="$2"; local out="$3"
  {
    echo "# Gitlab Group: ${ns}; Gitlab Project: ${pr} - Used env"
    echo "export SOURCE_GL_SERVER_URL=${SOURCE_GL_SERVER_URL:-}"
    echo "export SOURCE_GL_NAMESPACE=${SOURCE_GL_NAMESPACE:-}"
    echo "export SOURCE_GL_PROJECT=${SOURCE_GL_PROJECT:-}"
    echo "export GH_ORG=${GH_ORG:-}"
    echo "export GH_REPO_NAME=${GH_REPO_NAME:-}"
    echo "export GH_REPO_VISIBILITY=${GH_REPO_VISIBILITY:-}"
    echo "export PRESIGNED_URL=${PRESIGNED_URL:-}"
    echo "export TARGET_GH_ORG=${TARGET_GH_ORG:-}"
    echo "export TARGET_GH_ORG_ID=${TARGET_GH_ORG_ID:-}"
    echo "export ARCHIVE_FILE_NAME=${ARCHIVE_FILE_NAME:-}"
    echo "export MIGRATION=${MIGRATION:-}"
    echo "export MIGRATION_SOURCE_ID=${MIGRATION_SOURCE_ID:-}"
    echo "export MIGRATION_ID=${MIGRATION_ID:-}"
    echo ""
  } >> "$out"
}

# Find the column index by header name (exact match), using dequote for safety.
find_col() {
  local name="$1"
  for i in "${!cols[@]}"; do
    [[ "$(dequote "${cols[$i]}")" == "$name" ]] && { echo "$i"; return 0; }
  done
  return 1
}

# --- Globals for summary ---
declare -a MIG_IDS=()
TOT=0; SKIP=0; OK=0; FAIL=0

# --- Read header and compute indices ---
header="$(head -n 1 "$UPLOADED_ARCHIVES" | tr -d '\r')"
#IFS=',' read -r -a cols <<< "$header"
readarray -t cols < <(parse_csv_line "$header")

# --- Validate headers ---

array_of_err_messages=()

GL_GRP_IDX="$(find_col 'gitlab_group')" || array_of_err_messages+=("[ERROR] Missing required header: gitlab_group")
GL_PRJ_IDX="$(find_col 'gitlab_project')" || array_of_err_messages+=("[ERROR] Missing required header: gitlab_project")
ARC_FILE_IDX="$(find_col 'archive_file_path')" || array_of_err_messages+=("[ERROR] Missing required header: archive_file_path")
TGT_REPO_IDX="$(find_col 'archive_file_name')" || array_of_err_messages+=("[ERROR] Missing required header: archive_file_name")
URL_IDX="$(find_col 'presigned_url')" || array_of_err_messages+=("[ERROR] Missing required header: presigned_url")
ORG_IDX="$(find_col 'github_org')" || array_of_err_messages+=("[ERROR] Missing required header: github_org")
REPO_IDX="$(find_col 'github_repo')" || array_of_err_messages+=("[ERROR] Missing required header: github_repo")
GH_REPO_VISIBILITY_IDX="$(find_col 'gh_repo_visibility')" || array_of_err_messages+=("[ERROR] Missing required header: gh_repo_visibility")


if ((${#array_of_err_messages[@]})); then
  {
    printf '%s\n' "${array_of_err_messages[@]}"
    echo "[ERROR] Header must contain 'gitlab_group', 'gitlab_project', 'archive_file_path', 'archive_file_name', 'presigned_url', 'github_org', 'github_repo', 'gh_repo_visibility' "
  } >&2
  exit 1
fi

# --- JS runner wrapper ---
process_rows() {
  # Runs one JS step via RUNNER_SCRIPT, parses 'export NAME=VALUE' lines, exports them, returns rc
  run_step() {
    local js_relative_path="$1"
    local runner_script_out
    local runner_script_status=0

    # Execute JS via runner and capture stdout+stderr
    runner_script_out="$("$RUNNER_SCRIPT" "$js_relative_path" 2>&1)"
    runner_script_status=$?
    echo "$js_relative_path script output is:
    $runner_script_out" >>"$LOG_FILE"

    # Parse only lines that look like: export NAME=VALUE
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        local name="${BASH_REMATCH[1]}"
        local value="${BASH_REMATCH[2]}"
        # Trim spaces; strip single/double quotes if present
        value="$(echo "$value" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        [[ "$value" =~ ^\"(.*)\"$ ]] && value="${BASH_REMATCH[1]}"
        [[ "$value" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"
        printf -v "$name" '%s' "$value"
        export "$name"
      fi
    done <<< "$runner_script_out"

    return "$runner_script_status"
  }

  # --- Robust per-row parsing ---
  while IFS= read -r raw; do
    line="$(echo "$raw" | tr -d '\r')"
    [[ -z "$line" ]] && continue

    #IFS=',' read -r -a flds <<< "$line"
    readarray -t flds < <(parse_csv_line "$line")

    gitlab_group="$(dequote "${flds[$GL_GRP_IDX]:-}")"
    project="$(dequote "${flds[$GL_PRJ_IDX]:-}")"
    archive_file_path="$(dequote "${flds[$ARC_FILE_IDX]:-}")"
    archive_file_name="$(dequote "${flds[$TGT_REPO_IDX]:-}")"
    presigned_url="$(dequote "${flds[$URL_IDX]:-}")"
    github_org="$(dequote "${flds[$ORG_IDX]:-}")"
    github_repo_name="$(dequote "${flds[$REPO_IDX]:-}")"
    gh_repo_visibility="$(dequote "${flds[$GH_REPO_VISIBILITY_IDX]:-}")"

    TOT=$((TOT+1))

    # minimal guard
    if [[ -z "$gitlab_group" || -z "$project" || -z "$presigned_url" || \
          -z "$archive_file_name" || -z "$github_org" || -z "$github_repo_name" || -z "$gh_repo_visibility" ]]; then
      SKIP=$((SKIP+1))
      echo "[WARN] Row ${TOT} - Skipping due to missing headers: gitlab_group='${gitlab_group}' gitlab_project='${project}' presigned_url='${presigned_url}' archive_file_name='${archive_file_name}' github_org='${github_org}' github_repo='${github_repo_name}' gh_repo_visibility='${gh_repo_visibility}' "
      continue
    fi

    # reset per-row env
    unset PRESIGNED_URL SOURCE_GL_NAMESPACE SOURCE_GL_PROJECT MIGRATION TARGET_GH_ORG_ID ARCHIVE_FILE_NAME GH_ORG GH_REPO_NAME MIGRATION_SOURCE_ID MIGRATION_ID GH_REPO_VISIBILITY

    # export row inputs
    export PRESIGNED_URL="${presigned_url}"
    export SOURCE_GL_NAMESPACE="${gitlab_group}"
    export SOURCE_GL_PROJECT="${project}"
    export ARCHIVE_FILE_NAME="${archive_file_name}"
    export GH_ORG="${github_org}"
    export GH_REPO_NAME="${github_repo_name}"
    export GH_REPO_VISIBILITY="${gh_repo_visibility}"
    export MIGRATION="$(printf '{"type":"gitlab","sourceRepoUrl":"%s","ghRepoName":"%s"}' "${SOURCE_GL_SERVER_URL%/}/${gitlab_group}/${project}.git" "${github_repo_name}")"

    echo "[INFO] Executing migration scripts for GitLab Group: ${gitlab_group} ; GitLab Project: ${project}"

    # --- Step 1: create-env-vars.js ---
    pushd "$MIGRATION_SCRIPTS" >/dev/null
    if ! run_step "$MIGRATION_SCRIPTS/create-env-vars.js"; then
      echo "[ERROR] Fail: create-env-vars.js ${gitlab_group}/${project}"
      echo "${gitlab_group},${project},${GH_ORG},${ARCHIVE_FILE_NAME},${GH_REPO_VISIBILITY},${MIGRATION_SOURCE_ID:-},${MIGRATION_ID:-}" >> "${MIGRATION_FAILURE_FILE}"
      append_env_details "$gitlab_group" "$project" "${MIGRATION_ENVS_FILE}"
      FAIL=$((FAIL+1))
      popd >/dev/null
      continue
    fi
    popd >/dev/null

    export TARGET_GH_ORG_ID="$TARGET_GH_ORG_ID"
    export TARGET_GH_ORG="$GH_ORG"
    if [[ -n "${TARGET_GH_ORG_ID:-}" ]]; then
      echo "[INFO] TARGET_GH_ORG_ID set: $TARGET_GH_ORG_ID" >>"$LOG_FILE"
    else
      echo "[ERROR] Fail: TARGET_GH_ORG_ID empty ${gitlab_group}/${project}"
      FAIL=$((FAIL+1))
      continue
    fi

    # --- Step 2: create-migration-source.js ---
    pushd "$MIGRATION_SCRIPTS" >/dev/null
    if ! run_step "$MIGRATION_SCRIPTS/create-migration-source.js"; then
      echo "[ERROR] Fail: create-migration-source.js ${gitlab_group}/${project}"
      echo "${gitlab_group},${project},${GH_ORG},${ARCHIVE_FILE_NAME},${GH_REPO_VISIBILITY},${MIGRATION_SOURCE_ID:-},${MIGRATION_ID:-}" >> "${MIGRATION_FAILURE_FILE}"
      append_env_details "$gitlab_group" "$project" "${MIGRATION_ENVS_FILE}"
      FAIL=$((FAIL+1))
      popd >/dev/null
      continue
    fi
    popd >/dev/null

    export MIGRATION_SOURCE_ID="$MIGRATION_SOURCE_ID"
    if [[ -n "${MIGRATION_SOURCE_ID:-}" ]]; then
      echo "[INFO] MIGRATION_SOURCE_ID set: $MIGRATION_SOURCE_ID" >>"$LOG_FILE"
    else
      echo "[ERROR] Fail: MIGRATION_SOURCE_ID empty ${gitlab_group}/${project}"
      FAIL=$((FAIL+1))
      continue
    fi

    # --- Step 3: start-repo-migration.js ---
    pushd "$MIGRATION_SCRIPTS" >/dev/null
    if ! run_step "$MIGRATION_SCRIPTS/start-repo-migration.js"; then
      echo "[ERROR] Fail: start-repo-migration.js ${gitlab_group}/${project}"
      echo "${gitlab_group},${project},${GH_ORG},${ARCHIVE_FILE_NAME},${GH_REPO_VISIBILITY},${MIGRATION_SOURCE_ID:-},${MIGRATION_ID:-}" >> "${MIGRATION_FAILURE_FILE}"
      append_env_details "$gitlab_group" "$project" "${MIGRATION_ENVS_FILE}"
      FAIL=$((FAIL+1))
      popd >/dev/null
      continue
    fi
    popd >/dev/null

    export MIGRATION_ID="$MIGRATION_ID"
    if [[ -n "${MIGRATION_ID:-}" ]]; then
      echo "[INFO] MIGRATION_ID set: $MIGRATION_ID" >>"$LOG_FILE"
    else
      echo "[ERROR] Fail: MIGRATION_ID empty ${gitlab_group}/${project}"
      FAIL=$((FAIL+1))
      continue
    fi

    MIG_IDS+=("${MIGRATION_ID}")
    echo "${gitlab_group},${project},${GH_ORG},${GH_REPO_NAME},${GH_REPO_VISIBILITY},${MIGRATION_SOURCE_ID},${MIGRATION_ID}" >> "${MIGRATION_OUTPUT_FILE}"
    append_env_details "$gitlab_group" "$project" "${MIGRATION_ENVS_FILE}"
    OK=$((OK+1))

  done < <(tail -n +2 "$UPLOADED_ARCHIVES") # skip header
}

print_summary() {
  echo ""
  echo "---------------- Migration Summary ----------------"
  echo "Total processed           :   ${TOT}"
  echo "Skipped                   :   ${SKIP}"
  echo "Total Migrations started  :   ${OK}"
  if [[ ${OK} -gt 0 ]]; then
    echo "Migration IDs:"
    for id in "${MIG_IDS[@]}"; do
      echo " - ${id}"
    done
  fi
  if [[ ${FAIL} -gt 0 ]]; then
    echo "Failed                    :   ${FAIL}"
    echo "See failures in: ${MIGRATION_FAILURE_FILE}"
  fi
  echo ""
  echo "Output files:"
  echo " - For migrations that started successfully, details are written to: ${MIGRATION_OUTPUT_FILE}"
  echo " - For migrations that are failed, details are written to: ${MIGRATION_FAILURE_FILE}"
  echo " - Detailed logs written to: ${LOG_FILE}"
  echo " - Env variables that are used for each repo are available in: ${MIGRATION_ENVS_FILE}" >>"$LOG_FILE"
  echo ""
  echo " - To run monitor script, set the MIGRATION_OUTPUT_FILE env"
  echo "export MIGRATION_OUTPUT_FILE=$MIGRATION_OUTPUT_FILE"
  echo ""
}

# --- Run ---
process_rows
print_summary
