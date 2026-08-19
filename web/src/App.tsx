import { For, Match, Show, Switch, createEffect, createMemo, createSignal, onCleanup, onMount } from 'solid-js'
import { APIError, api } from './api'
import type { Bootstrap } from './contracts'
import { createPollingResource } from './polling'
import { InstancesView } from './views/InstancesView'
import { LogsView } from './views/LogsView'
import { RunDetailView } from './views/RunDetailView'
import { SettingsView } from './views/SettingsView'
import { WorkflowsView } from './views/WorkflowsView'
import { OpsRunView } from './ops/OpsRunView'
import { OpsWorkflowsView } from './ops/OpsWorkflowsView'

type NavigationView = 'instances' | 'logs' | 'workflows' | 'ops' | 'settings'
type View = NavigationView | 'run-detail' | 'ops-run'

export interface ProfileViewTransition {
  clearSelection: boolean
  view: View
}

export function profileViewTransition(
  previousProfileKey: string | undefined,
  nextProfileKey: string,
  mode: 'riela-app' | 'cli-serve' | undefined,
  currentView: View,
): ProfileViewTransition {
  if (mode === 'cli-serve') return { clearSelection: true, view: 'instances' }
  const profileChanged = previousProfileKey !== undefined && previousProfileKey !== nextProfileKey
  const fallbackView = currentView === 'run-detail' ? 'logs' : currentView === 'ops-run' ? 'ops' : currentView
  return {
    clearSelection: profileChanged,
    view: profileChanged ? fallbackView : currentView,
  }
}

const navigation: Array<{ id: NavigationView; label: string; glyph: string }> = [
  { id: 'instances', label: 'Instances', glyph: '◇' },
  { id: 'logs', label: 'Run logs', glyph: '≋' },
  { id: 'workflows', label: 'Workflows', glyph: '⌘' },
  { id: 'ops', label: 'Command deck', glyph: '✦' },
  { id: 'settings', label: 'Settings', glyph: '◉' },
]

// The command deck relies on riela-app-only aggregate APIs, so it is hidden
// alongside Settings when the host is a bare CLI serve.
const CLI_SERVE_HIDDEN_VIEWS = new Set<NavigationView>(['settings', 'ops'])

export function App() {
  const [view, setView] = createSignal<View>('instances')
  const [selectedInstanceId, setSelectedInstanceId] = createSignal('')
  const [selectedRun, setSelectedRun] = createSignal<{ sessionId: string; workflowId: string }>()
  const [selectedOpsRun, setSelectedOpsRun] = createSignal<{ instanceId: string; sessionId: string; workflowId: string }>()
  const host = createPollingResource(() => 'active-host', discoverHost)
  const profileKey = createMemo(() => host.data()?.bootstrap ? `riela-app:${host.data()!.bootstrap!.profile}` : 'cli-serve')
  const visibleNavigation = createMemo(() => host.data()?.mode === 'cli-serve'
    ? navigation.filter((item) => !CLI_SERVE_HIDDEN_VIEWS.has(item.id))
    : navigation)
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
      setSelectedOpsRun(undefined)
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
            <button classList={{ active: view() === item.id || (item.id === 'logs' && view() === 'run-detail') || (item.id === 'ops' && view() === 'ops-run') }} aria-current={view() === item.id || (item.id === 'logs' && view() === 'run-detail') || (item.id === 'ops' && view() === 'ops-run') ? 'page' : undefined} onClick={() => setView(item.id)}>
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
            <Match when={view() === 'ops'}>
              <Show when={profileKey()} keyed>{(_opsProfileKey) =>
                <OpsWorkflowsView
                  profileKey={profileKey()}
                  profileName={host.data()?.bootstrap?.profile ?? ''}
                  onOpenRun={(run) => {
                    setSelectedOpsRun({ instanceId: run.instanceId, sessionId: run.sessionId, workflowId: run.workflowId })
                    setView('ops-run')
                  }}
                />
              }</Show>
            </Match>
            <Match when={view() === 'ops-run' && selectedOpsRun()}>
              <OpsRunView
                profileKey={profileKey()}
                instanceId={selectedOpsRun()!.instanceId}
                sessionId={selectedOpsRun()!.sessionId}
                workflowId={selectedOpsRun()!.workflowId}
                onBack={() => setView('ops')}
              />
            </Match>
            <Match when={view() === 'settings'}>
              <Show when={profileKey()} keyed>{(_settingsProfileKey) =>
                <SettingsView
                  profileKey={profileKey()}
                  profileName={host.data()?.bootstrap?.profile ?? ''}
                  onHostChange={() => void host.refresh()}
                />
              }</Show>
            </Match>
          </Switch>
        </Show>
      </main>
    </div>
  )
}

async function discoverHost(signal: AbortSignal): Promise<{ mode: 'riela-app' | 'cli-serve'; bootstrap?: Bootstrap }> {
  try {
    return { mode: 'riela-app', bootstrap: await api.bootstrap(signal) }
  } catch (error) {
    if (error instanceof APIError && error.status === 404) return { mode: 'cli-serve' }
    throw error
  }
}
