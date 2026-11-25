import { api, APIError } from '../api'
import { activityWaitMs } from '../bots/activityStream'
import { activityPageLimit, originFields, singleRemote } from '../bots/client'
import type { ConsoleClientEnvironment } from '../console/client'
import { graphqlRequest } from '../console/graphqlRequest'
import { rielaFetch } from '../transport'
import type { AskActivityPage, AskList, AskMessageInput, AskSelection, AskSnapshot } from './contracts'

const conversationFields = `
  conversationId title context { kind id } selection { vendor providerInstanceId model effort }
  turn { turnId status backend providerInstanceId model toolTransport limitedPolicy error { code message } }
`
const snapshotFields = `
  conversation { ${conversationFields} }
  messages { seq role text turnId citations { kind id sessionId } }
  actions { actionId turnId kind target reason status expiresAt result { ok summary code } }
  limits {
    userMessageBytes assistantMessageBytes messagesPerConversation conversationsPerStore historyMessages historyMessageCharacters
    turnsPerConversation toolCallsPerTurn toolCallsPerConversation toolResultBytes toolBytesPerTurn toolBytesPerConversation
    roundsPerTurn turnDeadlineSeconds draftDefinitionBytes actionsPerTurn actionLifetimeSeconds contextSummaryBytes
  }
  warnings origin { ${originFields} }
`
const listFields = `conversations { ${conversationFields} } origin { ${originFields} }`

export class AskClient {
  constructor(private readonly environment: ConsoleClientEnvironment) {}

  start(input: AskMessageInput & { selection: AskSelection }) {
    return this.mutation('startAsk', 'StartAskInput', input, snapshotFields)
  }

  send(input: AskMessageInput & { conversationId: string }) {
    return this.mutation('sendAskMessage', 'SendAskMessageInput', input, snapshotFields)
  }

  cancel(conversationId: string, remote?: string) {
    return this.mutation('cancelAsk', 'AskConversationInput', { conversationId, remote }, snapshotFields)
  }

  confirm(conversationId: string, actionId: string, remote?: string) {
    return this.mutation('confirmAskAction', 'AskActionInput', { conversationId, actionId, remote }, snapshotFields)
  }

  dismiss(conversationId: string, actionId: string, remote?: string) {
    return this.mutation('dismissAskAction', 'AskActionInput', { conversationId, actionId, remote }, snapshotFields)
  }

  remove(conversationId: string, remote?: string) {
    return this.mutation<AskList>('removeAskConversation', 'AskConversationInput', { conversationId, remote }, listFields)
  }

  async list(remote = 'local', signal?: AbortSignal) {
    const data = await graphqlRequest<{ askConversations: AskList }>(this.environment, 'WebAskList', `
      query WebAskList($remote: String!) { askConversations(remote: $remote) { ${listFields} } }
    `, { remote: singleRemote(remote) }, signal)
    return data.askConversations
  }

  async get(conversationId: string, remote = 'local', signal?: AbortSignal) {
    const data = await graphqlRequest<{ askConversation: AskSnapshot }>(this.environment, 'WebAskGet', `
      query WebAskGet($conversationId: String!, $remote: String!) {
        askConversation(conversationId: $conversationId, remote: $remote) { ${snapshotFields} }
      }
    `, { conversationId, remote: singleRemote(remote) }, signal)
    return data.askConversation
  }

  async getActivity({ conversationId, afterSequence, waitMs, signal, remote = 'local' }: {
    conversationId: string; afterSequence: number; waitMs: number; signal?: AbortSignal; remote?: string
  }) {
    const data = await graphqlRequest<{ askActivity: AskActivityPage }>(this.environment, 'WebAskActivity', `
      query WebAskActivity($conversationId: String!, $afterSequence: Int!, $limit: Int!, $waitMs: Int!, $remote: String!) {
        askActivity(conversationId: $conversationId, afterSequence: $afterSequence, limit: $limit, waitMs: $waitMs, remote: $remote) {
          events { seq at kind executionId payload }
          state {
            currentExecutionId currentStepId pendingRequestIds lastMessageLine usage
            plans { planId entries { content status } }
            toolCalls { toolCallId title status }
          }
          lastSequence firstRetainedSequence truncated turnStatus activitySource
          origin { ${originFields} }
        }
      }
    `, { conversationId, afterSequence, limit: activityPageLimit, waitMs, remote: singleRemote(remote) }, signal)
    const { origin } = data.askActivity
    if (!origin.verified || origin.connection !== 'connected' || origin.remote !== remote) {
      throw new APIError('Activity origin unavailable.', 409, 'origin_unavailable')
    }
    return data.askActivity
  }

  private async mutation<T = AskSnapshot>(
    field: string, inputType: string, input: AskMessageInput | { conversationId: string; actionId?: string; remote?: string }, fields: string,
  ): Promise<T> {
    const data = await graphqlRequest<Record<string, T>>(this.environment, 'WebAskMutation', `
      mutation WebAskMutation($input: ${inputType}!) { ${field}(input: $input) { ${fields} } }
    `, { input: { ...input, remote: singleRemote(input.remote ?? 'local') } })
    return data[field]!
  }
}

export function askActivityReader(client: Pick<AskClient, 'getActivity'>, conversationId: string, remote: string) {
  return async (afterSequence: number, signal: AbortSignal) => {
    const page = await client.getActivity({ conversationId, remote, afterSequence, signal, waitMs: activityWaitMs })
    const lastSequence = page.events.length === activityPageLimit ? page.events.at(-1)!.seq : page.lastSequence
    return { ...page, lastSequence, sessionStatus: page.turnStatus }
  }
}

export const askClient = new AskClient({ request: rielaFetch, appHeaders: () => api.noteHeaders() })
