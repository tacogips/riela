import { expect, test } from 'bun:test'
import { APIError } from '../api'
import { BotsClient } from './client'
import type { BotActivityPage, BotListPayload } from './contracts'

function withResponse(body: object) {
  const requests: { input: RequestInfo | URL; init?: RequestInit; body: Record<string, unknown> }[] = []
  const client = new BotsClient({
    request: async (input, init) => {
      requests.push({ input, init, body: JSON.parse(String(init?.body)) as Record<string, unknown> })
      return Response.json(body)
    },
    appHeaders: () => ({ 'X-Riela-Profile': 'project', Authorization: 'Bearer test-token' }),
  })
  return { client, requests }
}

test('lists bots with a single authenticated GraphQL POST and preserves projected order', async () => {
  const payload: BotListPayload = {
    bots: ['z', 'a'].map((botId) => ({
      bot: { botId, name: botId, paused: false },
      counts: { needsYou: 1, working: 0, waiting: 0, planned: 0 },
      inProgress: [], listState: { pinned: false }, section: 'active',
      origin: { remote: 'local' },
    })),
    groups: [{ key: 'team', needsYou: true, botIds: ['z', 'a'] }],
  }
  const { client, requests } = withResponse({ data: { bots: payload } })
  const signal = new AbortController().signal
  expect(await client.listBots('workspace', signal)).toEqual(payload)
  expect(requests).toHaveLength(1)
  const request = requests[0]!
  expect(request.input).toBe('/graphql')
  expect(request.init).toMatchObject({
    method: 'POST', credentials: 'same-origin', signal,
    headers: { 'Content-Type': 'application/json', 'X-Riela-Profile': 'project', Authorization: 'Bearer test-token' },
  })
  expect(request.body).toMatchObject({ operationName: 'WebBots', variables: { filter: { groupBy: 'workspace' } } })
})

test('maps server GraphQL error codes to APIError', async () => {
  const { client } = withResponse({ errors: [{ message: 'Bot not found', extensions: { code: 'bot_not_found' } }] })
  const error: unknown = await client.getBot('missing').catch((error: unknown) => error)
  expect(error).toBeInstanceOf(APIError)
  expect(error).toMatchObject({ code: 'bot_not_found', message: 'Bot not found' })
})

test('passes activity cursor and long-poll timeout through variables', async () => {
  const payload: BotActivityPage = {
    events: [], lastSequence: 17, truncated: false, sessionStatus: 'running', activitySource: 'acp',
  }
  const { client, requests } = withResponse({ data: { botActivity: payload } })
  expect(await client.getActivity({ sessionId: 'session/1', afterSequence: 17, waitMs: 25_000 })).toEqual(payload)
  expect(requests[0]?.body.variables).toEqual({ sessionId: 'session/1', afterSequence: 17, limit: 200, waitMs: 25_000 })
})

test('sends native option IDs unchanged and sends decline without an option', async () => {
  const { client, requests } = withResponse({ data: { answerBotRequest: { requestId: 'request', status: 'answered' } } })
  await client.answerRequest({ requestId: 'request', optionId: 'allow/once:1' })
  await client.answerRequest({ requestId: 'request', decline: true })
  expect(requests.map(({ body }) => body.variables)).toEqual([
    { input: { requestId: 'request', optionId: 'allow/once:1' } },
    { input: { requestId: 'request', decline: true } },
  ])
})
