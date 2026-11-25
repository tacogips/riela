import { For, Show, createMemo, createResource, createSignal } from 'solid-js'
import { ActionButton } from '../components/ActionButton'
import { botsClient } from './client'
import type { Bot, CreateBotInput } from './contracts'

// NodeExecutionBackend in Sources/RielaCore/WorkflowModel.swift.
export const drivers = [
  ['codex-agent', 'Codex'],
  ['claude-code-agent', 'Claude Code'],
  ['cursor-cli-agent', 'Cursor CLI'],
  ['official/openai-sdk', 'OpenAI SDK'],
  ['official/anthropic-sdk', 'Anthropic SDK'],
  ['official/gemini-sdk', 'Gemini SDK'],
  ['official/cursor-sdk', 'Cursor SDK'],
] as const

export function BotForm(props: {
  remote: string
  bot?: Bot
  busy: boolean
  onSubmit: (input: CreateBotInput) => void
}) {
  const [backend, setBackend] = createSignal(props.bot?.defaultBackend ?? '')
  const [model, setModel] = createSignal(props.bot?.defaultModel ?? 'default')
  const [custom, setCustom] = createSignal(props.bot?.defaultModel ?? '')
  const [catalog] = createResource(() => props.remote, async (remote) => {
    try {
      return await botsClient.getModelCatalog(remote)
    } catch {
      return []
    }
  })
  const models = createMemo(() => [...new Set((catalog() ?? [])
    .filter((provider) => provider.origin.verified && provider.origin.remote === props.remote
      && (!backend() || provider.driver === backend()))
    .flatMap((provider) => provider.models.map(({ id }) => id)).filter((id) => id !== 'default'))])
  const customSelected = () => model() !== 'default' && !models().includes(model())

  return <form class="panel bots-form" onSubmit={(event) => {
    event.preventDefault()
    const fields = new FormData(event.currentTarget)
    const name = String(fields.get('name') ?? '').trim()
    const defaultModel = customSelected() ? custom().trim() : model()
    if (name && defaultModel) props.onSubmit({ name, defaultBackend: backend() || undefined, defaultModel })
  }}>
    <label>Name<input name="name" value={props.bot?.name ?? ''} required /></label>
    <label>Backend<select value={backend()} onChange={(event) => {
      setBackend(event.currentTarget.value)
      setModel('default')
    }}>
      <Show when={!props.bot?.defaultBackend}><option value="">Default</option></Show>
      <Show when={backend() && !drivers.some(([id]) => id === backend())}>
        <option value={backend()}>{backend()}</option>
      </Show>
      <For each={drivers}>{([value, label]) => <option value={value}>{label}</option>}</For>
    </select></label>
    <label>Model<select value={customSelected() ? '' : model()} onChange={(event) => setModel(event.currentTarget.value)}>
      <option value="default">Default</option>
      <For each={models()}>{(id) => <option value={id}>{id}</option>}</For>
      <option value="">Custom model…</option>
    </select></label>
    <Show when={customSelected()}><label>Model ID<input value={custom()} onInput={(event) => setCustom(event.currentTarget.value)} required /></label></Show>
    <ActionButton type="submit" disabled={props.busy}>{props.bot ? 'Save bot' : 'Create bot'}</ActionButton>
  </form>
}
