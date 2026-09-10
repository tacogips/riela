import { expect, test } from '@playwright/test'

test('connects with a token, rejects a bad token and requires login after reload', async ({ page }) => {
  await page.route('**/api/v1/**', async route => {
    if (route.request().headers().authorization !== 'Bearer fixture-access-token') {
      return route.fulfill({ status: 401, json: { error: { code: 'web_authentication_required', message: 'Enter the server access token to connect.' } } })
    }
    if (new URL(route.request().url()).pathname === '/api/v1/bootstrap') {
      return route.fulfill({ json: {
        profile: 'default', revision: 1, csrfToken: 'fixture-csrf', apiVersion: 'v1', hostKind: 'cli-serve',
        capabilities: [], server: { state: 'running', boundPort: 4174 },
      } })
    }
    return route.fulfill({ json: { profile: 'default', revision: 1, items: [] } })
  })
  await page.goto('/')
  await expect(page.getByRole('heading', { name: 'Connect to Riela', exact: true })).toBeVisible()
  await page.getByLabel('Server access token', { exact: true }).fill('bad-token')
  await page.getByRole('button', { name: 'Connect', exact: true }).click()
  await expect(page.getByRole('alert')).toHaveText('Access token was not accepted. Try again.')
  await page.getByLabel('Server access token', { exact: true }).fill('fixture-access-token')
  await page.getByRole('button', { name: 'Connect', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Workflow instances', exact: true })).toBeVisible()
  expect(await page.evaluate(() => JSON.stringify({ local: { ...localStorage }, session: { ...sessionStorage } }))).not.toContain('fixture-access-token')
  await page.reload()
  await expect(page.getByRole('heading', { name: 'Connect to Riela', exact: true })).toBeVisible()
})
