import { For, Match, Show, Switch, createEffect, createMemo, createSignal, onCleanup, onMount } from 'solid-js'
import { APIError, api } from './api'
import { NotebookExpansionPanel } from './components/NotebookExpansionPanel'
import type { Bootstrap } from './contracts'
import type { HostMode } from './notes/types'
import { createPollingResource } from './polling'
import { InstancesView } from './views/InstancesView'
import { LogsView } from './views/LogsView'
import { NoteAgentView, type NoteAgentPrefill } from './views/NoteAgentView'
import { NoteConfigAgentView } from './views/NoteConfigAgentView'
import { NotesView } from './views/NotesView'
import { RunDetailView } from './views/RunDetailView'
import { SettingsView } from './views/SettingsView'
import { WorkflowsView } from './views/WorkflowsView'

type NavigationView = 'notes' | 'note-agent' | 'note-config' | 'instances' | 'logs' | 'workflows' | 'settings'
type View = NavigationView | 'run-detail'

export interface ProfileViewTransition {
  clearSelection: boolean
  view: View
}

export function profileViewTransition(
  previousProfileKey: string | undefined,
  nextProfileKey: string,
  mode: HostMode | undefined,
  currentView: View,
): ProfileViewTransition {
  if (mode === 'cli-serve') return { clearSelection: true, view: 'notes' }
  const profileChanged = previousProfileKey !== undefined && previousProfileKey !== nextProfileKey
  return {
    clearSelection: profileChanged,
    view: profileChanged && currentView === 'run-detail' ? 'logs' : currentView,
  }
}

const navigation: Array<{ id: NavigationView; label: string; glyph: string }> = [
  { id: 'notes', label: 'Notes', glyph: '▤' },
  { id: 'note-agent', label: 'Note Agent', glyph: '✱' },
  { id: 'note-config', label: 'Note Config', glyph: '⚙' },
  { id: 'instances', label: 'Instances', glyph: '◇' },
  { id: 'logs', label: 'Run logs', glyph: '≋' },
  { id: 'workflows', label: 'Workflows', glyph: '⌘' },
  { id: 'settings', label: 'Settings', glyph: '◉' },
]

export function App() {
  const [view, setView] = createSignal<View>('instances')
  const [selectedInstanceId, setSelectedInstanceId] = createSignal('')
  const [selectedRun, setSelectedRun] = createSignal<{ sessionId: string; workflowId: string }>()
  const [expansionTarget, setExpansionTarget] = createSignal<{ notebookId: string; notebookTitle: string }>()
  const [agentPrefill, setAgentPrefill] = createSignal<NoteAgentPrefill>()
  const host = createPollingResource(() => 'active-host', discoverHost)
  const profileKey = createMemo(() => host.data()?.bootstrap ? `riela-app:${host.data()!.bootstrap!.profile}` : 'cli-serve')
  const visibleNavigation = createMemo(() => host.data()?.mode === 'cli-serve' ? navigation.filter((item) => item.id === 'notes') : navigation)
  let previousProfileKey: string | undefined
  const restoreRunHash = () => {
    const match = window.location.hash.match(/^#\/runs\/([^/]+)$/)
    if (!match) return
    const sessionId = decodeURIComponent(match[1]!)
    if (!sessionId) return
    setSelectedInstanceId('')
    setSelectedRun({ sessionId, workflowId: 'private workflow' })
    setView('run-detail')
  }
  onMount(() => {
    restoreRunHash()
    window.addEventListener('hashchange', restoreRunHash)
    onCleanup(() => window.removeEventListener('hashchange', restoreRunHash))
  })
  createEffect(() => {
    const nextProfileKey = profileKey()
    const transition = profileViewTransition(previousProfileKey, nextProfileKey, host.data()?.mode, view())
    if (transition.clearSelection) {
      setSelectedInstanceId('')
      setSelectedRun(undefined)
    }
    if (transition.view !== view()) setView(transition.view)
    previousProfileKey = nextProfileKey
  })

  return (
    <div class="app-shell">
      <a class="skip-link" href="#main-content">Skip to content</a>
      <aside class="sidebar">
        <div class="brand">
          <div class="brand-mark">R</div>
          <div><strong>Riela</strong><span>Local control plane</span></div>
        </div>
        <nav aria-label="Primary navigation">
          <For each={visibleNavigation()}>{(item) => (
            <button classList={{ active: view() === item.id || (item.id === 'logs' && view() === 'run-detail') }} aria-current={view() === item.id || (item.id === 'logs' && view() === 'run-detail') ? 'page' : undefined} onClick={() => setView(item.id)}>
              <span class="nav-glyph" aria-hidden="true">{item.glyph}</span>{item.label}
            </button>
          )}</For>
        </nav>
        <div class="server-card" role="status" aria-live="polite">
          <span classList={{ dot: true, live: host.data()?.mode === 'cli-serve' || host.data()?.bootstrap?.server.state === 'running' }} />
          <div><strong>{host.data()?.mode === 'cli-serve' ? 'CLI serve' : host.data()?.bootstrap?.server.state ?? 'Connecting'}</strong><span>{host.data()?.bootstrap?.server.boundPort ? `127.0.0.1:${host.data()?.bootstrap?.server.boundPort}` : 'Local server'}</span></div>
        </div>
      </aside>
      <main id="main-content" tabindex="-1">
        <Show when={host.loading() && !host.data()}><div class="center-state"><span class="loader" />Connecting to Riela…</div></Show>
        <Show when={host.error()}><div class="center-state error-panel"><strong>Could not connect</strong><span>{String(host.error())}</span><button onClick={() => void host.refresh()}>Try again</button></div></Show>
        <Show when={host.data()}>
          <header class="topbar">
            <div><span class="eyebrow">{host.data()?.mode === 'cli-serve' ? 'HOST' : 'PROFILE'}</span><strong>{host.data()?.bootstrap?.profile ?? 'riela serve'}</strong></div>
            <span class="api-pill">{host.data()?.mode === 'cli-serve' ? 'NOTE API' : `API ${host.data()?.bootstrap?.apiVersion}`}</span>
          </header>
          <Switch>
            <Match when={view() === 'notes'}>
              <Show when={profileKey()} keyed>{(_notesProfileKey) =>
                <NotesView
                  mode={host.data()!.mode}
                  profileName={host.data()?.bootstrap?.profile ?? ''}
                  onExpandNotebook={host.data()?.mode === 'riela-app'
                    ? (notebookId, notebookTitle) => setExpansionTarget({ notebookId, notebookTitle })
                    : undefined}
                  onAskAgent={host.data()?.mode === 'riela-app'
                    ? (payload) => {
                      setAgentPrefill({
                        draft: `Ask about ${payload.title}:`,
                        attachment: { name: `${payload.noteId}.md`, content: payload.bodyMarkdown },
                      })
                      setView('note-agent')
                    }
                    : undefined}
                />
              }</Show>
            </Match>
            <Match when={view() === 'note-agent'}>
              <Show when={profileKey()} keyed>{(_agentProfileKey) =>
                <NoteAgentView
                  profileName={host.data()?.bootstrap?.profile ?? ''}
                  prefill={agentPrefill()}
                  onPrefillConsumed={() => setAgentPrefill(undefined)}
                />
              }</Show>
            </Match>
            <Match when={view() === 'note-config'}>
              <Show when={profileKey()} keyed>{(_configProfileKey) =>
                <NoteConfigAgentView profileName={host.data()?.bootstrap?.profile ?? ''} />
              }</Show>
            </Match>
            <Match when={view() === 'instances'}><InstancesView profileKey={profileKey()} profileName={host.data()?.bootstrap?.profile ?? ''} /></Match>
            <Match when={view() === 'logs'}><LogsView profileKey={profileKey()} selectedInstanceId={selectedInstanceId()} onSelectInstance={setSelectedInstanceId} onOpenRun={(execution) => { setSelectedRun({ sessionId: execution.sessionId, workflowId: execution.workflowId }); setView('run-detail') }} /></Match>
            <Match when={view() === 'run-detail' && selectedRun()}><RunDetailView profileKey={profileKey()} instanceId={selectedInstanceId()} sessionId={selectedRun()!.sessionId} workflowId={selectedRun()!.workflowId} onBack={() => setView('logs')} /></Match>
            <Match when={view() === 'workflows'}>
              <Show when={profileKey()} keyed>{(_workflowsProfileKey) =>
                <WorkflowsView
                  profileKey={profileKey()}
                  profileName={host.data()?.bootstrap?.profile ?? ''}
                />
              }</Show>
            </Match>
            <Match when={view() === 'settings'}>
              <Show when={profileKey()} keyed>{(_settingsProfileKey) =>
                <SettingsView
                  profileKey={profileKey()}
                  profileName={host.data()?.bootstrap?.profile ?? ''}
                  onServerChange={() => void host.refresh()}
                />
              }</Show>
            </Match>
          </Switch>
          <Show when={expansionTarget()}>{(target) => (
            <div class="expansion-overlay" role="dialog" aria-label={`Notebook expansion for ${target().notebookTitle}`}>
              <NotebookExpansionPanel
                profileName={host.data()?.bootstrap?.profile ?? ''}
                notebookId={target().notebookId}
                notebookTitle={target().notebookTitle}
                onClose={() => setExpansionTarget(undefined)}
              />
            </div>
          )}</Show>
        </Show>
      </main>
    </div>
  )
}

async function discoverHost(signal: AbortSignal): Promise<{ mode: HostMode; bootstrap?: Bootstrap }> {
  try {
    return { mode: 'riela-app', bootstrap: await api.bootstrap(signal) }
  } catch (error) {
    if (error instanceof APIError && error.status === 404) return { mode: 'cli-serve' }
    throw error
  }
}
