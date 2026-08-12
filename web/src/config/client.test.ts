import { describe, expect, test } from 'bun:test'
import { RielaConfigurationClient } from './client'

describe('RielaConfigurationClient', () => {
  test('reads configuration through GraphQL', async () => {
    let body: Record<string, unknown> | undefined
    const client = new RielaConfigurationClient(async (_input, init) => {
      body = JSON.parse(String(init?.body)) as Record<string, unknown>
      return Response.json({ data: { configuration: fixtureConfiguration() } })
    })

    const configuration = await client.get()

    expect(configuration.profile).toBe('default')
    expect(configuration.assistant.modelCatalogs[0]?.models).toEqual(['gpt-live'])
    expect(body?.operationName).toBe('WebConfiguration')
  })

  test('sends revision and profile with assistant mutation', async () => {
    let variables: Record<string, unknown> | undefined
    const client = new RielaConfigurationClient(async (_input, init) => {
      const body = JSON.parse(String(init?.body)) as { variables: Record<string, unknown> }
      variables = body.variables
      return Response.json({ data: { updateAssistantConfiguration: fixtureConfiguration() } })
    })

    await client.updateAssistant(fixtureConfiguration(), {
      assistance: 'Concise',
      vendor: 'openai-api',
      model: 'gpt-live',
    })

    expect(variables).toEqual({
      input: {
        expectedRevision: 7,
        expectedProfile: 'default',
        assistance: 'Concise',
        vendor: 'openai-api',
        model: 'gpt-live',
      },
    })
  })
})

function fixtureConfiguration() {
  return {
    profile: 'default',
    revision: 7,
    profiles: ['default'],
    workflowDirectories: [],
    assistant: {
      assistance: '',
      vendor: 'openai-api',
      model: 'gpt-live',
      modelCatalogs: [{ vendor: 'openai-api', models: ['gpt-live'] }],
    },
    appearance: { colorScheme: 'dark', options: ['dark', 'light'] },
    server: {
      isEnabled: true,
      configuredPort: 19091,
      boundPort: 19091,
      restartRequired: false,
      state: 'running',
    },
  }
}
