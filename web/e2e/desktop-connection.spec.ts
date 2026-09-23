import { expect, test } from '@playwright/test'

test('local needs no login; web mode authenticates remotely and returning local clears it', async ({ page }) => {
  await page.addInitScript(() => {
    Object.assign(window, { __TAURI__: { core: { invoke: async (command: string, args: {
      endpoint?: string; request: { path: string; headers: Record<string, string> }
    }) => {
      if (command === 'riela_open_passkey_login') return undefined
      if (args.request.path === '/api/v1/auth/device/start') return { status: 200, headers: {}, body: btoa(JSON.stringify({
        deviceID: 'A'.repeat(43), deviceSecret: 'B'.repeat(43), code: 'MATCH123', verificationURL: 'https://riela.example/#/auth/device/' + 'A'.repeat(43),
      })) }
      if (args.request.path === '/api/v1/auth/device/poll') return { status: 200, headers: {}, body: btoa(JSON.stringify({ token: 'fixture-token' })) }
      const remote = command === 'riela_remote_request'
      if (!remote && args.request.headers.authorization) throw new Error('Local request carried remote credentials')
      if (remote && args.endpoint !== 'https://riela.example') throw new Error('Wrong remote endpoint')
      const authenticated = !remote || args.request.headers.authorization === 'Bearer fixture-token'
      const profile = remote ? 'remote-profile' : 'local-profile'
      let body: unknown = { profile, revision: 1, items: [] }
      if (!authenticated) body = { error: { code: 'web_authentication_required', message: 'Enter token' } }
      else if (args.request.path === '/api/v1/bootstrap') body = {
        profile, revision: 1, csrfToken: 'fixture-csrf', apiVersion: 'v1',
        hostKind: remote ? 'cli-serve' : 'riela-app', capabilities: [], server: { state: 'stopped' },
      }
      else if (args.request.path === '/api/v1/workflows/sources') body = {
        profile, revision: 1, directories: [], projectDirectories: [], repositories: [], discovered: [],
      }
      else if (args.request.path === '/graphql') {
        // Console reads moved off /api/v1 onto the control plane (design 2.4).
        const operation = (JSON.parse(args.request.body || '{}') as { operationName?: string }).operationName
        if (operation === 'WebConsoleInstances') body = { data: { consoleInstances: { profile, revision: 1, items: [] } } }
        else if (operation === 'WebConsoleInstance') body = { data: { consoleInstance: { profile, revision: 1, item: null } } }
        else if (operation === 'WebOpsOverview') {
          body = { data: { opsOverview: { profile, revision: 1, workflows: [], workflowsTruncated: false,
            instances: [], runs: [], runsTruncated: false, diagnostics: [] } } }
        } else body = { data: { workflows: { workflows: [], errors: [] } } }
      }
      return { status: authenticated ? 200 : 401, headers: {}, body: btoa(JSON.stringify(body)) }
    } } } })
  })
  await page.goto('/')
  await expect(page.getByText('local-profile', { exact: true })).toBeVisible()
  await expect(page.getByLabel('Server access token', { exact: true })).toHaveCount(0)
  await page.getByText('Connection: Local', { exact: true }).click()
  await page.getByLabel('Connection mode').selectOption('web')
  await page.getByLabel('Riela server URL').fill('https://riela.example')
  await page.getByRole('button', { name: 'Connect', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Connect to Riela', exact: true })).toBeVisible()
  await expect(page.getByText('local-profile', { exact: true })).toHaveCount(0)
  await page.getByRole('button', { name: 'Sign in using browser', exact: true }).click()
  await expect(page.getByText('remote-profile', { exact: true })).toBeVisible()
  await page.getByText('Connection: Web mode', { exact: true }).click()
  await page.getByLabel('Connection mode').selectOption('local')
  await page.getByRole('button', { name: 'Connect', exact: true }).click()
  await expect(page.getByText('local-profile', { exact: true })).toBeVisible()
  await expect(page.getByLabel('Server access token', { exact: true })).toHaveCount(0)
  expect(await page.evaluate(() => JSON.stringify({ ...sessionStorage }))).not.toContain('fixture-token')
})
