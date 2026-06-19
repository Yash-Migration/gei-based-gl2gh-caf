

############################################################
# COMMON VARIABLES (used by all scripts)
############################################################
BASE_SCRIPT_LOC="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$BASE_SCRIPT_LOC/logs"
WORKDIR="$BASE_SCRIPT_LOC/gitlab_migration_archives"
ARTIFACTS_DIR="$BASE_SCRIPT_LOC/output_files"
MIGRATION_SCRIPTS="$BASE_SCRIPT_LOC/migration_scripts"
GITLAB_API_ENDPOINT="${SOURCE_GL_SERVER_URL}/api/v4"

############################################################
# ENV FOR GL-EXPORTER, UPLOAD ARCHIVE, REPO MIGRATION
############################################################
GL_EXPORTER_IMAGE="gl-exporter"
GITHUB_UPLOAD_SCRIPT="$MIGRATION_SCRIPTS/upload-to-github-blob.sh"
AZURE_UPLOAD_SCRIPT="$MIGRATION_SCRIPTS/upload-to-azure-blob.sh"
AWS_UPLOAD_SCRIPT="$MIGRATION_SCRIPTS/upload-to-aws-blob.sh"
GITHUB_ENV="$ARTIFACTS_DIR/github_env.txt"

############################################################
# CONFIG GL EXPORTER ARGS 
############################################################
DISABLE_SSL=Y

# --- Runner script to invoke JS scripts
RUNNER_SCRIPT="$BASE_SCRIPT_LOC/runner.sh"

############################################################
# LOG FILES
############################################################
CREATE_ARCHIVE_LOG="$LOG_DIR/create-migration-archive"
UPLOAD_ARCHIVE_LOG="$LOG_DIR/upload-archive"
START_MIGRATION_LOG="$LOG_DIR/start-gl2gh-migration"

############################################################
# END OF CONFIGURATION
############################################################
