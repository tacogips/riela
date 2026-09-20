import { expect, test, type Page, type Route } from '@playwright/test'

const instanceId = 'project:workflow'
const sessionId = 'session-42'
const secondInstanceId = 'project:workflow-second'

const instance = {
  id: instanceId,
  sourceId: 'source-review',
  isDefault: false,
  name: 'Review workflow',
  workflowId: 'review-loop',
  source: 'project workflow',
  sourceKind: 'directory',
  status: 'stopped',
  statusDetail: 'Inactive',
  active: false,
  enabledAtLaunch: true,
  workingDirectory: null,
  environmentFilePath: null,
  environmentVariables: [],
  requiredEnvironment: [],
  workflowVariables: {},
  nodePatchCount: 1,
  nodePatches: { review: { executionBackend: 'codex', model: 'gpt-5.6', effort: 'high' } },
  eventSources: [],
}

const secondInstance = {
  ...instance,
  id: secondInstanceId,
  name: 'Second workflow',
  workflowId: 'review-loop',
  workingDirectory: '/tmp/second-workflow',
  workflowVariables: { owner: 'second' },
}

const mutableWorkflow = {
  originId: 'user:mutable-review',
  workflowId: 'mutable-review',
  name: 'Mutable review',
  description: 'Editable',
  scope: 'USER',
  provenance: 'MUTABLE',
  mutable: true,
  activationState: 'ACTIVE',
  valid: true,
  definitionRevision: 'rev-1',
  definition: { workflowId: 'mutable-review', defaults: {}, nodes: [], steps: [] },
  diagnostics: [],
}

const secondMutableWorkflow = {
  ...mutableWorkflow,
  originId: 'user:mutable-second',
  workflowId: 'mutable-second',
  name: 'Mutable second',
  definitionRevision: 'rev-2',
  definition: { workflowId: 'mutable-second', defaults: {}, nodes: [], steps: [] },
}

async function installWorkflowAPI(page: Page, options: {
  externalInstanceChange?: boolean
  registryConflict?: boolean
  registryConflictOnce?: boolean
  registryValidationFailure?: boolean
  runDetailMode?: 'empty' | 'error'
  traceAttempts?: boolean
  staleSelection?: boolean
  staleMutableSelection?: boolean
  staleSourceSelection?: boolean
} = {}) {
  let registryUpdateAttempts = 0
  let instanceFetches = 0
  await page.route('**/graphql', async (route: Route) => {
    const body = route.request().postDataJSON() as {
      operationName?: string
      query?: string
      variables?: { target?: { originId?: string } }
    }
    const operation = body.operationName
    const result = (data: unknown) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ data }),
    })
    if (operation === 'WebMutableWorkflows') {
      return result({
        workflows: {
          workflows: options.staleMutableSelection
            ? [mutableWorkflow, secondMutableWorkflow]
            : [mutableWorkflow],
          errors: [],
        },
      })
    }
    if (operation === 'WebMutableWorkflow') {
      const selected = body.variables?.target?.originId === secondMutableWorkflow.originId
        ? secondMutableWorkflow
        : mutableWorkflow
      if (options.staleMutableSelection && selected === secondMutableWorkflow) {
        await new Promise((resolve) => setTimeout(resolve, 150))
      }
      return result({ workflow: { workflow: selected, errors: [] } })
    }
    if (operation === 'WebUpdateMutableWorkflow') {
      registryUpdateAttempts += 1
      if (options.registryConflict || (options.registryConflictOnce && registryUpdateAttempts === 1)) {
        return result({ updateMutableWorkflow: { accepted: false, workflow: null, errors: [{ code: 'REGISTRY_CONFLICT', message: 'Changed elsewhere' }] } })
      }
      if (options.registryValidationFailure) {
        return result({ updateMutableWorkflow: { accepted: false, workflow: null, errors: [{ code: 'INVALID_WORKFLOW', message: 'Referenced node file is missing.' }] } })
      }
      return result({ updateMutableWorkflow: { accepted: true, workflow: mutableWorkflow, errors: [] } })
    }
    if (operation === 'WebSetWorkflowActivation') {
      const field = body.query?.includes('deactivateWorkflow') ? 'deactivateWorkflow' : 'activateWorkflow'
      return result({ [field]: { accepted: true, workflow: mutableWorkflow, errors: [] } })
    }
    if (operation === 'WebDeleteMutableWorkflow') {
      return result({ deleteMutableWorkflow: { accepted: true, workflow: null, errors: [] } })
    }
    if (operation === 'WebRegisterMutableWorkflow') {
      return result({ registerMutableWorkflow: { accepted: true, workflow: mutableWorkflow, errors: [] } })
    }
    if (operation === 'WebUpdateWorkflowInstanceConfiguration') {
      const input = (body.variables as { input?: { expectedRevision?: number } } | undefined)?.input
      if (options.externalInstanceChange && input?.expectedRevision === 1) {
        return route.fulfill({
          status: 409,
          contentType: 'application/json',
          body: JSON.stringify({ errors: [{ message: 'Changed elsewhere', extensions: { code: 'REVISION_CONFLICT' } }] }),
        })
      }
      return result({ updateWorkflowInstanceConfiguration: { profile: 'e2e', revision: 2 } })
    }
    return route.fulfill({ status: 418, body: 'unexpected operation' })
  })
  await page.route('**/api/v1/**', async (route: Route) => {
    const request = route.request()
    const path = new URL(request.url()).pathname
    const json = (value: unknown) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(value),
    })
    if (path === '/api/v1/bootstrap') return json({ apiVersion: 'v1', profile: 'e2e', csrfToken: 'csrf', revision: 1, capabilities: [], server: { revision: 1, isEnabled: true, configuredPort: 19091, boundPort: 19091, restartRequired: false, state: 'running' } })
    if (path === '/api/v1/instances' && request.method() === 'GET') {
      instanceFetches += 1
      const changed = options.externalInstanceChange && instanceFetches > 2
      return json({
        profile: 'e2e',
        revision: changed ? 2 : 1,
        items: options.staleSelection
          ? [instance, secondInstance]
          : [{ ...instance, workingDirectory: changed ? '/tmp/external-change' : null }, ...(options.staleSourceSelection ? [{ ...instance, id: 'second-source-default', sourceId: 'source-second', isDefault: true, workflowId: 'second-loop' }] : [])],
      })
    }
    if (path === `/api/v1/instances/${encodeURIComponent(instanceId)}` && request.method() === 'GET') {
      return json({
        profile: 'e2e',
        revision: options.externalInstanceChange ? 2 : 1,
        item: options.externalInstanceChange
          ? { ...instance, workingDirectory: '/tmp/external-change' }
          : instance,
      })
    }
    if (path === `/api/v1/instances/${encodeURIComponent(instanceId)}/executions`) {
      if (options.staleSelection) await new Promise((resolve) => setTimeout(resolve, 150))
      return json({ revision: 1, instanceId, diagnostics: [], truncated: false, items: [{ sessionId, workflowId: 'review-loop', status: 'completed', currentStepId: null, activeStepIds: [], updatedAt: '2026-07-29T01:00:00Z' }] })
    }
    if (path === `/api/v1/instances/${encodeURIComponent(secondInstanceId)}/executions`) {
      return json({ revision: 1, instanceId: secondInstanceId, diagnostics: [], truncated: false, items: [{ sessionId: 'session-second', workflowId: 'review-loop-second', status: 'completed', currentStepId: null, activeStepIds: [], updatedAt: '2026-07-29T01:00:00Z' }] })
    }
    if (path === `/api/v1/instances/${encodeURIComponent(instanceId)}/executions/${sessionId}`) {
      if (options.runDetailMode === 'error') {
        return route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: { code: 'unavailable', message: 'Run detail unavailable' } }),
        })
      }
      const empty = options.runDetailMode === 'empty'
      return json({
        revision: 1,
        instanceId,
        session: { sessionId, workflowId: 'review-loop', status: 'completed', currentStepId: null, updatedAt: '2026-07-29T01:00:00Z' },
        steps: empty ? [] : [{ executionId: 'exec-1', stepId: 'review', nodeId: 'reviewer', attempt: 1, status: 'completed', backend: 'codex', startedAt: '2026-07-29T00:59:00Z', endedAt: '2026-07-29T01:00:00Z', durationMs: 60000, failureReason: null, events: [{ sequence: 1, at: '2026-07-29T00:59:30Z', eventType: 'tool', channel: 'tool', toolName: 'rg' }], eventTotalCount: 1, eventsTruncated: false }, ...(options.traceAttempts ? [
          { executionId: 'exec-2', stepId: 'complete', nodeId: 'writer', attempt: 1, status: 'failed', backend: 'codex', startedAt: '2026-07-29T01:00:00Z', endedAt: '2026-07-29T01:00:10Z', durationMs: 10000, failureReason: 'Retry requested', events: [], eventTotalCount: 0, eventsTruncated: false },
          { executionId: 'exec-3', stepId: 'complete', nodeId: 'writer', attempt: 2, status: 'completed', backend: 'codex', startedAt: '2026-07-29T01:00:12Z', endedAt: '2026-07-29T01:00:32Z', durationMs: 20000, failureReason: null, events: [], eventTotalCount: 0, eventsTruncated: false },
        ] : [])],
        stepsTotalCount: empty ? 0 : options.traceAttempts ? 3 : 1,
        stepsTruncated: false,
        logs: empty ? [] : [{ communicationId: 'comm-1', direction: 'outbox', fromStepId: 'review', toStepId: 'complete', sourceStepExecutionId: 'exec-1', status: 'delivered', deliveryKind: 'direct', createdOrder: 1, createdAt: '2026-07-29T00:59:45Z' }],
        logsTotalCount: empty ? 0 : 1,
        logsTruncated: false,
        diagnostics: empty ? [] : [{ summary: 'workflow validation failed', truncated: false }],
        diagnosticsTotalCount: empty ? 0 : 1,
        diagnosticsTruncated: false,
        gates: empty ? [] : [{ gateId: 'review-gate', stepId: 'review', decision: 'accepted', blockingFindingCount: 0, findings: [], findingsTotalCount: 0, findingsTruncated: false, evidenceRefs: [], evidenceRefsTotalCount: 0, evidenceRefsTruncated: false, diagnostics: [], diagnosticsTotalCount: 0, diagnosticsTruncated: false }],
        gatesTotalCount: empty ? 0 : 1,
        gatesTruncated: false,
        recovery: null,
        truncated: false,
      })
    }
    if (path === '/api/v1/workflows/sources') {
      return json({
        profile: 'e2e',
        revision: 1,
        directories: [],
        projectDirectories: [],
        repositories: [],
        discovered: options.staleSourceSelection
          ? [
              { id: 'source-review', name: 'Review loop', workflowId: 'review-loop', scope: 'project', sourceKind: 'directory' },
              { id: 'source-second', name: 'Second loop', workflowId: 'second-loop', scope: 'project', sourceKind: 'directory' },
            ]
          : [{ id: 'source-review', name: 'Review loop', workflowId: 'review-loop', scope: 'project', sourceKind: 'directory' }],
      })
    }
    if (path === '/api/v1/workflows/sources/source-review/definition') {
      return json({ revision: 1, sourceId: 'source-review', workflowId: 'review-loop', name: 'Review loop', scope: 'project', sourceKind: 'directory', definitionRevision: 'def-1', definition: { description: 'Review changes', descriptionTruncated: false, entryStepId: 'review', managerStepId: null, steps: [{ id: 'review', nodeId: 'reviewer', role: 'review', transitions: [], transitionsTotalCount: 0, transitionsTruncated: false }], stepsTotalCount: 1, stepsTruncated: false, nodes: [{ id: 'reviewer', kind: 'agent', role: 'review' }], nodesTotalCount: 1, nodesTruncated: false, transitionsTotalCount: 0, transitionsTruncated: false }, diagnostics: [{ summary: 'workflow validation failed', truncated: true }], diagnosticsTotalCount: 1, diagnosticsTruncated: false, truncated: false })
    }
    if (path === '/api/v1/workflows/sources/source-second/definition') {
      await new Promise((resolve) => setTimeout(resolve, 500))
      return json({ revision: 1, sourceId: 'source-second', workflowId: 'second-loop', name: 'Second loop', scope: 'project', sourceKind: 'directory', definitionRevision: 'def-2', definition: { description: 'Second definition', descriptionTruncated: false, entryStepId: 'second', managerStepId: null, steps: [{ id: 'second', nodeId: 'second-node', role: 'worker', transitions: [], transitionsTotalCount: 0, transitionsTruncated: false }], stepsTotalCount: 1, stepsTruncated: false, nodes: [{ id: 'second-node', kind: 'agent', role: 'worker' }], nodesTotalCount: 1, nodesTruncated: false, transitionsTotalCount: 0, transitionsTruncated: false }, diagnostics: [], diagnosticsTotalCount: 0, diagnosticsTruncated: false, truncated: false })
    }
    return route.fulfill({ status: 418, body: `unexpected ${request.method()} ${path}` })
  })
}

async function openConfiguration(page: Page) {
  const workflow = page.getByRole('button', { name: 'ワークフローを開く Review loop', exact: true })
  if (!page.url().includes('/workflows/source-review')) await workflow.click()
  await page.getByRole('button', { name: /Review workflow/, exact: true }).click()
}

test('opens real run detail and exposes polling visibility state', async ({ page }) => {
  await installWorkflowAPI(page)
  await page.goto('/')
  await openConfiguration(page)
  await page.getByRole('button', { name: '履歴', exact: true }).click()
  await page.getByRole('button', { name: `Open run ${sessionId}`, exact: true }).click()
  await expect(page.getByRole('heading', { name: sessionId, exact: true })).toBeVisible()
  await expect(page.getByText('review-gate', { exact: true })).toBeVisible()
  await expect(page.getByText('review → complete · direct', { exact: true })).toBeVisible()
  await expect(page.getByText('workflow validation failed', { exact: true })).toBeVisible()
  await expect(page.getByText('Auto-refresh on', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Refresh', exact: true }).click()
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, value: true })
    document.dispatchEvent(new Event('visibilitychange'))
  })
  await expect(page.getByText('Auto-refresh paused', { exact: true })).toBeVisible()
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, value: false })
    document.dispatchEvent(new Event('visibilitychange'))
  })
  await page.getByRole('button', { name: 'Back to Run logs', exact: true }).click()
  await expect(page.getByRole('button', { name: '履歴', exact: true })).toHaveAttribute('aria-pressed', 'true')
})

test('renders run-detail empty and error states', async ({ page }) => {
  await installWorkflowAPI(page, { runDetailMode: 'empty' })
  await page.goto('/')
  await openConfiguration(page)
  await page.getByRole('button', { name: '履歴', exact: true }).click()
  await page.getByRole('button', { name: `Open run ${sessionId}`, exact: true }).click()
  await expect(page.getByText('No step executions', { exact: true })).toBeVisible()

  await page.unrouteAll({ behavior: 'wait' })
  await installWorkflowAPI(page, { runDetailMode: 'error' })
  await page.getByRole('button', { name: 'Refresh', exact: true }).click()
  await expect(page.getByRole('alert')).toHaveText('Run detail unavailable')
})

test('trace drilldown selects attempt values and preserves selection across graph and refresh', async ({ page }) => {
  await installWorkflowAPI(page, { traceAttempts: true })
  await page.route('**/api/v1/workflow-editor/runs/session-42/steps/exec-1', async (route) => {
    expect(route.request().headers()['x-riela-profile']).toBe('e2e')
    await route.fulfill({ json: { input: { prompt: 'Inspect the workflow' }, output: { decision: 'accepted' }, inputRecorded: true, outputRecorded: true } })
  })
  await page.route('**/api/v1/workflow-editor/runs/session-42/steps/exec-3', async (route) => {
    await route.fulfill({ json: { input: { retry: 2 }, output: { report: 'Finished' }, inputRecorded: true, outputRecorded: true } })
  })
  await page.goto('/')
  await openConfiguration(page)
  await page.getByRole('button', { name: '履歴', exact: true }).click()
  await page.getByRole('button', { name: `Open run ${sessionId}`, exact: true }).click()
  const visualization = page.getByRole('region', { name: 'Run visualization' })
  await visualization.getByRole('button', { name: 'Events for review attempt 1' }).click()
  await expect(visualization.getByText('tool · rg')).toBeVisible()
  await visualization.getByRole('button', { name: 'Inspect review attempt 1' }).click()
  const inspector = page.getByRole('complementary', { name: 'Execution input and output' })
  await expect(inspector.getByText(/Inspect the workflow/)).toBeVisible()
  await expect(inspector.getByText(/"decision": "accepted"/)).toBeVisible()
  await page.getByRole('button', { name: 'Refresh', exact: true }).click()
  await expect(inspector.getByText(/Inspect the workflow/)).toBeVisible()
  await visualization.getByRole('button', { name: 'Graph', exact: true }).click()
  await expect(visualization.getByRole('img', { name: 'Workflow step routing graph' })).toBeVisible()
  await expect(visualization.getByRole('button', { name: 'Inspect review attempt 1' })).toHaveAttribute('aria-pressed', 'true')
  await visualization.getByRole('button', { name: 'Trace timeline', exact: true }).click()
  await visualization.getByRole('button', { name: 'Inspect complete attempt 2' }).click()
  await expect(inspector.getByText(/"retry": 2/)).toBeVisible()
  await expect(inspector.getByText(/Inspect the workflow/)).toHaveCount(0)
  const bars = visualization.locator('.trace-bar')
  await expect(bars).toHaveCount(3)
  const offsets = await bars.evaluateAll((elements) => elements.map((element) => parseFloat((element as HTMLElement).style.left)))
  expect(offsets[0]).toBe(0)
  expect(offsets[1]).toBeGreaterThan(offsets[0]!)
  expect(offsets[2]).toBeGreaterThan(offsets[1]!)
  await page.screenshot({ path: '../tmp/run-trace/trace-selected.png', fullPage: true })
  await page.setViewportSize({ width: 700, height: 900 })
  await expect(inspector.getByText(/"retry": 2/)).toBeVisible()
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  await inspector.getByRole('button', { name: 'Close details' }).click()
  await expect(inspector).toHaveCount(0)
})

test('blocks invalid variables JSON and renders node patches', async ({ page }) => {
  await installWorkflowAPI(page)
  await page.goto('/')
  await openConfiguration(page)
  await page.getByLabel('Workflow variables', { exact: true }).fill('{')
  await expect(page.getByRole('alert')).toContainText('Invalid JSON:')
  await expect(page.getByRole('button', { name: 'Save changes', exact: true })).toBeDisabled()
  await expect(page.getByText('Model: gpt-5.6', { exact: true })).toBeVisible()
})

test('resets instance editor ownership and preserves its revision across polling', async ({ page }) => {
  await installWorkflowAPI(page, { staleSelection: true })
  await page.goto('/')
  await openConfiguration(page)
  await page.getByLabel('Working directory', { exact: true }).fill('/tmp/draft-for-first')
  await page.getByRole('button', { name: /Second workflow/, exact: true }).click()
  await expect(page.getByLabel('Working directory', { exact: true })).toHaveValue('/tmp/second-workflow')
  await expect(page.getByLabel('Workflow variables', { exact: true })).toHaveValue('{\n  "owner": "second"\n}')

  await page.unrouteAll({ behavior: 'wait' })
  await installWorkflowAPI(page, { externalInstanceChange: true })
  await page.reload()
  await openConfiguration(page)
  await page.getByLabel('Working directory', { exact: true }).fill('/tmp/local-draft')
  await page.getByRole('button', { name: 'Refresh configurations', exact: true }).click()
  await page.getByRole('button', { name: 'Save changes', exact: true }).click()
  await expect(page.getByText('Changed elsewhere — refresh before saving again.', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Refresh', exact: true }).last().click()
  await expect(page.getByLabel('Working directory', { exact: true })).toHaveValue('/tmp/external-change')
})

test('discards an old instance response after selection changes', async ({ page }) => {
  await installWorkflowAPI(page, { staleSelection: true })
  await page.goto('/')
  await openConfiguration(page)
  await page.getByRole('button', { name: '履歴', exact: true }).click()
  await page.getByRole('button', { name: /Second workflow/, exact: true }).click()
  await page.getByRole('button', { name: '履歴', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Open run session-second', exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: `Open run ${sessionId}`, exact: true })).toHaveCount(0)
})

test('inspects discovered definitions and edits a mutable workflow', async ({ page }) => {
  await installWorkflowAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'ワークフロー', exact: true }).click()
  await page.getByText('ワークフローの追加・管理', { exact: true }).click()
  await openConfiguration(page)
  await expect(page.getByRole('group', { name: 'Workflow graph Review loop', exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'ワークフロー定義', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Discovered workflows', exact: true })).toHaveCount(0)
  await expect(page).toHaveURL(/#\/workflows\/source-review\/configurations\/project%3Aworkflow\/definition$/)
  await expect(page.getByRole('button', { name: 'Inspect node review', exact: true })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Validation diagnostics', exact: true })).toBeVisible()
  await expect(page.getByText('workflow validation failed (truncated)', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'ワークフロー一覧へ', exact: true }).click()
  await page.getByText('ワークフローの追加・管理', { exact: true }).click()
  await page.getByRole('button', { name: 'Select mutable workflow Mutable review', exact: true }).click()
  await page.getByRole('button', { name: 'Edit JSON', exact: true }).click()
  await page.getByLabel('Mutable workflow definition', { exact: true }).fill('{"workflowId":"mutable-review","defaults":{},"nodes":[],"steps":[]}')
  await page.getByRole('button', { name: 'Save workflow', exact: true }).click()
  await expect(page.getByText('Mutable workflow updated.', { exact: true })).toBeVisible()
  await expect(page.getByLabel('Mutable workflow definition', { exact: true })).toHaveCount(0)
  await page.getByRole('button', { name: 'Edit JSON', exact: true }).click()
  await page.getByRole('button', { name: 'Save workflow', exact: true }).click()
  await expect(page.getByLabel('Mutable workflow definition', { exact: true })).toHaveCount(0)
})

test('hides retained discovered-definition state while a new source loads', async ({ page }) => {
  await installWorkflowAPI(page, { staleSourceSelection: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'ワークフロー', exact: true }).click()
  await page.getByText('ワークフローの追加・管理', { exact: true }).click()
  await openConfiguration(page)
  await page.getByRole('button', { name: 'ワークフロー定義', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Inspect node review', exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'ワークフロー一覧へ', exact: true }).click()
  await page.getByRole('button', { name: 'ワークフローを開く Second loop', exact: true }).click()
  await expect(page.getByText('Loading workflow graph…', { exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Inspect node review', exact: true })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Inspect node second', exact: true })).toBeVisible()
})

test('disables stale mutable actions while a different origin is loading', async ({ page }) => {
  await installWorkflowAPI(page, { staleMutableSelection: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'ワークフロー', exact: true }).click()
  await page.getByText('ワークフローの追加・管理', { exact: true }).click()
  await page.getByRole('button', { name: 'Select mutable workflow Mutable review', exact: true }).click()
  await expect(page.getByText(mutableWorkflow.originId, { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Select mutable workflow Mutable second', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Edit JSON', exact: true })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Delete', exact: true })).toHaveCount(0)
  await expect(page.getByText(secondMutableWorkflow.originId, { exact: true })).toBeVisible()
  await expect(page.getByText(mutableWorkflow.originId, { exact: true })).toHaveCount(0)
})

test('surfaces registry conflicts with refresh recovery', async ({ page }) => {
  await installWorkflowAPI(page, { registryConflictOnce: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'ワークフロー', exact: true }).click()
  await page.getByText('ワークフローの追加・管理', { exact: true }).click()
  await page.getByRole('button', { name: 'Select mutable workflow Mutable review', exact: true }).click()
  await page.getByRole('button', { name: 'Edit JSON', exact: true }).click()
  await page.getByRole('button', { name: 'Save workflow', exact: true }).click()
  await expect(page.getByText('Changed elsewhere — refresh the registry before trying again.', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Refresh', exact: true }).last().click()
  await expect(page.getByLabel('Mutable workflow definition', { exact: true })).toHaveCount(0)
  await page.getByRole('button', { name: 'Edit JSON', exact: true }).click()
  await page.getByRole('button', { name: 'Save workflow', exact: true }).click()
  await expect(page.getByText('Mutable workflow updated.', { exact: true })).toBeVisible()
})

test('clears the pasted registration editor after success', async ({ page }) => {
  await installWorkflowAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'ワークフロー', exact: true }).click()
  await page.getByText('ワークフローの追加・管理', { exact: true }).click()
  await page.getByRole('button', { name: 'Register pasted JSON', exact: true }).click()
  await page.getByLabel('New workflow definition', { exact: true }).fill(
    '{"workflowId":"new-workflow","defaults":{},"nodes":[],"steps":[]}',
  )
  await page.getByRole('button', { name: 'Register workflow', exact: true }).click()
  await expect(page.getByText('Mutable workflow registered.', { exact: true })).toBeVisible()
  await expect(page.getByLabel('New workflow definition', { exact: true })).toHaveCount(0)
  await expect(page.getByLabel('Mutable workflow definition', { exact: true })).toHaveCount(0)
})

test('preserves server validation feedback without conflict recovery', async ({ page }) => {
  await installWorkflowAPI(page, { registryValidationFailure: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'ワークフロー', exact: true }).click()
  await page.getByText('ワークフローの追加・管理', { exact: true }).click()
  await page.getByRole('button', { name: 'Select mutable workflow Mutable review', exact: true }).click()
  await page.getByRole('button', { name: 'Edit JSON', exact: true }).click()
  await page.getByRole('button', { name: 'Save workflow', exact: true }).click()
  await expect(page.getByText('Referenced node file is missing.', { exact: true })).toBeVisible()
  await expect(page.getByText('Changed elsewhere — refresh the registry before trying again.', { exact: true })).toHaveCount(0)
})

test('deactivates and confirmed-deletes a mutable workflow', async ({ page }) => {
  await installWorkflowAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'ワークフロー', exact: true }).click()
  await page.getByText('ワークフローの追加・管理', { exact: true }).click()
  await page.getByRole('button', { name: 'Select mutable workflow Mutable review', exact: true }).click()
  await page.getByRole('button', { name: 'Deactivate', exact: true }).click()
  await expect(page.getByText('Workflow deactivated.', { exact: true })).toBeVisible()
  page.once('dialog', (dialog) => void dialog.accept())
  await page.getByRole('button', { name: 'Delete', exact: true }).click()
  await expect(page.getByText('Workflow deleted.', { exact: true })).toBeVisible()
})

test('cli-serve hides riela-app-only surfaces', async ({ page }) => {
  await page.route('**/api/v1/bootstrap', (route) => route.fulfill({
    status: 404,
    contentType: 'application/json',
    body: JSON.stringify({ error: { code: 'not_found', message: 'Not available' } }),
  }))
  await page.route('**/api/v1/**', (route) => route.fulfill({
    status: 404,
    contentType: 'application/json',
    body: JSON.stringify({ error: { code: 'not_found', message: 'Not available' }, revision: 1 }),
  }))
  await page.route('**/graphql', (route) => route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify({ data: {} }),
  }))
  await page.goto('/')
  await expect(page.getByRole('button', { name: 'Instances', exact: true })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Run logs', exact: true })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'ワークフロー', exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Settings', exact: true })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Command deck', exact: true })).toHaveCount(0)
})

test('workflow graph supports node inspection, back navigation and deep links', async ({ page }) => {
  await installWorkflowAPI(page)
  await page.goto('/#/workflows')
  await page.getByRole('button', { name: 'ワークフローを開く Review loop', exact: true }).click()
  const graph = page.getByRole('group', { name: 'Workflow graph Review loop', exact: true })
  const configurations = page.getByRole('complementary', { name: '実行設定', exact: true })
  await expect(graph).toBeVisible()
  await expect(configurations).toBeVisible()
  const graphBounds = await graph.boundingBox()
  const configurationBounds = await configurations.boundingBox()
  expect(graphBounds).not.toBeNull()
  expect(configurationBounds).not.toBeNull()
  expect(graphBounds!.x + graphBounds!.width).toBeLessThanOrEqual(configurationBounds!.x)
  await configurations.getByRole('button', { name: /Review workflow/ }).click()
  await expect(configurations.getByLabel('Working directory', { exact: true })).toBeVisible()
  await expect(graph).toBeVisible()
  await page.screenshot({ path: '../tmp/web-dashboard-e2e/screenshots/workflow-graph-right-configuration.png', fullPage: true })
  await page.getByRole('button', { name: 'Inspect node review', exact: true }).click()
  await expect(page.getByRole('complementary', { name: 'Node details' }).getByRole('heading', { name: 'review', exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Zoom in', exact: true }).click()
  await page.getByRole('button', { name: 'Fit view', exact: true }).click()
  await page.reload()
  await expect(page.getByRole('group', { name: 'Workflow graph Review loop', exact: true })).toBeVisible()
  await page.goBack()
  await expect(graph).toBeVisible()
  await expect(page.getByRole('button', { name: /Review workflow/ })).toHaveAttribute('aria-pressed', 'false')
  await page.getByRole('button', { name: 'ワークフロー一覧へ', exact: true }).click()
  await expect(page.getByRole('button', { name: 'ワークフローを開く Review loop', exact: true })).toBeVisible()
})
