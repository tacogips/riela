import { describe, expect, test } from 'bun:test'
import { APIError } from '../api'
import { ConsoleClient } from './client'
import type { Instance } from '../contracts'

const instance: Instance = {
  id: 'default',
  sourceId: 'source-a',
  isDefault: true,
  name: '標準設定',
  workflowId: 'workflow-a',
  source: '/workflows/workflow-a',
  sourceKind: 'directory',
  status: 'stopped',
  statusDetail: 'Inactive',
  active: false,
  enabledAtLaunch: false,
  workingDirectory: null,
  environmentFilePath: null,
  environmentVariables: [],
  requiredEnvironment: [],
  workflowVariables: {},
  nodePatchCount: 0,
  nodePatches: {},
  eventSources: [],
}

function harness(responses: Array<{ body: unknown; status?: number; raw?: boolean }>) {
  const requests: Array<{ input: string; init?: RequestInit }> = []
  return {
    requests,
    client: new ConsoleClient({
      appHeaders: () => ({ 'X-Riela-CSRF': 'csrf-token' }),
      request: async (input, init) => {
        requests.push({ input: String(input), init })
        const response = responses.shift()
        if (!response) throw new Error('missing response')
        return new Response(
          response.raw ? String(response.body) : JSON.stringify(response.body),
          { status: response.status ?? 200, headers: { 'Content-Type': 'application/json' } },
        )
      },
    }),
  }
}

function requestBody(request?: { init?: RequestInit }) {
  return JSON.parse(String(request?.init?.body)) as {
    operationName: string
    query: string
    variables: Record<string, unknown>
  }
}

describe('console client', () => {
  test('reads the instance list over GraphQL, not /api/v1/instances', async () => {
    const test = harness([{
      body: { data: { consoleInstances: { profile: 'default', revision: 3, items: [instance] } } },
    }])

    const payload = await test.client.listInstances()
    expect(payload.items).toEqual([instance])
    expect(payload.revision).toBe(3)
    const request = test.requests[0]
    expect(request?.input).toBe('/graphql')
    expect(request?.init?.credentials).toBe('same-origin')
    expect(new Headers(request?.init?.headers).get('X-Riela-CSRF')).toBe('csrf-token')
    expect(requestBody(request).operationName).toBe('WebConsoleInstances')
  })

  test('reads one instance by identity and rejects a missing one', async () => {
    const found = harness([{
      body: { data: { consoleInstance: { profile: 'default', revision: 4, item: instance } } },
    }])
    const detail = await found.client.getInstance('default')
    expect(detail.item).toEqual(instance)
    expect(requestBody(found.requests[0]).variables).toEqual({ identity: 'default' })

    const missing = harness([{
      body: { data: { consoleInstance: { profile: 'default', revision: 4, item: null } } },
    }])
    await expect(missing.client.getInstance('gone')).rejects.toThrow(APIError)
  })

  test('reads the ops overview over GraphQL', async () => {
    const test = harness([{
      body: {
        data: {
          opsOverview: {
            profile: 'default',
            revision: 5,
            workflows: [],
            workflowsTruncated: false,
            instances: [],
            runs: [],
            runsTruncated: false,
            diagnostics: [],
          },
        },
      },
    }])
    const overview = await test.client.getOpsOverview()
    expect(overview.revision).toBe(5)
    expect(test.requests[0]?.input).toBe('/graphql')
    expect(requestBody(test.requests[0]).operationName).toBe('WebOpsOverview')
  })

  test('surfaces GraphQL errors as APIError with their extension code', async () => {
    const test = harness([{
      body: {
        errors: [{ message: 'console unavailable', extensions: { code: 'CONSOLE_UNAVAILABLE' } }],
      },
    }])
    await expect(test.client.listInstances()).rejects.toMatchObject({
      message: 'console unavailable',
      code: 'CONSOLE_UNAVAILABLE',
    })
  })
})

describe('retired console routes', () => {
  test('no source file calls the deleted instance or ops overview routes', async () => {
    const { Glob } = await import('bun')
    // POST /api/v1/instances survives (instance creation); the retired reads
    // are the GETs and the whole ops overview route.
    const retired = ["api.get<InstancesResponse>('/api/v1/instances'", '/api/v1/ops/overview', '/api/v1/instances/${encodeURIComponent(props.instance().id)}`']
    const offenders: string[] = []
    for await (const path of new Glob('src/**/*.{ts,tsx}').scan('.')) {
      if (path.startsWith('src/console/')) continue
      const contents = await Bun.file(path).text()
      for (const route of retired) {
        if (contents.includes(route)) offenders.push(`${path}: ${route}`)
      }
    }
    expect(offenders).toEqual([])
  })
})
