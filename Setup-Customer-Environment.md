# Setup Customer Environment Workflow

This workflow automatically bootstraps a GitHub Environment whenever a new customer branch is created.

It creates the environment, applies a branch deployment policy, and initializes the required environment variables and secrets with placeholder values.

> Migration workflow remains unchanged. This workflow only prepares the customer-specific environment configuration.

---

## Workflow Name

```yaml
name: Setup Customer Environment
```

---

## Trigger

The workflow runs automatically on the GitHub `create` event.

```yaml
on:
  create:
```

It is intended to run when a new branch is created.

### Branches Ignored

The workflow will not run for branches that start with:

- `feature/`
- `bugfix/`
- `hotfix/`

This prevents environment creation for normal development or temporary branches.

---

## Purpose

This workflow is used to automatically create and prepare a customer-specific GitHub Environment based on the branch name.

For example, if a branch named `customer-a` is created, the workflow will create an environment named:

```text
customer-a
```

The same branch name is also configured as the allowed deployment branch for that environment.

---

## Required Repository Secret

This workflow requires the following repository-level secret to already exist:

| Secret Name | Purpose |
|---|---|
| `GH_PAT` | GitHub Personal Access Token used by GitHub CLI to create environments, variables, secrets, and branch policies. |

> The workflow uses `secrets.GH_PAT` as `GH_TOKEN` for GitHub CLI authentication.

---

## Required Permissions

The workflow uses the following GitHub Actions permissions:

```yaml
permissions:
  contents: read
  actions: write
```

The configured `GH_PAT` must have enough access to manage repository environments, environment variables, environment secrets, and environment deployment branch policies.

---

## Workflow Steps

### Step 1/5 - Generate Environment Name

The workflow reads the newly created branch name from:

```yaml
${{ github.event.ref }}
```

This value is used as the environment name.

Example:

```text
Branch: customer-a
Environment: customer-a
```

---

### Step 2/5 - Create GitHub Environment

The workflow creates a GitHub Environment using the branch name.

It also enables custom deployment branch policies for the environment:

```json
{
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
```

This allows the workflow to explicitly configure which branch is allowed for deployments.

---

### Step 3/5 - Configure Branch Policy

The workflow checks whether a deployment branch policy already exists for the environment.

If the policy already exists, it skips creation.

If the policy does not exist, it creates a branch policy using the environment name.

Example:

```text
Environment: customer-a
Allowed Branch: customer-a
```

---

### Step 4/5 - Create Environment Variables

The workflow creates the following environment-level variables with a default placeholder value:

```text
__SET_ME__
```

Variables created:

| Variable Name | Description |
|---|---|
| `SOURCE_GL_SERVER_URL` | GitLab server URL used as the migration source. |
| `GITLAB_USERNAME` | GitLab username used for migration/export operations. |
| `GH_HOST` | GitHub host value. |
| `GL_EXPORTER_REPO_URL` | Repository URL for the GitLab exporter. |
| `STORAGE_TYPE` | Storage backend type for exported migration archives. |
| `AZ_CONTAINER` | Azure Storage container name, if Azure storage is used. |
| `AWS_BUCKET_NAME` | AWS S3 bucket name, if AWS storage is used. |
| `AWS_REGION` | AWS region, if AWS storage is used. |

If a variable already exists, the workflow does not overwrite it.

---

### Step 5/5 - Create Environment Secrets

The workflow creates the following environment-level secrets with a default placeholder value:

```text
__SET_ME__
```

Secrets created:

| Secret Name | Description |
|---|---|
| `GITLAB_API_PRIVATE_TOKEN` | GitLab API token used to access source GitLab data. |
| `GH_PAT` | GitHub PAT used by the migration workflow. |
| `GLXREPO_GH_PAT` | GitHub PAT used for GitLab exporter repository access. |
| `AZURE_STORAGE_CONNECTION_STRING` | Azure Storage connection string, if Azure storage is used. |
| `AWS_ACCESS_KEY_ID` | AWS access key ID, if AWS storage is used. |
| `AWS_SECRET_ACCESS_KEY` | AWS secret access key, if AWS storage is used. |

If a secret already exists, the workflow does not overwrite it.

---

## What Gets Created

When a valid branch is created, this workflow creates or verifies the following:

1. GitHub Environment with the same name as the branch.
2. Deployment branch policy allowing the same branch.
3. Required environment variables.
4. Required environment secrets.
5. Summary output with next steps.

---

## Example

If the following branch is created:

```text
acme-customer
```

The workflow will create:

```text
Environment       : acme-customer
Allowed Branch    : acme-customer
Variables         : Created with __SET_ME__ placeholder
Secrets           : Created with __SET_ME__ placeholder
```

---

### Optional Cleanup

The workflow creates variables and secrets for all supported storage types (GitHub, Azure, and AWS).

After the environment is created, review the generated variables and secrets and remove any entries that are not applicable to your migration setup.

For example:

- If using Azure Storage, AWS-related variables and secrets can be removed.
- If using AWS Storage, Azure-related variables and secrets can be removed.
- If using GitHub Storage, Azure and AWS-specific variables and secrets can be removed.

Only the variables and secrets required for your selected storage type need to be retained.

> Note: Removal of unused variables and secrets is optional. They do not impact workflow execution if left in place.

## Post-Setup Actions

After the workflow completes successfully, update the created environment values manually.

### 1. Populate Environment Variables

Go to:

```text
Repository Settings > Environments > <environment-name> > Environment variables
```

Replace `__SET_ME__` with actual values for all required variables.

### 2. Populate Environment Secrets

Go to:

```text
Repository Settings > Environments > <environment-name> > Environment secrets
```

Replace placeholder secret values with actual secret values.

### 3. Validate Branch Policy

Confirm that the environment allows deployments only from the matching customer branch.

Example:

```text
Environment: acme-customer
Allowed branch: acme-customer
```

### 4. Run/Test Migration Workflow

After all variables and secrets are populated, run or trigger the migration workflow as per the existing process.

---

## Important Notes

- This workflow is independent from the migration workflow.
- The migration workflow does not need to be changed for environment creation.
- Environment name is directly derived from the branch name.
- Existing variables and secrets are skipped and not overwritten.
- Placeholder values must be replaced before running the migration workflow.
- Development branches such as `feature/*`, `bugfix/*`, and `hotfix/*` are ignored.

---

## Troubleshooting

### `gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN environment variable`

Ensure the workflow has this configured:

```yaml
env:
  GH_TOKEN: ${{ secrets.GH_PAT }}
```

Also confirm that the repository secret `GH_PAT` exists.

---

### Environment Was Not Created

Check the branch name.

The workflow only runs when:

- The created ref is a branch.
- The branch does not start with `feature/`, `bugfix/`, or `hotfix/`.

---

### Variables or Secrets Were Not Created

Confirm that the `GH_PAT` has the required permissions to manage environment variables and secrets.

Also check the workflow logs for GitHub CLI errors.

---

### Existing Variable or Secret Was Not Updated

This is expected behavior.

The workflow checks existing variables and secrets and skips them if they already exist. It does not overwrite existing values.

---

## Summary

This workflow provides an automated way to prepare customer-specific GitHub Environments immediately after a customer branch is created.

It helps separate environment setup from migration execution and allows each customer branch to have its own variables, secrets, and deployment branch policy.
