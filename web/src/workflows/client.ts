import { APIError, api } from '../api'
import type { RegistryMutationPayload, RegistryWorkflow } from './types'

interface GraphQLResponse<T> {
  data?: T
  errors?: Array<{ message: string; extensions?: { code?: string } }>
}

export interface WorkflowClientEnvironment {
  request: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>
  appHeaders: () => Record<string, string>
}

const workflowMetadataFields = `
  originId workflowId name description scope provenance mutable activationState valid
  definitionRevision
  diagnostics { severity path message }
`

const workflowFields = `${workflowMetadataFields} definition`

export class WorkflowRegistryClient {
  constructor(private readonly environment: WorkflowClientEnvironment) {}

  async listMutableWorkflows(): Promise<RegistryWorkflow[]> {
    const data = await this.execute<{ workflows: { workflows: RegistryWorkflow[]; errors: Array<{ message: string }> } }>(
      `query WebMutableWorkflows {
      workflows(filter: { provenance: MUTABLE, scope: USER }) {
        workflows { ${workflowMetadataFields} }
        errors { code message }
      }
    }`,
      {},
      'WebMutableWorkflows',
    )
    const firstError = data.workflows.errors[0]
    if (firstError) throw new APIError(firstError.message, 200, 'registry_query_failed')
    return data.workflows.workflows
  }

  async getMutableWorkflow(workflow: RegistryWorkflow): Promise<RegistryWorkflow> {
    const data = await this.execute<{ workflow: { workflow: RegistryWorkflow | null; errors: Array<{ message: string }> } }>(
      `query WebMutableWorkflow($target: WorkflowTargetInput!) {
      workflow(target: $target) {
        workflow { ${workflowFields} }
        errors { code message }
      }
    }`,
      { target: { workflowId: workflow.workflowId, scope: 'USER', originId: workflow.originId } },
      'WebMutableWorkflow',
    )
    if (!data.workflow.workflow) {
      throw new APIError(
        data.workflow.errors[0]?.message ?? 'Workflow was not found.',
        200,
        'workflow_not_found',
      )
    }
    return data.workflow.workflow
  }

  async registerMutableWorkflow(definition: Record<string, unknown>): Promise<RegistryMutationPayload> {
    return this.mutation(
      `mutation WebRegisterMutableWorkflow($input: RegisterMutableWorkflowInput!) {
      registerMutableWorkflow(input: $input) { accepted workflow { ${workflowFields} } errors { code message } }
    }`,
      { input: { definition, overwrite: false, activationState: 'ACTIVE' } },
      'WebRegisterMutableWorkflow',
      'registerMutableWorkflow',
    )
  }

  async updateMutableWorkflow(
    workflow: RegistryWorkflow,
    definition: Record<string, unknown>,
  ): Promise<RegistryMutationPayload> {
    return this.mutation(
      `mutation WebUpdateMutableWorkflow($input: UpdateMutableWorkflowInput!) {
      updateMutableWorkflow(input: $input) { accepted workflow { ${workflowFields} } errors { code message } }
    }`,
      {
        input: {
          target: { workflowId: workflow.workflowId, scope: 'USER', originId: workflow.originId },
          definition,
          expectedDefinitionRevision: workflow.definitionRevision,
        },
      },
      'WebUpdateMutableWorkflow',
      'updateMutableWorkflow',
    )
  }

  async deleteMutableWorkflow(workflow: RegistryWorkflow): Promise<RegistryMutationPayload> {
    return this.mutation(
      `mutation WebDeleteMutableWorkflow($input: DeleteMutableWorkflowInput!) {
      deleteMutableWorkflow(input: $input) { accepted errors { code message } }
    }`,
      {
        input: {
          target: { workflowId: workflow.workflowId, scope: 'USER', originId: workflow.originId },
          expectedDefinitionRevision: workflow.definitionRevision,
        },
      },
      'WebDeleteMutableWorkflow',
      'deleteMutableWorkflow',
    )
  }

  async setMutableWorkflowActivation(
    workflow: RegistryWorkflow,
    activate: boolean,
  ): Promise<RegistryMutationPayload> {
    const operation = activate ? 'activateWorkflow' : 'deactivateWorkflow'
    return this.mutation(
      `mutation WebSetWorkflowActivation($input: SetWorkflowActivationInput!) {
      ${operation}(input: $input) { accepted workflow { ${workflowFields} } errors { code message } }
    }`,
      {
        input: {
          target: { workflowId: workflow.workflowId, scope: 'USER', originId: workflow.originId },
          expectedDefinitionRevision: workflow.definitionRevision,
          expectedActivationState: workflow.activationState,
        },
      },
      'WebSetWorkflowActivation',
      operation,
    )
  }

  private async execute<T>(
    query: string,
    variables: Record<string, unknown>,
    operationName: string,
  ): Promise<T> {
    const response = await this.environment.request('/graphql', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', ...this.environment.appHeaders() },
      body: JSON.stringify({ query, variables, operationName }),
    })
    const text = await response.text()
    let payload: GraphQLResponse<T>
    try {
      payload = JSON.parse(text) as GraphQLResponse<T>
    } catch {
      throw new APIError('The workflow registry returned invalid JSON.', response.status, 'invalid_response')
    }
    const graphQLError = payload.errors?.[0]
    if (!response.ok || graphQLError || !payload.data) {
      throw new APIError(
        graphQLError?.message ?? `GraphQL request failed (${response.status})`,
        response.status,
        graphQLError?.extensions?.code ?? 'graphql_request_failed',
      )
    }
    return payload.data
  }

  private async mutation(
    query: string,
    variables: Record<string, unknown>,
    operationName: string,
    field: string,
  ): Promise<RegistryMutationPayload> {
    const data = await this.execute<Record<string, RegistryMutationPayload>>(
      query,
      variables,
      operationName,
    )
    const payload = data[field]
    if (!payload) {
      throw new APIError('The workflow registry returned an invalid response.', 500, 'invalid_response')
    }
    if (!payload.accepted) {
      const error = payload.errors[0]
      const code = error?.code ?? 'registry_rejected'
      throw new APIError(
        error?.message ?? 'The workflow registry rejected the change.',
        code === 'REGISTRY_CONFLICT' ? 409 : 400,
        code,
      )
    }
    return payload
  }
}

const defaultClient = new WorkflowRegistryClient({
  request: (input, init) => fetch(input, init),
  appHeaders: () => api.noteHeaders(),
})

export const listMutableWorkflows = () => defaultClient.listMutableWorkflows()
export const getMutableWorkflow = (workflow: RegistryWorkflow) =>
  defaultClient.getMutableWorkflow(workflow)
export const registerMutableWorkflow = (definition: Record<string, unknown>) =>
  defaultClient.registerMutableWorkflow(definition)
export const updateMutableWorkflow = (
  workflow: RegistryWorkflow,
  definition: Record<string, unknown>,
) => defaultClient.updateMutableWorkflow(workflow, definition)
export const deleteMutableWorkflow = (workflow: RegistryWorkflow) =>
  defaultClient.deleteMutableWorkflow(workflow)
export const setMutableWorkflowActivation = (
  workflow: RegistryWorkflow,
  activate: boolean,
) => defaultClient.setMutableWorkflowActivation(workflow, activate)
