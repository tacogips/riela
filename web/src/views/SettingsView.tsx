import { For, Show, createResource, createSignal } from 'solid-js'
import { APIError, api, requireExpectedProfile } from '../api'
import type {
  AppearanceSettings,
  AssistantSettings,
  NoteClientRegistration,
  NoteClientsResponse,
  NoteS3Profile,
  NoteSettings,
  WebServerSettings,
} from '../contracts'
import { ErrorBanner, LoadingState, MutationMessage, PageHeader } from '../components/Primitives'
import { QRCodeSVG } from '../components/QRCode'
import '../settings-extra.css'

type SettingsSection = 'assistant' | 'notes' | 'storage' | 'clients' | 'appearance' | 'server'

const CONFLICT_CODES = ['profile_conflict', 'revision_conflict']

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function isStaleStateConflict(error: unknown): boolean {
  return error instanceof APIError && error.status === 409 && CONFLICT_CODES.includes(error.code)
}

function colorSchemeLabel(option: string): string {
  return option.charAt(0).toUpperCase() + option.slice(1)
}

/** Mirrors the native S3 editor validation so the form fails fast before a round trip. */
export function validateS3Profile(draft: NoteS3Profile): string | undefined {
  if (!draft.name || !draft.endpoint || !draft.region || !draft.bucket) {
    return 'name, endpoint, region, and bucket are required.'
  }
  try { new URL(draft.endpoint) } catch { return 'endpoint must be a valid URL.' }
  if (!draft.accessKeyIdEnv || !draft.secretAccessKeyEnv) {
    return 'access key and secret key environment variable names are required.'
  }
  return undefined
}

export function s3ProfileFromForm(data: FormData): NoteS3Profile {
  const field = (name: string) => String(data.get(name) ?? '').trim()
  const sessionTokenEnv = field('sessionTokenEnv')
  return {
    name: field('name'),
    endpoint: field('endpoint'),
    region: field('region'),
    bucket: field('bucket'),
    accessKeyIdEnv: field('accessKeyIdEnv'),
    secretAccessKeyEnv: field('secretAccessKeyEnv'),
    sessionTokenEnv: sessionTokenEnv === '' ? null : sessionTokenEnv,
    keyPrefix: field('keyPrefix'),
  }
}

export function SettingsView(props: { profileKey: string; profileName: string; onServerChange: () => void }) {
  const [assistant, { refetch: refetchAssistant }] = createResource(
    () => props.profileKey,
    async () => requireExpectedProfile(
      await api.get<AssistantSettings>('/api/v1/settings/assistant'),
      props.profileName,
    ),
  )
  const [notes, { refetch: refetchNotes }] = createResource(
    () => props.profileKey,
    async () => requireExpectedProfile(
      await api.get<NoteSettings>('/api/v1/settings/notes'),
      props.profileName,
    ),
  )
  const [clients, { refetch: refetchClients }] = createResource(
    () => props.profileKey,
    async () => requireExpectedProfile(
      await api.get<NoteClientsResponse>('/api/v1/settings/notes/clients'),
      props.profileName,
    ),
  )
  const [appearance, { refetch: refetchAppearance }] = createResource(
    () => props.profileKey,
    async () => requireExpectedProfile(
      await api.get<AppearanceSettings>('/api/v1/settings/appearance'),
      props.profileName,
    ),
  )
  const [server, { refetch: refetchServer }] = createResource(() => api.get<WebServerSettings>('/api/v1/settings/web-server'))
  const [messages, setMessages] = createSignal<Partial<Record<SettingsSection, string>>>({})
  const [errors, setErrors] = createSignal<Partial<Record<SettingsSection, boolean>>>({})
  const [conflicts, setConflicts] = createSignal<Partial<Record<SettingsSection, boolean>>>({})
  const [saving, setSaving] = createSignal<SettingsSection>()
  const [portConfirmation, setPortConfirmation] = createSignal('')
  const [registration, setRegistration] = createSignal<NoteClientRegistration>()
  const [revoking, setRevoking] = createSignal<string>()

  const setSectionError = (section: SettingsSection, message: string) => {
    setErrors((value) => ({ ...value, [section]: true }))
    setConflicts((value) => ({ ...value, [section]: false }))
    setMessages((value) => ({ ...value, [section]: message }))
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
      requireExpectedProfile(
        await api.mutate<AssistantSettings>('/api/v1/settings/assistant', 'PUT', {
          assistance: data.get('assistance'),
          vendor: data.get('vendor'),
          model: data.get('model'),
          expectedProfile: props.profileName,
        }),
        props.profileName,
      )
      void refetchAssistant()
    }, 'Assistant settings saved.')
  }
  const saveNotes = async (form: HTMLFormElement) => {
    const data = new FormData(form)
    await runMutation('notes', async () => {
      requireExpectedProfile(
        await api.mutate<NoteSettings>('/api/v1/settings/notes', 'PUT', {
          exposesNoteAPI: data.get('exposesNoteAPI') === 'on',
          expectedProfile: props.profileName,
        }),
        props.profileName,
      )
      void refetchNotes()
    }, 'Note settings saved.')
  }
  const putS3Profiles = async (s3Profiles: NoteS3Profile[], success: string) => {
    await runMutation('storage', async () => {
      requireExpectedProfile(
        await api.mutate<NoteSettings>('/api/v1/settings/notes', 'PUT', {
          s3Profiles,
          expectedProfile: props.profileName,
        }),
        props.profileName,
      )
      void refetchNotes()
    }, success)
  }
  const saveS3Profile = async (form: HTMLFormElement) => {
    const draft = s3ProfileFromForm(new FormData(form))
    const invalid = validateS3Profile(draft)
    if (invalid) { setSectionError('storage', invalid); return }
    await putS3Profiles([draft], `Saved S3 profile ${draft.name}.`)
  }
  const clearS3Profiles = async () => {
    await putS3Profiles([], 'Removed saved S3 profiles for this note profile.')
  }
  const registerClient = async () => {
    await runMutation('clients', async () => {
      const challenge = requireExpectedProfile(
        await api.mutate<NoteClientRegistration>('/api/v1/settings/notes/clients/registrations', 'POST', {
          expectedProfile: props.profileName,
        }),
        props.profileName,
      )
      setRegistration(challenge)
      void refetchClients()
    }, 'Scan the QR code or enter the code from the client app.')
  }
  const revokeClient = async (clientId: string, displayName: string) => {
    setRevoking(clientId)
    await runMutation('clients', async () => {
      requireExpectedProfile(
        await api.mutate<{ profile: string; revision: number }>(
          `/api/v1/settings/notes/clients/${encodeURIComponent(clientId)}`,
          'DELETE',
          { expectedProfile: props.profileName },
        ),
        props.profileName,
      )
      void refetchClients()
    }, `Revoked ${displayName}.`)
    setRevoking(undefined)
  }
  const copyRegistrationURL = async (registrationURL: string) => {
    try {
      await navigator.clipboard.writeText(registrationURL)
      setMessages((value) => ({ ...value, clients: 'Registration URL copied.' }))
      setErrors((value) => ({ ...value, clients: false }))
    } catch (error) {
      setSectionError('clients', `Could not copy the URL: ${errorMessage(error)}`)
    }
  }
  const saveAppearance = async (colorScheme: string) => {
    await runMutation('appearance', async () => {
      requireExpectedProfile(
        await api.mutate<AppearanceSettings>('/api/v1/settings/appearance', 'PUT', { colorScheme }),
        props.profileName,
      )
      void refetchAppearance()
    }, `Native windows switched to ${colorSchemeLabel(colorScheme)}.`)
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
    if (section === 'notes' || section === 'storage') void refetchNotes()
    if (section === 'clients') void refetchClients()
    if (section === 'appearance') void refetchAppearance()
    if (section === 'server') void refetchServer()
  }
  const SectionMessage = (section: SettingsSection) => <Show when={messages()[section]}>{(message) => <MutationMessage message={message()} isError={errors()[section]} onRefresh={conflicts()[section] ? () => refresh(section) : undefined} />}</Show>

  const storedProfile = () => notes()?.s3Profiles?.[0]

  return <section class="page"><PageHeader eyebrow="PREFERENCES" title="Settings" description="The same persisted profile and application settings used by the native app." />
    <div class="settings-stack">
      <Show when={assistant.loading}><LoadingState label="Loading assistant settings…" /></Show><Show when={assistant.error}><ErrorBanner message={errorMessage(assistant.error)} /></Show>
      <Show when={assistant()}>{(value) => <form class="panel settings-panel" onSubmit={(event) => { event.preventDefault(); void saveAssistant(event.currentTarget) }}><div class="section-title"><div><h2>Assistant</h2><p>Guidance and model selection. Conversation history is never exposed here.</p></div></div><label><span>Assistance</span><textarea name="assistance" rows="4">{value().assistance}</textarea></label><div class="form-grid"><label><span>Vendor</span><select name="vendor" value={value().vendor}><option value="openai-api">OpenAI API</option><option value="anthropic-api">Anthropic API</option><option value="codex-cli">Codex CLI</option><option value="claude-code-cli">Claude Code CLI</option><option value="cursor-cli">Cursor CLI</option></select></label><label><span>Model</span><input name="model" value={value().model} /></label></div><div class="save-row">{SectionMessage('assistant')}<button disabled={saving() === 'assistant'}>{saving() === 'assistant' ? 'Saving…' : 'Save assistant'}</button></div></form>}</Show>

      <Show when={notes.loading}><LoadingState label="Loading note settings…" /></Show><Show when={notes.error}><ErrorBanner message={errorMessage(notes.error)} /></Show>
      <Show when={notes()}>{(value) => <form class="panel settings-panel" onSubmit={(event) => { event.preventDefault(); void saveNotes(event.currentTarget) }}><div class="section-title"><div><h2>Notes</h2><p>Note API exposure for this profile.</p></div><span>{value().s3ProfileCount} S3 profiles</span></div><Show when={value().noteRoot}>{(root) => <label><span>Note root</span><input disabled value={root()} /></label>}</Show><label class="check-row"><input type="checkbox" name="exposesNoteAPI" checked={value().exposesNoteAPI} /><span>Expose Note API for served workflows</span></label><div class="save-row">{SectionMessage('notes')}<button disabled={saving() === 'notes'}>{saving() === 'notes' ? 'Saving…' : 'Save notes'}</button></div></form>}</Show>

      <Show when={notes()}>{(value) => <form class="panel settings-panel" onSubmit={(event) => { event.preventDefault(); void saveS3Profile(event.currentTarget) }}>
        <div class="section-title"><div><h2>S3 storage profile</h2><p>Credentials are referenced by environment variable name and are never stored here.</p></div><span>{value().s3ProfileCount === 0 ? 'No profile saved' : 'Profile saved'}</span></div>
        <div class="form-grid">
          <label><span>Name</span><input name="name" value={storedProfile()?.name ?? 'default-s3'} placeholder="default-s3" /></label>
          <label><span>Endpoint</span><input name="endpoint" value={storedProfile()?.endpoint ?? ''} placeholder="https://s3.example.com" /></label>
          <label><span>Region</span><input name="region" value={storedProfile()?.region ?? ''} placeholder="ap-northeast-1" /></label>
          <label><span>Bucket</span><input name="bucket" value={storedProfile()?.bucket ?? ''} placeholder="bucket-name" /></label>
          <label><span>Key prefix</span><input name="keyPrefix" value={storedProfile()?.keyPrefix ?? ''} placeholder="profiles/default" /></label>
          <label><span>Access key env</span><input name="accessKeyIdEnv" value={storedProfile()?.accessKeyIdEnv ?? ''} placeholder="AWS_ACCESS_KEY_ID" /></label>
          <label><span>Secret env</span><input name="secretAccessKeyEnv" value={storedProfile()?.secretAccessKeyEnv ?? ''} placeholder="AWS_SECRET_ACCESS_KEY" /></label>
          <label><span>Session env</span><input name="sessionTokenEnv" value={storedProfile()?.sessionTokenEnv ?? ''} placeholder="AWS_SESSION_TOKEN" /></label>
        </div>
        <div class="save-row">{SectionMessage('storage')}<div class="button-row"><button type="button" class="secondary" disabled={saving() === 'storage'} onClick={() => void clearS3Profiles()}>Clear</button><button disabled={saving() === 'storage'}>{saving() === 'storage' ? 'Saving…' : 'Save profile'}</button></div></div>
      </form>}</Show>

      <Show when={clients.loading}><LoadingState label="Loading registered clients…" /></Show><Show when={clients.error}><ErrorBanner message={errorMessage(clients.error)} /></Show>
      <Show when={clients()}>{(value) => <div class="panel settings-panel">
        <div class="section-title"><div><h2>Registered clients</h2><p>Note API clients paired with this profile. Tokens are shown only while registering.</p></div><button type="button" disabled={saving() === 'clients'} onClick={() => void registerClient()}>{saving() === 'clients' ? 'Working…' : 'Register client'}</button></div>
        <Show when={registration()}>{(challenge) => <div class="registration-card">
          <QRCodeSVG text={challenge().qrText} size={200} />
          <div class="registration-detail">
            <span class="registration-code">{challenge().code}</span>
            <p class="registration-url" title={challenge().registrationURL}>{challenge().registrationURL}</p>
            <span class="registration-expiry">Expires at {challenge().expiresAt}</span>
            <div class="button-row"><button type="button" class="secondary" onClick={() => void copyRegistrationURL(challenge().registrationURL)}>Copy URL</button><button type="button" class="secondary" onClick={() => setRegistration(undefined)}>Done</button></div>
          </div>
        </div>}</Show>
        <Show when={value().items.length > 0} fallback={<p class="client-empty">No registered clients.</p>}>
          <For each={value().items}>{(client) => <div class="list-row client-row">
            <div><strong>{client.displayName}</strong><span>Created {client.createdAt} — {client.clientId}</span></div>
            <button type="button" class="secondary" disabled={revoking() === client.clientId} onClick={() => void revokeClient(client.clientId, client.displayName)}>{revoking() === client.clientId ? 'Revoking…' : 'Revoke'}</button>
          </div>}</For>
        </Show>
        <div class="save-row">{SectionMessage('clients')}</div>
      </div>}</Show>

      <Show when={appearance.error}><ErrorBanner message={errorMessage(appearance.error)} /></Show>
      <Show when={appearance()}>{(value) => <div class="panel settings-panel">
        <div class="section-title"><div><h2>Appearance</h2><p>Color scheme for the native Riela windows. This page keeps its own dark theme.</p></div></div>
        <div class="form-grid"><label><span>Native window appearance</span><select disabled={saving() === 'appearance'} value={value().colorScheme} onChange={(event) => void saveAppearance(event.currentTarget.value)}><For each={value().options}>{(option) => <option value={option}>{colorSchemeLabel(option)}</option>}</For></select></label></div>
        <div class="save-row">{SectionMessage('appearance')}</div>
      </div>}</Show>

      <Show when={server.loading}><LoadingState label="Loading web server settings…" /></Show><Show when={server.error}><ErrorBanner message={errorMessage(server.error)} /></Show>
      <Show when={server()}>{(value) => <form class="panel settings-panel" onSubmit={(event) => { event.preventDefault(); void saveServer(event.currentTarget) }}><div class="section-title"><div><h2>Web server</h2><p>Loopback-only listener managed from the Riela menu.</p></div><span class={`status-chip ${value().state}`}>{value().state}</span></div><div class="form-grid"><label><span>Configured port</span><input name="port" type="number" min="1" max="65535" value={value().configuredPort} /></label><label><span>Bound endpoint</span><input disabled value={value().boundPort ? `127.0.0.1:${value().boundPort}` : 'Not running'} /></label></div><div class="confirmation-box"><strong>Changing the port makes this page unreachable until you open the new address.</strong><span>Restart or recover the server from the Riela menu-bar app. Type CHANGE PORT before saving a different port.</span><label><span>Port-change confirmation</span><input value={portConfirmation()} onInput={(event) => setPortConfirmation(event.currentTarget.value)} placeholder="CHANGE PORT" /></label></div><Show when={value().restartRequired}><p class="restart-notice">Restart required from the Riela menu-bar app.</p></Show><div class="save-row">{SectionMessage('server')}<button disabled={saving() === 'server'}>{saving() === 'server' ? 'Saving…' : 'Save server'}</button></div></form>}</Show>
    </div>
  </section>
}
