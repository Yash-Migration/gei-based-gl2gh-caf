#!/usr/bin/env bash
set -euo pipefail

## --- Config ---> # Set script base path and load env from config.sh.
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

## --- Input / derived env --->
MIGRATION_OUTPUT_FILE="${MIGRATION_OUTPUT_FILE:-}"

GH_HOST="${GH_HOST:-}"
if [[ -z "$GH_HOST" ]]; then
  echo "GH_HOST is not set"
  echo 'Set GH_HOST; export GH_HOST="github.com" for Non-DR (or) GH_HOST="SUBDOMAIN.ghe.com" for DR'
  exit 1
fi

if [[ "$GITHUB_TYPE" == "GitHub" ]]; then
  TARGET_API_URL="https://api.github.com"
elif [[ "$GITHUB_TYPE" == "GitHubDR" ]]; then
  TARGET_API_URL="https://api.${GH_HOST}"
else
  echo "[ERROR] Invalid GITHUB_TYPE: $GITHUB_TYPE"
  echo "[ERROR] Valid values: GitHub | GitHubDR"
  exit 1
fi

RUN_TS="$(date +"%Y%m%d_%H%M%S")"
LOG_FILE="${MONITOR_MIGRATION_LOG:-$LOG_DIR/monitor-migration}-${RUN_TS}.log"
OUTPUT_FILE="$ARTIFACTS_DIR/migration-status-${RUN_TS}.csv"
PER_MIGRATION_LOG_DIR="$LOG_DIR/monitor-migration-${RUN_TS}"

INTERVAL=30

mkdir -p "$LOG_DIR" "$ARTIFACTS_DIR" "$PER_MIGRATION_LOG_DIR"

if [[ -z "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] MIGRATION_OUTPUT_FILE env is not set. Please set it using the below command."
  echo "export MIGRATION_OUTPUT_FILE=output-file.csv"
  exit 1
elif [[ ! -s "$MIGRATION_OUTPUT_FILE" ]]; then
  echo "[ERROR] Migration output file is missing/empty: $MIGRATION_OUTPUT_FILE"
  exit 1
else
  echo "[INFO] Using migration output file: $MIGRATION_OUTPUT_FILE"
fi

## Save all stdout+stderr to logfile AND still show on terminal
exec > >(tee -a "$LOG_FILE") 2>&1

## --- Basic checks --->

command -v gh >/dev/null 2>&1 || { echo "[ERROR] GitHub CLI (gh) not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq not found"; exit 1; }
command -v nproc >/dev/null 2>&1 || { echo "[ERROR] nproc not found"; exit 1; }

TOTAL_MIGRATIONS=$(($(wc -l < "$MIGRATION_OUTPUT_FILE") - 1))
if [[ "$TOTAL_MIGRATIONS" -le 0 ]]; then
  echo "[ERROR] No migrations found in CSV file: $MIGRATION_OUTPUT_FILE"
  exit 1
fi

CPU_COUNT=$(nproc)
PARALLEL=$(( CPU_COUNT < TOTAL_MIGRATIONS ? CPU_COUNT : TOTAL_MIGRATIONS ))
PARALLEL=$(( PARALLEL > 8 ? 8 : PARALLEL ))

echo "[INFO] Starting migration monitoring..."
echo "[INFO] Migration output file : $MIGRATION_OUTPUT_FILE"
echo "[INFO] Target API URL        : $TARGET_API_URL"
echo "[INFO] Total migrations      : $TOTAL_MIGRATIONS"
echo "[INFO] Parallel workers      : $PARALLEL"
echo "[INFO] Progress interval     : ${INTERVAL}s"
echo "[INFO] Status output file    : $OUTPUT_FILE"
echo "[INFO] Full log file         : $LOG_FILE"
echo "[INFO] Per-migration logs    : $PER_MIGRATION_LOG_DIR"

RESULTS_TMP=$(mktemp)
INPUT_TMP=$(mktemp)

echo "github_org,github_repository,migration_id,status" > "$OUTPUT_FILE"

#########################################################
## Helpers
#########################################################

dequote() {
  local field="${1:-}"
  field="${field%$'\r'}"
  field="${field%\"}"
  field="${field#\"}"
  echo "$field"
}

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
        if [[ $((i + 1)) -lt ${#line} && "${line:$((i+1)):1}" == '"' ]]; then
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

find_col() {
  local name="$1"

  for i in "${!cols[@]}"; do
    [[ "$(dequote "${cols[$i]}")" == "$name" ]] && {
      echo "$i"
      return 0
    }
  done

  return 1
}

append_repo_to_list() {
  local current="${1:-}"
  local value="${2:-}"

  if [[ -z "$value" ]]; then
    echo "$current"
  elif [[ -z "$current" ]]; then
    echo "$value"
  else
    echo "$current, $value"
  fi
}

collect_status_snapshot() {
  local line org repo migration state repo_name
  local completed_count=0
  local failed_count=0
  local running_count=0
  local queued_count=0

  local completed_repos=""
  local failed_repos=""
  local in_progress_repos=""
  local queued_repos=""

  declare -A latest_status=()

  if [[ -s "$RESULTS_TMP" ]]; then
    while IFS=',' read -r org repo migration state; do
      [[ -z "${migration:-}" ]] && continue
      latest_status["$migration"]="$state"
    done < "$RESULTS_TMP"
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS=',' read -r org repo migration <<< "$line"
    repo_name="${org}/${repo}"

    case "${latest_status[$migration]:-QUEUED}" in
      COMPLETED)
        completed_count=$((completed_count + 1))
        completed_repos="$(append_repo_to_list "$completed_repos" "$repo_name")"
        ;;
      FAILED)
        failed_count=$((failed_count + 1))
        failed_repos="$(append_repo_to_list "$failed_repos" "$repo_name")"
        ;;
      STARTED)
        running_count=$((running_count + 1))
        in_progress_repos="$(append_repo_to_list "$in_progress_repos" "$repo_name")"
        ;;
      *)
        queued_count=$((queued_count + 1))
        queued_repos="$(append_repo_to_list "$queued_repos" "$repo_name")"
        ;;
    esac
  done < "$INPUT_TMP"

  SNAPSHOT_COMPLETED="$completed_count"
  SNAPSHOT_FAILED="$failed_count"
  SNAPSHOT_RUNNING="$running_count"
  SNAPSHOT_QUEUED="$queued_count"
  SNAPSHOT_FINISHED=$((completed_count + failed_count))
  SNAPSHOT_COMPLETED_REPOS="${completed_repos:-None}"
  SNAPSHOT_FAILED_REPOS="${failed_repos:-None}"
  SNAPSHOT_IN_PROGRESS_REPOS="${in_progress_repos:-None}"
  SNAPSHOT_QUEUED_REPOS="${queued_repos:-None}"
}

#########################################################
## Read header
#########################################################

header="$(head -n 1 "$MIGRATION_OUTPUT_FILE" | tr -d '\r')"
readarray -t cols < <(parse_csv_line "$header")

array_of_err_messages=()

ORG_IDX="$(find_col 'github_org')" || \
array_of_err_messages+=("[ERROR] Missing required header: github_org")

REPO_IDX="$(find_col 'github_repository')" || \
array_of_err_messages+=("[ERROR] Missing required header: github_repository")

MIGRATION_ID_IDX="$(find_col 'migration_id')" || \
array_of_err_messages+=("[ERROR] Missing required header: migration_id")

if ((${#array_of_err_messages[@]})); then
  {
    printf '%s\n' "${array_of_err_messages[@]}"
    echo "[ERROR] Header must contain 'github_org', 'github_repository', 'migration_id'"
  } >&2
  exit 1
fi

#########################################################
## Build input list
#########################################################

while IFS= read -r raw; do
  line="$(echo "$raw" | tr -d '\r')"
  [[ -z "$line" ]] && continue

  readarray -t flds < <(parse_csv_line "$line")

  github_org="$(dequote "${flds[$ORG_IDX]:-}")"
  github_repository="$(dequote "${flds[$REPO_IDX]:-}")"
  migration_id="$(dequote "${flds[$MIGRATION_ID_IDX]:-}")"

  [[ -z "$migration_id" ]] && continue

  echo "$github_org,$github_repository,$migration_id"
done < <(tail -n +2 "$MIGRATION_OUTPUT_FILE") > "$INPUT_TMP"

export TARGET_API_URL
export RESULTS_TMP
export PER_MIGRATION_LOG_DIR
export LOG_FILE

#########################################################
## Monitor Function
#########################################################

run_monitor() {
  local line="$1"

  IFS=',' read -r org repo migration <<< "$line"

  local safe_name
  safe_name="$(echo "${org}_${repo}_${migration}" | tr '/:' '__')"

  local log_file="$PER_MIGRATION_LOG_DIR/${safe_name}.log"

  echo "$org,$repo,$migration,STARTED" >> "$RESULTS_TMP"

  {
    echo "======================================"
    echo "Repo      : $org/$repo"
    echo "Migration : $migration"
    echo "Started   : $(date)"
    echo "======================================"
    echo

    gh ado2gh wait-for-migration \
      --migration-id "$migration" \
      --target-api-url "$TARGET_API_URL"

  } > "$log_file" 2>&1

  local exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    status="COMPLETED"
  else
    status="FAILED"
  fi

  echo "$org,$repo,$migration,$status" >> "$RESULTS_TMP"

  {
    echo
    echo "======================================"
    echo "Repo        : $org/$repo"
    echo "Migration   : $migration"
    echo "Final Status: $status"
    echo "Log file    : $log_file"
    echo "======================================"
  } >> "$LOG_FILE"
}

export -f run_monitor

cat "$INPUT_TMP" | \
xargs -I {} -P "$PARALLEL" bash -c 'run_monitor "$@"' _ {} &

MONITOR_PID=$!
MONITOR_START_TS=$(date +%s)

#########################################################
## Live monitoring
#########################################################
FIRST_DISPLAY=true
while kill -0 "$MONITOR_PID" 2>/dev/null; do
  collect_status_snapshot

  now=$(date +%s)
  elapsed=$((now - MONITOR_START_TS))
  printf -v elapsed_hhmmss '%dm:%02ds' $((elapsed/60)) $((elapsed%60))

  if [[ "$FIRST_DISPLAY" == true ]]; then
    FIRST_DISPLAY=false
  else
    tput cuu 6 2>/dev/null || true
    tput ed 2>/dev/null || true
  fi

cat <<EOF
==================================================
[$(date '+%H:%M:%S')] Monitoring migrations...
Completed : ${SNAPSHOT_FINISHED}/${TOTAL_MIGRATIONS}
Success   : ${SNAPSHOT_COMPLETED} | Failed: ${SNAPSHOT_FAILED} | In-Progress: ${SNAPSHOT_RUNNING}
Elapsed   : ${elapsed_hhmmss}
==================================================
EOF

  {
    echo
    echo "Migration State Details ($(date))"
    echo "---------------------------------"
    echo "Repos that are in-progress: ${SNAPSHOT_IN_PROGRESS_REPOS}"
    echo "Repos that are completed  : ${SNAPSHOT_COMPLETED_REPOS}"
    echo "Repos that are queued     : ${SNAPSHOT_QUEUED_REPOS}"
    echo "Repos that are failed     : ${SNAPSHOT_FAILED_REPOS}"
    echo
  } >> "$LOG_FILE"

  sleep "$INTERVAL"
done

wait "$MONITOR_PID" || true

collect_status_snapshot

now=$(date +%s)
elapsed=$((now - MONITOR_START_TS))
printf -v elapsed_hhmmss '%dm:%02ds' $((elapsed/60)) $((elapsed%60))

if [[ "$FIRST_DISPLAY" != true ]]; then
  tput cuu 6 2>/dev/null || true
  tput ed 2>/dev/null || true
fi

cat <<EOF
==================================================
[$(date '+%H:%M:%S')] Monitoring migrations...
Completed : ${SNAPSHOT_FINISHED}/${TOTAL_MIGRATIONS}
Success   : ${SNAPSHOT_COMPLETED} | Failed: ${SNAPSHOT_FAILED} | In-Progress: ${SNAPSHOT_RUNNING}
Elapsed   : ${elapsed_hhmmss}
==================================================
EOF

awk -F',' '
  {
    latest[$3]=$0
  }
  END {
    for (id in latest) {
      split(latest[id], f, ",")
      if (f[4] == "COMPLETED" || f[4] == "FAILED") {
        print latest[id]
      }
    }
  }
' "$RESULTS_TMP" | sort >> "$OUTPUT_FILE"

rm -f "$RESULTS_TMP" "$INPUT_TMP"

#########################################################
## Final Summary
#########################################################

echo
echo "FINAL MIGRATION SUMMARY"
echo "=================================================="

TOTAL=0
SUCCESS=0
FAILED=0

while IFS=',' read -r org repo migration status; do
  [[ "$org" == "github_org" ]] && continue
  [[ -z "${migration:-}" ]] && continue

  TOTAL=$((TOTAL + 1))

  case "$status" in
    COMPLETED)
      SUCCESS=$((SUCCESS + 1))
      ;;
    FAILED)
      FAILED=$((FAILED + 1))
      ;;
  esac
done < "$OUTPUT_FILE"

echo "Total Repositories : $TOTAL"
echo "Successful         : $SUCCESS"
echo "Failed             : $FAILED"
echo "=================================================="
echo

if [[ "$FAILED" -gt 0 ]]; then
  echo "Failed Repositories"
  echo "-------------------"
  awk -F',' '
    NR > 1 && $4 == "FAILED" {
      printf "  - %s/%s (Migration ID: %s)\n", $1, $2, $3
    }
  ' "$OUTPUT_FILE"
  echo
fi

echo
echo "Detailed Results"
echo "----------------"
column -s, -t "$OUTPUT_FILE"

echo
echo "Migration status written to: $OUTPUT_FILE"
echo "Detailed logs written to: $LOG_FILE"
echo "Repository migration logs written to: $PER_MIGRATION_LOG_DIR directory"
echo

if [[ "$FAILED" -gt 0 ]]; then
  echo
  echo "[ERROR] One or more migrations failed. Check logs under: $PER_MIGRATION_LOG_DIR"
  exit 1
fi

echo
