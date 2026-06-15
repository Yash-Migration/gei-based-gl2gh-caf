# GitLab → GitHub Migration

## 1. Executive Summary – Objective
This document provides detailed procedures to migrate source code repositories from **GitLab Server** to **GitHub**.

## 2. Requirements

### 2.1 GitHub Runner Host Requirements
- **OS:** Ubuntu
- Required tooling validated by the pipeline:
  - `curl`
  - `jq`
  - `git`
  - `docker`
  - `node`
  - `npm`
  - GitHub CLI (`gh`)
- If the runner user has sudo access, missing packages are installed automatically by the pipeline.
- If the runner user does not have sudo access, the pipeline fails and prints the required action items.
- Docker access is validated. If Docker is installed but the runner user cannot run Docker commands, the runner user must be added to the Docker group.

### 2.2 Access Requirements
- **GitHub access** to:
  - View migration scripts stored in the project
  - Trigger the pipeline
  - Review pipeline artifacts
  - Approve protected GitHub environments
  - Monitor the migration pipeline

### 2.3 Required Token Scopes

#### GitLab API Token
- Must be generated using an **admin user**.
- Required permissions: **full API access**.
- Used by `gl-exporter` during archive generation.

#### GitHub Personal Access Token (PAT)
Required scopes:
- `repo`
- `admin:org`
- `workflow`
- `user`

### 2.4 Enable GitHub Object Storage Feature Flag
- GitHub object storage feature flag must be enabled for both:
  - GitHub enterprise/account handle
  - Target GitHub organizations

### 2.5 Intermediate Storage for Archive Files
Supported storage options:
- GitHub Storage, up to 30 GB
- Azure Storage, up to 40 GB
- AWS Storage, up to 40 GB

### 2.6 Network Configuration
The customer is required to configure allow IP lists according to their implementation.

Reference documentation:

```text
https://docs.github.com/en/enterprise-cloud@latest/migrations/ado/managing-access-for-a-migration-from-azure-devops#configuring-ip-allow-lists-for-migrations
```

## 3. Repository Contents

```text
.
├── .github/workflows/gl-to-gh-migration.yml
├── README.md
├── config.sh
├── runner.sh
├── gl-migration-readiness-check.sh
├── generate-gl-migration-archive.sh
├── upload-gl-migration-archive.sh
├── start-gl2gh-repo-migration.sh
├── polling_monitoring.sh
├── gl-post-migration-validation.sh
├── gitlab-stats-sample.csv
├── gl_exporter/
└── migration_scripts/
    ├── batch.js
    ├── create-env-vars.js
    ├── create-migration-source.js
    ├── gh-api.js
    ├── index.js
    ├── issue.js
    ├── migration.js
    ├── repository.js
    ├── start-repo-migration.js
    ├── state.js
    ├── team.js
    ├── upload-to-github-blob.sh
    ├── upload-to-azure-blob.sh
    ├── upload-to-aws-blob.sh
    ├── user.js
    └── workflow.js
```

## 4. Scripts and Purpose

### 4.1 Shell Scripts

| Script | Purpose |
|------|---------|
| `config.sh` | Contains shared / generic variables used by multiple scripts. |
| `runner.sh` | Runner helper / wrapper script used to execute migration operations in the runner environment. |
| `gl-migration-readiness-check.sh` | Checks active merge requests and running pipelines before migration. |
| `generate-gl-migration-archive.sh` | Generates GitLab migration archives / exports for repositories defined in the inventory. |
| `upload-gl-migration-archive.sh` | Uploads generated archives to the configured intermediate storage. |
| `start-gl2gh-repo-migration.sh` | Starts GitLab to GitHub repository migration jobs in GitHub. |
| `polling_monitoring.sh` | Monitors repository migration status and generates `migration-status.csv`. |
| `gl-post-migration-validation.sh` | Compares branch and commit counts between GitLab and GitHub to validate migration. This script is not part of the main migration pipeline and must be run manually after migration completes. |

### 4.2 Scripts in `migration_scripts/` Directory
This directory contains JavaScript modules and helper scripts used to orchestrate GitHub migration operations.

| List of scripts |
|------|
| `batch.js` |
| `create-env-vars.js` |
| `create-migration-source.js` |
| `gh-api.js` |
| `index.js` |
| `issue.js` |
| `migration.js` |
| `repository.js` |
| `start-repo-migration.js` |
| `state.js` |
| `team.js` |
| `user.js` |
| `workflow.js` |
| `upload-to-github-blob.sh` |
| `upload-to-azure-blob.sh` |
| `upload-to-aws-blob.sh` |

## 5. Pre-Migration

### 5.1 Generate Inventory CSV
Before triggering the pipeline, generate an inventory file using the GitHub CLI extension `gitlab-stats`:

```bash
gh gitlab-stats --hostname "gitlab.company.com" --token "glpat-xxxx" --namespace my-gitlab-group
```

This produces a CSV inventory of repositories.

### 5.2 Edit Inventory CSV
After generation, edit the CSV and add two columns:
- `github_org`
- `github_repo`

Fill in the target GitHub organization and repository name for each row.

#### Example Inventory CSV

| Namespace | Project | Commit_Count | Branch_Count | Full_URL | github_org | github_repo |
| -------- | -------- | -------- | -------- | -------- | -------- | -------- |
| demo-group/sub-group | demo-project | 20 | 1 | `http://gitlab-server/demo-group/sub-group/demo-project` | ghorg | demoproject |
| demo-group-1/sub-group-1 | demo-project-1 | 20 | 1 | `http://gitlab-server/demo-group/sub-group/demo-project-1` | ghorg | demoproject1 |

**Notes**
- The example shows only the minimum required columns.
- The actual inventory CSV may contain additional metadata columns generated by `gh gitlab-stats`.
- Columns `github_org` and `github_repo` must be populated before running the pipeline.
- Upload the CSV to the GitHub repository.
- This file name is passed as the `INVENTORY_FILE` input when running the pipeline.

### 5.3 Upload Inventory to GitHub Repository
Upload the updated CSV into the GitHub repository so the pipeline can access it.

## 6. CI/CD Variable Setup (GitHub Environment)

All variables and secrets must be configured at the **GitHub Environment level**, not at the repository level.

Navigate to:

GitHub Repository → Settings → Environments → <ENVIRONMENT_NAME>

---

### Environment Variables

| Name | Description |
|------|-------------|
| SOURCE_GL_SERVER_URL | https://gitlab.company.com |
| GITLAB_USERNAME | gitlab-user |
| GH_HOST | github.com or SUBDOMAIN.ghe.com |
| STORAGE_TYPE | GITHUB / AZURE / AWS |
| AZ_CONTAINER | Required only if STORAGE_TYPE = Azure |
| AWS_BUCKET_NAME | Required only if STORAGE_TYPE = AWS |
| AWS_REGION | Required only if STORAGE_TYPE = AWS |

---

### Environment Secrets

| Name | Description |
|------|-------------|
| GITLAB_API_PRIVATE_TOKEN | GitLab token |
| GH_PAT | GitHub PAT |
| AZURE_STORAGE_CONNECTION_STRING | Required only if STORAGE_TYPE = Azure |
| AWS_ACCESS_KEY_ID | Required only if STORAGE_TYPE = AWS |
| AWS_SECRET_ACCESS_KEY | Required only if STORAGE_TYPE = AWS |

## 7. GitHub Environment Setup

The workflow uses two types of GitHub environments:

### 7.1 Client Configuration Environment
Create a GitHub environment that contains the customer's variables and secrets.

This environment name is provided during workflow execution using the input:

```text
ENVIRONMENT_NAME
```

Jobs that use this environment:
- `getting-env-ready`
- `validate-prerequisites`
- `pre-migration-readiness-check`
- `generate-migration-archives`
- `upload-migration-archives`
- `start-repository-migration`
- `display-migration-summary`
- `monitor-repository-migrations`

### 7.2 Approval Environment
Create the following GitHub environment:

```text
approvers-group
```

This environment is used for manual approval gates:
- Approval after readiness check
- Approval before monitoring

Configure required reviewers in `approvers-group` to enforce manual approvals.

## 8. Pipeline Flow

1. Getting environment ready
   - Validates Ubuntu runner
   - Validates or installs required packages
   - Validates Docker access
   - Installs GitHub CLI if missing
   - Installs npm packages
   - Authenticates GitHub CLI
   - Installs required GitHub CLI extensions

2. Validate prerequisites
   - Validates required variables and secrets
   - Validates `GITHUB_TYPE`
   - Validates `STORAGE_TYPE`
   - Validates required scripts
   - Validates inventory file

3. Pre-migration readiness check
   - Checks active GitLab merge requests and running pipelines
   - Uploads readiness output and logs as artifacts

4. Manual approval after readiness check
   - Uses `approvers-group`
   - Reviewer must check readiness output before continuing

5. Generate migration archives
   - Builds `gl-exporter` Docker image if missing
   - Generates migration archives
   - Captures archive list
   - Uploads archive output and logs as artifacts

6. Upload migration archives
   - Uploads archives to GitHub, Azure, or AWS storage depending on `STORAGE_TYPE`
   - Captures uploaded archive list
   - Uploads output and logs as artifacts

7. Start repository migrations
   - Starts GitLab to GitHub repository migrations
   - Produces migration output files
   - Uploads output and logs as artifacts

8. Display migration summary
   - Reads outputs from generate, upload, and start stages
   - Displays success and failure metrics
   - Creates `final-migration-summary.txt`
   - Uploads summary and related artifacts

9. Manual approval before monitoring
   - Uses `approvers-group`
   - Reviewer must check migration output before monitoring starts

10. Monitor repository migrations
    - Authenticates GitHub CLI
    - Installs or upgrades `gh-ado2gh`
    - Derives `TARGET_API_URL` based on `GH_HOST`
    - Reads `output_files/migration-outputs_*.csv`
    - Runs `polling_monitoring.sh`
    - Uploads `migration-status.csv`

11. Preserve artifacts
    - Output files, logs, summaries, and monitoring reports are uploaded as workflow artifacts.

## 8.1 Pipeline Trigger
The pipeline is manually triggered from GitHub Actions.

## 8.2 Executing the Pipeline

1. Open the GitHub repository.
2. Navigate to **Actions → GitLab to GitHub Migration Pipeline**.
3. Select **Run workflow**.
4. Provide inputs:

   - **Environment Name**
     - GitHub environment containing this customer's variables and secrets.
     - Example: `customer-prod-env`

   - **Inventory File**
     - GitLab Stats CSV generated using `gh gitlab-stats`.
     - Example: `gitlab-stats.csv`

   - **GitHub Type**
     - `GitHub` for GitHub Enterprise Cloud.
     - `GitHubDR` for GitHub Enterprise Cloud with Data Residency.

   - **Runner Label**
     - Example: `ubuntu-latest` or `self-hosted`.

5. Select **Run workflow** to start.

## 8.3 Artifacts and Retention
The pipeline uploads artifacts to support troubleshooting.

Artifacts include:
- Readiness output
- Migration archive generation output
- Archive upload output
- Migration start output
- Final migration summary
- Monitoring status CSV
- Output files
- Logs

Artifact retention is configured in the workflow using `retention-days: 7`.

## 9. Monitor the Status of Migration

Migration monitoring can be performed through the pipeline or manually.

### 9.1 Automated Monitoring Through Pipeline
The workflow includes an automated monitoring stage:

```text
monitor-repository-migrations
```

This stage:
- Runs after migration initiation.
- Requires approval through `approvers-group` before monitoring begins.
- Authenticates GitHub CLI using `GH_PAT` and `GH_HOST`.
- Installs or upgrades `gh-ado2gh`.
- Derives `TARGET_API_URL`:
  - `https://api.github.com` when `GH_HOST=github.com`
  - `https://api.<GH_HOST>` when using GitHub Enterprise Cloud with Data Residency
- Reads migration IDs from:

```text
output_files/migration-outputs_*.csv
```

- Runs:

```bash
./polling_monitoring.sh
```

Generated artifact:

```text
migration-status.csv
```

### 9.2 Manual Monitoring by Migration ID

#### GitHub Enterprise Cloud without Data Residency

```bash
gh ado2gh wait-for-migration --migration-id <migration-id>
```

#### GitHub Enterprise Cloud with Data Residency

```bash
gh ado2gh wait-for-migration --migration-id <migration-id> --target-api-url "https://api.SUBDOMAIN.ghe.com"
```

### 9.3 Monitor Migrations with GitHub Extension - gh-migration-monitor

#### GitHub Enterprise Cloud without Data Residency

```bash
gh migration-monitor --organization <GH_ORG> --github-token <GH_PAT>
```

#### GitHub Enterprise Cloud with Data Residency

```text
gh-migration-monitor extension is not supported for GitHub Enterprise Cloud with Data Residency.
```

## 10. Post Migration Validation
Run the following steps after migrations complete.

```bash
export INVENTORY_FILE="<your-inventory-file>.csv"
export GH_TOKEN="<github_pat>"
./gl-post-migration-validation.sh
```

This script validates migration accuracy by comparing:
- Branch counts
- Commit counts
- Repository metadata

between GitLab and the corresponding GitHub repositories using the GitHub API.

## 11. User Identity Mapping - Mannequins

### 11.1 Generate Mannequins

#### GitHub Enterprise Cloud without Data Residency

```bash
gh ado2gh generate-mannequin-csv --github-org "{github-org}"
```

#### GitHub Enterprise Cloud with Data Residency

```bash
gh ado2gh generate-mannequin-csv --github-org "{github-org}" --target-api-url https://api.SUBDOMAIN.ghe.com
```

### 11.2 Update Mannequin Mapping
Open `mannequins.csv` and populate the **Target User** column with valid GitHub usernames.

#### Mannequin User Mapping Example

| mannequin-user | mannequin-id | target-user |
|----------------|--------------|-------------|
| gluser1 | M_kgDODtfbRA | github-user1 |
| gluser2 | M_kgDODtfbRg | github-user2 |

**Explanation:**
- During migration, unmapped GitLab users are imported into GitHub as mannequins.
- The `target-user` column must be updated with the correct GitHub username.
- This mapping is later used to reclaim mannequins and associate commits, issues, and comments with real GitHub users.

### 11.3 Reclaim Mannequins

#### GitHub Enterprise Cloud without Data Residency

```bash
gh ado2gh reclaim-mannequin --github-org "{github-org}" --csv $CSV_FILE --skip-invitation
```

#### GitHub Enterprise Cloud with Data Residency

```bash
gh ado2gh reclaim-mannequin --github-org "{github-org}" --csv $CSV_FILE --skip-invitation --target-api-url https://api.SUBDOMAIN.ghe.com
```

## 12. Appendix

### 12.1 Install GitHub CLI
Install GitHub CLI by following the official installation documentation:

```text
https://github.com/cli/cli#installation
```

### 12.2 Install GitHub CLI Extensions
The workflow automatically installs or upgrades the required GitHub CLI extensions during the `getting-env-ready` job.

Required extensions:
- `gh-gitlab-stats`
- `gh-migration-monitor`
- `gh-ado2gh`

Manual installation commands:

```bash
gh extension install https://github.com/mona-actions/gh-gitlab-stats
```

```bash
gh extension install https://github.com/mona-actions/gh-migration-monitor
```

```bash
gh extension install https://github.com/github/gh-ado2gh
```

### 12.3 Build gl-exporter Docker Image
The pipeline builds the `gl-exporter` Docker image automatically during the archive generation stage if it is not already present.

Manual build command:

```bash
cd gl_exporter
docker build --no-cache=true -t gl-exporter .
```

Verify the image:

```bash
docker images | grep "gl-exporter"
```

Example output:

```text
REPOSITORY    TAG       IMAGE ID       CREATED        SIZE
gl-exporter   latest    5e168437a7a1   12 hours ago   1.51GB
ruby          3.2.1     3440a912810a   2 years ago    893MB
```
