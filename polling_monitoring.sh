#!/usr/bin/env bash
set -euo pipefail

CSV_FILE="${CSV_FILE}"
TARGET_API_URL="${TARGET_API_URL}"

INTERVAL=10
OUTPUT_FILE="migration_status.csv"
LOG_DIR="migration_monitor_logs"

mkdir -p "$LOG_DIR"

TOTAL_MIGRATIONS=$(($(wc -l < "$CSV_FILE") - 1))

if [[ "$TOTAL_MIGRATIONS" -le 0 ]]; then
  echo "[ERROR] No migrations found in CSV file: $CSV_FILE"
  exit 1
fi

CPU_COUNT=$(nproc)
PARALLEL=$(( CPU_COUNT < TOTAL_MIGRATIONS ? CPU_COUNT : TOTAL_MIGRATIONS ))
PARALLEL=$(( PARALLEL > 8 ? 8 : PARALLEL ))

echo "Starting migration monitoring..."
echo "--------------------------------"
echo "CSV file        : $CSV_FILE"
echo "Target API URL  : $TARGET_API_URL"
echo "Total migrations: $TOTAL_MIGRATIONS"
echo "Parallel workers: $PARALLEL"
echo "Progress interval: ${INTERVAL}s"
echo

RESULTS_TMP=$(mktemp)
INPUT_TMP=$(mktemp)

echo "github_org,github_repository,migration_id,status" > "$OUTPUT_FILE"

tail -n +2 "$CSV_FILE" | \
while IFS=',' read -r \
  gitlab_group \
  gitlab_project \
  github_org \
  github_repository \
  migration_source_id \
  migration_id
do
  [[ -z "${migration_id:-}" ]] && continue
  echo "$github_org,$github_repository,$migration_id"
done > "$INPUT_TMP"

export TARGET_API_URL
export RESULTS_TMP
export LOG_DIR

run_monitor() {
  local line="$1"

  IFS=',' read -r org repo migration <<< "$line"

  local safe_name
  safe_name="$(echo "${org}_${repo}_${migration}" | tr '/:' '__')"

  local log_file="$LOG_DIR/${safe_name}.log"

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

  exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    status="COMPLETED"
  else
    status="FAILED"
  fi

  echo "$org,$repo,$migration,$status" >> "$RESULTS_TMP"

  echo
  echo "======================================"
  echo "Repo        : $org/$repo"
  echo "Migration   : $migration"
  echo "Final Status: $status"
  echo "Log file    : $log_file"
  echo "======================================"
}

export -f run_monitor

cat "$INPUT_TMP" | xargs -I {} -P "$PARALLEL" bash -c 'run_monitor "$@"' _ {} &
MONITOR_PID=$!

while kill -0 "$MONITOR_PID" 2>/dev/null; do
  completed=0
  failed=0
  finished=0

  if [[ -s "$RESULTS_TMP" ]]; then
    completed=$(grep -c ",COMPLETED$" "$RESULTS_TMP" || true)
    failed=$(grep -c ",FAILED$" "$RESULTS_TMP" || true)
    finished=$((completed + failed))
  fi

  pending=$((TOTAL_MIGRATIONS - finished))

  echo
  echo "======================================"
  echo "LIVE MONITORING SUMMARY - $(date)"
  echo "======================================"
  echo "Total       : $TOTAL_MIGRATIONS"
  echo "Completed   : $completed"
  echo "Failed      : $failed"
  echo "InProgress  : $pending"
  echo "======================================"

  sleep "$INTERVAL"
done

wait "$MONITOR_PID" || true

sort "$RESULTS_TMP" >> "$OUTPUT_FILE"

rm -f "$RESULTS_TMP" "$INPUT_TMP"

echo
echo "==========================================="
echo "FINAL MIGRATION SUMMARY"
echo "==========================================="

TOTAL=0
SUCCESS=0
FAILED=0

while IFS=',' read -r org repo migration status; do
  [[ "$org" == "github_org" ]] && continue

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

echo "Total migrations : $TOTAL"
echo "Successful       : $SUCCESS"
echo "Failed           : $FAILED"

echo
echo "Detailed Results"
echo "----------------"
column -s, -t "$OUTPUT_FILE"

echo
echo "CSV output generated : $OUTPUT_FILE"
echo "Logs directory       : $LOG_DIR"

if [[ "$FAILED" -gt 0 ]]; then
  echo
  echo "[ERROR] One or more migrations failed. Check logs under: $LOG_DIR"
  exit 1
fi

echo
echo "All migrations completed successfully."
