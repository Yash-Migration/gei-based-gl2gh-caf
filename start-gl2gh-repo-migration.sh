#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# GitLab to GitHub Migration using gh gl2gh migrate-repo
# ============================================================
#
# This script is intended to replace the old:
#   generate archive -> upload archive -> start migration
#
# with a direct:
#   gh gl2gh migrate-repo
#
# Mandatory environment variables:
#   SOURCE_GL_SERVER_URL
#   TARGET_API_URL
#   TARGET_UPLOADS_URL
#   GITLAB_API_PRIVATE_TOKEN
#   GH_PAT
#   INVENTORY_FILE
#
# Expected inventory columns:
#   Namespace / namespace / gitlab_group / gitlab_namespace / group
#   Project / project / gitlab_project / project_name / name
#   github_org / gh_org / target_org / organization / org
#   github_repo / gh_repo / target_repo / repository / repo
#   gh_repo_visibility / visibility / target_repo_visibility
#
# Optional inventory columns:
#   include_in_export    -> maps to --gitlab-only
#   exclude_from_export  -> maps to --gitlab-except
#
# Output:
#   output_files/migration-outputs_<timestamp>.csv
#   output_files/migration-failures_<timestamp>.csv
#   logs/
#   logs/gl2gh-verbose-logs/
#
# Prints:
#   export MIGRATION_OUTPUT_FILE=<path>
#
# ============================================================

timestamp="$(date -u +%Y%m%d_%H%M%S)"

ROOT_DIR="${CI_PROJECT_DIR:-$(pwd)}"
OUTPUT_DIR="$ROOT_DIR/output_files"
LOG_DIR="$ROOT_DIR/logs"
VERBOSE_DIR="$LOG_DIR/gl2gh-verbose-logs"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$VERBOSE_DIR"

RUN_LOG="$LOG_DIR/gl2gh-migrate-repos-$timestamp.log"
MIGRATION_OUTPUT_FILE="$OUTPUT_DIR/migration-outputs_$timestamp.csv"
FAILURE_FILE="$OUTPUT_DIR/migration-failures_$timestamp.csv"

touch "$RUN_LOG"

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$RUN_LOG"
}

fail() {
  log "[ERROR] $*"
  exit 1
}

trim() {
  local value="${1:-}"
  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_url() {
  local url
  url="$(trim "${1:-}")"

  if [[ -z "$url" ]]; then
    printf ''
    return 0
  fi

  if [[ "$url" != http://* && "$url" != https://* ]]; then
    url="https://$url"
  fi

  url="${url%/}"
  printf '%s' "$url"
}

csv_escape() {
  local value="${1:-}"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_env() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || fail "$name is required"
}

csv_value() {
  local line="$1"
  local idx="$2"

  if [[ "$idx" -lt 0 ]]; then
    printf ''
    return 0
  fi

  python3 - "$line" "$idx" <<'PY'
import csv
import sys

line = sys.argv[1]
idx = int(sys.argv[2])

try:
    row = next(csv.reader([line]))
    print(row[idx] if idx < len(row) else "")
except Exception:
    print("")
PY
}

find_col_index() {
  local header="$1"
  shift

  python3 - "$header" "$@" <<'PY'
import csv
import sys

header = sys.argv[1]
wanted = [x.strip().lower() for x in sys.argv[2:]]

try:
    cols = next(csv.reader([header]))
except Exception:
    print(-1)
    sys.exit(0)

normalized = []

for col in cols:
    c = col.strip().strip('"').strip("'").lower()
    c = c.replace(" ", "_").replace("-", "_")
    normalized.append(c)

wanted_norm = [
    w.replace(" ", "_").replace("-", "_")
    for w in wanted
]

for i, col in enumerate(normalized):
    if col in wanted_norm:
        print(i)
        sys.exit(0)

print(-1)
PY
}

validate_visibility() {
  local visibility="$1"
  visibility="$(trim "$visibility")"
  visibility="$(echo "$visibility" | tr '[:upper:]' '[:lower:]')"

  case "$visibility" in
    internal|private|public)
      printf '%s' "$visibility"
      ;;
    "")
      printf 'internal'
      ;;
    *)
      log "[WARN] Invalid gh_repo_visibility '$visibility'. Defaulting to internal."
      printf 'internal'
      ;;
  esac
}

convert_pipe_list_to_comma() {
  local value="$1"
  value="$(trim "$value")"
  value="${value//|/,}"
  printf '%s' "$value"
}

capture_verbose_logs() {
  local safe_name="$1"

  local copied="false"

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue

    local base
    base="$(basename "$file")"

    cp "$file" "$VERBOSE_DIR/${safe_name}_${base}_${timestamp}" 2>/dev/null || true
    copied="true"
  done < <(
    find \
      "${RUNNER_TEMP:-/tmp}" \
      "$ROOT_DIR" \
      "$HOME" \
      -maxdepth 7 \
      -type f \
      \( -iname "verbose.log" -o -iname "*verbose*.log" -o -iname "gl2gh*.log" \) \
      2>/dev/null || true
  )

  if [[ "$copied" == "true" ]]; then
    log "[INFO] Verbose logs captured under $VERBOSE_DIR"
  else
    log "[WARN] No verbose.log found for this repository"
  fi
}

extract_migration_id() {
  local file="$1"
  local migration_id=""

  migration_id="$(
    grep -Eio 'Migration[[:space:]]+ID[:[:space:]]*[A-Za-z0-9_-]+' "$file" 2>/dev/null \
      | tail -n1 \
      | sed -E 's/Migration[[:space:]]+ID[:[:space:]]*//I' \
      || true
  )"

  if [[ -z "$migration_id" ]]; then
    migration_id="$(
      grep -Eio 'Migration[[:space:]]+in[[:space:]]+progress[[:space:]]+\(ID:[[:space:]]*[A-Za-z0-9_-]+\)' "$file" 2>/dev/null \
        | tail -n1 \
        | sed -E 's/.*\(ID:[[:space:]]*([A-Za-z0-9_-]+)\).*/\1/I' \
        || true
    )"
  fi

  if [[ -z "$migration_id" ]]; then
    migration_id="$(
      grep -Eio 'migrationId[=:[:space:]]*[A-Za-z0-9_-]+' "$file" 2>/dev/null \
        | tail -n1 \
        | sed -E 's/migrationId[=:[:space:]]*//I' \
        || true
    )"
  fi

  printf '%s' "$migration_id"
}

build_common_args() {
  COMMON_ARGS=()

  SOURCE_GL_SERVER_URL="$(normalize_url "$SOURCE_GL_SERVER_URL")"
  TARGET_API_URL="$(normalize_url "$TARGET_API_URL")"
  TARGET_UPLOADS_URL="$(normalize_url "$TARGET_UPLOADS_URL")"

  [[ -n "$SOURCE_GL_SERVER_URL" ]] || fail "SOURCE_GL_SERVER_URL is empty after normalization"
  [[ -n "$TARGET_API_URL" ]] || fail "TARGET_API_URL is empty after normalization"
  [[ -n "$TARGET_UPLOADS_URL" ]] || fail "TARGET_UPLOADS_URL is empty after normalization"

  COMMON_ARGS+=(--gitlab-server-url "$SOURCE_GL_SERVER_URL")
  COMMON_ARGS+=(--use-github-storage)
  COMMON_ARGS+=(--github-pat "$GH_PAT")
  COMMON_ARGS+=(--gitlab-pat "$GITLAB_API_PRIVATE_TOKEN")
  COMMON_ARGS+=(--target-api-url "$TARGET_API_URL")
  COMMON_ARGS+=(--target-uploads-url "$TARGET_UPLOADS_URL")

  if [[ -n "${GL_EXPORTER_DOCKER_IMAGE:-}" ]]; then
    COMMON_ARGS+=(--docker-image "$GL_EXPORTER_DOCKER_IMAGE")
  fi

  if [[ "${GITLAB_DEBUG:-false}" == "true" ]]; then
    COMMON_ARGS+=(--gitlab-debug)
  fi

  if [[ "${GL2GH_QUEUE_ONLY:-true}" == "true" ]]; then
    COMMON_ARGS+=(--queue-only)
  fi

  COMMON_ARGS+=(--verbose)
}

run_one_migration() {
  local row_num="$1"
  local gitlab_group="$2"
  local gitlab_project="$3"
  local github_org="$4"
  local github_repo="$5"
  local visibility="$6"
  local include_in_export="$7"
  local exclude_from_export="$8"

  local safe_name
  safe_name="$(echo "${github_org}_${github_repo}" | tr '/: ' '___' | tr -cd 'A-Za-z0-9._-')"

  local repo_log="$LOG_DIR/gl2gh-${safe_name}-$timestamp.out"
  local status="FAILED"
  local migration_id=""
  local exit_code=0
  local error_message=""

  log "------------------------------------------------------------"
  log "[INFO] Row             : $row_num"
  log "[INFO] GitLab group    : $gitlab_group"
  log "[INFO] GitLab project  : $gitlab_project"
  log "[INFO] GitHub org      : $github_org"
  log "[INFO] GitHub repo     : $github_repo"
  log "[INFO] Repo visibility : $visibility"
  log "[INFO] Repo log        : $repo_log"
  log "------------------------------------------------------------"

  EXTRA_ARGS=()

  if [[ -n "$include_in_export" && -n "$exclude_from_export" ]]; then
    error_message="Both include_in_export and exclude_from_export are populated. Only one is allowed."
    log "[ERROR] $error_message"

    {
      csv_escape "$row_num"; echo -n ","
      csv_escape "$gitlab_group"; echo -n ","
      csv_escape "$gitlab_project"; echo -n ","
      csv_escape "$github_org"; echo -n ","
      csv_escape "$github_repo"; echo -n ","
      csv_escape "$visibility"; echo -n ","
      csv_escape "FAILED"; echo -n ","
      csv_escape ""; echo -n ","
      csv_escape "1"; echo -n ","
      csv_escape "$repo_log"; echo -n ","
      csv_escape "$error_message"; echo
    } >> "$MIGRATION_OUTPUT_FILE"

    {
      csv_escape "$row_num"; echo -n ","
      csv_escape "$gitlab_group"; echo -n ","
      csv_escape "$gitlab_project"; echo -n ","
      csv_escape "$github_org"; echo -n ","
      csv_escape "$github_repo"; echo -n ","
      csv_escape "1"; echo -n ","
      csv_escape "$error_message"; echo
    } >> "$FAILURE_FILE"

    return 1
  fi

  if [[ -n "$include_in_export" ]]; then
    EXTRA_ARGS+=(--gitlab-only "$(convert_pipe_list_to_comma "$include_in_export")")
  fi

  if [[ -n "$exclude_from_export" ]]; then
    EXTRA_ARGS+=(--gitlab-except "$(convert_pipe_list_to_comma "$exclude_from_export")")
  fi

  set +e

  gh gl2gh migrate-repo \
    "${COMMON_ARGS[@]}" \
    --gitlab-group "$gitlab_group" \
    --gitlab-project "$gitlab_project" \
    --github-org "$github_org" \
    --github-repo "$github_repo" \
    --target-repo-visibility "$visibility" \
    "${EXTRA_ARGS[@]}" \
    > "$repo_log" 2>&1

  exit_code=$?

  set -e

  cat "$repo_log" >> "$RUN_LOG" || true

  migration_id="$(extract_migration_id "$repo_log")"
  capture_verbose_logs "$safe_name"

  if [[ "$exit_code" -eq 0 ]]; then
    status="STARTED"
    log "[SUCCESS] Migration command completed for $github_org/$github_repo"
  else
    status="FAILED"
    error_message="$(tail -n 30 "$repo_log" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
    log "[ERROR] Migration command failed for $github_org/$github_repo"
    log "[ERROR] Repo log: $repo_log"

    {
      csv_escape "$row_num"; echo -n ","
      csv_escape "$gitlab_group"; echo -n ","
      csv_escape "$gitlab_project"; echo -n ","
      csv_escape "$github_org"; echo -n ","
      csv_escape "$github_repo"; echo -n ","
      csv_escape "$exit_code"; echo -n ","
      csv_escape "$error_message"; echo
    } >> "$FAILURE_FILE"
  fi

  {
    csv_escape "$row_num"; echo -n ","
    csv_escape "$gitlab_group"; echo -n ","
    csv_escape "$gitlab_project"; echo -n ","
    csv_escape "$github_org"; echo -n ","
    csv_escape "$github_repo"; echo -n ","
    csv_escape "$visibility"; echo -n ","
    csv_escape "$status"; echo -n ","
    csv_escape "$migration_id"; echo -n ","
    csv_escape "$exit_code"; echo -n ","
    csv_escape "$repo_log"; echo -n ","
    csv_escape "$error_message"; echo
  } >> "$MIGRATION_OUTPUT_FILE"

  [[ "$exit_code" -eq 0 ]]
}

main() {
  log "============================================================"
  log "GitLab to GitHub migration using gh gl2gh migrate-repo"
  log "============================================================"

  require_cmd gh
  require_cmd python3
  require_cmd grep
  require_cmd sed
  require_cmd awk
  require_cmd find

  require_env SOURCE_GL_SERVER_URL
  require_env TARGET_API_URL
  require_env TARGET_UPLOADS_URL
  require_env GITLAB_API_PRIVATE_TOKEN
  require_env GH_PAT
  require_env INVENTORY_FILE

  [[ -f "$INVENTORY_FILE" ]] || fail "Inventory file not found: $INVENTORY_FILE"
  [[ -s "$INVENTORY_FILE" ]] || fail "Inventory file is empty: $INVENTORY_FILE"

  export GH_PAT="$GH_PAT"
  export GH_TOKEN="$GH_PAT"
  export GL_PAT="$GITLAB_API_PRIVATE_TOKEN"
  export GEI_SKIP_VERSION_CHECK="${GEI_SKIP_VERSION_CHECK:-true}"
  export GEI_SKIP_STATUS_CHECK="${GEI_SKIP_STATUS_CHECK:-true}"

  build_common_args

  log "[INFO] SOURCE_GL_SERVER_URL  : $SOURCE_GL_SERVER_URL"
  log "[INFO] TARGET_API_URL        : $TARGET_API_URL"
  log "[INFO] TARGET_UPLOADS_URL    : $TARGET_UPLOADS_URL"
  log "[INFO] INVENTORY_FILE        : $INVENTORY_FILE"
  log "[INFO] MIGRATION_OUTPUT_FILE : $MIGRATION_OUTPUT_FILE"
  log "[INFO] FAILURE_FILE          : $FAILURE_FILE"

  echo '"row","gitlab_group","gitlab_project","github_org","github_repo","gh_repo_visibility","status","migration_id","exit_code","log_file","error_message"' > "$MIGRATION_OUTPUT_FILE"
  echo '"row","gitlab_group","gitlab_project","github_org","github_repo","exit_code","error_message"' > "$FAILURE_FILE"

  header="$(head -n 1 "$INVENTORY_FILE")"

  idx_gitlab_group="$(find_col_index "$header" "Namespace" "namespace" "gitlab_group" "gitlab namespace" "gitlab_namespace" "group")"
  idx_gitlab_project="$(find_col_index "$header" "Project" "project" "gitlab_project" "project_name" "name")"
  idx_github_org="$(find_col_index "$header" "github_org" "github org" "gh_org" "target_org" "organization" "org")"
  idx_github_repo="$(find_col_index "$header" "github_repo" "github repo" "gh_repo" "target_repo" "repository" "repo")"
  idx_visibility="$(find_col_index "$header" "gh_repo_visibility" "repo_visibility" "github_repo_visibility" "visibility" "target_repo_visibility")"
  idx_include="$(find_col_index "$header" "include_in_export" "gitlab_only" "include")"
  idx_exclude="$(find_col_index "$header" "exclude_from_export" "gitlab_except" "exclude")"

  [[ "$idx_gitlab_group" -ge 0 ]] || fail "Inventory column missing: Namespace/gitlab_group"
  [[ "$idx_gitlab_project" -ge 0 ]] || fail "Inventory column missing: Project/gitlab_project"
  [[ "$idx_github_org" -ge 0 ]] || fail "Inventory column missing: github_org"
  [[ "$idx_github_repo" -ge 0 ]] || fail "Inventory column missing: github_repo"

  total=0
  started=0
  failed=0
  skipped=0
  row_num=1

  while IFS= read -r line || [[ -n "$line" ]]; do
    row_num=$((row_num + 1))

    if [[ -z "$(trim "$line")" ]]; then
      continue
    fi

    gitlab_group="$(trim "$(csv_value "$line" "$idx_gitlab_group")")"
    gitlab_project="$(trim "$(csv_value "$line" "$idx_gitlab_project")")"
    github_org="$(trim "$(csv_value "$line" "$idx_github_org")")"
    github_repo="$(trim "$(csv_value "$line" "$idx_github_repo")")"
    visibility="$(trim "$(csv_value "$line" "$idx_visibility")")"
    include_in_export="$(trim "$(csv_value "$line" "$idx_include")")"
    exclude_from_export="$(trim "$(csv_value "$line" "$idx_exclude")")"

    visibility="$(validate_visibility "$visibility")"

    if [[ -z "$gitlab_group" || -z "$gitlab_project" || -z "$github_org" || -z "$github_repo" ]]; then
      log "[WARN] Skipping row $row_num because required values are missing"
      skipped=$((skipped + 1))
      continue
    fi

    total=$((total + 1))

    set +e

    run_one_migration \
      "$row_num" \
      "$gitlab_group" \
      "$gitlab_project" \
      "$github_org" \
      "$github_repo" \
      "$visibility" \
      "$include_in_export" \
      "$exclude_from_export"

    rc=$?

    set -e

    if [[ "$rc" -eq 0 ]]; then
      started=$((started + 1))
    else
      failed=$((failed + 1))
    fi

  done < <(tail -n +2 "$INVENTORY_FILE")

  actual_started="$(awk -F',' 'NR>1 && $7 ~ /STARTED/ {c++} END {print c+0}' "$MIGRATION_OUTPUT_FILE")"
  actual_failed="$(awk -F',' 'NR>1 {c++} END {print c+0}' "$FAILURE_FILE")"

  log "============================================================"
  log "Migration Summary"
  log "============================================================"
  log "Total rows selected       : $total"
  log "Total rows skipped        : $skipped"
  log "Total migrations started  : $actual_started"
  log "Total migrations failed   : $actual_failed"
  log "Migration output file     : $MIGRATION_OUTPUT_FILE"
  log "Failure file              : $FAILURE_FILE"
  log "Run log                   : $RUN_LOG"
  log "Verbose logs              : $VERBOSE_DIR"
  log "============================================================"

  echo "export MIGRATION_OUTPUT_FILE=$MIGRATION_OUTPUT_FILE"

  if [[ "$actual_started" -eq 0 ]]; then
    fail "No migrations were started. Check $FAILURE_FILE and $RUN_LOG"
  fi

  if [[ "$actual_failed" -gt 0 ]]; then
    log "[WARN] Some migrations failed. Review $FAILURE_FILE"
  fi
}

main "$@"
