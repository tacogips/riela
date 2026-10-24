import { describe, expect, test } from 'bun:test'
import { RielaEnvironmentClient, environmentErrorMessage, parseEnvironmentResponse } from './client'

const status = { readiness: 'ready', generation: 2, names: ['TOKEN'], configuredNames: ['TOKEN'], missingNames: [], sourceIDs: ['loader'] }

describe('runtime environment surface', () => {
  test('returns the status on success', async () => {
    const result = await parseEnvironmentResponse(Response.json(status))
    expect(result).toEqual({ ok: true, status })
  })

  test('reads the safe code from a 422 status body', async () => {
    const failed = { ...status, readiness: 'failed', lastError: 'environment_source_failed' }
    const result = await parseEnvironmentResponse(Response.json(failed, { status: 422 }))
    expect(result).toEqual({ ok: false, httpStatus: 422, code: 'environment_source_failed', status: failed })
  })

  test('accepts new precondition codes as plain strings', async () => {
    for (const code of ['environment_restart_required', 'environment_reload_in_progress', 'environment_instance_changed']) {
      const result = await parseEnvironmentResponse(Response.json({ ...status, lastError: code }, { status: 422 }))
      expect(result.ok).toBe(false)
      if (!result.ok) expect(result.code).toBe(code)
      expect(environmentErrorMessage(code)).not.toContain('previous snapshot')
    }
    expect(environmentErrorMessage('environment_future_code')).toContain('environment_future_code')
  })

  test('reads the error code from a 409 body and survives non-JSON bodies', async () => {
    const conflict = await parseEnvironmentResponse(Response.json(
      { error: { code: 'profile_or_instance_conflict', message: 'Select the current profile and instance.' } }, { status: 409 },
    ))
    expect(conflict).toEqual({ ok: false, httpStatus: 409, code: 'profile_or_instance_conflict' })
    const broken = await parseEnvironmentResponse(new Response('oops', { status: 500 }))
    expect(broken).toEqual({ ok: false, httpStatus: 500, code: 'environment_request_failed' })
  })

  test('reload posts the action with profile and revision', async () => {
    let captured: { url: string; init?: RequestInit } | undefined
    const client = new RielaEnvironmentClient(async (input, init) => {
      captured = { url: String(input), init }
      return Response.json(status)
    })
    const result = await client.reload('user:a b', 'default', 7)
    expect(result.ok).toBe(true)
    expect(captured?.url).toBe('/api/v1/instances/user%3Aa%20b/actions')
    expect(captured?.init?.method).toBe('POST')
    expect(JSON.parse(String(captured?.init?.body))).toEqual({ action: 'reloadEnvironment', expectedProfile: 'default', expectedRevision: 7 })
    expect((captured?.init?.headers as Record<string, string>)['X-Riela-Profile']).toBe('default')
  })
})
