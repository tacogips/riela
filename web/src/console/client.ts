import { rielaFetch } from '../transport'
import { APIError, api } from '../api'
import type {
  Instance,
  InstanceResponse,
  InstancesResponse,
  OpsOverviewResponse,
} from '../contracts'

interface GraphQLResponse<T> {
  data?: T
  errors?: Array<{ message: string; extensions?: { code?: string } }>
}

export interface ConsoleClientEnvironment {
  request: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>
  appHeaders: () => Record<string, string>
}

const instanceFields = `
  id sourceId isDefault name workflowId source sourceKind status statusDetail
  active enabledAtLaunch workingDirectory environmentFilePath
  environmentVariables { name isSet masked }
  requiredEnvironment { name description required secret source present }
  workflowVariables nodePatchCount nodePatches
  eventSources { id kind }
`

const opsOverviewFields = `
  profile revision workflowsTruncated runsTruncated diagnostics
  workflows {
    sourceId name workflowId scope sourceKind description entryStepId managerStepId stepsTruncated
    steps { id nodeId role description transitions { toStepId label fanoutJoinStepId } }
    nodes { id kind role addon }
  }
  instances { id sourceId isDefault name workflowId status active }
  runs { instanceId sessionId workflowId status currentStepId activeStepIds updatedAt }
`

/// Console reads live on GraphQL; the `/api/v1/instances` and
/// `/api/v1/ops/overview` routes they used to call were deleted.
export class ConsoleClient {
  constructor(private readonly environment: ConsoleClientEnvironment) {}

  async listInstances(signal?: AbortSignal): Promise<InstancesResponse> {
    const data = await this.execute<{ consoleInstances: InstancesResponse }>(
      `query WebConsoleInstances { consoleInstances { profile revision items { ${instanceFields} } } }`,
      {},
      'WebConsoleInstances',
      signal,
    )
    return data.consoleInstances
  }

  async getInstance(identity: string, signal?: AbortSignal): Promise<InstanceResponse> {
    const data = await this.execute<{ consoleInstance: { profile: string; revision: number; item: Instance | null } }>(
      `query WebConsoleInstance($identity: String!) {
      consoleInstance(identity: $identity) { profile revision item { ${instanceFields} } }
    }`,
      { identity },
      'WebConsoleInstance',
      signal,
    )
    const payload = data.consoleInstance
    if (!payload.item) {
      throw new APIError('Workflow instance was not found.', 404, 'instance_not_found')
    }
    return { profile: payload.profile, revision: payload.revision, item: payload.item }
  }

  async getOpsOverview(signal?: AbortSignal): Promise<OpsOverviewResponse> {
    const data = await this.execute<{ opsOverview: OpsOverviewResponse }>(
      `query WebOpsOverview { opsOverview { ${opsOverviewFields} } }`,
      {},
      'WebOpsOverview',
      signal,
    )
    return data.opsOverview
  }

  private async execute<T>(
    query: string,
    variables: Record<string, unknown>,
    operationName: string,
    signal?: AbortSignal,
  ): Promise<T> {
    const response = await this.environment.request('/graphql', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', ...this.environment.appHeaders() },
      body: JSON.stringify({ query, variables, operationName }),
      signal,
    })
    const text = await response.text()
    let payload: GraphQLResponse<T>
    try {
      payload = JSON.parse(text) as GraphQLResponse<T>
    } catch {
      throw new APIError('The console returned invalid JSON.', response.status, 'invalid_response')
    }
    const graphQLError = payload.errors?.[0]
    if (!response.ok || graphQLError || !payload.data) {
      throw new APIError(
        graphQLError?.message ?? `Console request failed (${response.status})`,
        response.status,
        graphQLError?.extensions?.code ?? 'console_request_failed',
      )
    }
    return payload.data
  }
}

const defaultClient = new ConsoleClient({
  request: (input, init) => rielaFetch(input, init),
  appHeaders: () => api.noteHeaders(),
})

export const listConsoleInstances = (signal?: AbortSignal) => defaultClient.listInstances(signal)
export const getConsoleInstance = (identity: string, signal?: AbortSignal) =>
  defaultClient.getInstance(identity, signal)
export const getOpsOverview = (signal?: AbortSignal) => defaultClient.getOpsOverview(signal)
