import { execFile, spawn } from 'node:child_process'
import { mkdir, mkdtemp, rm } from 'node:fs/promises'
import { createServer } from 'node:net'
import { resolve } from 'node:path'
import { promisify } from 'node:util'
import type { Page } from '@playwright/test'

const exec = promisify(execFile)

export async function startPasskeyServer() {
  const repository = resolve('..')
  const scratch = resolve(repository, 'tmp/passkey-auth/e2e')
  await mkdir(scratch, { recursive: true })
  const root = await mkdtemp(resolve(scratch, 'server-'))
  const home = resolve(root, 'home')
  await mkdir(home)
  const port = await new Promise<number>((resolve, reject) => {
    const probe = createServer()
    probe.once('error', reject)
    probe.listen(0, '127.0.0.1', () => {
      const address = probe.address()
      if (!address || typeof address === 'string') throw new Error('No listener port')
      probe.close(() => resolve(address.port))
    })
  })
  const origin = `http://localhost:${port}`
  const env = { ...process.env, HOME: home, RIELA_WEB_ORIGIN: origin, RIELA_WEB_AUTH_ROOT: resolve(root, 'auth') }
  delete env.RIELA_CONTROLLER_CONFIG
  const binary = resolve(repository, '.build/debug/riela')
  const child = spawn(binary, ['serve', '--host', '127.0.0.1', '--port', String(port), '--working-dir', root,
    '--web-root', resolve(repository, 'web/dist')], { env, stdio: ['ignore', 'pipe', 'pipe'] })
  let stderr = ''
  child.stderr.on('data', chunk => { stderr += String(chunk) })
  try {
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error(`Riela startup timed out: ${stderr}`)), 20_000)
      child.once('error', error => { clearTimeout(timeout); reject(error) })
      child.once('exit', code => { clearTimeout(timeout); reject(new Error(`Riela exited ${code}: ${stderr}`)) })
      child.stdout.on('data', chunk => {
        if (String(chunk).includes('endpoint=')) { clearTimeout(timeout); resolve() }
      })
    })
  } catch (error) {
    child.kill('SIGTERM')
    throw error
  }
  return {
    origin,
    cli: async (...args: string[]) => (await exec(binary, ['auth', ...args], { env })).stdout.trim(),
    stop: async () => {
      if (child.exitCode === null) await new Promise<void>(resolve => {
        child.once('exit', () => resolve())
        child.kill('SIGTERM')
      })
      await rm(root, { recursive: true, force: true })
    },
  }
}

export async function addVirtualPasskey(page: Page) {
  const client = await page.context().newCDPSession(page)
  await client.send('WebAuthn.enable')
  const { authenticatorId } = await client.send('WebAuthn.addVirtualAuthenticator', { options: {
    protocol: 'ctap2', transport: 'internal', hasResidentKey: true,
    hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true,
  } })
  return { client, authenticatorId }
}
