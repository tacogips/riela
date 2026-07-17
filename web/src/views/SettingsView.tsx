import { createResource, createSignal } from 'solid-js'
import { api } from '../api'
import type { AssistantSettings, NoteSettings, WebServerSettings } from '../contracts'
import { PageHeader } from '../components/Primitives'

export function SettingsView(props: { onServerChange: () => void }) {
  const [assistant, { refetch: refetchAssistant }] = createResource(() => api.get<AssistantSettings>('/api/v1/settings/assistant'))
  const [notes, { refetch: refetchNotes }] = createResource(() => api.get<NoteSettings>('/api/v1/settings/notes'))
  const [server, { refetch: refetchServer }] = createResource(() => api.get<WebServerSettings>('/api/v1/settings/web-server'))
  const [message, setMessage] = createSignal('')

  const saveAssistant = async (form: HTMLFormElement) => {
    const data = new FormData(form)
    await api.mutate('/api/v1/settings/assistant', 'PUT', { assistance: data.get('assistance'), vendor: data.get('vendor'), model: data.get('model') })
    setMessage('Assistant settings saved'); void refetchAssistant()
  }
  const saveNotes = async (form: HTMLFormElement) => {
    const data = new FormData(form)
    await api.mutate('/api/v1/settings/notes', 'PUT', { exposesNoteAPI: data.get('exposesNoteAPI') === 'on', defaultTranslationTargetLanguage: data.get('language') })
    setMessage('Note settings saved'); void refetchNotes()
  }
  const saveServer = async (form: HTMLFormElement) => {
    const data = new FormData(form)
    await api.mutate('/api/v1/settings/web-server', 'PUT', { port: Number(data.get('port')) })
    setMessage('Server port saved. Restart from the menu to apply it.'); void refetchServer(); props.onServerChange()
  }

  return <section class="page"><PageHeader eyebrow="PREFERENCES" title="Settings" description="The same persisted profile and application settings used by the native app." />
    <div class="settings-stack"><form class="panel settings-panel" onSubmit={(event) => { event.preventDefault(); void saveAssistant(event.currentTarget) }}><div class="section-title"><div><h2>Assistant</h2><p>Guidance and model selection. Conversation history is never exposed here.</p></div></div><label><span>Assistance</span><textarea name="assistance" rows="4">{assistant()?.assistance}</textarea></label><div class="form-grid"><label><span>Vendor</span><select name="vendor" value={assistant()?.vendor}><option value="openai-api">OpenAI API</option><option value="anthropic-api">Anthropic API</option><option value="codex-cli">Codex CLI</option><option value="claude-code-cli">Claude Code CLI</option><option value="cursor-cli">Cursor CLI</option></select></label><label><span>Model</span><input name="model" value={assistant()?.model ?? ''} /></label></div><div class="save-row"><span /><button>Save assistant</button></div></form>
      <form class="panel settings-panel" onSubmit={(event) => { event.preventDefault(); void saveNotes(event.currentTarget) }}><div class="section-title"><div><h2>Notes</h2><p>Note API exposure and translation defaults for this profile.</p></div><span>{notes()?.s3ProfileCount ?? 0} S3 profiles</span></div><label class="check-row"><input type="checkbox" name="exposesNoteAPI" checked={notes()?.exposesNoteAPI} /><span>Expose Note API for served workflows</span></label><label><span>Translation target</span><input name="language" value={notes()?.defaultTranslationTargetLanguage ?? ''} /></label><div class="save-row"><span /><button>Save notes</button></div></form>
      <form class="panel settings-panel" onSubmit={(event) => { event.preventDefault(); void saveServer(event.currentTarget) }}><div class="section-title"><div><h2>Web server</h2><p>Loopback-only listener managed from the Riela menu.</p></div><span class="status-chip">{server()?.state}</span></div><div class="form-grid"><label><span>Configured port</span><input name="port" type="number" min="1" max="65535" value={server()?.configuredPort ?? 19091} /></label><label><span>Bound endpoint</span><input disabled value={server()?.boundPort ? `127.0.0.1:${server()?.boundPort}` : 'Not running'} /></label></div><div class="save-row"><span>{server()?.restartRequired ? 'Restart required' : message()}</span><button>Save server</button></div></form>
    </div>
  </section>
}
