import { Show, createResource, createSignal } from 'solid-js'
import { APIError, api } from '../api'
import type { AssistantSettings, NoteSettings, WebServerSettings } from '../contracts'
import { ErrorBanner, LoadingState, MutationMessage, PageHeader } from '../components/Primitives'

type SettingsSection = 'assistant' | 'notes' | 'server'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function SettingsView(props: { onServerChange: () => void }) {
  const [assistant, { refetch: refetchAssistant }] = createResource(() => api.get<AssistantSettings>('/api/v1/settings/assistant'))
  const [notes, { refetch: refetchNotes }] = createResource(() => api.get<NoteSettings>('/api/v1/settings/notes'))
  const [server, { refetch: refetchServer }] = createResource(() => api.get<WebServerSettings>('/api/v1/settings/web-server'))
  const [messages, setMessages] = createSignal<Partial<Record<SettingsSection, string>>>({})
  const [errors, setErrors] = createSignal<Partial<Record<SettingsSection, boolean>>>({})
  const [conflicts, setConflicts] = createSignal<Partial<Record<SettingsSection, boolean>>>({})
  const [saving, setSaving] = createSignal<SettingsSection>()
  const [portConfirmation, setPortConfirmation] = createSignal('')

  const runMutation = async (section: SettingsSection, action: () => Promise<void>, success: string) => {
    setSaving(section); setMessages((value) => ({ ...value, [section]: '' })); setErrors((value) => ({ ...value, [section]: false })); setConflicts((value) => ({ ...value, [section]: false }))
    try {
      await action()
      setMessages((value) => ({ ...value, [section]: success }))
    } catch (error) {
      const isConflict = error instanceof APIError && error.status === 409
      setErrors((value) => ({ ...value, [section]: true })); setConflicts((value) => ({ ...value, [section]: isConflict }))
      setMessages((value) => ({ ...value, [section]: isConflict ? 'Changed elsewhere — refresh before saving again.' : errorMessage(error) }))
    } finally { setSaving(undefined) }
  }

  const saveAssistant = async (form: HTMLFormElement) => {
    const data = new FormData(form)
    await runMutation('assistant', async () => {
      await api.mutate('/api/v1/settings/assistant', 'PUT', { assistance: data.get('assistance'), vendor: data.get('vendor'), model: data.get('model') })
      void refetchAssistant()
    }, 'Assistant settings saved.')
  }
  const saveNotes = async (form: HTMLFormElement) => {
    const data = new FormData(form)
    await runMutation('notes', async () => {
      await api.mutate('/api/v1/settings/notes', 'PUT', { exposesNoteAPI: data.get('exposesNoteAPI') === 'on', defaultTranslationTargetLanguage: data.get('language') })
      void refetchNotes()
    }, 'Note settings saved.')
  }
  const saveServer = async (form: HTMLFormElement) => {
    const data = new FormData(form)
    const port = Number(data.get('port'))
    if (port !== server()?.configuredPort && portConfirmation() !== 'CHANGE PORT') {
      setErrors((value) => ({ ...value, server: true }))
      setMessages((value) => ({ ...value, server: 'Type CHANGE PORT to confirm that this page may become unreachable.' }))
      return
    }
    await runMutation('server', async () => {
      await api.mutate('/api/v1/settings/web-server', 'PUT', { port })
      setPortConfirmation(''); void refetchServer(); props.onServerChange()
    }, 'Server port saved. Restart from the Riela menu to apply it.')
  }

  const refresh = (section: SettingsSection) => {
    if (section === 'assistant') void refetchAssistant()
    if (section === 'notes') void refetchNotes()
    if (section === 'server') void refetchServer()
  }
  const SectionMessage = (section: SettingsSection) => <Show when={messages()[section]}>{(message) => <MutationMessage message={message()} isError={errors()[section]} onRefresh={conflicts()[section] ? () => refresh(section) : undefined} />}</Show>

  return <section class="page"><PageHeader eyebrow="PREFERENCES" title="Settings" description="The same persisted profile and application settings used by the native app." />
    <div class="settings-stack">
      <Show when={assistant.loading}><LoadingState label="Loading assistant settings…" /></Show><Show when={assistant.error}><ErrorBanner message={errorMessage(assistant.error)} /></Show>
      <Show when={assistant()}>{(value) => <form class="panel settings-panel" onSubmit={(event) => { event.preventDefault(); void saveAssistant(event.currentTarget) }}><div class="section-title"><div><h2>Assistant</h2><p>Guidance and model selection. Conversation history is never exposed here.</p></div></div><label><span>Assistance</span><textarea name="assistance" rows="4">{value().assistance}</textarea></label><div class="form-grid"><label><span>Vendor</span><select name="vendor" value={value().vendor}><option value="openai-api">OpenAI API</option><option value="anthropic-api">Anthropic API</option><option value="codex-cli">Codex CLI</option><option value="claude-code-cli">Claude Code CLI</option><option value="cursor-cli">Cursor CLI</option></select></label><label><span>Model</span><input name="model" value={value().model} /></label></div><div class="save-row">{SectionMessage('assistant')}<button disabled={saving() === 'assistant'}>{saving() === 'assistant' ? 'Saving…' : 'Save assistant'}</button></div></form>}</Show>

      <Show when={notes.loading}><LoadingState label="Loading note settings…" /></Show><Show when={notes.error}><ErrorBanner message={errorMessage(notes.error)} /></Show>
      <Show when={notes()}>{(value) => <form class="panel settings-panel" onSubmit={(event) => { event.preventDefault(); void saveNotes(event.currentTarget) }}><div class="section-title"><div><h2>Notes</h2><p>Note API exposure and translation defaults for this profile.</p></div><span>{value().s3ProfileCount} S3 profiles</span></div><label class="check-row"><input type="checkbox" name="exposesNoteAPI" checked={value().exposesNoteAPI} /><span>Expose Note API for served workflows</span></label><label><span>Translation target</span><input name="language" value={value().defaultTranslationTargetLanguage} /></label><div class="save-row">{SectionMessage('notes')}<button disabled={saving() === 'notes'}>{saving() === 'notes' ? 'Saving…' : 'Save notes'}</button></div></form>}</Show>

      <Show when={server.loading}><LoadingState label="Loading web server settings…" /></Show><Show when={server.error}><ErrorBanner message={errorMessage(server.error)} /></Show>
      <Show when={server()}>{(value) => <form class="panel settings-panel" onSubmit={(event) => { event.preventDefault(); void saveServer(event.currentTarget) }}><div class="section-title"><div><h2>Web server</h2><p>Loopback-only listener managed from the Riela menu.</p></div><span class={`status-chip ${value().state}`}>{value().state}</span></div><div class="form-grid"><label><span>Configured port</span><input name="port" type="number" min="1" max="65535" value={value().configuredPort} /></label><label><span>Bound endpoint</span><input disabled value={value().boundPort ? `127.0.0.1:${value().boundPort}` : 'Not running'} /></label></div><div class="confirmation-box"><strong>Changing the port makes this page unreachable until you open the new address.</strong><span>Restart or recover the server from the Riela menu-bar app. Type CHANGE PORT before saving a different port.</span><label><span>Port-change confirmation</span><input value={portConfirmation()} onInput={(event) => setPortConfirmation(event.currentTarget.value)} placeholder="CHANGE PORT" /></label></div><Show when={value().restartRequired}><p class="restart-notice">Restart required from the Riela menu-bar app.</p></Show><div class="save-row">{SectionMessage('server')}<button disabled={saving() === 'server'}>{saving() === 'server' ? 'Saving…' : 'Save server'}</button></div></form>}</Show>
    </div>
  </section>
}
