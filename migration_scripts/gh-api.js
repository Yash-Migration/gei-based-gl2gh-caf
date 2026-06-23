const { Batch } = require('./batch.js')
const { Issue } = require('./issue.js')
const { Workflow } = require('./workflow.js')
const { State } = require('./state.js')


class GHApi {
  // Constructor
  constructor({ github }) {
    // Override GitHub API host (DR / custom API URL)
    const apiBase = (process.env.GH_API_URL || "").replace(/\/+$/, "");

    if (apiBase) {
      // REST base URL for Octokit
      github.baseUrl = apiBase;

      // GraphQL endpoint should match the same host
      // (GraphQL uses a different endpoint than REST)
      // Ensure we use /graphql on that same host.
      if (typeof github.graphql === "function") {
        github.graphql = github.graphql.defaults({
          url: `${apiBase}/graphql`,
        });
      }
    }

    // Initialize properties
    this.github = github;

    // IMPORTANT: do not keep PAT empty if you later pass it in GraphQL mutations
    // Keep it from env; scripts typically export GH_PAT.
    this.ghPAT = process.env.GH_PAT || process.env.GITHUB_TOKEN || "";
  }



  // Getters
  get github() {
    return this._github
  }

  get ghPAT() {
    return this._ghPAT
  }

  // Setters
  set github(value) {
    this._github = value
  }

  set ghPAT(value) {
    this._ghPAT = value
  }

  // Public methods

  // ## Handle rate limiting and errors
  async handleRateLimitingAndErrors(func, callerName = 'Unknown') {
    try {
      return await func()
    } catch (error) {
      if (error.message.includes('rate limit')) {
        // Handle rate limiting
        const currentTime = Math.floor(Date.now() / 1000) // Current time in epoch seconds
        const resetTime = parseInt(
          error.response.headers['x-ratelimit-reset'],
          10
        ) // Reset time in epoch seconds
        const retryAfter = (resetTime - currentTime) * 1000 // Time to wait in milliseconds

        console.log(`Rate limit exceeded. Retrying after ${retryAfter} ms...`)
        await new Promise((resolve) => setTimeout(resolve, retryAfter))
        return await this.handleRateLimitingAndErrors(func, callerName)
      } else {
        throw new Error(
          `Calling function: ${callerName} Error: ${error.message}`
        )
      }
    }
  }

  // ## Batch Migrations
  async getBatchMigrationById({ batchId, ghOrg }) {
    return await this.handleRateLimitingAndErrors(async () => {
      try {
        // Read state from file
        const batchJson = await State.readState(batchId)
        return Batch.fromJSON(batchJson)
      } catch (error) {
        // If state file doesn't exist, create new batch
        return new Batch({ id: batchId, ghOrg: ghOrg })
      }
    }, 'getBatchMigrationById')
  }

  async getBatchMigrationByIssue({ owner, repo, issueNumber }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Get the issue
      const issue = await this.github.rest.issues.get({
        owner: owner,
        repo: repo,
        issue_number: issueNumber,
      })

      // Extract batch ID from issue title
      const match = issue.data.title.match(/\[Batch Migration\] (.*)/)
      if (!match) {
        throw new Error(
          `Issue title does not match the expected format: ${issue.data.title}`
        )
      }
      const batchId = match[1]
      // Read state from file
      const batchJson = await State.readState(batchId)
      return Batch.fromJSON(batchJson)
    }, 'getBatchMigrationByIssue')
  }

  async updateBatchMigration({ owner, repo, batch }) {
    return await this.handleRateLimitingAndErrors(async () => {
      if (batch.issueNumber == 0) {
        // Create issue
        let issueContent = await Issue.createTitleBody({ batch: batch })
        batch.issueNumber = await this.createIssue({
          owner: owner,
          repo: repo,
          title: issueContent.title,
          body: issueContent.body,
        })
      }

      // Always update the issue to ensure the latest information is available
      let updatedIssueContent = await Issue.createTitleBody({ batch: batch })
      await this.updateIssue({
        owner: owner,
        repo: repo,
        issueNumber: batch.issueNumber,
        title: updatedIssueContent.title,
        body: updatedIssueContent.body,
      })

      // Save the batch state
      await State.writeState(JSON.stringify(batch))

      // Return true to indicate success
      return true
    }, 'updateBatchMigration')
  }

  // ## Issues
  async searchIssues({ owner, repo, searchString }) {
    return await this.handleRateLimitingAndErrors(async () => {
      let results = []
      let page = 1
      const perPage = 100

      while (true) {
        const response = await this.github.rest.search.issuesAndPullRequests({
          q: searchString,
          owner: owner,
          repo: repo,
          per_page: perPage,
          page: page,
        })

        const issues = response.data.items
        if (issues.length == 0) {
          break
        }

        results = results.concat(issues)
        page++
      }

      return results
    }, 'searchIssues')
  }

  async createIssue({ owner, repo, title, body }) {
    return await this.handleRateLimitingAndErrors(async () => {
      const issue = await this.github.rest.issues.create({
        owner: owner,
        repo: repo,
        title: title,
        body: body,
      })
      // Return the issue number
      return issue.data.number
    }, 'createIssue')
  }

  async updateIssue({ owner, repo, issueNumber, title, body, state = 'open' }) {
    return await this.handleRateLimitingAndErrors(async () => {
      await this.github.rest.issues.update({
        owner: owner,
        repo: repo,
        issue_number: issueNumber,
        title: title,
        body: body,
        state: state,
      })
      // Return true to indicate success
      return true
    }, 'updateIssue')
  }

  async removeIssueLabel({ owner, repo, issueNumber, label }) {
    return await this.handleRateLimitingAndErrors(async () => {
      await this.github.request(
        'DELETE /repos/{owner}/{repo}/issues/{issue_number}/labels/{name}',
        {
          owner: owner,
          repo: repo,
          issue_number: issueNumber,
          name: label,
        }
      )
      // Return true to indicate success
      return true
    }, 'removeIssueLabel')
  }

  async addIssueLabel({ owner, repo, issueNumber, label }) {
    return await this.handleRateLimitingAndErrors(async () => {
      await this.github.request(
        'POST /repos/{owner}/{repo}/issues/{issue_number}/labels',
        {
          owner: owner,
          repo: repo,
          issue_number: issueNumber,
          labels: [label],
        }
      )
      // Return true to indicate success
      return true
    }, 'addIssueLabel')
  }

  // ## Workflows
  async getWorkflowRuns({ owner, repo, date }) {
    return await this.handleRateLimitingAndErrors(async () => {
      const results = await this.github.paginate(
        'GET /repos/{owner}/{repo}/actions/runs',
        {
          owner: owner,
          repo: repo,
          per_page: 100,
          created: `>=${date}`,
        },
        (response, done) =>
          response.data.map((run) => {
            if (run.status == 'in_progress' || run.status == 'queued') {
              return new Workflow({
                name: run.name,
                runId: run.id,
                startDateTime: run.created_at,
                status: 'In Progress',
              })
            } else {
              return new Workflow({
                name: run.name,
                runId: run.id,
                startDateTime: run.created_at,
                status: run.conclusion,
              })
            }
          })
      )

      // Return the workflow run
      return results
    }, 'getWorkflowRunId')
  }

  async getWorkflowRun({ owner, repo, runId }) {
    return await this.handleRateLimitingAndErrors(async () => {
      const run = await this.github.request(
        'GET /repos/{owner}/{repo}/actions/runs/{run_id}',
        {
          owner: owner,
          repo: repo,
          run_id: runId,
        }
      )

      // Formatting the status
      let status
      if (run.data.status == 'in_progress' || run.data.status == 'queued') {
        status = 'In Progress'
      } else {
        status = run.data.status
      }

      // Create new workflow object
      const workflow = new Workflow({
        name: run.data.name,
        runId: run.data.id,
        startDateTime: run.data.created_at,
        status: status,
      })

      return workflow
    }, 'getWorkflowRun')
  }

  async getWorkflowRunDetails({ owner, repo, workflow }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Get the workflow run jobs
      const jobs = await this.getWorkflowRunJobs({
        owner,
        repo,
        runId: workflow.runId,
      })

      // Debugging
      console.log(`Jobs results: ${JSON.stringify(jobs)}`)

      // Get the logs for each job and combine them into a single string
      const jobLogs = await Promise.all(
        jobs.map(async (job) => {
          const log = await this.getWorkflowRunJobLogs({
            owner,
            repo,
            jobId: job.id,
          })
          return log
        })
      )

      // Iterate through jobLogs and look for the line
      // that contains "[INFO] Workflow status:"
      for (const jobLog of jobLogs) {
        const statusLine = jobLog
          .split('\n')
          .find((line) => line.includes('[INFO] Workflow status:'))
        if (statusLine) {
          const result = JSON.parse(
            statusLine.split('[INFO] Workflow status:')[1].trim()
          )
          workflow.status = result.conclusion
          workflow.outputs = result.outputs
          workflow.messages = result.messages
        }

        // Return the workflow run
        return workflow
      }
    }, 'getWorkflowRunDetails')
  }

  async getWorkflowRunJobs({ owner, repo, runId }) {
    return await this.handleRateLimitingAndErrors(async () => {
      const jobs = await this.github.request(
        'GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs',
        {
          owner: owner,
          repo: repo,
          run_id: runId,
        }
      )
      return jobs.data.jobs
    }, 'getWorkflowRunJobs')
  }

  async getWorkflowRunJobLogs({ owner, repo, jobId }) {
    return await this.handleRateLimitingAndErrors(async () => {
      const log = await this.github.request(
        'GET /repos/{owner}/{repo}/actions/jobs/{job_id}/logs',
        {
          owner: owner,
          repo: repo,
          job_id: jobId,
        }
      )
      return log.data
    }, 'getWorkflowRunJobLogs')
  }

  async dispatchWorkflow({ owner, repo, workflow, inputs }) {
    return await this.handleRateLimitingAndErrors(async () => {
      const result = await this.github.rest.actions.createWorkflowDispatch({
        owner: owner,
        repo: repo,
        workflow_id: workflow,
        ref: 'main',
        inputs: inputs,
      })

      return true
    }, 'dispatchWorkflow')
  }

  // ## Repositories
  async getRepositoryByName({ owner, repo }) {
    return await this.handleRateLimitingAndErrors(async () => {
      const result = await this.github.request('GET /repos/{owner}/{repo}', {
        owner: owner,
        repo: repo,
      })
      return result.data
    }, 'getRepositoryByName')
  }

  async addRepositoryCollaborator({ owner, repo, user }) {
    return await this.handleRateLimitingAndErrors(async () => {
      await this.github.request(
        'PUT /repos/{owner}/{repo}/collaborators/{username}',
        {
          owner: owner,
          repo: repo,
          username: user.ghUsername,
          permission: user.repoPermission,
        }
      )
      return true
    }, 'addRepositoryCollaborator')
  }

  // ## Repository Variables
  async createVariable({ owner, repo, name, value }) {
    return await this.handleRateLimitingAndErrors(async () => {
      await this.github.rest.actions.createRepoVariable({
        owner: owner,
        repo: repo,
        name: name,
        value: value,
      })
      return true
    }, 'createVariable')
  }

  async updateVariable({ owner, repo, name, value }) {
    return await this.handleRateLimitingAndErrors(async () => {
      await this.github.rest.actions.updateRepoVariable({
        owner: owner,
        repo: repo,
        name: name,
        value: value,
      })
      return true
    }, 'updateVariable')
  }

  async updateCustomProperties({ owner, repo, customProperties }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Transform the properties into the expected format
      const fixedProperties = customProperties.map((prop) => ({
        property_name: prop.key,
        value: prop.value,
      }))

      const result = await this.github.request(
        'PATCH /repos/{owner}/{repo}/properties/values',
        {
          owner: owner,
          repo: repo,
          properties: fixedProperties,
        }
      )
      return true
    }, 'updateCustomProperties')
  }

  // ## Teams
  async createTeam({ organization, name, description }) {
    return await this.handleRateLimitingAndErrors(async () => {
      await this.github.rest.teams.create({
        org: organization,
        name: name,
        description: description,
        privacy: 'closed',
      })
      return true
    }, 'createTeam')
  }

  async addTeamMember({ organization, teamSlug, username, teamRole }) {
    return await this.handleRateLimitingAndErrors(async () => {
      await this.github.rest.teams.addOrUpdateMembershipForUserInOrg({
        org: organization,
        team_slug: teamSlug,
        username: username,
        role: teamRole,
      })
      return true
    }, 'addTeamMember')
  }

  async addRepositoryTeam({ organization, repo, teamSlug, permission }) {
    return await this.handleRateLimitingAndErrors(async () => {
      await this.github.request(
        'PUT /orgs/{org}/teams/{team_slug}/repos/{owner}/{repo}',
        {
          org: organization,
          team_slug: teamSlug,
          owner: organization,
          repo: repo,
          permission: permission,
        }
      )
      return true
    }, 'addRepositoryTeam')
  }

  // ## Organizations
  async getOrganizationId({ orgSlug }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Create the query
      const query = `query ($orgSlug: String!) {
        organization(login: $orgSlug) {
          id
        }
      }`

      // Create the variables
      const variables = {
        orgSlug: orgSlug,
      }

      // Run the query
      const data = await this.github.graphql(query, variables)

      // Pull out the id
      const orgId = data.organization.id

      // Return the organization id
      return String(orgId)
    }, 'getOrganizationId')
  }

  // ## GEI Migrations
  async createGLMigrationSource({ name, ownerId, sourceServerUrl }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Create the migration
      let query = `mutation($name: String!, $ownerId: ID!, $sourceUrl: String!) {
        createMigrationSource(
          input: {
            ownerId: $ownerId
            name: $name
            url: $sourceUrl
            type: GL_EXPORTER_ARCHIVE
          }
        ) {
          migrationSource {
            id
            name
            url
            type
          }
        }
      }`

      let variables = {
        ownerId: ownerId,
        name: name,
        sourceUrl: sourceServerUrl,
      }

      let headers = {
        'GraphQL-Features': 'octoshift_gl_exporter',
      }

      // Run the migration query
      const data = await this.github.graphql(query, { ...variables, headers })

      // Collect the migration data
      let migration = data.createMigrationSource.migrationSource.id

      // Return the migration data
      return migration
    }, 'createGLMigrationSource')
  }

  async startGLRepositoryMigration({
    sourceId,
    organizationId,
    repositoryName,
    signedArchiveUrl,
    glArchiveUrl,
  }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Create the migration
      let query = `mutation startRepositoryMigration (
        $sourceId: ID!
        $ownerId: ID!
        $repositoryName: String!
        $continueOnError: Boolean!
        $githubPat: String!
        $targetRepoVisibility: String!
        $sourceRepositoryUrl: URI!
        $gitArchiveUrl: String!
        $metadataArchiveUrl: String!
      ) {
        startRepositoryMigration(
          input: {
            sourceId: $sourceId
            ownerId: $ownerId
            repositoryName: $repositoryName
            continueOnError: $continueOnError
            githubPat: $githubPat
            targetRepoVisibility: $targetRepoVisibility
            sourceRepositoryUrl: $sourceRepositoryUrl
            gitArchiveUrl: $gitArchiveUrl
            metadataArchiveUrl: $metadataArchiveUrl
          }
        ) {
          repositoryMigration {
            id
            migrationSource {
              id
              name
              type
            }
            sourceUrl
          }
        }
      }`

      const repoVisibility = (
        process.env.GH_REPO_VISIBILITY || 'private'
      ).toLowerCase()

      if (!['private', 'public', 'internal'].includes(repoVisibility)) {
        throw new Error(
          `Invalid GH_REPO_VISIBILITY '${repoVisibility}'. Valid values: private, public, internal`
        )
      }

      let variables = {
        sourceId: sourceId,
        ownerId: organizationId,
        repositoryName: repositoryName,
        continueOnError: true,
        githubPat: this.ghPAT,
        targetRepoVisibility: repoVisibility,
        sourceRepositoryUrl: glArchiveUrl,
        gitArchiveUrl: signedArchiveUrl,
        metadataArchiveUrl: signedArchiveUrl,
      }

      let headers = {
        'GraphQL-Features': 'octoshift_gl_exporter',
      }

      // Run the migration query
      const data = await this.github.graphql(query, { ...variables, headers })

      // Collect the migration data
      let migration = data.startRepositoryMigration.repositoryMigration.id

      // Return the migration data
      return migration
    }, 'startGLRepositoryMigration')
  }

  // ## ECI Migrations
  async createMigration({ organizationId }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Create the migration
      let query = `mutation($organizationId: ID!) {
        startImport(input: { organizationId: $organizationId }) {
          migration {
            uploadUrl
            guid
            id
            databaseId
            state
          }
        }
      }`

      let variables = {
        organizationId: organizationId,
      }

      let headers = {
        'GraphQL-Features': 'gh_migrator_import_to_dotcom',
      }

      // Run the migration query
      const data = await this.github.graphql(query, { ...variables, headers })

      // Collect the migration data
      let migration = data.startImport.migration

      // Return the migration data
      return migration
    }, 'createMigration')
  }
  async getECIMigrationStatus({ owner, migrationGUID }) {
    return await this.handleRateLimitingAndErrors(async () => {
      let query = `query ($organization: String!, $guid: String!) {
              organization(login: $organization) {
                      migration(guid: $guid) {
                              state
                              databaseId
                      }
              }
      }`

      let variables = {
        organization: owner,
        guid: migrationGUID,
      }

      let headers = {
        'GraphQL-Features': 'gh_migrator_import_to_dotcom',
      }

      // Run the migration status query
      const data = await this.github.graphql(query, { ...variables, headers })

      // Extract the state of the migration
      let state = data.organization.migration.state

      // return the state of the migration
      return state
    }, 'getECIMigrationStatus')
  }

  async prepareMigration({ migrationId }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Create the prepare migration mutation
      let query = `mutation($migrationId: ID!){
        prepareImport(input: {
          migrationId: $migrationId
        }) {
          migration {
            guid
            id
            state
            databaseId
          }
        }
      }`

      let variables = {
        migrationId: migrationId,
      }

      let headers = {
        'GraphQL-Features': 'gh_migrator_import_to_dotcom',
      }

      // Run the prepare migration mutation
      const data = await this.github.graphql(query, { ...variables, headers })

      // Return the data
      return data.prepareImport.migration.state
    }, 'prepareMigration')
  }

  async getMigrationConflicts({ owner, migrationGUID }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Create the migration conflicts query
      let query = `query ($login: String!, $guid: String!) {
        organization(login: $login) {
          migration(guid: $guid) {
            guid
            id
            state
            conflicts {
              modelName
              sourceUrl
              targetUrl
              recommendedAction
              notes
            }
          }
        }
      }`

      let variables = {
        login: owner,
        guid: migrationGUID,
      }

      let headers = {
        'GraphQL-Features': 'gh_migrator_import_to_dotcom',
      }

      // Run the migration conflicts query
      const data = await this.github.graphql(query, { ...variables, headers })

      // Return the data
      return data.organization.migration.conflicts
    }, 'getMigrationConflicts')
  }

  async addMigrationImportMappings({ migrationId, mappings }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Create the migration import mappings mutation
      let query = `mutation($migrationId: ID!){
        addImportMapping(input: {
          migrationId: $migrationId
          mappings: ${mappings}
        }) {
          migration {
            guid
            id
            state
          }
        }
      }`

      let variables = {
        migrationId: migrationId,
      }

      let headers = {
        'GraphQL-Features': 'gh_migrator_import_to_dotcom',
      }

      // Run the migration import mappings mutation
      const data = await this.github.graphql(query, { ...variables, headers })

      // Return the data
      return data.addImportMapping.migration.state
    }, 'addMigrationImportMappings')
  }

  async startMigrationImport({ migrationId }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Create the start migration import mutation
      let query = `mutation($migrationId: ID!){
        performImport(input: {
          migrationId: $migrationId
        }) {
          migration {
            guid
            id
            state
          }
        }
      }`

      let variables = {
        migrationId: migrationId,
      }

      let headers = {
        'GraphQL-Features': 'gh_migrator_import_to_dotcom',
      }

      // Run the start migration import mutation
      const data = await this.github.graphql(query, { ...variables, headers })

      // Return the data
      return data.performImport.migration.state
    }, 'startMigrationImport')
  }

  async uploadArchive({ uploadUrl, bufferContent, fileSize }) {
    return await this.handleRateLimitingAndErrors(async () => {
      await this.github.request({
        method: 'PATCH',
        url: uploadUrl,
        data: bufferContent,
        headers: {
          Accept: 'application/vnd.github.wyandotte-preview+json',
          'Content-Type': 'application/gzip',
          'Content-Length': fileSize,
        },
      })
      return true
    }, 'uploadArchive')
  }

  async uploadArchiveParts({ uploadUrl, parts, fileSize }) {
    let responseLocation
    let uploadId
    let uploadGUID

    // Create the base headers
    let baseHeaders = {
      Accept: 'application/vnd.github.wyandotte-preview+json',
      'Content-Type': 'application/octet-stream',
      Authorization: `Bearer ${this._ghPAT}`,
    }

    // Start the upload and get GUID and ID
    await await this.handleRateLimitingAndErrors(async () => {
      // Testing fetch
      let url = `${uploadUrl.split('?')[0]}/blobs/uploads`
      const startResponse = await fetch(url, {
        method: 'POST',
        body: JSON.stringify({
          content_type: 'application/octet-stream',
          name: 'migration_upload.tar.gz.zip',
          size: fileSize,
        }),
        headers: baseHeaders,
      })

      // Extract the location, GUID, and ID
      responseLocation = startResponse.headers.get('location')
      uploadId = startResponse.headers.get('multipart-upload-id')
      uploadGUID = responseLocation
        .split('?')[1]
        .split('&')
        .filter((param) => param.indexOf('guid') > -1)[0]
        .split('=')[1]
    }, 'uploadArchiveInParts-start')

    // Upload the parts
    let index = 0

    for await (const part of parts) {
      // Increment the index
      index++

      await await this.handleRateLimitingAndErrors(async () => {
        let url = `${
          uploadUrl.split('?')[0]
        }/blobs/uploads?upload_id=${uploadId}&guid=${uploadGUID}&part_number=${index}`

        // Logging the part number
        console.info(`[INFO] Uploading part ${index}`)
        console.info(`[INFO] Upload URL for part ${index}: ${url}`)

        const partResponse = await fetch(url, {
          method: 'PATCH',
          body: part,
          headers: baseHeaders,
        })

        // Log the part response
        console.info(
          `[INFO] Part ${index} response: ${JSON.stringify(partResponse)}`
        )
      }, 'uploadArchiveInParts-part')
    }

    // Complete the upload
    await await this.handleRateLimitingAndErrors(async () => {
      let url = `${
        uploadUrl.split('?')[0]
      }/blobs/uploads?upload_id=${uploadId}&guid=${uploadGUID}&part_number=${index}`

      // Logging the final url
      this.core.info(`[INFO] Completing upload: ${url}`)

      const completeResponse = await fetch(url, {
        method: 'PUT',
        body: JSON.stringify({}),
        headers: baseHeaders,
      })

      // Log the complete response
      this.core.info(
        `[INFO] Complete response: ${JSON.stringify(completeResponse)}`
      )
    }, 'uploadArchiveInParts-complete')
  }

  async unlockRepository({ migrationId }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Create the unlock imported repository mutation
      let query = `mutation($migrationId: ID!){
        unlockImportedRepositories(input: { migrationId: $migrationId }) {
          migration {
            guid
            id
            state
          }
          unlockedRepositories {
            nameWithOwner
          }
        }
      }`

      let variables = {
        migrationId: migrationId,
      }

      let headers = {
        'GraphQL-Features': 'gh_migrator_import_to_dotcom',
      }

      // Run the unlock imported repository mutation
      const data = await this.github.graphql(query, { ...variables, headers })

      // Return the data
      return data.unlockImportedRepositories.migration.state
    }, 'unlockRepository')
  }

  // GEI Migrations
  async getGEIMigrationStatus({ migrationId }) {
    return await this.handleRateLimitingAndErrors(async () => {
      // Create the migration status query
      let query = `query ($id: ID!) {
                    node(id: $id) {
                      ... on Migration {
                        id
                        createdAt
                        sourceUrl
                        migrationLogUrl
                        migrationSource {
                          name
                        }
                        state
                        warningsCount
                        failureReason
                        repositoryName
                      }
                    }
                  }`

      let variables = { id: migrationId }

      // Run the migration status query
      const data = await this.github.graphql(query, variables)

      // Return the data
      return data.node
    }, 'getGEIMigrationStatus')
  }
}

module.exports = { GHApi }
