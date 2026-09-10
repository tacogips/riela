import { expect, test } from '@playwright/test'

test('server instance controls start, restart, disable at launch and stop', async ({ page }) => {
  let revision = 1
  let running = false
  let enabled = false
  const actions: string[] = []
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
    return route.fulfill({ json: { profile: 'default', revision, items: [{
      id: 'test-instance', name: 'Test instance', workflowId: 'test-workflow', source: 'project', sourceKind: 'directory',
      status: running ? 'running' : 'stopped', statusDetail: running ? 'Running' : 'Inactive',
      active: running, enabledAtLaunch: enabled, workingDirectory: null, environmentFilePath: null,
      environmentVariables: [], requiredEnvironment: [], workflowVariables: {}, nodePatchCount: 0,
      nodePatches: {}, eventSources: [],
    }] } })
  })
  await page.goto('/')
  await page.getByRole('button', { name: /Test instance/ }).click()
  await page.getByRole('button', { name: 'Start instance', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Start instance', exact: true })).toBeDisabled()
  await page.getByRole('button', { name: 'Restart instance', exact: true }).click()
  await page.getByRole('button', { name: 'Disable at launch', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Enable at launch', exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Stop instance', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Start instance', exact: true })).toBeEnabled()
  expect(actions).toEqual(['start', 'restart', 'disableAtLaunch', 'stop'])
})
