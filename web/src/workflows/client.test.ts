import { describe, expect, test } from 'bun:test'
import { APIError } from '../api'
import { WorkflowRegistryClient } from './client'
import type { RegistryWorkflow } from './types'

const workflow: RegistryWorkflow = {
  originId: 'user:mutable-review',
  workflowId: 'mutable-review',
  name: 'Mutable review',
  description: 'Review',
  scope: 'USER',
  provenance: 'MUTABLE',
  mutable: true,
  activationState: 'ACTIVE',
  valid: true,
  definitionRevision: 'revision-1',
  definition: { workflowId: 'mutable-review' },
  diagnostics: [],
}

function harness(responses: Array<{ body: unknown; status?: number; raw?: boolean }>) {
  const requests: Array<{ input: string; init?: RequestInit }> = []
  return {
    requests,
    client: new WorkflowRegistryClient({
      appHeaders: () => ({ 'X-Riela-CSRF': 'csrf-token' }),
      request: async (input, init) => {
        requests.push({ input: String(input), init })
        const response = responses.shift()
        if (!response) throw new Error('missing response')
        return new Response(
          response.raw ? String(response.body) : JSON.stringify(response.body),
          {
            status: response.status ?? 200,
            headers: { 'Content-Type': 'application/json' },
          },
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

describe('workflow registry client', () => {
  test('sends same-origin CSRF metadata queries without requesting definitions', async () => {
    const test = harness([{
      body: { data: { workflows: { workflows: [workflow], errors: [] } } },
    }])

    expect(await test.client.listMutableWorkflows()).toEqual([workflow])
    const request = test.requests[0]
    const body = requestBody(request)
    expect(request?.input).toBe('/graphql')
    expect(request?.init?.credentials).toBe('same-origin')
    expect(new Headers(request?.init?.headers).get('X-Riela-CSRF')).toBe('csrf-token')
    expect(body.operationName).toBe('WebMutableWorkflows')
    expect(body.query).not.toContain('definition }')
  })

  test('sends exact origin and revision for update, activation, and deletion', async () => {
    const accepted = { accepted: true, workflow, errors: [] }
    const test = harness([
      { body: { data: { updateMutableWorkflow: accepted } } },
      { body: { data: { deactivateWorkflow: accepted } } },
      { body: { data: { deleteMutableWorkflow: { ...accepted, workflow: null } } } },
    ])

    await test.client.updateMutableWorkflow(workflow, { workflowId: workflow.workflowId })
    await test.client.setMutableWorkflowActivation(workflow, false)
    await test.client.deleteMutableWorkflow(workflow)

    const update = requestBody(test.requests[0])
    const activation = requestBody(test.requests[1])
    const deletion = requestBody(test.requests[2])
    expect(update.variables).toEqual({
      input: {
        target: {
          workflowId: workflow.workflowId,
          scope: 'USER',
          originId: workflow.originId,
        },
        definition: { workflowId: workflow.workflowId },
        expectedDefinitionRevision: workflow.definitionRevision,
      },
    })
    expect(activation.variables).toEqual({
      input: {
        target: {
          workflowId: workflow.workflowId,
          scope: 'USER',
          originId: workflow.originId,
        },
        expectedDefinitionRevision: workflow.definitionRevision,
        expectedActivationState: 'ACTIVE',
      },
    })
    expect(activation.query).toContain('deactivateWorkflow')
    expect(deletion.variables).toEqual({
      input: {
        target: {
          workflowId: workflow.workflowId,
          scope: 'USER',
          originId: workflow.originId,
        },
        expectedDefinitionRevision: workflow.definitionRevision,
      },
    })
  })

  test('distinguishes registry conflicts from validation failures and malformed envelopes', async () => {
    const test = harness([
      {
        body: {
          data: {
            updateMutableWorkflow: {
              accepted: false,
              workflow: null,
              errors: [{ code: 'REGISTRY_CONFLICT', message: 'Changed elsewhere' }],
            },
          },
        },
      },
      {
        body: {
          data: {
            updateMutableWorkflow: {
              accepted: false,
              workflow: null,
              errors: [{ code: 'INVALID_WORKFLOW', message: 'Referenced node file is missing.' }],
            },
          },
        },
      },
      { body: 'not-json', raw: true },
      { body: { data: {} } },
    ])

    await expectAPIError(
      test.client.updateMutableWorkflow(workflow, { workflowId: workflow.workflowId }),
      'REGISTRY_CONFLICT',
      409,
    )
    await expectAPIError(
      test.client.updateMutableWorkflow(workflow, { workflowId: workflow.workflowId }),
      'INVALID_WORKFLOW',
      400,
      'Referenced node file is missing.',
    )
    await expectAPIError(test.client.listMutableWorkflows(), 'invalid_response', 200)
    await expectAPIError(
      test.client.updateMutableWorkflow(workflow, { workflowId: workflow.workflowId }),
      'invalid_response',
      500,
    )
  })
})

async function expectAPIError(
  promise: Promise<unknown>,
  code: string,
  status: number,
  message?: string,
): Promise<void> {
  try {
    await promise
    throw new Error(`expected ${code}`)
  } catch (error) {
    expect(error).toBeInstanceOf(APIError)
    expect((error as APIError).code).toBe(code)
    expect((error as APIError).status).toBe(status)
    if (message) expect((error as APIError).message).toBe(message)
  }
}
