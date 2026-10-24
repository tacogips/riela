import { rielaFetch } from '../transport'
import { APIError, api } from '../api'
import type { ConfigurationRevision, RielaConfiguration, RuntimeEnvironmentStatus } from '../contracts'

interface GraphQLResponse<T> {
  data?: T
  errors?: Array<{ message: string; extensions?: { code?: string } }>
}

const configurationFields = `
  profile revision profiles workflowDirectories
  workflowStorage { directory defaultDirectory isDefault cliWorkflowHome }
  assistant { assistance vendor model modelCatalogs { vendor models } }
  appearance { colorScheme options }
  server { isEnabled configuredPort boundPort restartRequired state }
`

export class RielaConfigurationClient {
  constructor(
    private readonly request: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response> =
      (input, init) => rielaFetch(input, init),
  ) {}

  async get(): Promise<RielaConfiguration> {
    const data = await this.execute<{ configuration: RielaConfiguration }>(
      `query WebConfiguration { configuration { ${configurationFields} } }`,
      {},
      'WebConfiguration',
    )
    return data.configuration
  }

  async updateAssistant(
    current: RielaConfiguration,
    input: { assistance: string; vendor: string; model: string },
  ): Promise<RielaConfiguration> {
    return this.mutate(
      `mutation WebUpdateAssistantConfiguration($input: UpdateAssistantConfigurationInput!) {
        updateAssistantConfiguration(input: $input) { ${configurationFields} }
      }`,
      {
        input: {
          expectedRevision: current.revision,
          expectedProfile: current.profile,
          ...input,
        },
      },
      'WebUpdateAssistantConfiguration',
      'updateAssistantConfiguration',
    )
  }

  async updateAppearance(current: RielaConfiguration, colorScheme: string): Promise<RielaConfiguration> {
    return this.mutate(
      `mutation WebUpdateAppearanceConfiguration($input: UpdateAppearanceConfigurationInput!) {
        updateAppearanceConfiguration(input: $input) { ${configurationFields} }
      }`,
      { input: { expectedRevision: current.revision, expectedProfile: current.profile, colorScheme } },
      'WebUpdateAppearanceConfiguration',
      'updateAppearanceConfiguration',
    )
  }

  async updateHTTPServer(current: RielaConfiguration, configuredPort: number): Promise<RielaConfiguration> {
    return this.mutate(
      `mutation WebUpdateHTTPServerConfiguration($input: UpdateHTTPServerConfigurationInput!) {
        updateHTTPServerConfiguration(input: $input) { ${configurationFields} }
      }`,
      { input: { expectedRevision: current.revision, configuredPort } },
      'WebUpdateHTTPServerConfiguration',
      'updateHTTPServerConfiguration',
    )
  }

  async setHTTPServerEnabled(current: RielaConfiguration, isEnabled: boolean): Promise<RielaConfiguration> {
    return this.mutate(
      `mutation WebUpdateHTTPServerConfiguration($input: UpdateHTTPServerConfigurationInput!) {
        updateHTTPServerConfiguration(input: $input) { ${configurationFields} }
      }`,
      { input: { expectedRevision: current.revision, isEnabled } },
      'WebUpdateHTTPServerConfiguration',
      'updateHTTPServerConfiguration',
    )
  }

  async updateWorkflowStorage(current: RielaConfiguration, directory: string): Promise<RielaConfiguration> {
    return this.mutate(
      `mutation WebUpdateWorkflowStorageConfiguration($input: UpdateWorkflowStorageConfigurationInput!) {
        updateWorkflowStorageConfiguration(input: $input) { ${configurationFields} }
      }`,
      { input: { expectedRevision: current.revision, expectedProfile: current.profile, directory } },
      'WebUpdateWorkflowStorageConfiguration',
      'updateWorkflowStorageConfiguration',
    )
  }

  async createProfile(current: RielaConfiguration, name: string): Promise<RielaConfiguration> {
    return this.profileMutation(current, name, 'createProfileConfiguration', 'WebCreateProfileConfiguration')
  }

  async removeProfile(current: RielaConfiguration, name: string): Promise<RielaConfiguration> {
    return this.profileMutation(current, name, 'removeProfileConfiguration', 'WebRemoveProfileConfiguration')
  }

  async switchProfile(current: RielaConfiguration, name: string): Promise<RielaConfiguration> {
    return this.profileMutation(current, name, 'switchProfileConfiguration', 'WebSwitchProfileConfiguration')
  }

  async addWorkflowDirectory(current: { profile: string; revision: number }, path: string): Promise<ConfigurationRevision> {
    return this.revisionMutation(
      'addWorkflowDirectoryConfiguration',
      'WorkflowDirectoryConfigurationInput',
      'WebAddWorkflowDirectoryConfiguration',
      { expectedRevision: current.revision, expectedProfile: current.profile, path },
    )
  }

  async updateWorkflowInstance(
    current: { profile: string; revision: number },
    input: {
      identity: string
      workingDirectory: string
      environmentFilePath: string
      environmentVariableUpdates: Record<string, string>
      environmentVariablesToClear: string[]
      environmentResolution?: unknown
      clearEnvironmentResolution?: boolean
      workflowVariables: Record<string, unknown>
    },
  ): Promise<ConfigurationRevision> {
    return this.revisionMutation(
      'updateWorkflowInstanceConfiguration',
      'WorkflowInstanceConfigurationInput',
      'WebUpdateWorkflowInstanceConfiguration',
      { expectedRevision: current.revision, expectedProfile: current.profile, ...input },
    )
  }

  async registerEventSource(
    current: { profile: string; revision: number },
    input: { identity: string; source: Record<string, unknown>; binding: Record<string, unknown> },
  ): Promise<ConfigurationRevision> {
    return this.revisionMutation(
      'registerEventSourceConfiguration',
      'EventSourceConfigurationInput',
      'WebRegisterEventSourceConfiguration',
      { expectedRevision: current.revision, expectedProfile: current.profile, ...input },
    )
  }

  private profileMutation(
    current: RielaConfiguration,
    name: string,
    field: string,
    operationName: string,
  ): Promise<RielaConfiguration> {
    return this.mutate(
      `mutation ${operationName}($input: ProfileConfigurationInput!) {
        ${field}(input: $input) { ${configurationFields} }
      }`,
      { input: { expectedRevision: current.revision, expectedProfile: current.profile, name } },
      operationName,
      field,
    )
  }

  private async revisionMutation(
    field: string,
    inputType: string,
    operationName: string,
    input: Record<string, unknown>,
  ): Promise<ConfigurationRevision> {
    const data = await this.execute<Record<string, ConfigurationRevision>>(
      `mutation ${operationName}($input: ${inputType}!) { ${field}(input: $input) { profile revision } }`,
      { input },
      operationName,
    )
    const value = data[field]
    if (!value) throw new APIError('Configuration mutation returned no revision.', 200, 'invalid_response')
    return value
  }

  private async mutate<Key extends string>(
    query: string,
    variables: Record<string, unknown>,
    operationName: string,
    key: Key,
  ): Promise<RielaConfiguration> {
    const data = await this.execute<Record<Key, RielaConfiguration>>(query, variables, operationName)
    return data[key]
  }

  private async execute<T>(
    query: string,
    variables: Record<string, unknown>,
    operationName: string,
  ): Promise<T> {
    const response = await this.request('/graphql', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...api.noteHeaders(),
      },
      credentials: 'same-origin',
      body: JSON.stringify({ query, variables, operationName }),
    })
    const payload = await response.json() as GraphQLResponse<T>
    const error = payload.errors?.[0]
    if (!response.ok || error || !payload.data) {
      throw new APIError(
        error?.message ?? `Configuration request failed (${response.status})`,
        response.status,
        error?.extensions?.code?.toLowerCase() ?? 'configuration_request_failed',
      )
    }
    return payload.data
  }
}

export const configurationClient = new RielaConfigurationClient()

/** Outcome of an environment request: the status on success, or the safe code
 *  from the 422 status body (`lastError`) / 409 error body (`error.code`). */
export type EnvironmentResult =
  | { ok: true; status: RuntimeEnvironmentStatus }
  | { ok: false; httpStatus: number; code: string; status?: RuntimeEnvironmentStatus }

function isEnvironmentStatus(value: unknown): value is RuntimeEnvironmentStatus {
  if (!value || typeof value !== 'object') return false
  const candidate = value as Record<string, unknown>
  return typeof candidate.readiness === 'string' && typeof candidate.generation === 'number'
    && Array.isArray(candidate.names)
}

export async function parseEnvironmentResponse(response: Response): Promise<EnvironmentResult> {
  let body: unknown
  try { body = JSON.parse(await response.text()) } catch { body = undefined }
  if (response.ok && isEnvironmentStatus(body)) return { ok: true, status: body }
  if (isEnvironmentStatus(body)) {
    const code = typeof body.lastError === 'string' && body.lastError ? body.lastError : 'environment_request_failed'
    return { ok: false, httpStatus: response.status, code, status: body }
  }
  const error = (body as { error?: { code?: unknown } } | undefined)?.error
  const code = typeof error?.code === 'string' ? error.code : response.ok ? 'invalid_response' : 'environment_request_failed'
  return { ok: false, httpStatus: response.status, code }
}

/** Short operator guidance for the environment codes the hosts return. */
export function environmentErrorMessage(code: string): string {
  switch (code) {
    case 'environment_restart_required': return 'Managed names changed. Stop and start this configuration to apply them.'
    case 'environment_reload_in_progress': return 'Another reload is running. Retry shortly.'
    case 'environment_instance_changed': return 'The configuration restarted during the reload. Retry.'
    case 'profile_conflict':
    case 'revision_conflict':
    case 'profile_or_instance_conflict': return 'Changed elsewhere. Refresh before continuing.'
    default: return `Environment reload failed (${code}). The previous snapshot is kept.`
  }
}

export class RielaEnvironmentClient {
  constructor(
    private readonly request: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response> =
      (input, init) => rielaFetch(input, init),
  ) {}

  async status(identity: string, profile: string): Promise<EnvironmentResult> {
    return parseEnvironmentResponse(await this.request(`/api/v1/instances/${encodeURIComponent(identity)}/environment`, {
      credentials: 'same-origin', headers: { ...api.noteHeaders(), 'X-Riela-Profile': profile },
    }))
  }

  async reload(identity: string, profile: string, expectedRevision: number): Promise<EnvironmentResult> {
    return parseEnvironmentResponse(await this.request(`/api/v1/instances/${encodeURIComponent(identity)}/actions`, {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', ...api.noteHeaders(), 'X-Riela-Profile': profile },
      body: JSON.stringify({ action: 'reloadEnvironment', expectedProfile: profile, expectedRevision }),
    }))
  }
}

export const environmentClient = new RielaEnvironmentClient()
