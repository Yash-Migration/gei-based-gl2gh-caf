# GitLab → GitHub Migration

## Optional: Centralized Multi-Team Environment Setup (One-Time Setup)
> Skip this section and proceed directly to **Section 1. Executive Summary – Objective** if the migration repository will be used by a single team and environments will be created and managed manually.

Organizations that want to use a single migration repository for multiple teams can optionally implement the automated environment provisioning workflow described in `Setup-Customer-Environment.md`.

Check this url for more detailed explaination **[Setup-Customer-Environment.md](./Setup-Customer-Environment.md)**

### How It Works

- A repository administrator configures a single repository-level secret:
  - `GH_PAT` (with permissions to create environments, variables, secrets, and branch policies).

- Teams do not require repository administrator access.

- Each team creates its own customer branch, for example:
  ```text
  team-a
  team-b
  customer-1
  customer-2
  ```
- Environment, Protection rule, Variables and Secrets placeholders are added automatically.
- Teams has to fill them with valid informations.

Note: In the `setup-customer-environment.yml` please do modify `GH_HOST` for Data Residency accounts only. `GH_HOST: <hostname.ghe.com>  eg: wizkraft.ghe.com`
  
## 1. Executive Summary – Objective
This document provides detailed procedures to migrate source code repositories from **GitLab Server** to **GitHub**.

## 2. Requirements
### 2.1 Access Requirements
- **GitHub access** to:
  - View migration scripts stored in the project
  - Trigger the pipeline
  - Review pipeline artifacts
  - Approve protected GitHub environments
  - Monitor the migration pipeline

### 2.2 Required Token Scopes

#### GitLab API Token
- Must be generated using an **admin user**.
- Required permissions: **full API access**.

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
├── OperationalGuide.md
├── README.md
├── Setup-Customer-Environment.md
├── config.sh
├── gitlab-stats-sample.csv
├── gitlab-stats.csv
├── gl-gitsizer-readiness-check.sh
├── gl-migration-readiness-check.sh
├── gl-post-migration-validation.sh
├── start-gl2gh-repo-migration.sh
├── user_inputs.env
```

## 4. Scripts and Purpose

### 4.1 Shell Scripts

| Script | Purpose |
|------|---------|
| `config.sh` | Contains shared / generic variables used by multiple scripts. |
| `gl-migration-readiness-check.sh` | Checks active merge requests and running pipelines before migration. |
| `gl-gitsizer-readiness-check.sh` | Performs GitSizer analysis to identify repositories and large files. |
| `start-gl2gh-repo-migration.sh` | Starts GitLab to GitHub repository migration jobs in GitHub. |
| `gl-post-migration-validation.sh` | Compare and Validate both Gitlab & GitHub Migrated Repo Contents(Branches,Commits). |


## 5. Pre-Migration

### 5.1 Generate Inventory CSV
Before triggering the pipeline, generate an inventory file using the GitHub CLI extension `gitlab-stats`:

```bash
gh gitlab-stats --hostname "gitlab.company.com" --token "glpat-xxxx" --namespace my-gitlab-group
```

This produces a CSV inventory of repositories.

### 5.2 Edit Inventory CSV
After generation, edit the CSV and add the following columns:
- `github_org` : Target GitHub Org
- `github_repo` : Target Repo Name
- `gh_repo_visibility` : Supported values: `public, private, internal`

### Optional Export Filters in the Inventory CSV

The inventory CSV supports the following optional columns:

#### `include_in_export`
- Used to export only specific GitLab entities.
- Maps to the `gl-exporter --only` option.
- Can be left empty.

#### `exclude_from_export`
- Used to exclude specific GitLab entities from the export.
- Maps to the `gl-exporter --except` option.
- Can be left empty.

#### Supported Values
The following values are supported:

- merge_requests
- issues
- commit_comments
- hooks
- wiki

#### Multiple Values
Multiple values can be specified using the pipe (`|`) separator. Comma-separated values are not supported for `include_in_export` and `exclude_from_export` columns.

Example:

```csv
include_in_export
issues|merge_requests|commit_comments|hooks|wiki
```
*Note: include_in_export and exclude_from_export are mutually exclusive. If both columns are populated for a repository row, that repository will fail validation and be skipped. The script will continue processing all remaining repositories in the inventory file.*

| Fill in the target GitHub organization and repository name for each row. |

#### Example Inventory CSV

| Namespace | Project | Commit_Count | Branch_Count | Full_URL | github_org | github_repo | gh_repo_visibility | include_in_export | exclude_from_export |
| -------- | -------- | -------- | -------- | -------- | -------- | -------- |-------- | -------- | -------- |
| demo-group/sub-group | demo-project | 20 | 1 | `http://gitlab-server/demo-group/sub-group/demo-project` | ghorg | demoproject | private | merge_requests |
| demo-group-1/sub-group-1 | demo-project-1 | 20 | 1 | `http://gitlab-server/demo-group/sub-group/demo-project-1` | ghorg | demoproject1 | public | | commit_comments |

**Notes**
- The example shows only the minimum required columns.
- The actual inventory CSV may contain additional metadata columns generated by `gh gitlab-stats`.
- Columns `github_org`, `gh_repo_visibility` and `github_repo` must be populated before running the pipeline.
- Upload the CSV to the GitHub repository.
- This file name is passed as the `INVENTORY_FILE` input when running the pipeline.

### 5.3 Upload Inventory to GitHub Repository
Upload the updated CSV into the GitHub repository so the pipeline can access it.

## 6. GitHub Environment Setup

The workflow uses two types of GitHub environments:

### 6.1 CI/CD Variable Setup (Environment Variables)
Create a GitHub environment that contains the customer's variables and secrets. All variables and secrets must be configured at the **GitHub Environment level**, not at the repository level.

Navigate to:

GitHub Repository → Settings → Environments → <ENVIRONMENT_NAME>
- Example ENVIRONMENT_NAME: `customer-prod-env`

This environment name is provided during workflow execution using the input:
- Example:
```text
customer-prod-env
```

Jobs that use this environment:
- `getting-env-ready`
- `validate-prerequisites`
- `pre-migration-readiness-check + GitSizer Check`
- `Manul Approval Gate`
- `Start-Repository-Migration`
- `Post-Migration-Validation`

#### Environment Variables

| Name | Description |
|------|-------------|
| SOURCE_GL_SERVER_URL | https://gitlab.company.com |
| GITLAB_USERNAME | gitlab-user |
| GH_HOST | github.com or SUBDOMAIN.ghe.com |
| STORAGE_TYPE | GITHUB / AZURE / AWS |
| AZ_CONTAINER | Required only if STORAGE_TYPE = Azure |
| AWS_BUCKET_NAME | Required only if STORAGE_TYPE = AWS |
| AWS_REGION | Required only if STORAGE_TYPE = AWS |
| TARGET_API_URL | https://api.company.ghe.com |
| TARGET_UPLOADS_URL | https://uploads.company.ghe.com  |



#### Environment Secrets

| Name | Description |
|------|-------------|
| GITLAB_API_PRIVATE_TOKEN | GitLab token with required access |
| GH_PAT | GitHub Personal Access Token with required scopes |
| AZURE_STORAGE_CONNECTION_STRING | Required only if STORAGE_TYPE = Azure |
| AWS_ACCESS_KEY_ID | Required only if STORAGE_TYPE = AWS |
| AWS_SECRET_ACCESS_KEY | Required only if STORAGE_TYPE = AWS |

gl-exporter repo information required to clone and build docker image for archiving the repos using the docker image.

### 6.2 Approval Environment
Create the following GitHub environment:

GitHub Repository → Settings → Environments → <APPROVERS_GROUP_ENV_NAME>

Give the group name as:
```text
approvers-group
```

This environment is used for manual approval gates:
- Approval after readiness check
- Approval before monitoring

Configure required reviewers in `approvers-group` to enforce manual approvals.

## 7. Pipeline Flow

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

3. Pre-migration readiness + Git Sizer Check
   - Checks active GitLab merge requests and running pipelines
   - Performs a GitSizer assessment to identify repositories and files that may require review before migration
   - Uploads readiness and GitSizer reports as workflow artifacts
   - GitSizer findings should be reviewed and approved before proceeding to the migration stages

4. Manual approval after readiness check
   - Uses `approvers-group`
   - Reviewer must check readiness output before continuing

5. Start repository migrations
   - Starts GitLab to GitHub repository migrations
   - Produces migration output files
   - Uploads output and logs as artifacts

6. Post-migration validation
    - Reads inventory file and validates successfully migrated repositories in GitHub
    - Validates branch and commit counts by running `gl-post-migration-validation.sh`
    - Uploads post-validation reports and logs

7. Preserve artifacts
    - Output files, logs, summaries, and monitoring reports are uploaded as workflow artifacts.

## 7.1 Pipeline Trigger
The pipeline is manually triggered from GitHub Actions.

## 7.2 Executing the Pipeline

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

## 7.3 Artifacts and Retention
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

## 8. Monitor the Status of Migration

### 8.1 Manual Monitoring by Migration ID

#### GitHub Enterprise Cloud without Data Residency

```bash
gh gl2gh wait-for-migration --migration-id <migration-id>
```

#### GitHub Enterprise Cloud with Data Residency

```bash
gh gl2gh wait-for-migration --migration-id <migration-id> --target-api-url "https://api.SUBDOMAIN.ghe.com"
```

### 8.3 Monitor Migrations with GitHub Extension - gh-migration-monitor

#### GitHub Enterprise Cloud without Data Residency

```bash
gh migration-monitor --organization <GH_ORG> --github-token <GH_PAT>
```

#### GitHub Enterprise Cloud with Data Residency

```text
gh-migration-monitor extension is not supported for GitHub Enterprise Cloud with Data Residency.
```

## 9. User Identity Mapping - Mannequins

### 9.1 Generate Mannequins

#### GitHub Enterprise Cloud without Data Residency

```bash
gh gl2gh generate-mannequin-csv --github-org "{github-org}"
```

#### GitHub Enterprise Cloud with Data Residency

```bash
gh gl2gh generate-mannequin-csv --github-org "{github-org}" --target-api-url https://api.SUBDOMAIN.ghe.com
```

### 9.2 Update Mannequin Mapping
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

### 9.3 Reclaim Mannequins

#### GitHub Enterprise Cloud without Data Residency

```bash
gh gl2gh reclaim-mannequin --github-org "{github-org}" --csv $CSV_FILE --skip-invitation
```

#### GitHub Enterprise Cloud with Data Residency

```bash
gh gl2gh reclaim-mannequin --github-org "{github-org}" --csv $CSV_FILE --skip-invitation --target-api-url https://api.SUBDOMAIN.ghe.com
```

## 10. Appendix

### 10.1 Install GitHub CLI
Install GitHub CLI by following the official installation documentation:

```text
https://github.com/cli/cli#installation
```

### 10.2 Install GitHub CLI Extensions
The workflow automatically installs or upgrades the required GitHub CLI extensions during the `getting-env-ready` job.

Required extensions:
- `gh-gl2gh`
- `gh-migration-monitor`
 
Manual installation commands:

```bash
gh extension install github/gh-gl2gh
```

```bash
gh extension install https://github.com/mona-actions/gh-migration-monitor
```
