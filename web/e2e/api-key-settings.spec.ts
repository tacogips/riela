import { expect, test } from '@playwright/test'

test('native settings issue expiring client/worker keys, toggle auth and revoke without persisting secrets', async ({ page }) => {
  await page.addInitScript(() => {
    let required = true
    const keys: Array<Record<string, unknown>> = []
    Object.assign(window, { __TAURI__: { core: { invoke: async (_command: string, args: {
      request: { path: string; method: string; body: string }
    }) => {
      const req = args.request
      let body: unknown = {}
      let status = 200
      const profile = 'default'
      if (req.path === '/api/v1/bootstrap') body = { profile, revision: 1, csrfToken: 'native', apiVersion: 'v1', hostKind: 'riela-app', capabilities: [], server: { state: 'stopped' } }
      else if (req.path === '/api/v1/settings/api-keys') {
        const input = req.body ? JSON.parse(req.body) : {}
        if (req.method === 'GET') body = { profile, requireClientKey: required, keys }
        else if (input.expectedProfile !== profile) { status = 409; body = { error: 'stale' } }
        else if (req.method === 'PUT') { required = input.requireClientKey }
        else if (req.method === 'DELETE') { keys.find(key => key.id === input.id)!.revokedAt = new Date().toISOString() }
        else {
          const record = { id: String(keys.length), name: input.name, purpose: input.purpose, workerID: input.workerID,
            createdAt: new Date().toISOString(), expiresAt: input.expiresAt }
          keys.push(record)
          body = { token: 'riela_fixture_secret_for_one_time_display', record }
        }
      } else if (req.path === '/api/v1/settings/workers') body = { profile, savedConfiguration: null, status: 'Stopped', configuration: { host: '127.0.0.1', port: 8788, storePath: 'jobs.json', workers: [] } }
      else if (req.path === '/api/v1/workflows/sources') body = { profile, revision: 1, directories: [], projectDirectories: [], repositories: [], discovered: [] }
      else if (req.path === '/graphql') {
        const operation = JSON.parse(req.body).operationName
        if (operation === 'WebConfiguration') body = { data: { configuration: {
          profile, revision: 1, profiles: [profile], workflowDirectories: [],
          assistant: { assistance: '', vendor: 'codex-cli', model: 'gpt', modelCatalogs: [{ vendor: 'codex-cli', models: ['gpt'] }] },
          appearance: { colorScheme: 'system', options: ['system'] },
          server: { isEnabled: false, configuredPort: 19091, boundPort: null, restartRequired: false, state: 'stopped' },
        } } }
        else if (operation === 'WebConsoleInstances') body = { data: { consoleInstances: { profile, revision: 1, items: [] } } }
        else body = { data: { workflows: { workflows: [], errors: [] } } }
      }
      return { status, headers: {}, body: btoa(JSON.stringify(body)) }
    } } } })
  })
  await page.goto('/#/settings')
  await expect(page.getByRole('button', { name: 'Refresh keys', exact: true })).toHaveCount(0)
  await expect(page.getByText('Issue keys for clients and workers. Changes apply immediately and survive app restarts.')).toHaveCount(0)
  await expect(page.getByRole('heading', { name: 'API Keys', exact: true })).toBeVisible()
  await page.getByLabel('Key name').fill('automation')
  await page.getByLabel('Expires at').fill('2030-12-31T12:30')
  await expect(page.getByRole('button', { name: 'Settings', exact: true }).locator('.action-button-caption')).toBeVisible()
  await page.getByRole('button', { name: 'Issue API key', exact: true }).click()
  await expect(page.getByRole('dialog', { name: 'Issue API key?' })).toContainText('cannot be recovered later')
  const dialogBox = await page.getByRole('dialog').boundingBox()
  const viewport = page.viewportSize()!
  expect(Math.abs(dialogBox!.x + dialogBox!.width / 2 - viewport.width / 2)).toBeLessThan(2)
  expect(Math.abs(dialogBox!.y + dialogBox!.height / 2 - viewport.height / 2)).toBeLessThan(2)
  await page.screenshot({ path: '../tmp/app-api-auth/issue-confirmation.png' })
  await page.keyboard.press('Escape')
  await expect(page.getByRole('dialog')).toHaveCount(0)
  await expect(page.getByText('No API keys.', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Issue API key', exact: true }).click()
  await page.getByRole('dialog', { name: 'Issue API key?' }).getByRole('button', { name: 'Issue key', exact: true }).click()
  await expect(page.getByLabel('Issued API key')).toHaveValue('riela_fixture_secret_for_one_time_display')
  await expect(page.getByText('automation', { exact: true })).toBeVisible()
  expect(await page.evaluate(() => JSON.stringify({ local: { ...localStorage }, session: { ...sessionStorage } }))).not.toContain('riela_fixture_secret')
  await page.getByRole('button', { name: 'Dismiss key' }).click()
  await expect(page.getByLabel('Issued API key')).toHaveCount(0)
  await page.getByLabel('Require an API key for client requests').click()
  await page.getByRole('dialog', { name: 'Change client authentication?' }).getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(page.getByLabel('Require an API key for client requests')).toBeChecked()
  await page.getByLabel('Require an API key for client requests').click()
  await page.getByRole('dialog', { name: 'Change client authentication?' }).getByRole('button', { name: 'Apply change', exact: true }).click()
  await expect(page.getByText('Client authentication policy saved.')).toBeVisible()
  await expect(page.getByLabel('Require an API key for client requests')).not.toBeChecked()
  await expect(page.getByRole('button', { name: 'Revoke key', exact: true })).toBeDisabled()
  await page.getByRole('radio', { name: 'automation', exact: true }).check()
  const revoke = page.getByRole('button', { name: 'Revoke key', exact: true })
  const color = await revoke.evaluate(element => getComputedStyle(element).color)
  const channels = color.match(/\d+/g)!.map(Number)
  expect(channels[0]).toBeGreaterThan(channels[1])
  const rowBox = await page.getByRole('radio', { name: 'automation', exact: true }).boundingBox()
  const revokeBox = await revoke.boundingBox()
  expect(revokeBox!.y).toBeGreaterThan(rowBox!.y)
  await page.getByRole('button', { name: 'Revoke key', exact: true }).click()
  await page.screenshot({ path: '../tmp/app-api-auth/revoke-confirmation.png' })
  await page.getByRole('dialog', { name: 'Revoke API key?' }).getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(page.getByText('Client API · Active')).toBeVisible()
  await page.getByRole('button', { name: 'Revoke key', exact: true }).click()
  await page.getByRole('dialog', { name: 'Revoke API key?' }).getByRole('button', { name: 'Revoke key', exact: true }).click()
  await expect(page.getByText('Client API · Revoked')).toBeVisible()
  await page.getByLabel('Key name').fill('linux worker')
  await page.getByLabel('Purpose').selectOption('worker')
  await page.getByLabel('Configured worker ID').fill('linux-1')
  await page.getByLabel('Expires at').fill('')
  await page.getByRole('button', { name: 'Issue API key', exact: true }).click()
  await page.getByRole('dialog', { name: 'Issue API key?' }).getByRole('button', { name: 'Issue key', exact: true }).click()
  await expect(page.getByText('Worker: linux-1 · Active')).toBeVisible()
  await expect(page.getByText(/Expires: Never/)).toBeVisible()
  await page.getByRole('button', { name: 'Dismiss key' }).click()
  await expect(page.getByLabel('Issued API key')).toHaveCount(0)
  await page.setViewportSize({ width: 390, height: 844 })
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  await page.screenshot({ path: '../tmp/app-api-auth/key-settings-browser.png', fullPage: true })
})
