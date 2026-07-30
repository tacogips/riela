import { describe, expect, test } from 'bun:test'
import { RielaAPIClient } from './api'

describe('API mutation contract', () => {
  test('JSON preserves nested workflow variable values', () => {
    const value = { expectedRevision: 4, workflowVariables: { enabled: true, retries: 3, labels: ['a', 'b'] } }
    expect(JSON.parse(JSON.stringify(value))).toEqual(value)
  })

  test('binds RielaApp GraphQL headers to the bootstrapped profile', async () => {
    let profile = 'profile-a'
    const client = new RielaAPIClient(async () => new Response(JSON.stringify({
      apiVersion: 'v1',
      profile,
      csrfToken: 'csrf-a',
      revision: 7,
      capabilities: [],
      server: {
        revision: 7,
        isEnabled: true,
        configuredPort: 19_091,
        boundPort: 19_091,
        restartRequired: false,
        state: 'running',
      },
    })))

    expect(client.noteHeaders()).toEqual({})
    await client.bootstrap()
    expect(client.noteHeaders()).toEqual({
      'X-Riela-CSRF': 'csrf-a',
      'X-Riela-Profile': 'profile-a',
    })

    profile = 'profile-b'
    await client.bootstrap()
    expect(client.noteHeaders()).toEqual({
      'X-Riela-CSRF': 'csrf-a',
      'X-Riela-Profile': 'profile-b',
    })
  })
})
