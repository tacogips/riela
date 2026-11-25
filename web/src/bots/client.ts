import { APIError, api } from '../api'
import type { ConsoleClientEnvironment } from '../console/client'
import type { ProviderInstance, SaveProviderInput } from '../models/contracts'
import { rielaFetch } from '../transport'
import type {
  AnswerBotRequestInput, Bot, BotActivityPage, BotDetailPayload, BotGrouping,
  BotListPayload, BotMemory, BotOrigin, BotSuggestion, CreateBotInput, RemoteList, SetBotListStateInput, UpdateBotInput,
} from './contracts'

interface GraphQLResponse<T> {
  data?: T
  errors?: { message: string; extensions?: { code?: string } }[]
}

const originFields = 'remote serverId serverName verified connection observedAt'
const providerFields = `
  instanceId driver label account builtIn availability authentication version probedAt
  models { id label sources reasoningEfforts serviceTiers modes } origin { ${originFields} }
`
const remoteFields = 'active remotes { name address serverName lastSeenAt connection }'

function singleRemote(remote: string) {
  if (remote === '*' || remote === 'unverified' || !remote) throw new APIError('Choose a remote.', 400, 'remote_required')
  return remote
}

const botFields = 'botId name paused defaultBackend defaultModel'
const listStateFields = 'pinned snoozedUntil settledAt settledBy'
const workFields = 'title workflowId stepId nodeId backend model elapsedMs'
const planFields = 'planId entries { content status }'
const boardFields = `
  ${workFields} itemKind itemId status waitingReason limitedResetAt activitySource
  doingNow answerPath lastResult sessionId listState { ${listStateFields} }
  checklist { ${planFields} }
  pendingRequests { requestId title options { optionId name } }
  question { text }
`
export const activityPageLimit = 200

export interface ActivityQuery {
  sessionId: string
  afterSequence: number
  waitMs: number
  signal?: AbortSignal
  remote?: string
}

export class BotsClient {
  constructor(private readonly environment: ConsoleClientEnvironment) {}

  async listBots(groupBy: BotGrouping, remote = 'local', signal?: AbortSignal): Promise<BotListPayload> {
    const data = await this.execute<{ bots: BotListPayload }>('WebBots', `
      query WebBots($filter: BotFilter) {
        bots(filter: $filter) {
          bots {
            bot { ${botFields} }
            counts { needsYou working waiting planned }
            inProgress { ${workFields} }
            lastActivityAt lastResult section workspaceGroup
            listState { ${listStateFields} }
            origin { ${originFields} }
          }
          groups { key needsYou botIds }
          origin { ${originFields} }
        }
      }
    `, { filter: { groupBy, remote } }, signal)
    return data.bots
  }

  async getBot(botId: string, remote = 'local', signal?: AbortSignal): Promise<BotDetailPayload> {
    const groups = ['needsYou', 'inProgress', 'waiting', 'planned', 'closed']
    const data = await this.execute<{ bot: BotDetailPayload }>('WebBot', `
      query WebBot($botId: String!, $remote: String!) {
        bot(botId: $botId, remote: $remote) {
          bot { ${botFields} }
          board { closedTotal ${groups.map((group) => `${group} { ${boardFields} }`).join(' ')} }
          routines { routineId name status nextRunAt }
          origin { ${originFields} }
          jobs { job schedule lastRun { status startedAt detail } }
        }
      }
    `, { botId, remote: singleRemote(remote) }, signal)
    return data.bot
  }

  createBot(input: CreateBotInput, remote = 'local') {
    return this.mutateBot('createBot', 'CreateBotInput', input, remote)
  }

  updateBot(input: UpdateBotInput, remote = 'local') {
    return this.mutateBot('updateBot', 'UpdateBotInput', input, remote)
  }

  setPaused(botId: string, paused: boolean, remote = 'local') {
    return this.mutateBot('setBotPaused', 'SetBotPausedInput', { botId, paused }, remote)
  }

  removeBot(botId: string, remote = 'local') {
    return this.mutateBot('removeBot', 'RemoveBotInput', { botId }, remote)
  }

  setListState(input: SetBotListStateInput, remote = 'local') {
    return this.mutateBot('setBotListState', 'SetBotListStateInput', input, remote)
  }

  async getActivity({ sessionId, afterSequence, waitMs, signal, remote = 'local' }: ActivityQuery): Promise<BotActivityPage> {
    const data = await this.execute<{ botActivity: BotActivityPage }>('WebBotActivity', `
      query WebBotActivity($sessionId: String!, $afterSequence: Int!, $limit: Int!, $waitMs: Int!, $remote: String!) {
        botActivity(sessionId: $sessionId, afterSequence: $afterSequence, limit: $limit, waitMs: $waitMs, remote: $remote) {
          events { seq at kind payload }
          state {
            currentExecutionId currentStepId pendingRequestIds lastMessageLine
            plans { ${planFields} }
            toolCalls { toolCallId title status }
          }
          lastSequence truncated sessionStatus activitySource
          origin { ${originFields} }
        }
      }
    `, { sessionId, afterSequence, limit: activityPageLimit, waitMs, remote: singleRemote(remote) }, signal)
    const origin = data.botActivity.origin
    if (!origin.verified || origin.remote !== remote || origin.connection !== 'connected') {
      throw new APIError('Activity origin unavailable.', 409, 'origin_unavailable')
    }
    return data.botActivity
  }

  async answerRequest(input: AnswerBotRequestInput, remote = 'local') {
    const data = await this.execute<{ answerBotRequest: { requestId: string; status: string } }>('WebAnswerBotRequest', `
      mutation WebAnswerBotRequest($input: AnswerBotRequestInput!) {
        answerBotRequest(input: $input) { requestId status }
      }
    `, { input: { ...input, remote: singleRemote(remote) } })
    return data.answerBotRequest
  }

  private async mutateBot(field: string, inputType: string, input: object, remote: string): Promise<Bot> {
    const data = await this.execute<Record<string, { bot: Bot }>>('WebBotMutation', `
      mutation WebBotMutation($input: ${inputType}!) {
        ${field}(input: $input) { bot { ${botFields} } }
      }
    `, { input: { ...input, remote: singleRemote(remote) } })
    return data[field]!.bot
  }

  async getMemory(botId: string, remote: string, signal?: AbortSignal) {
    const data = await this.execute<{ botMemory: BotMemory }>('WebBotMemory', `
      query WebBotMemory($botId: String!, $remote: String!) {
        botMemory(botId: $botId, remote: $remote) {
          markdown changes { changeId actor reason createdAt } origin { ${originFields} }
        }
      }
    `, { botId, remote: singleRemote(remote) }, signal)
    return data.botMemory
  }

  updateMemory(botId: string, markdown: string, remote: string) {
    return this.managementMutation('updateBotMemory', 'UpdateBotMemoryInput', { botId, markdown, remote: singleRemote(remote) }, 'change { changeId }')
  }

  undoMemory(botId: string, changeId: string, remote: string) {
    return this.managementMutation('undoBotMemoryChange', 'UndoBotMemoryChangeInput', { botId, changeId, remote: singleRemote(remote) }, 'change { changeId }')
  }

  captureFeedback(botId: string, sessionId: string, text: string, remote: string) {
    return this.managementMutation('captureBotFeedback', 'CaptureBotFeedbackInput', { botId, sessionId, text, remote: singleRemote(remote) }, 'change { changeId }')
  }

  async getSuggestions(botId: string, remote: string, signal?: AbortSignal) {
    const data = await this.execute<{ botSuggestions: { suggestions: BotSuggestion[]; origin: BotOrigin } }>('WebBotSuggestions', `
      query WebBotSuggestions($botId: String!, $remote: String!) {
        botSuggestions(botId: $botId, remote: $remote, status: "open") {
          suggestions { suggestionId title detail action { workflowName } origin { ${originFields} } }
          origin { ${originFields} }
        }
      }
    `, { botId, remote: singleRemote(remote) }, signal)
    return data.botSuggestions
  }

  decideSuggestion(suggestionId: string, decision: 'accept' | 'dismiss', run: boolean, remote: string) {
    return this.managementMutation('decideBotSuggestion', 'DecideBotSuggestionInput',
      { suggestionId, decision, run, remote: singleRemote(remote) }, 'suggestion { status }')
  }

  runJob(botId: string, job: string, remote: string) {
    return this.managementMutation<{ status: string; detail?: string | null }>('runBotJob', 'RunBotJobInput',
      { botId, job, force: true, remote: singleRemote(remote) }, 'status detail')
  }

  async getProviders(remote: string, signal?: AbortSignal) {
    const data = await this.execute<{ providers: { providers: ProviderInstance[] } }>('WebProviders', `
      query WebProviders($remote: String!) { providers(remote: $remote) { providers { ${providerFields} } } }
    `, { remote }, signal)
    return data.providers.providers
  }

  async getModelCatalog(remote: string, signal?: AbortSignal) {
    const data = await this.execute<{ modelCatalog: { providers: ProviderInstance[] } }>('WebModelCatalog', `
      query WebModelCatalog($remote: String!) { modelCatalog(remote: $remote) { providers { ${providerFields} } } }
    `, { remote: singleRemote(remote) }, signal)
    return data.modelCatalog.providers
  }

  refreshProvider(instanceId: string, remote: string) {
    return this.managementMutation('refreshProviders', 'RefreshProvidersInput', { instanceId, remote: singleRemote(remote) }, 'providers { instanceId }')
  }

  saveProvider(input: SaveProviderInput, remote: string) {
    return this.managementMutation('saveProviderInstance', 'SaveProviderInstanceInput', { ...input, remote: singleRemote(remote) }, 'provider { instanceId }')
  }

  removeProvider(instanceId: string, remote: string) {
    return this.managementMutation('removeProviderInstance', 'RemoveProviderInstanceInput', { instanceId, remote: singleRemote(remote) }, 'providers { instanceId }')
  }

  async getRemotes(signal?: AbortSignal) {
    const data = await this.execute<{ remotes: RemoteList }>('WebRemotes', `
      query WebRemotes { remotes { ${remoteFields} } }
    `, {}, signal)
    return data.remotes
  }

  async addRemote(name: string, code: string) {
    try {
      return await this.managementMutation<RemoteList>('addRemote', 'AddRemoteInput', { name, code }, remoteFields)
    } catch (error) {
      // Pairing errors must never repeat input or transport diagnostics.
      const errorCode = error instanceof APIError && /^[a-zA-Z0-9_]+$/.test(error.code) && !error.code.includes(code)
        ? error.code : 'pairing_failed'
      throw new APIError(errorCode, error instanceof APIError ? error.status : 0, errorCode)
    }
  }

  removeRemote(name: string) {
    return this.managementMutation<RemoteList>('removeRemote', 'RemoveRemoteInput', { name }, remoteFields)
  }

  useRemote(name: string) {
    return this.managementMutation<RemoteList>('useRemote', 'UseRemoteInput', { name }, remoteFields)
  }

  private async managementMutation<T>(field: string, inputType: string, input: object, fields: string): Promise<T> {
    const data = await this.execute<Record<string, T>>('WebManagementMutation', `
      mutation WebManagementMutation($input: ${inputType}!) {
        ${field}(input: $input) { ${fields} }
      }
    `, { input })
    return data[field]!
  }

  private async execute<T>(
    operationName: string, query: string, variables: Record<string, unknown>, signal?: AbortSignal,
  ): Promise<T> {
    const response = await this.environment.request('/graphql', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', ...this.environment.appHeaders() },
      body: JSON.stringify({ operationName, query, variables }),
      signal,
    })
    const body = await response.text()
    let payload: GraphQLResponse<T> | null
    try {
      payload = JSON.parse(body) as GraphQLResponse<T> | null
    } catch {
      throw new APIError('The console returned invalid JSON.', response.status, 'invalid_response')
    }
    const error = payload?.errors?.[0]
    if (!response.ok || error || !payload?.data) {
      throw new APIError(
        error?.message ?? `Console request failed (${response.status})`,
        response.status,
        error?.extensions?.code ?? 'console_request_failed',
      )
    }
    return payload.data
  }
}

export const botsClient = new BotsClient({
  request: rielaFetch,
  appHeaders: () => api.noteHeaders(),
})
