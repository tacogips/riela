import { For, Show, createEffect, createMemo, createResource, createSignal } from 'solid-js'
import { APIError } from '../api'
import { configurationClient } from '../config/client'
import { ErrorBanner, LoadingState, MutationMessage, PageHeader } from '../components/Primitives'
import '../settings-extra.css'

type SettingsSection = 'profiles' | 'assistant' | 'appearance' | 'server'

const CONFLICT_CODES = ['profile_conflict', 'revision_conflict']

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function isStaleStateConflict(error: unknown): boolean {
  return error instanceof APIError && CONFLICT_CODES.includes(error.code)
}

function colorSchemeLabel(option: string): string {
  return option.charAt(0).toUpperCase() + option.slice(1)
}

/** Mirrors the native S3 editor validation so the form fails fast before a round trip. */
export function SettingsView(props: { profileKey: string; profileName: string; onHostChange: () => void }) {
  const [configuration, { refetch }] = createResource(() => props.profileKey, () => configurationClient.get())
  const [messages, setMessages] = createSignal<Partial<Record<SettingsSection, string>>>({})
  const [errors, setErrors] = createSignal<Partial<Record<SettingsSection, boolean>>>({})
  const [conflicts, setConflicts] = createSignal<Partial<Record<SettingsSection, boolean>>>({})
  const [saving, setSaving] = createSignal<SettingsSection>()
  const [portConfirmation, setPortConfirmation] = createSignal('')
  const [selectedVendor, setSelectedVendor] = createSignal('')
  const [selectedModel, setSelectedModel] = createSignal('')
  const [profileName, setProfileName] = createSignal('')
  createEffect(() => {
    setSelectedVendor(configuration()?.assistant.vendor ?? '')
    setSelectedModel(configuration()?.assistant.model ?? '')
  })
  const selectedModels = createMemo(() => configuration()?.assistant.modelCatalogs
    .find((catalog) => catalog.vendor === selectedVendor())?.models ?? [])
  const selectVendor = (vendor: string) => {
    setSelectedVendor(vendor)
    setSelectedModel(configuration()?.assistant.modelCatalogs.find((catalog) => catalog.vendor === vendor)?.models[0] ?? '')
  }


  const runMutation = async (section: SettingsSection, action: () => Promise<void>, success: string) => {
    setSaving(section); setMessages((value) => ({ ...value, [section]: '' })); setErrors((value) => ({ ...value, [section]: false })); setConflicts((value) => ({ ...value, [section]: false }))
    try {
      await action()
      setMessages((value) => ({ ...value, [section]: success }))
    } catch (error) {
      const isConflict = isStaleStateConflict(error)
      setErrors((value) => ({ ...value, [section]: true })); setConflicts((value) => ({ ...value, [section]: isConflict }))
      setMessages((value) => ({ ...value, [section]: isConflict ? 'Changed elsewhere — refresh before saving again.' : errorMessage(error) }))
    } finally { setSaving(undefined) }
  }

  const saveAssistant = async (form: HTMLFormElement) => {
    const data = new FormData(form)
    await runMutation('assistant', async () => {
      const current = configuration()
      if (!current) throw new Error('Configuration is still loading.')
      await configurationClient.updateAssistant(current, {
        assistance: String(data.get('assistance') ?? ''),
        vendor: String(data.get('vendor') ?? ''),
        model: selectedModel(),
      })
      await refetch()
    }, 'Assistant settings saved.')
  }
  const saveAppearance = async (colorScheme: string) => {
    await runMutation('appearance', async () => {
      const current = configuration()
      if (!current) throw new Error('Configuration is still loading.')
      await configurationClient.updateAppearance(current, colorScheme)
      await refetch()
    }, `Native windows switched to ${colorSchemeLabel(colorScheme)}.`)
  }
  const saveServer = async (form: HTMLFormElement) => {
    const data = new FormData(form)
    const port = Number(data.get('port'))
    if (port !== configuration()?.server.configuredPort && portConfirmation() !== 'CHANGE PORT') {
      setErrors((value) => ({ ...value, server: true }))
      setMessages((value) => ({ ...value, server: 'Type CHANGE PORT to confirm that this page may become unreachable.' }))
      return
    }
    await runMutation('server', async () => {
      const current = configuration()
      if (!current) throw new Error('Configuration is still loading.')
      await configurationClient.updateHTTPServer(current, port)
      setPortConfirmation(''); await refetch(); props.onHostChange()
    }, 'Server port saved. Restart from the Riela menu to apply it.')
  }
  const createProfile = async () => {
    await runMutation('profiles', async () => {
      const current = configuration()
      if (!current) throw new Error('Configuration is still loading.')
      await configurationClient.createProfile(current, profileName())
      setProfileName(''); await refetch()
    }, 'Profile created.')
  }
  const removeProfile = async (name: string) => {
    await runMutation('profiles', async () => {
      const current = configuration()
      if (!current) throw new Error('Configuration is still loading.')
      await configurationClient.removeProfile(current, name)
      await refetch()
    }, `Profile ${name} removed.`)
  }
  const switchProfile = async (name: string) => {
    await runMutation('profiles', async () => {
      const current = configuration()
      if (!current) throw new Error('Configuration is still loading.')
      await configurationClient.switchProfile(current, name)
      props.onHostChange()
    }, `Switched to ${name}.`)
  }

  const refresh = (_section: SettingsSection) => {
    void refetch()
  }
  const SectionMessage = (section: SettingsSection) => <Show when={messages()[section]}>{(message) => <MutationMessage message={message()} isError={errors()[section]} onRefresh={conflicts()[section] ? () => refresh(section) : undefined} />}</Show>

  return <section class="page"><PageHeader eyebrow="PREFERENCES" title="Settings" description="The same persisted profile and application settings used by the native app." />
    <div class="settings-stack">
      <Show when={configuration.loading}><LoadingState label="Loading configuration…" /></Show><Show when={configuration.error}><ErrorBanner message={errorMessage(configuration.error)} /></Show>
      <Show when={configuration()}>{(value) => <div class="panel settings-panel"><div class="section-title"><div><h2>Profiles</h2><p>Create, select, and remove persisted RielaApp profiles.</p></div></div><div class="requirements"><For each={value().profiles}>{(name) => <div class="requirement-row"><div><strong>{name}</strong><span>{name === value().profile ? 'Active profile' : 'Inactive profile'}</span></div><div class="refresh-actions"><Show when={name !== value().profile}><button class="secondary" disabled={saving() === 'profiles'} onClick={() => void switchProfile(name)}>Switch</button></Show><button class="secondary" disabled={saving() === 'profiles' || name === 'default' || name === value().profile} onClick={() => void removeProfile(name)}>Remove</button></div></div>}</For></div><div class="form-grid"><label><span>New profile</span><input value={profileName()} onInput={(event) => setProfileName(event.currentTarget.value)} /></label></div><div class="save-row">{SectionMessage('profiles')}<button disabled={saving() === 'profiles' || !profileName().trim()} onClick={() => void createProfile()}>Create profile</button></div></div>}</Show>
      <Show when={configuration()?.assistant}>{(value) => <form class="panel settings-panel" onSubmit={(event) => { event.preventDefault(); void saveAssistant(event.currentTarget) }}><div class="section-title"><div><h2>Assistant</h2><p>Guidance and model selection. API model lists come from agent-gateway.</p></div></div><label><span>Assistance</span><textarea name="assistance" rows="4">{value().assistance}</textarea></label><div class="form-grid"><label><span>Vendor</span><select name="vendor" value={selectedVendor()} onChange={(event) => selectVendor(event.currentTarget.value)}><option value="openai-api">OpenAI API</option><option value="anthropic-api">Anthropic API</option><option value="cursor-api">Cursor API</option><option value="codex-cli">Codex CLI</option><option value="claude-code-cli">Claude Code CLI</option><option value="cursor-cli">Cursor CLI</option></select></label><label><span>Model</span><select name="model" value={selectedModel()} onChange={(event) => setSelectedModel(event.currentTarget.value)}><For each={selectedModels()}>{(model) => <option value={model}>{model}</option>}</For></select></label></div><div class="save-row">{SectionMessage('assistant')}<button disabled={saving() === 'assistant'}>{saving() === 'assistant' ? 'Saving…' : 'Save assistant'}</button></div></form>}</Show>

      <Show when={configuration()?.appearance}>{(value) => <div class="panel settings-panel">
        <div class="section-title"><div><h2>Appearance</h2><p>Color scheme for the native Riela windows. This page keeps its own dark theme.</p></div></div>
        <div class="form-grid"><label><span>Native window appearance</span><select disabled={saving() === 'appearance'} value={value().colorScheme} onChange={(event) => void saveAppearance(event.currentTarget.value)}><For each={value().options}>{(option) => <option value={option}>{colorSchemeLabel(option)}</option>}</For></select></label></div>
        <div class="save-row">{SectionMessage('appearance')}</div>
      </div>}</Show>

      <Show when={configuration()?.server}>{(value) => <form class="panel settings-panel" onSubmit={(event) => { event.preventDefault(); void saveServer(event.currentTarget) }}><div class="section-title"><div><h2>Web Config server</h2><p>Optional loopback listener hosted by RielaApp. The app continues running when it is stopped.</p></div><span class={`status-chip ${value().state}`}>{value().state}</span></div><div class="form-grid"><label><span>Configured port</span><input name="port" type="number" min="1" max="65535" value={value().configuredPort} /></label><label><span>Bound endpoint</span><input disabled value={value().boundPort ? `127.0.0.1:${value().boundPort}` : 'Not running'} /></label></div><div class="confirmation-box"><strong>Changing the port makes this page unreachable until you open the new address.</strong><span>Restart or recover Web Config from the Riela menu-bar app. Type CHANGE PORT before saving a different port.</span><label><span>Port-change confirmation</span><input value={portConfirmation()} onInput={(event) => setPortConfirmation(event.currentTarget.value)} placeholder="CHANGE PORT" /></label></div><Show when={value().restartRequired}><p class="restart-notice">Restart required from the Riela menu-bar app.</p></Show><div class="save-row">{SectionMessage('server')}<button disabled={saving() === 'server'}>{saving() === 'server' ? 'Saving…' : 'Save server'}</button></div></form>}</Show>
    </div>
  </section>
}
