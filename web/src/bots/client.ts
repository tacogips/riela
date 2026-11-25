import { APIError, api } from '../api'
import type { ConsoleClientEnvironment } from '../console/client'
import { rielaFetch } from '../transport'
import type {
  AnswerBotRequestInput, Bot, BotActivityPage, BotDetailPayload, BotGrouping,
  BotListPayload, CreateBotInput, SetBotListStateInput, UpdateBotInput,
} from './contracts'

interface GraphQLResponse<T> {
  data?: T
  errors?: { message: string; extensions?: { code?: string } }[]
}

const botFields = 'botId name paused'
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
}

export class BotsClient {
  constructor(private readonly environment: ConsoleClientEnvironment) {}

  async listBots(groupBy: BotGrouping, signal?: AbortSignal): Promise<BotListPayload> {
    const data = await this.execute<{ bots: BotListPayload }>('WebBots', `
      query WebBots($filter: BotFilter) {
        bots(filter: $filter) {
          bots {
            bot { ${botFields} }
            counts { needsYou working waiting planned }
            inProgress { ${workFields} }
            lastActivityAt lastResult section
            listState { ${listStateFields} }
            origin { remote serverName }
          }
          groups { key needsYou botIds }
        }
      }
    `, { filter: { groupBy } }, signal)
    return data.bots
  }

  async getBot(botId: string, signal?: AbortSignal): Promise<BotDetailPayload> {
    const groups = ['needsYou', 'inProgress', 'waiting', 'planned', 'closed']
    const data = await this.execute<{ bot: BotDetailPayload }>('WebBot', `
      query WebBot($botId: String!) {
        bot(botId: $botId) {
          bot { ${botFields} }
          board { closedTotal ${groups.map((group) => `${group} { ${boardFields} }`).join(' ')} }
          routines { routineId name status nextRunAt }
        }
      }
    `, { botId }, signal)
    return data.bot
  }

  createBot(input: CreateBotInput) {
    return this.mutateBot('createBot', 'CreateBotInput', input)
  }

  updateBot(input: UpdateBotInput) {
    return this.mutateBot('updateBot', 'UpdateBotInput', input)
  }

  setPaused(botId: string, paused: boolean) {
    return this.mutateBot('setBotPaused', 'SetBotPausedInput', { botId, paused })
  }

  removeBot(botId: string) {
    return this.mutateBot('removeBot', 'RemoveBotInput', { botId })
  }

  setListState(input: SetBotListStateInput) {
    return this.mutateBot('setBotListState', 'SetBotListStateInput', input)
  }

  async getActivity({ sessionId, afterSequence, waitMs, signal }: ActivityQuery): Promise<BotActivityPage> {
    const data = await this.execute<{ botActivity: BotActivityPage }>('WebBotActivity', `
      query WebBotActivity($sessionId: String!, $afterSequence: Int!, $limit: Int!, $waitMs: Int!) {
        botActivity(sessionId: $sessionId, afterSequence: $afterSequence, limit: $limit, waitMs: $waitMs) {
          events { seq at kind payload }
          state {
            currentExecutionId currentStepId pendingRequestIds lastMessageLine
            plans { ${planFields} }
            toolCalls { toolCallId title status }
          }
          lastSequence truncated sessionStatus activitySource
        }
      }
    `, { sessionId, afterSequence, limit: activityPageLimit, waitMs }, signal)
    return data.botActivity
  }

  async answerRequest(input: AnswerBotRequestInput) {
    const data = await this.execute<{ answerBotRequest: { requestId: string; status: string } }>('WebAnswerBotRequest', `
      mutation WebAnswerBotRequest($input: AnswerBotRequestInput!) {
        answerBotRequest(input: $input) { requestId status }
      }
    `, { input })
    return data.answerBotRequest
  }

  private async mutateBot(field: string, inputType: string, input: object): Promise<Bot> {
    const data = await this.execute<Record<string, { bot: Bot }>>('WebBotMutation', `
      mutation WebBotMutation($input: ${inputType}!) {
        ${field}(input: $input) { bot { ${botFields} } }
      }
    `, { input })
    return data[field]!.bot
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
