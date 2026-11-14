import { expect, test, type Locator, type Page, type Route } from '@playwright/test'

const compositeId = 'project-workflow:/tmp/riela:review-loop'
const plantedSecret = 'SENTINEL_SECRET_MUST_NOT_RENDER'

const instance = {
  id: compositeId,
  name: 'Review loop',
  workflowId: 'review-loop',
  source: 'project workflow',
  sourceKind: 'directory',
  status: 'stopped',
  statusDetail: 'Inactive',
  active: false,
  enabledAtLaunch: true,
  workingDirectory: null,
  environmentFilePath: null,
  environmentVariables: [{ name: 'API_KEY', isSet: true, masked: '••••••••' }],
  requiredEnvironment: [{ name: 'API_KEY', description: 'Provider credential', required: true, secret: true, source: 'workflow', present: true }],
  workflowVariables: {},
  nodePatchCount: 0,
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
  environmentVariables: [],
  requiredEnvironment: [],
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
  page.on('console', (message) => {
    if (message.type() !== 'error') return
    const expectedConflictNoise = options.mutationMode === 'conflict'
      && message.text().includes('409 (Conflict)')
    if (!expectedConflictNoise) browserErrors.push(message.text())
  })
  page.on('pageerror', (error) => browserErrors.push(error.message))
  page.on('requestfailed', (request) => failedRequests.push(`${request.method()} ${request.url()}: ${request.failure()?.errorText ?? 'failed'}`))
  page.on('response', (response) => {
    const url = new URL(response.url())
    const expectedConflict = options.mutationMode === 'conflict' && response.status() === 409 && url.pathname === '/api/v1/workflows/sources/directories'
    if (response.status() >= 400 && !expectedConflict) badResponses.push(`${response.status()} ${response.request().method()} ${url.pathname}`)
  })
  await page.route('**/api/v1/**', async (route: Route) => {
    const request = route.request()
    const url = new URL(request.url())
    requests.push(`${request.method()} ${url.pathname}`)
    const json = (value: unknown) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(value) })
    if (url.pathname === '/api/v1/bootstrap') return json({ apiVersion: 'v1', profile: 'e2e', csrfToken: 'csrf', revision: 1, capabilities: [], server: { revision: 1, isEnabled: true, configuredPort: 19091, boundPort: 19091, restartRequired: false, state: 'running' } })
    if (url.pathname === '/api/v1/instances' && request.method() === 'GET') {
      if (options.instancesDelay) await new Promise((resolve) => setTimeout(resolve, options.instancesDelay))
      return json({ revision: 1, items: [instance, missingSourceInstance] })
    }
    if (url.pathname === `/api/v1/instances/${encodeURIComponent(compositeId)}/executions`) return json({ revision: 1, instanceId: compositeId, items: [], diagnostics: [], truncated: false })
    if (url.pathname === `/api/v1/instances/${encodeURIComponent(compositeId)}/configuration`) {
      mutationCount += 1
      return json({ revision: 2, item: instance })
    }
    if (url.pathname === '/api/v1/workflows/sources') {
      if (options.workflowMode === 'malformed') return route.fulfill({ status: 200, contentType: 'application/json', body: '{' })
      return json({ revision: 1, directories: [], projectDirectories: [], repositories: [], discovered: [] })
    }
    if (url.pathname === '/api/v1/workflows/sources/directories') {
      mutationCount += 1
      if (options.mutationMode === 'conflict') return route.fulfill({ status: 409, contentType: 'application/json', body: JSON.stringify({ error: { code: 'revision_conflict', message: 'Changed elsewhere' }, revision: 2 }) })
      return json({ revision: 2, directories: [], projectDirectories: [], repositories: [], discovered: [] })
    }
    if (url.pathname === '/api/v1/settings/assistant' && request.method() === 'GET') return json({ revision: 1, assistance: '', vendor: 'openai-api', model: 'gpt-5.6' })
    if (url.pathname === '/api/v1/settings/notes' && request.method() === 'GET') return json({ revision: 1, exposesNoteAPI: false, defaultTranslationTargetLanguage: 'English', s3ProfileCount: 0 })
    if (url.pathname === '/api/v1/settings/web-server' && request.method() === 'GET') return json({ revision: 1, isEnabled: true, configuredPort, boundPort: 19091, restartRequired, state: 'running' })
    if (url.pathname === '/api/v1/settings/assistant' && request.method() === 'PUT') {
      mutationCount += 1
      if (options.mutationMode === 'malformed') return route.fulfill({ status: 200, contentType: 'application/json', body: '{' })
      return json({ revision: 2, assistance: '', vendor: 'openai-api', model: 'gpt-5.6' })
    }
    if (url.pathname === '/api/v1/settings/web-server' && request.method() === 'PUT') {
      mutationCount += 1
      configuredPort = (request.postDataJSON() as { port?: number }).port ?? configuredPort
      restartRequired = true
      return json({ revision: 2, isEnabled: true, configuredPort, boundPort: 19091, restartRequired, state: 'running' })
    }
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

test('suppresses empty ids and resolves encoded ids for logs and configuration', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'Run logs' }).click()
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
  expect(fixture.requests).toContain(`PUT /api/v1/instances/${encodeURIComponent(compositeId)}/configuration`)
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
  await expect(page.getByRole('button', { name: 'Refresh' })).toBeVisible()
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
  await page.getByLabel('Configured port').fill('19092')
  await page.getByRole('button', { name: 'Save server' }).click()
  await expect(page.getByText('Type CHANGE PORT to confirm that this page may become unreachable.')).toBeVisible()
  await page.getByLabel('Port-change confirmation').fill('CHANGE PORT')
  await page.getByRole('button', { name: 'Save server' }).click()
  await expect(page.getByText('Server port saved. Restart from the Riela menu to apply it.')).toBeVisible()
  await expect(page.getByText('Restart required from the Riela menu-bar app.')).toBeVisible()
  await captureEvidence(page, 'settings-port-restart-required', page.locator('.settings-panel').filter({ hasText: 'Web server' }))
  fixture.assertClean()
})

test('keeps narrow navigation, focus, and content usable', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  const fixture = await installAPI(page)
  await page.goto('/')
  await expect(page.getByRole('button', { name: 'Instances' })).toHaveAttribute('aria-current', 'page')
  await page.keyboard.press('Tab')
  await expect(page.getByRole('link', { name: 'Skip to content' })).toBeFocused()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  const columns = await page.locator('.instance-grid').evaluate((element) => getComputedStyle(element).gridTemplateColumns.split(' ').length)
  expect(columns).toBe(1)
  await captureEvidence(page, 'mobile-instances')
  fixture.assertClean()
})
