import { expect, test } from 'bun:test'
import { AskClient } from './client'

const origin = { remote: 'pair', verified: true, connection: 'connected' }

function requests(reply: object) {
  const captured: { path: RequestInfo | URL; body: { query: string; variables: object }; signal?: AbortSignal | null }[] = []
  const client = new AskClient({
    appHeaders: () => ({}),
    request: (path, init) => {
      captured.push({ path, body: JSON.parse(String(init?.body)), signal: init?.signal })
      return Promise.resolve(Response.json(reply))
    },
  })
  return { client, captured }
}

test('sends start context, remote and provider selection, while reply omits selection', async () => {
  const { client, captured } = requests({ data: { startAsk: { origin }, sendAskMessage: { origin } } })
  const message = { message: 'How is the run?', context: { kind: 'session', id: 's1' }, remote: 'pair' } as const
  const selection = { providerInstanceId: 'team', model: 'reasoning', effort: 'high' }
  await client.start({ ...message, selection })
  await client.send({ ...message, conversationId: 'c1' })
  expect(captured[0]).toMatchObject({
    path: '/graphql',
    body: { query: expect.stringContaining('startAsk(input: $input)'), variables: { input: { ...message, selection } } },
  })
  expect(captured[1]?.body.variables).toEqual({ input: { ...message, conversationId: 'c1' } })
})

test('passes activity cursor, waiting window, and abort signal', async () => {
  const { client, captured } = requests({ data: { askActivity: { origin, turnStatus: 'completed' } } })
  const signal = new AbortController().signal
  await expect(client.getActivity({ conversationId: 'c1', afterSequence: 9, waitMs: 25_000, remote: 'pair', signal }))
    .resolves.toMatchObject({ turnStatus: 'completed' })
  expect(captured[0]).toMatchObject({ body: { query: expect.stringContaining('executionId payload'),
    variables: { conversationId: 'c1', afterSequence: 9, waitMs: 25_000, limit: 200, remote: 'pair' } }, signal })
})

test('preserves the GraphQL error code and pins the default remote to local', async () => {
  const { client, captured } = requests({ errors: [{ message: 'Unavailable', extensions: { code: 'ask_provider_unsupported' } }] })
  await expect(client.start({ message: 'Status?', context: { kind: 'none' }, selection: {} }))
    .rejects.toMatchObject({ code: 'ask_provider_unsupported' })
  expect(captured[0]?.body.variables).toEqual({ input: { message: 'Status?', context: { kind: 'none' }, selection: {}, remote: 'local' } })
})
