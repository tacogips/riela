import { expect, test } from '@playwright/test'

test('server instance controls start, restart, disable at launch and stop', async ({ page }) => {
  let revision = 1
  let running = false
  let enabled = false
  const actions: string[] = []
  const consoleInstance = () => ({
    id: 'test-instance', sourceId: 'test-source', isDefault: true, name: 'Test instance', workflowId: 'test-workflow', source: 'project', sourceKind: 'directory',
    status: running ? 'running' : 'stopped', statusDetail: running ? 'Running' : 'Inactive',
    active: running, enabledAtLaunch: enabled, workingDirectory: null, environmentFilePath: null,
    environmentVariables: [], requiredEnvironment: [], workflowVariables: {}, nodePatchCount: 0,
    nodePatches: {}, eventSources: [],
  })
  // Console reads moved off /api/v1 onto the control plane (design 2.4).
  await page.route('**/graphql', route => {
    const body = route.request().postDataJSON() as { operationName?: string }
    if (body.operationName === 'WebConsoleInstances') {
      return route.fulfill({ json: { data: { consoleInstances: { profile: 'default', revision, items: [consoleInstance()] } } } })
    }
    if (body.operationName === 'WebConsoleInstance') {
      return route.fulfill({ json: { data: { consoleInstance: { profile: 'default', revision, item: consoleInstance() } } } })
    }
    return route.fulfill({ json: { data: { workflows: { workflows: [], errors: [] } } } })
  })
  await page.route('**/api/v1/**', async route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/actions')) {
      const body = route.request().postDataJSON()
      expect(body.expectedProfile).toBe('default')
      expect(body.expectedRevision).toBe(revision)
      expect(route.request().headers()['x-riela-csrf']).toBe('test-csrf')
      actions.push(body.action)
      if (body.action === 'start' || body.action === 'restart') { running = true; enabled = true }
      if (body.action === 'stop') running = false
      if (body.action === 'disableAtLaunch') enabled = false
      revision++
      return route.fulfill({ json: { profile: 'default', revision } })
    }
    if (path === '/api/v1/bootstrap') return route.fulfill({ json: {
      profile: 'default', revision, apiVersion: 'v1', hostKind: 'cli-serve', csrfToken: 'test-csrf',
      capabilities: [], server: { state: 'running', boundPort: 4174 },
    } })
    if (path === '/api/v1/workflows/sources') return route.fulfill({ json: {
      profile: 'default', revision, directories: [], projectDirectories: [], repositories: [],
      discovered: [{ id: 'test-source', name: 'Test workflow', workflowId: 'test-workflow', scope: 'project', sourceKind: 'directory' }],
    } })
    if (path === '/api/v1/workflows/sources/test-source/definition') return route.fulfill({ json: {
      revision, sourceId: 'test-source', workflowId: 'test-workflow', name: 'Test workflow',
      scope: 'project', sourceKind: 'directory', definitionRevision: 'definition-1',
      definition: {
        description: 'Test workflow', descriptionTruncated: false, entryStepId: 'test', managerStepId: null,
        steps: [{ id: 'test', nodeId: 'test-node', role: 'worker', transitions: [], transitionsTotalCount: 0, transitionsTruncated: false }],
        stepsTotalCount: 1, stepsTruncated: false, nodes: [{ id: 'test-node', kind: 'agent', role: 'worker' }],
        nodesTotalCount: 1, nodesTruncated: false, transitionsTotalCount: 0, transitionsTruncated: false,
      },
      diagnostics: [], diagnosticsTotalCount: 0, diagnosticsTruncated: false, truncated: false,
    } })
    return route.fulfill({ json: { profile: 'default', revision, items: [], diagnostics: [], truncated: false } })
  })
  await page.goto('/')
  await page.getByRole('button', { name: 'ワークフローを開く Test workflow', exact: true }).click()
  await expect(page.getByRole('group', { name: 'Workflow graph Test workflow', exact: true })).toBeVisible()
  await page.getByRole('button', { name: /標準設定/ }).click()
  await page.getByRole('button', { name: '実行', exact: true }).click()
  await expect(page.getByRole('button', { name: '実行', exact: true })).toBeDisabled()
  await page.getByRole('button', { name: '再実行', exact: true }).click()
  await page.getByRole('button', { name: 'Disable at launch', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Enable at launch', exact: true })).toBeVisible()
  await page.getByRole('button', { name: '停止', exact: true }).click()
  await expect(page.getByRole('button', { name: '実行', exact: true })).toBeEnabled()
  expect(actions).toEqual(['start', 'restart', 'disableAtLaunch', 'stop'])
})
