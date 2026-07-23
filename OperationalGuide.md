# GitLab → GitHub Migration - Operational Guide

## Purpose

This guide explains the operational flow for using the GitLab → GitHub Migration pipeline.

It covers:

- Customer onboarding
- Environment setup
- Pipeline execution
- Migration stages
- Approval checkpoints
- Output artifacts

For detailed technical configuration and prerequisites, refer to [README.md](./README.md#2-requirements)

# 1. Customer Onboarding

The repository supports two operating models.

## Option A – Single Customer / Single Team

Create a GitHub Environment manually and configure the required environment variables and secrets. Refer to the [Environrments&Secrets](./README.md#environment-variables) in the README for the complete configuration requirements.

Example:

```text
customer-dev-env
```

Use this environment name when running the migration workflow.

---

## Option B – Multi-Customer / Shared Migration Platform

Use the automated environment setup workflow. Refer to [Setup-Customer-Environment.md](./Setup-Customer-Environment.md) for details.

### Step 1

Create a customer branch:

```text
customer-a
```

### Step 2

The `Setup Customer Environment` workflow automatically:

- Creates Environment `customer-a`
- Creates deployment branch policy
- Creates required variables
- Creates required secrets
- Populates placeholders using:

```text
__SET_ME__
```

### Step 3

Update all generated variables and secrets with actual values.

After this step the environment is ready for migration execution.

---

# 2. Prepare Migration Inventory

Generate inventory:

```bash
gh gitlab-stats --hostname <gitlab-server-url> --token <gitlab-token> --namespace <group-name>
```

Update the inventory file with below mandatory headers:

```text
github_org
github_repo
gh_repo_visibility
```
For details on editing the inventory CSV and configuring optional export filters (include_in_export, exclude_from_export), refer to the [Edit-inventory-csv](./README.md#52-edit-inventory-csv). section in README.md.

Commit the inventory CSV into the repository.

Example:

```text
gitlab-stats.csv
```

---

# 3. Run Migration Workflow

Navigate to:

```text
Actions
 |
 |── All Workflows
     |── GitLab to GitHub Migration Pipeline
```

Select:

```text
Run workflow
```

Provide:

| Input | Example |
|---------|---------|
| Environment Name | customer-a |
| Inventory File | gitlab-stats.csv |
| GitHub Type | GitHub / GitHubDR |
| Runner | self-hosted / ubuntu-latest |

Start the workflow.

---

# 4. Migration Workflow Stages

The migration workflow executes the following stages.

---

## Stage 1 - Getting Environment Ready

Purpose:

- Validate runner
- Validate required tools
- Authenticate GitHub CLI
- Install required GitHub extensions

Output:

```text
Runner ready for migration
```

---

## Stage 2 - Validate Prerequisites

Purpose:

- Validate environment variables
- Validate environment secrets
- Validate inventory file
- Validate workflow configuration

Output:

```text
All required migration inputs validated
```

---

## Stage 3 - Pre-Migration Readiness Check

Purpose:

- Check active Merge Requests
- Check running GitLab pipelines
- Perform GitSizer analysis

Artifacts:

```text
readiness-report.csv
gitsizer-report.csv
```

Review findings before continuing.

---

## Approval Gate 1

Reviewer approval required.

Environment:

```text
approvers-group
```

Purpose:

- Review readiness results
- Review GitSizer findings
- Decide whether migration can proceed

---

## Stage 4 - Generate Migration Archives

Purpose:

- Build gl-exporter image if required
- Generate GitLab migration archives

Artifacts:

```text
archive-generation.log
archive-output.csv
```

---

## Stage 5 - Upload Migration Archives

Purpose:

Upload generated archives to:

- GitHub Storage
- Azure Storage
- AWS Storage

Artifacts:

```text
archive-upload.log
```

---

## Stage 6 - Start Repository Migration

Purpose:

Start GitLab → GitHub migrations.

Artifacts:

```text
migration-outputs.csv
```

This file contains migration IDs used for monitoring.

---

## Stage 7 - Migration Summary

Purpose:

Aggregate migration results.

Artifacts:

```text
final-migration-summary.txt
```

Review successful and failed migrations.

---

## Approval Gate 2

Reviewer approval required.

Environment:

```text
approvers-group
```

Purpose:

Review migration submission results before monitoring begins.

---

## Stage 8 - Monitor Repository Migrations

Purpose:

Monitor migration progress using GitHub migration APIs.

Artifacts:

```text
migration-status.csv
```

Review final migration status.

---

## Stage 9 - Post-Migration Validation

Purpose:

Validate migrated repositories.

Checks:

- Branch counts
- Commit counts

Artifacts:

```text
post-validation-report.csv
```

Review validation results and investigate any mismatches.

---

# 5. Workflow Completion

The migration is considered complete when:

- Migration status shows completed repositories
- Post-validation passes
- Required artifacts are reviewed

Key outputs:

```text
migration-status.csv
post-validation-report.csv
final-migration-summary.txt
```

---

# 6. Artifact Locations

The workflow automatically uploads artifacts for every major migration stage.

Common artifacts include:

```text
Readiness Reports
GitSizer Reports
Archive Outputs
Migration Outputs
Migration Status
Post Validation Reports
Migration Summary
Logs
```

Default retention:

```text
7 Days
```

---

# Operational Flow Diagram

```text
Customer Setup
       │
       ▼
Inventory Preparation
       │
       ▼
Run Workflow
       │
       ▼
Getting Environment Ready
       │
       ▼
Validate Prerequisites
       │
       ▼
Pre-Migration Readiness
       │
       ▼
Approval Gate 1
       │
       ▼
Generate Archives
       │
       ▼
Upload Archives
       │
       ▼
Start Migration
       │
       ▼
Migration Summary
       │
       ▼
Approval Gate 2
       │
       ▼
Monitor Migration
       │
       ▼
Post-Migration Validation
       │
       ▼
Migration Complete
```
