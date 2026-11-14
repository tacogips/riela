import { expect, test, type Locator, type Page, type Route } from '@playwright/test'

const compositeId = 'project-workflow:/tmp/riela:review-loop'
const plantedSecret = 'SENTINEL_SECRET_MUST_NOT_RENDER'
const opsSessionId = 'session-aurora-042'

const instance = {
  id: compositeId,
  name: 'Review loop',
  workflowId: 'review-loop',
  source: 'project workflow',
  sourceKind: 'directory',
  status: 'running',
  statusDetail: 'Running',
  active: true,
  enabledAtLaunch: true,
  workingDirectory: null,
  environmentFilePath: null,
  environmentVariables: [{ name: 'API_KEY', isSet: true, masked: '••••••••' }],
  requiredEnvironment: [{ name: 'API_KEY', description: 'Provider credential', required: true, secret: true, source: 'workflow', present: true }],
  workflowVariables: {},
  nodePatchCount: 0,
  nodePatches: {},
  eventSources: [],
}

const missingSourceInstance = {
  ...instance,
  id: 'removed-workflow',
  name: 'Removed workflow',
  workflowId: 'removed-source',
  source: 'Missing source: removed-source',
  sourceKind: 'missing',
  status: 'needsSource',
  statusDetail: 'The configured workflow source is unavailable. Relink it in the native app.',
  active: false,
  environmentVariables: [],
  requiredEnvironment: [],
}

const opsStep = (
  id: string,
  transitions: Array<{ toStepId: string; label?: string; fanoutJoinStepId?: string }>,
) => ({
  id,
  nodeId: `${id}-node`,
  role: 'worker',
  description: null,
  transitions: transitions.map((transition) => ({
    toStepId: transition.toStepId,
    label: transition.label ?? null,
    fanoutJoinStepId: transition.fanoutJoinStepId ?? null,
  })),
})

const opsOverview = {
  profile: 'e2e',
  revision: 1,
  workflows: [
    {
      sourceId: 'source-review-loop',
      name: 'Review loop',
      workflowId: 'review-loop',
      scope: 'project',
      sourceKind: 'directory',
      description: 'Design, implement, review, and loop until the gate clears.',
      entryStepId: 'design',
      managerStepId: null,
      steps: [
        opsStep('design', [{ toStepId: 'review' }]),
        opsStep('review', [{ toStepId: 'gate', label: 'findings' }]),
        opsStep('gate', [{ toStepId: 'publish', label: 'clean' }, { toStepId: 'review', label: 'rework' }]),
        opsStep('publish', []),
      ],
      nodes: [
        { id: 'design', kind: null, role: null, addon: null },
        { id: 'review', kind: 'task', role: null, addon: null },
        { id: 'gate', kind: 'loop-judge', role: null, addon: null },
        { id: 'publish', kind: 'output', role: null, addon: 'riela/notebook-upsert' },
      ],
      stepsTruncated: false,
    },
    {
      sourceId: 'source-inbox',
      name: 'Document inbox',
      workflowId: 'document-inbox',
      scope: 'user',
      sourceKind: 'package',
      description: 'Watch the inbox and file converted notes.',
      entryStepId: 'watch',
      managerStepId: null,
      steps: [
        opsStep('watch', [{ toStepId: 'convert', label: 'per file', fanoutJoinStepId: 'file' }]),
        opsStep('convert', [{ toStepId: 'file' }]),
        opsStep('file', []),
      ],
      nodes: [
        { id: 'watch', kind: null, role: null, addon: 'riela/file-change' },
        { id: 'convert', kind: null, role: null, addon: 'riela/markdown-convert' },
        { id: 'file', kind: 'output', role: null, addon: null },
      ],
      stepsTruncated: false,
    },
  ],
  workflowsTruncated: false,
  instances: [
    { id: compositeId, name: 'Review loop', workflowId: 'review-loop', status: 'running', active: true },
  ],
  runs: [
    { instanceId: compositeId, sessionId: opsSessionId, workflowId: 'review-loop', status: 'running', currentStepId: 'review', activeStepIds: ['review'], updatedAt: '2026-08-19T07:31:00Z' },
    { instanceId: compositeId, sessionId: 'session-borealis-041', workflowId: 'review-loop', status: 'failed', currentStepId: null, activeStepIds: [], updatedAt: '2026-08-19T06:20:00Z' },
  ],
  runsTruncated: false,
  diagnostics: [],
}

const opsExecution = (stepId: string, attempt: number, status: string, startedAt: string, failure: string | null = null) => ({
  executionId: `exec-${stepId}-${attempt}`,
  executionIdTruncated: false,
  stepId,
  stepIdTruncated: false,
  nodeId: `${stepId}-node`,
  nodeIdTruncated: false,
  attempt,
  status,
  backend: 'claude-code-agent',
  startedAt,
  endedAt: null,
  durationMs: status === 'running' ? null : 42000,
  failureReason: failure,
  failureReasonTruncated: false,
  events: [
    { sequence: 1, at: startedAt, eventType: 'session-start', eventTypeTruncated: false, channel: 'agent', toolName: null, toolNameTruncated: false },
  ],
  eventTotalCount: 1,
  eventsTruncated: false,
})

const opsRouting = (fromStepId: string, toStepId: string, sourceStepExecutionId: string, order: number) => ({
  communicationId: `comm-${order}`,
  communicationIdTruncated: false,
  direction: 'outbound',
  fromStepId,
  fromStepIdTruncated: false,
  toStepId,
  toStepIdTruncated: false,
  sourceStepExecutionId,
  sourceStepExecutionIdTruncated: false,
  status: 'delivered',
  deliveryKind: 'handoff',
  createdOrder: order,
  createdAt: '2026-08-19T07:00:00Z',
})

const opsRunDetail = {
  revision: 1,
  instanceId: compositeId,
  instanceIdTruncated: false,
  session: {
    sessionId: opsSessionId,
    sessionIdTruncated: false,
    workflowId: 'review-loop',
    workflowIdTruncated: false,
    status: 'running',
    currentStepId: 'review',
    currentStepIdTruncated: false,
    updatedAt: '2026-08-19T07:31:00Z',
  },
  steps: [
    opsExecution('design', 1, 'completed', '2026-08-19T06:00:00Z'),
    opsExecution('review', 1, 'failed', '2026-08-19T06:30:00Z', 'Reviewer found blocking findings'),
    opsExecution('review', 2, 'running', '2026-08-19T07:10:00Z'),
  ],
  stepsTotalCount: 3,
  stepsTruncated: false,
  logs: [
    opsRouting('design', 'review', 'exec-design-1', 1),
    opsRouting('review', 'gate', 'exec-review-1', 2),
  ],
  logsTotalCount: 2,
  logsTruncated: false,
  diagnostics: [],
  diagnosticsTotalCount: 0,
  diagnosticsTruncated: false,
  gates: [{
    gateId: 'gate-review-1',
    gateIdTruncated: false,
    stepId: 'gate',
    stepIdTruncated: false,
    decision: 'rework',
    blockingFindingCount: 1,
    findings: [{ id: 'finding-1', idTruncated: false, severity: 'high', severityTruncated: false, file: null, fileTruncated: false, line: null, summary: 'Unhandled abort race', summaryTruncated: false, evidenceReferenceCount: 0 }],
    findingsTotalCount: 1,
    findingsTruncated: false,
    evidenceRefs: [],
    evidenceRefsTotalCount: 0,
    evidenceRefsTruncated: false,
    diagnostics: [],
    diagnosticsTotalCount: 0,
    diagnosticsTruncated: false,
  }],
  gatesTotalCount: 1,
  gatesTruncated: false,
  recovery: null,
  truncated: false,
}

type FixtureOptions = {
  instancesDelay?: number
  workflowMode?: 'empty' | 'malformed'
  mutationMode?: 'success' | 'malformed' | 'conflict'
}

async function installAPI(page: Page, options: FixtureOptions = {}) {
  const requests: string[] = []
  const unexpectedRequests: string[] = []
  const browserErrors: string[] = []
  const failedRequests: string[] = []
  const badResponses: string[] = []
  let mutationCount = 0
  let configuredPort = 19091
  let restartRequired = false
  const configuration = () => ({
    profile: 'e2e',
    revision: 1,
    profiles: ['default', 'e2e'],
    workflowDirectories: [],
    assistant: {
      assistance: '',
      vendor: 'openai-api',
      model: 'gpt-5.6',
      modelCatalogs: [{ vendor: 'openai-api', models: ['gpt-5.6'] }],
    },
    appearance: { colorScheme: 'dark', options: ['dark', 'light'] },
    server: { isEnabled: true, configuredPort, boundPort: 19091, restartRequired, state: 'running' },
  })
  page.on('console', (message) => {
    if (message.type() !== 'error') return
    const expectedConflictNoise = options.mutationMode === 'conflict' && message.text().includes('409 (Conflict)')
    if (!expectedConflictNoise) browserErrors.push(message.text())
  })
  page.on('pageerror', (error) => browserErrors.push(error.message))
  page.on('requestfailed', (request) => {
    failedRequests.push(`${request.method()} ${request.url()}: ${request.failure()?.errorText ?? 'failed'}`)
  })
  page.on('response', (response) => {
    const url = new URL(response.url())
    const expectedConflict = options.mutationMode === 'conflict' && response.status() === 409 && url.pathname === '/graphql'
    if (response.status() >= 400 && !expectedConflict) badResponses.push(`${response.status()} ${response.request().method()} ${url.pathname}`)
  })
  await page.route('**/graphql', async (route: Route) => {
    const request = route.request()
    const body = request.postDataJSON() as { operationName?: string; variables?: Record<string, unknown> }
    const operation = body.operationName ?? 'Unknown'
    requests.push(`POST /graphql:${operation}`)
    const result = (value: unknown) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ data: value }) })
    if (operation === 'WebConfiguration') return result({ configuration: configuration() })
    if (operation === 'WebUpdateAssistantConfiguration') {
      mutationCount += 1
      if (options.mutationMode === 'malformed') return route.fulfill({ status: 200, contentType: 'application/json', body: '{' })
      return result({ updateAssistantConfiguration: configuration() })
    }
    if (operation === 'WebUpdateAppearanceConfiguration') {
      mutationCount += 1
      return result({ updateAppearanceConfiguration: configuration() })
    }
    if (operation === 'WebUpdateHTTPServerConfiguration') {
      mutationCount += 1
      const input = body.variables?.input as { configuredPort?: number } | undefined
      configuredPort = input?.configuredPort ?? configuredPort
      restartRequired = true
      return result({ updateHTTPServerConfiguration: configuration() })
    }
    if (operation === 'WebAddWorkflowDirectoryConfiguration') {
      mutationCount += 1
      if (options.mutationMode === 'conflict') {
        return route.fulfill({
          status: 409,
          contentType: 'application/json',
          body: JSON.stringify({ errors: [{ message: 'Changed elsewhere', extensions: { code: 'REVISION_CONFLICT' } }] }),
        })
      }
      return result({ addWorkflowDirectoryConfiguration: { profile: 'e2e', revision: 2 } })
    }
    if (operation === 'WebUpdateWorkflowInstanceConfiguration') {
      mutationCount += 1
      return result({ updateWorkflowInstanceConfiguration: { profile: 'e2e', revision: 2 } })
    }
    if (operation === 'WebMutableWorkflows') {
      return result({ workflows: { workflows: [], errors: [] } })
    }
    unexpectedRequests.push(`POST /graphql:${operation}`)
    return route.fulfill({ status: 418, contentType: 'application/json', body: JSON.stringify({ error: 'unexpected GraphQL operation' }) })
  })
  await page.route('**/api/v1/**', async (route: Route) => {
    const request = route.request()
    const url = new URL(request.url())
    requests.push(`${request.method()} ${url.pathname}`)
    const json = (value: unknown) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(value) })
    if (url.pathname === '/api/v1/bootstrap') return json({ apiVersion: 'v1', profile: 'e2e', csrfToken: 'csrf', revision: 1, capabilities: [], server: { revision: 1, isEnabled: true, configuredPort: 19091, boundPort: 19091, restartRequired: false, state: 'running' } })
    if (url.pathname === '/api/v1/instances' && request.method() === 'GET') {
      if (options.instancesDelay) await new Promise((resolve) => setTimeout(resolve, options.instancesDelay))
      return json({ profile: 'e2e', revision: 1, items: [instance, missingSourceInstance] })
    }
    if (url.pathname === `/api/v1/instances/${encodeURIComponent(compositeId)}` && request.method() === 'GET') {
      return json({ profile: 'e2e', revision: 2, item: instance })
    }
    if (url.pathname === `/api/v1/instances/${encodeURIComponent(compositeId)}/executions`) {
      return json({ revision: 1, instanceId: compositeId, items: [], diagnostics: [], truncated: false })
    }
    if (url.pathname === `/api/v1/instances/${encodeURIComponent(compositeId)}/executions/${opsSessionId}`) {
      return json(opsRunDetail)
    }
    if (url.pathname === `/api/v1/executions/${opsSessionId}`) {
      return json(opsRunDetail)
    }
    if (url.pathname === '/api/v1/workflows/sources') {
      if (options.workflowMode === 'malformed') return route.fulfill({ status: 200, contentType: 'application/json', body: '{' })
      return json({ profile: 'e2e', revision: 1, directories: [], projectDirectories: [], repositories: [], discovered: [] })
    }
    if (url.pathname === '/api/v1/ops/overview') return json(opsOverview)
    unexpectedRequests.push(`${request.method()} ${url.pathname}`)
    return route.fulfill({ status: 418, contentType: 'application/json', body: JSON.stringify({ error: { code: 'unexpected_request', message: `${request.method()} ${url.pathname}` }, revision: 1 }) })
  })
  return {
    requests,
    mutationCount: () => mutationCount,
    assertClean: () => {
      expect(unexpectedRequests, 'unexpected API requests').toEqual([])
      expect(browserErrors, 'browser console and page errors').toEqual([])
      expect(failedRequests, 'failed network requests').toEqual([])
      expect(badResponses, 'unexpected HTTP error responses').toEqual([])
    },
  }
}

async function captureEvidence(page: Page, name: string, target?: Locator) {
  await (target ?? page.locator('.app-shell')).screenshot({
    path: `../tmp/web-dashboard-e2e/screenshots/${name}.png`,
    animations: 'disabled',
  })
}

test('suppresses empty ids, resolves encoded ids, and saves instance configuration', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await expect.poll(() => page.url()).toContain('#/instances')
  await page.getByRole('button', { name: 'Run logs' }).click()
  await expect.poll(() => page.url()).toContain('#/logs')
  await expect(page.locator('.empty-state').getByText('Choose an instance', { exact: true })).toBeVisible()
  expect(fixture.requests.some((request) => request.includes('/instances//executions'))).toBe(false)
  await page.getByLabel('Instance').selectOption(compositeId)
  await expect(page.getByText('No persisted runs', { exact: true })).toBeVisible()
  expect(fixture.requests).toContain(`GET /api/v1/instances/${encodeURIComponent(compositeId)}/executions`)
  await captureEvidence(page, 'run-logs-empty-history')

  await page.getByRole('button', { name: 'Instances' }).click()
  await page.getByRole('button', { name: /Review loop/ }).click()
  await page.getByRole('button', { name: 'Save changes' }).click()
  await expect(page.getByText(/Saved\. Active instances/)).toBeVisible()
  expect(fixture.requests).toContain('POST /graphql:WebUpdateWorkflowInstanceConfiguration')
  expect(await page.locator('body').innerText()).not.toContain(plantedSecret)
  await page.getByRole('button', { name: /Removed workflow/ }).click()
  await expect(page.getByText('This configured instance cannot find its workflow source.')).toBeVisible()
  await captureEvidence(page, 'instances-missing-source')
  fixture.assertClean()
})

test('shows loading, empty, error, and mutation recovery states', async ({ page }) => {
  const fixture = await installAPI(page, { instancesDelay: 250, workflowMode: 'empty', mutationMode: 'conflict' })
  await page.goto('/')
  await expect(page.getByText('Loading workflow instances…')).toBeVisible()
  await expect(page.getByRole('button', { name: /Review loop/ })).toBeVisible()
  await page.getByRole('button', { name: 'Workflows' }).click()
  await expect(page.getByText('No sources configured')).toBeVisible()
  await expect(page.getByText('Nothing discovered')).toBeVisible()
  await page.getByLabel('Additional workflow directory').fill('/tmp/workflows')
  await page.getByRole('button', { name: 'Add directory' }).click()
  await expect(page.getByText(/Changed elsewhere — refresh/)).toBeVisible()
  await expect(page.getByLabel('Additional workflow directory')).toHaveValue('/tmp/workflows')
  const sourceReadsBeforeRefresh = fixture.requests.filter((request) =>
    request === 'GET /api/v1/workflows/sources').length
  await page.getByRole('button', { name: 'Refresh', exact: true }).last().click()
  await expect.poll(() => fixture.requests.filter((request) =>
    request === 'GET /api/v1/workflows/sources').length).toBeGreaterThan(sourceReadsBeforeRefresh)
  await expect(page.getByRole('button', { name: 'Add directory', exact: true })).toBeEnabled()
  await captureEvidence(page, 'workflows-conflict-recovery')
  fixture.assertClean()
})

test('renders resource and settings mutation failures', async ({ page }) => {
  const fixture = await installAPI(page, { workflowMode: 'malformed', mutationMode: 'malformed' })
  await page.goto('/')
  await page.getByRole('button', { name: 'Workflows' }).click()
  await expect(page.getByRole('alert')).toBeVisible()
  await page.getByRole('button', { name: 'Settings' }).click()
  await page.getByRole('button', { name: 'Save assistant' }).click()
  await expect(page.getByText(/JSON|Unexpected end/i)).toBeVisible()
  await captureEvidence(page, 'settings-mutation-error', page.locator('.settings-panel').filter({ hasText: 'Assistant' }))
  fixture.assertClean()
})

test('confirms a port change and keeps success and restart feedback visible', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'Settings' }).click()
  await expect(page.getByText('Active profile', { exact: true })).toBeVisible()
  await expect(page.getByLabel('Native window appearance')).toHaveValue('dark')
  await page.getByLabel('Configured port').fill('19092')
  await page.getByRole('button', { name: 'Save server' }).click()
  await expect(page.getByText('Type CHANGE PORT to confirm that this page may become unreachable.')).toBeVisible()
  await page.getByLabel('Port-change confirmation').fill('CHANGE PORT')
  await page.getByRole('button', { name: 'Save server' }).click()
  await expect(page.getByText('Server port saved. Restart from the Riela menu to apply it.')).toBeVisible()
  await expect(page.getByText('Restart required from the Riela menu-bar app.')).toBeVisible()
  await captureEvidence(page, 'settings-port-restart-required', page.locator('.settings-panel').filter({ hasText: 'Web Config server' }))
  fixture.assertClean()
})

test('command deck focuses workflows and opens run telemetry', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'Command deck' }).click()

  // Constellation: both hubs and the deck carousel are present.
  await expect(page.getByText('All systems · 2')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Focus workflow Review loop' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Focus workflow Document inbox' })).toBeVisible()
  await captureEvidence(page, 'command-deck-constellation')

  // The live-runs lens hides workflows without live runs.
  await page.getByLabel('live runs only').check()
  await expect(page.getByRole('button', { name: 'Focus workflow Document inbox' })).toHaveCount(0)
  await page.getByLabel('live runs only').uncheck()

  // Focus a workflow: the fan renders steps and the detail panel opens.
  await page.getByRole('button', { name: 'Focus workflow Review loop' }).click()
  await expect(page.getByRole('button', { name: '← Deck' })).toBeVisible()
  await expect(page.getByRole('dialog', { name: 'Selection detail' })).toContainText('Review loop')
  await page.getByRole('button', { name: 'Inspect step gate' }).click()
  await expect(page.getByRole('dialog', { name: 'Selection detail' })).toContainText('gate')
  await expect(page.getByRole('dialog', { name: 'Selection detail' })).toContainText('publish')
  await captureEvidence(page, 'command-deck-focus')

  // Open the live run from the recent-runs rail.
  await page.getByRole('button', { name: new RegExp(opsSessionId) }).first().click()
  await expect(page.getByText('traveled route', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Inspect step review' }).click()
  await expect(page.getByRole('dialog', { name: 'Step review detail' })).toContainText('attempt 2 · running')
  await expect(page.getByRole('dialog', { name: 'Step review detail' })).toContainText('Reviewer found blocking findings')
  await captureEvidence(page, 'command-deck-run')

  // The run view is deep-linkable: the hash names the run and survives reload.
  await expect.poll(() => page.url()).toContain(`#/ops/runs/${encodeURIComponent(compositeId)}/${opsSessionId}`)
  await page.reload()
  await expect(page.getByText('traveled route', { exact: true })).toBeVisible()

  // Return to the deck.
  await page.getByRole('button', { name: '← Command deck' }).click()
  await expect(page.getByRole('button', { name: 'Focus workflow Review loop' })).toBeVisible()
  fixture.assertClean()
})

test('published run links deep-link straight into run detail', async ({ page }) => {
  const fixture = await installAPI(page)
  // RIELA_WEB_RUN_LINK_TEMPLATE contract: #/runs/{sessionId}.
  await page.goto(`/#/runs/${opsSessionId}`)
  await expect(page.getByRole('heading', { name: opsSessionId })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Step executions' })).toBeVisible()
  fixture.assertClean()
})

test('keeps narrow navigation, focus, and content usable', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  const fixture = await installAPI(page)
  await page.goto('/')
  await expect(page.getByRole('button', { name: 'Instances' })).toHaveAttribute('aria-current', 'page')
  await page.keyboard.press('Tab')
  await expect(page.getByRole('link', { name: 'Skip to content' })).toBeFocused()
  // The full navigation is wider than a phone viewport, so it has to scroll
  // inside its own strip instead of widening the document.
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  expect(await page.locator('.sidebar nav').evaluate((element) =>
    element.scrollWidth > element.clientWidth && getComputedStyle(element).overflowX === 'auto')).toBe(true)
  const columns = await page.locator('.instance-grid').evaluate((element) => getComputedStyle(element).gridTemplateColumns.split(' ').length)
  expect(columns).toBe(1)
  await captureEvidence(page, 'mobile-instances')
  fixture.assertClean()
})
