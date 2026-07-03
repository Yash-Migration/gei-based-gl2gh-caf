#!/usr/bin/env bash

set -euo pipefail
# -e: exit immediately if a command exits with a non-zero status.
# -u: treat unset variables as an error and exit.
# -o pipefail: if any command in a pipeline fails, the whole pipeline fails.

# --- Config ---> # Set script base path and load env from config.sh.
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Set env for logs
RUN_TS="$(date +"%Y%m%d_%H%M%S")"
LOG_FILE="${CREATE_ARCHIVE_LOG}_${RUN_TS}.log"
mkdir -p "$LOG_DIR"

# Save all stdout+stderr to logfile AND still show on terminal
exec > >(tee -a "$LOG_FILE") 2>&1

# --- Folders ---> # Ensure working and artifacts folders exist (create if missing).
mkdir -p "$WORKDIR" "$ARTIFACTS_DIR"

# --- Output list file ---> # Timestamp to make output filenames unique per run.
SUCCESS_LIST_FILE="$ARTIFACTS_DIR/archive-lists_${RUN_TS}.csv"

# Write CSV header: group, project, and the generated archive path.
echo '"gitlab_group","gitlab_project","archive_file","github_org","github_repo","gh_repo_visibility"' > "$SUCCESS_LIST_FILE"

# --- Basic checks ---> # Ensure the inventory CSV exists and docker image exists.
if [[ ! -s "$INVENTORY_FILE" ]]; then
    echo "[ERROR] Inventory file '$INVENTORY_FILE' missing or empty"
    exit 1
else
    echo "[INFO] Using Inventory file: $INVENTORY_FILE"
    echo ""
fi

# Check if docker command can be executed
if docker ps >/dev/null 2>&1; then
    DOCKER_CMD="docker"
    elif sudo -n docker ps >/dev/null 2>&1; then
    DOCKER_CMD="sudo docker"
else
    echo "[ERROR] Docker access not available (need docker group or passwordless sudo)"
    exit 1
fi

# Verify gl-exporter docker image present
if ! $DOCKER_CMD image inspect "$GL_EXPORTER_IMAGE" >/dev/null 2>&1; then
    echo "[ERROR] $GL_EXPORTER_IMAGE not found"
    exit 1
else
    echo "[INFO] gl-exporter version: $(docker run --rm "$GL_EXPORTER_IMAGE" gl_exporter --version)"
fi

# --- Helpers ---# String for filenames: - replace / or \ and spaces with underscores
file_safe() { echo "$1" | tr '/ ' '_' ; }

validate_export_models() {
    local value="$1"
    local row="$2"
    local column="$3"

    local model

    IFS='|' read -r -a models <<< "$value"

    for model in "${models[@]}"; do

        if [[ "|${GL_EXPORTER_ALLOWED_MODELS}|" != *"|${model}|"* ]]; then
            echo "[ERROR] Row: ${row} - Invalid value '$model' in ${column}"
            echo "[ERROR] Allowed values: ${GL_EXPORTER_ALLOWED_MODELS}"
            return 1
        fi
    done

    return 0
}

convert_pipe_to_comma() {
    echo "$1" | tr '|' ','
}

# Check if SSL is disabled
SSL_OPTS=""
if [[ "${DISABLE_SSL:-N}" == "Y" ]]; then
    SSL_OPTS="--ssl-no-verify"
    #echo "[INFO] SSL verification disabled in config.sh"
fi

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

# Counters for total rows, success and fails and array to capture failed list
total=0
skipped=0
ok=0
fail=0
declare -a failed=()

# --- Read header to find columns, split by command and find the index value
header="$(head -n 1 "$INVENTORY_FILE" | tr -d '\r')"
#IFS=',' read -r -a cols <<< "$header"
readarray -t cols < <(parse_csv_line "$header")

find_col() {
    # Finds the column index in 'cols[]' whose value exactly matches $1.
    # Loops through header array; if match found, prints index (0,1,2…) and returns 0, else returns 1.
    # Example: cols[0]="Namespace" → find_col Namespace → prints 0
    # Example: cols[1]="Project" → find_col Project → prints 1
    local name="$1"
    for i in "${!cols[@]}"; do
        [[ "${cols[$i]}" == "$name" ]] && echo "$i" && return 0
    done
    return 1
}

# --- Validate headers ---
array_of_err_messages=()

NS_IDX="$(find_col "Namespace")" || array_of_err_messages+=("[ERROR] Missing required header: Namespace")
PR_IDX="$(find_col "Project")"   || array_of_err_messages+=("[ERROR] Missing required header: Project")
GH_ORG_IDX="$(find_col "github_org")" || array_of_err_messages+=("[ERROR] Missing required header: github_org")
GH_REPO_IDX="$(find_col "github_repo")" || array_of_err_messages+=("[ERROR] Missing required header: github_repo")
Branch_Count="$(find_col "Branch_Count")" || array_of_err_messages+=("[ERROR] Missing required header: Branch_Count")
Commit_Count="$(find_col "Commit_Count")" || array_of_err_messages+=("[ERROR] Missing required header: Commit_Count")
FULL_URL_IDX="$(find_col "Full_URL")" || array_of_err_messages+=("[ERROR] Missing required header: Full_URL")
GH_REPO_VISIBILITY="$(find_col "gh_repo_visibility")" || array_of_err_messages+=("[ERROR] Missing required header: gh_repo_visibility")

# Flags
INCLUDE_IN_EXPORT_IDX="$(find_col "include_in_export" || true)"
EXCLUDE_FROM_EXPORT_IDX="$(find_col "exclude_from_export" || true)"

if ((${#array_of_err_messages[@]})); then
    {
        printf '%s\n' "${array_of_err_messages[@]}"
        echo "[ERROR] Header must contain 'Namespace', 'Project', 'Commit_Count', 'Branch_Count', 'Full_URL', 'github_org', 'github_repo', 'gh_repo_visibility' "
    } >&2
    exit 1
fi

# --- Generate CSV for projects in each row ---
while IFS= read -r raw; do
    line="$(echo "$raw" | tr -d '\r')"  # Read a line and strip any Windows CR.
    #IFS=',' read -r -a flds <<< "$line"    # Split the line into fields by comma.
    readarray -t flds < <(parse_csv_line "$line")

    ns="$(echo "${flds[$NS_IDX]:-}" | xargs)"
    pr="$(echo "${flds[$PR_IDX]:-}" | xargs)"
    github_org="$(echo "${flds[$GH_ORG_IDX]:-}" | xargs)"
    github_repo="$(echo "${flds[$GH_REPO_IDX]:-}" | xargs)"
    gh_repo_visibility="$(echo "${flds[$GH_REPO_VISIBILITY]:-}" | xargs)"
    full_url="$(echo "${flds[$FULL_URL_IDX]:-}" | xargs)"

    include_in_export=""
    exclude_from_export=""

    if [[ -n "${INCLUDE_IN_EXPORT_IDX:-}" ]]; then
        include_in_export="${flds[$INCLUDE_IN_EXPORT_IDX]:-}"
    fi

    if [[ -n "${EXCLUDE_FROM_EXPORT_IDX:-}" ]]; then
        exclude_from_export="${flds[$EXCLUDE_FROM_EXPORT_IDX]:-}"
    fi

    total=$((total + 1))   # Increment total rows processed.

    [[ -z "$ns" || -z "$pr" || -z "$github_org" || -z "$github_repo"  || -z "$gh_repo_visibility" || -z "$full_url" ]] && skipped=$((skipped+1)) && echo "" && echo "[WARN] Row: ${total} - Skipping due to missing required fields: gitlab_group='${ns}' gitlab_project='${pr}' Full_URL='${full_url}' github_org='${github_org}' github_repo='${github_repo}' gh_repo_visibility='$gh_repo_visibility'" && continue   # Skip rows that don’t have both Namespace, Project, GitHub Org and GitHub Repo.

    if [[ "$gh_repo_visibility" != "private" && "$gh_repo_visibility" != "public" && "$gh_repo_visibility" != "internal" ]]; then
       echo ""
       echo "[ERROR] Row: ${total} - Invalid gh_repo_visibility '$gh_repo_visibility' for project '$ns/$pr'"
       echo "[ERROR] Valid values: private, public, internal"
       fail=$((fail + 1))
       failed+=("$ns/$pr")
       continue
    fi

    GL_EXPORTER_ARGS=""

    if [[ -n "$include_in_export" && -n "$exclude_from_export" ]]; then
        echo "[ERROR] Row: ${total} - include_in_export and exclude_from_export cannot both be populated"
        fail=$((fail + 1))
        failed+=("$ns/$pr")
        continue
    fi

    if [[ -n "$include_in_export" ]]; then
        if ! validate_export_models "$include_in_export" "$total" "include_in_export"; then
            fail=$((fail + 1))
            failed+=("$ns/$pr")
            continue
        fi
        GL_EXPORTER_ARGS="--only $(convert_pipe_to_comma "$include_in_export")"
        echo "[INFO] Export filter applied for project '$ns/$pr': including only [$include_in_export]"
    elif [[ -n "$exclude_from_export" ]]; then
        if ! validate_export_models "$exclude_from_export" "$total" "exclude_from_export"; then
            fail=$((fail + 1))
            failed+=("$ns/$pr")
            continue
        fi
        GL_EXPORTER_ARGS="--except $(convert_pipe_to_comma "$exclude_from_export")"
        echo "[INFO] Export filter applied for project '$ns/$pr': excluding [$exclude_from_export]"
    else
        echo ". "
        echo "[INFO] No include/exclude filters specified for project '$ns/$pr': Exporting entire repository."
    fi

    # Resolve correct GitLab project slug from Full_URL
    clean_url="${full_url%%\?*}"
    clean_url="${clean_url%.git}"

    path_part="$(echo "$clean_url" | sed -E 's#https?://[^/]+/##')"

    resolved_ns="$(dirname "$path_part")"
    resolved_pr="$(basename "$path_part")"

    echo "[INFO] Resolved namespace: '$ns' -> '$resolved_ns'"
    echo "[INFO] Resolved project : '$pr' -> '$resolved_pr'"

    ns="$resolved_ns"
    pr="$resolved_pr"

    # Name of the output archive for this project.
    safe_ns="$(file_safe "$ns")"
    safe_pr="$(file_safe "$pr")"
    out_tar="migration_archive_${safe_ns}_${safe_pr}.tar.gz"

    echo "[INFO] Exporting: $ns / $pr -> $WORKDIR/$out_tar"

    # Temporary CSV passed to gl-exporter for just this project.
    tmp_csv="$WORKDIR/export_tmp.csv"
    printf '%s,%s\n' "$ns" "\"$pr\"" > "$tmp_csv"

    # Run gl-exporter in Docker:
    #  - Pass API endpoint, username, and token via environment.
    #  - Mount WORKDIR at /workspace so exporter can read/write files.
    #  - Input CSV: /workspace/export_tmp.csv
    #  - Output archive: /workspace/<out_tar>

    # $GL_EXPORTER_ARGS:
    # Per-project exporter arguments derived from the inventory CSV.
    # Example: include_in_export / exclude_from_export values are converted to --only or --except for the specific project being processed.

    # ${GL_EXPORTER_EXTRA_ARGS:-}:
    # Global exporter arguments defined in config.sh and applied to every project.
    # Example: setting '--debug' or '--lock-projects=transient' will apply that option to all project exports in the current run.

    if $DOCKER_CMD run --rm \
    -e GITLAB_API_ENDPOINT="$GITLAB_API_ENDPOINT" \
    -e GITLAB_USERNAME="$GITLAB_USERNAME" \
    -e GITLAB_API_PRIVATE_TOKEN="$GITLAB_API_PRIVATE_TOKEN" \
    -v "$WORKDIR":/workspace \
    "$GL_EXPORTER_IMAGE" \
    gl_exporter $GL_EXPORTER_ARGS ${GL_EXPORTER_EXTRA_ARGS:-} $SSL_OPTS -f "/workspace/$(basename "$tmp_csv")" -o "/workspace/$out_tar" >>"$LOG_FILE" 2>&1
    then
        echo "\"$ns\",\"$pr\",\"$WORKDIR/$out_tar\",\"$github_org\",\"$github_repo\",\"$gh_repo_visibility\"" >> "$SUCCESS_LIST_FILE"  # Append a success record to the output CSV (quoted values).
        ok=$((ok + 1))  # Increment success count.
    else
        echo "[ERROR] FAILED: $ns/$pr"  # Log failure for this Namespace/Project.

        failed+=("$ns/$pr")     # Record the failed item for summary output.
        fail=$((fail + 1))      # Increment failure count.
    fi
    rm -f "$tmp_csv"  # Clean up the temporary per-row CSV.
    echo ""

done < <(tail -n +2 "$INVENTORY_FILE")

# --- Summary ---
echo
echo "Summary:"
echo "  Total   : $total"
echo "  Skipped : $skipped"
echo "  Success : $ok"
echo "  Failed  : $fail"
if (( fail > 0 )); then
    echo "Failed list:"
    for f in "${failed[@]}"; do echo "  - $f"; done
fi
echo
echo "List of gitlab projects processed: $SUCCESS_LIST_FILE"
echo "Archives are created in: $WORKDIR"
echo "Detailed logs written to $LOG_FILE"
echo

echo "Run the below command to set env variable before running next script"
echo "export ARCHIVE_LIST=$SUCCESS_LIST_FILE"
echo
