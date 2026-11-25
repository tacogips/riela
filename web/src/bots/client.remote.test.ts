import { expect, test } from 'bun:test'
import { BotsClient } from './client'

function clientWithResponse(response: object) {
  const requests: { query: string; variables: unknown }[] = []
  const client = new BotsClient({
    appHeaders: () => ({}),
    request: async (_path, init) => {
      requests.push(JSON.parse(String(init?.body)) as typeof requests[number])
      return Response.json(response)
    },
  })
  return { client, requests }
}

test('list and answer target the selected server explicitly', async () => {
  const { client, requests } = clientWithResponse({
    data: { bots: { bots: [], groups: [] }, answerBotRequest: { requestId: 'req', status: 'answered' } },
  })
  await client.listBots('none', 'srv')
  await client.answerRequest({ requestId: 'req', optionId: 'native/option' }, 'srv')
  expect(requests.map(({ variables }) => variables)).toEqual([
    { filter: { groupBy: 'none', remote: 'srv' } },
    { input: { requestId: 'req', optionId: 'native/option', remote: 'srv' } },
  ])
})

test('rejects wildcard activity and mutations before sending a request', async () => {
  const { client, requests } = clientWithResponse({})
  await expect(client.getActivity({ sessionId: 'run', afterSequence: 0, waitMs: 0, remote: '*' }))
    .rejects.toMatchObject({ code: 'remote_required' })
  await expect(client.answerRequest({ requestId: 'req', decline: true }, '*'))
    .rejects.toMatchObject({ code: 'remote_required' })
  expect(requests).toHaveLength(0)
})

test('pairs by name and code and returns the server-owned registry', async () => {
  const registry = { active: 'local', remotes: [] }
  const { client, requests } = clientWithResponse({ data: { addRemote: registry } })
  expect(await client.addRemote('srv', 'rp1.example')).toEqual(registry)
  expect(requests[0]?.variables).toEqual({ input: { name: 'srv', code: 'rp1.example' } })
})

test('preserves the pairing error code and strips the pairing secret from messages', async () => {
  const code = 'rp1.example'
  const { client } = clientWithResponse({
    errors: [{ message: `Rejected ${code}`, extensions: { code: 'pairing_invalid' } }],
  })
  const error = await client.addRemote('srv', code).catch((failure: unknown) => failure)
  expect(error).toMatchObject({ code: 'pairing_invalid', message: 'pairing_invalid' })
  expect(String(error)).not.toContain(code)
})
