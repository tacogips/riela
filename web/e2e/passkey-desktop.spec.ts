import { expect, test } from '@playwright/test'
import { addVirtualPasskey, startPasskeyServer } from './passkey-fixture'

test('desktop protocol hands a real browser Passkey login back only to the initiating window', async ({ page, context }) => {
  const server = await startPasskeyServer()
  const browser = await context.newPage()
  try {
    await addVirtualPasskey(browser)
    await browser.goto(await server.cli('invite', 'desktop-operator'))
    await browser.getByRole('button', { name: 'Create Passkey', exact: true }).click()
    await expect(browser.getByRole('heading', { name: 'ワークフロー', exact: true, level: 1 })).toBeVisible()
    let verificationURL = ''
    let cancelStatus = 0
    await page.exposeBinding('nativeInvoke', async (_, command: string, args: {
      endpoint: string; deviceId?: string; request?: { method: string; path: string; body: string; headers: Record<string, string> }
    }) => {
      expect(args.endpoint).toBe(server.origin)
      if (command === 'riela_open_passkey_login') {
        verificationURL = `${args.endpoint}/#/auth/device/${args.deviceId}`
        await browser.goto(verificationURL)
        return
      }
      expect(command).toBe('riela_remote_request')
      const request = args.request!
      const response = await context.request.fetch(`${server.origin}${request.path}`, {
        method: request.method, headers: { ...request.headers, Origin: server.origin },
        data: request.body || undefined, maxRedirects: 0,
      })
      if (request.path === '/api/v1/auth/device/cancel') cancelStatus = response.status()
      return { status: response.status(), headers: response.headers(), body: (await response.body()).toString('base64') }
    })
    await page.addInitScript(origin => {
      sessionStorage.setItem('riela.desktop.server-origin', origin)
      const nativeInvoke = (window as typeof window & { nativeInvoke: unknown }).nativeInvoke
      Object.assign(window, { __TAURI__: { core: { invoke: nativeInvoke } } })
    }, server.origin)
    await page.goto('/')
    await page.getByRole('button', { name: 'Sign in using browser', exact: true }).click()
    await expect(browser.getByRole('heading', { name: 'Sign in to Riela desktop' })).toBeVisible()
    const code = await browser.locator('main strong').innerText()
    await expect(page.getByText(code, { exact: true })).toBeVisible()
    await browser.screenshot({ path: test.info().outputPath('passkey-desktop-approval.png') })
    expect(verificationURL).not.toContain('deviceSecret')
    await browser.getByRole('button', { name: 'Code matches — sign in with Passkey', exact: true }).click()
    await expect(browser.getByText('Desktop sign-in approved. Return to Riela. You can close this tab.')).toBeVisible()
    await expect(page.getByRole('heading', { name: 'ワークフロー', exact: true, level: 1 })).toBeVisible()
    await expect(page.getByText('Web mode connected', { exact: true })).toBeVisible()
    await page.getByRole('button', { name: 'Sign out', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Sign in using browser', exact: true })).toBeVisible()
    await page.getByRole('button', { name: 'Sign in using browser', exact: true }).click()
    await expect(browser.getByRole('heading', { name: 'Sign in to Riela desktop' })).toBeVisible()
    await page.getByRole('button', { name: 'Cancel', exact: true }).click()
    await expect.poll(() => cancelStatus).toBe(200)
    await browser.getByRole('button', { name: 'Code matches — sign in with Passkey', exact: true }).click()
    await expect(browser.getByRole('alert')).toContainText('expired')
  } finally { await browser.close(); await server.stop() }
})
