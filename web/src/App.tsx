import { For, Match, Show, Switch, createEffect, createMemo, createSignal, onCleanup, onMount } from 'solid-js'
import { desktopServerOrigin, hasBrowserAccessToken, isDesktop, setBrowserAccessToken } from './transport'
import { DesktopConnection } from './views/DesktopConnection'
import { authRequest } from './auth/passkeys'
import { APIError, api } from './api'
import type { Bootstrap } from './contracts'
import { createPollingResource } from './polling'
import { LogsView } from './views/LogsView'
import { RunDetailView } from './views/RunDetailView'
import { SettingsView } from './views/SettingsView'
import { WorkflowRunConfigurationsView, type ConfigurationTab } from './views/WorkflowRunConfigurationsView'
import { ServerLoginView } from './views/ServerLoginView'
import { WorkflowsView } from './views/WorkflowsView'
import { OpsRunView } from './ops/OpsRunView'
import { OpsWorkflowsView } from './ops/OpsWorkflowsView'
import { parseViewHash, viewHash, type HashRoute } from './routes'

type NavigationView = 'instances' | 'logs' | 'workflows' | 'ops' | 'settings'
type View = NavigationView | 'workflow-detail' | 'run-detail' | 'ops-run'

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
  const profileChanged = previousProfileKey !== undefined && previousProfileKey !== nextProfileKey
  void mode
  const fallbackView = currentView === 'workflow-detail' ? 'workflows' : currentView === 'run-detail' ? 'workflows' : currentView === 'ops-run' ? 'ops' : currentView
  return {
    clearSelection: profileChanged,
    view: profileChanged ? fallbackView : currentView,
  }
}

const navigation: Array<{ id: NavigationView; label: string; glyph: string }> = [
  { id: 'workflows', label: 'ワークフロー', glyph: '⌘' },
  { id: 'ops', label: 'Command deck', glyph: '✦' },
  { id: 'settings', label: 'Settings', glyph: '◉' },
]

// The command deck relies on riela-app-only aggregate APIs, so it is hidden
// alongside Settings when the host is a bare CLI serve.
const CLI_SERVE_HIDDEN_VIEWS = new Set<NavigationView>(['settings', 'ops'])

export function App() {
  const remoteOrigin = desktopServerOrigin()
  const [view, setView] = createSignal<View>('workflows')
  const [configurationTab, setConfigurationTab] = createSignal<ConfigurationTab>('settings')
  const [selectedSourceId, setSelectedSourceId] = createSignal('')
  const [selectedInstanceId, setSelectedInstanceId] = createSignal('')
  const [selectedRun, setSelectedRun] = createSignal<{ sessionId: string; workflowId: string }>()
  const [selectedOpsRun, setSelectedOpsRun] = createSignal<{ instanceId: string; sessionId: string; workflowId: string }>()
  const [connectionRevision, setConnectionRevision] = createSignal(0)
  const host = createPollingResource(() => `active-host:${connectionRevision()}`, discoverHost)
  const authenticationRequired = createMemo(() => {
    const error = host.error()
    return (!isDesktop() || !!remoteOrigin) && error instanceof APIError && error.status === 401
  })
  const profileKey = createMemo(() => host.data()?.bootstrap ? `riela-app:${host.data()!.bootstrap!.profile}` : 'cli-serve')
  const visibleNavigation = createMemo(() => host.data()?.mode === 'cli-serve'
    ? navigation.filter((item) => !CLI_SERVE_HIDDEN_VIEWS.has(item.id))
    : navigation)
  let previousProfileKey: string | undefined
  // Two-way hash routing: state changes write the canonical hash, and hash
  // changes (deep links, back/forward, RIELA_WEB_RUN_LINK_TEMPLATE links)
  // apply state. Self-written hashes are ignored via the canonical-hash guard.
  const currentHashRoute = (): HashRoute | undefined => {
    const currentView = view()
    if (currentView === 'workflow-detail') return { view: 'workflow-detail', sourceId: selectedSourceId(), configurationId: selectedInstanceId() || undefined, tab: configurationTab() }
    if (currentView === 'run-detail') {
      const run = selectedRun()
      return run ? { view: 'run-detail', sessionId: run.sessionId, sourceId: selectedSourceId() || undefined, configurationId: selectedInstanceId() || undefined } : undefined
    }
    if (currentView === 'ops-run') {
      const run = selectedOpsRun()
      return run ? { view: 'ops-run', instanceId: run.instanceId, sessionId: run.sessionId } : undefined
    }
    return { view: currentView }
  }
  const applyHashRoute = () => {
    const hash = window.location.hash
    const applied = currentHashRoute()
    if (applied && viewHash(applied) === hash) return
    const route = parseViewHash(hash)
    if (!route) return
    if (route.view === 'workflow-detail') {
      setSelectedSourceId(route.sourceId)
      setSelectedInstanceId(route.configurationId ?? '')
      setConfigurationTab(route.tab ?? 'settings')
    } else if (route.view === 'run-detail') {
      setSelectedSourceId(route.sourceId ?? '')
      setSelectedInstanceId(route.configurationId ?? '')
      setConfigurationTab('history')
      setSelectedRun({ sessionId: route.sessionId, workflowId: 'private workflow' })
    } else if (route.view === 'ops-run') {
      setSelectedOpsRun({ instanceId: route.instanceId, sessionId: route.sessionId, workflowId: '' })
    }
    setView(route.view === 'instances' ? 'workflows' : route.view)
  }
  onMount(() => {
    if (parseViewHash(window.location.hash)) {
      applyHashRoute()
    } else {
      // Canonicalize the initial entry so the first back press never lands on
      // a hashless URL that would immediately be pushed forward again.
      window.history.replaceState(null, '', viewHash({ view: 'workflows' }))
    }
    window.addEventListener('hashchange', applyHashRoute)
    onCleanup(() => window.removeEventListener('hashchange', applyHashRoute))
    createEffect(() => {
      const route = currentHashRoute()
      if (!route) return
      const hash = viewHash(route)
      if (window.location.hash !== hash) window.location.hash = hash
    })
  })
  createEffect(() => {
    // Until host discovery resolves, profileKey() is a provisional
    // 'cli-serve'; treating the flip to the real profile as a profile change
    // would wipe deep-linked run state on every page load.
    if (!host.data()) return
    const nextProfileKey = profileKey()
    const transition = profileViewTransition(previousProfileKey, nextProfileKey, host.data()?.mode, view())
    if (transition.clearSelection) {
      setSelectedSourceId('')
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
      <header class="app-header">
        <div class="brand">
          <div class="brand-mark">R</div>
          <div><strong>Riela</strong><span>{remoteOrigin ? 'Remote control plane' : 'Local control plane'}</span></div>
        </div>
        <nav aria-label="Primary navigation">
          <For each={visibleNavigation()}>{(item) => (
            <button classList={{ active: view() === item.id || (item.id === 'workflows' && view() === 'workflow-detail') || (item.id === 'logs' && view() === 'run-detail') || (item.id === 'ops' && view() === 'ops-run') }} aria-current={view() === item.id || (item.id === 'workflows' && view() === 'workflow-detail') || (item.id === 'logs' && view() === 'run-detail') || (item.id === 'ops' && view() === 'ops-run') ? 'page' : undefined} onClick={() => setView(item.id)}>
              <span class="nav-glyph" aria-hidden="true">{item.glyph}</span>{item.label}
            </button>
          )}</For>
        </nav>
        <Show when={host.data() && !authenticationRequired()}>
          <div class="header-profile">
            <span class="eyebrow">{host.data()?.mode === 'cli-serve' ? 'HOST' : 'PROFILE'}</span>
            <strong>{host.data()?.bootstrap?.profile ?? 'riela serve'}</strong>
          </div>
          <span class="api-pill">{host.data()?.mode === 'cli-serve' ? 'NOTE API' : `API ${host.data()?.bootstrap?.apiVersion}`}</span>
        </Show>
        <div class="server-card" role="status" aria-live="polite">
          <span classList={{ dot: true, live: !!host.data() && !host.error() }} />
          <div><strong>{host.error() ? 'Disconnected' : !host.data() ? 'Connecting' : remoteOrigin ? 'Web mode connected' : isDesktop() ? 'Desktop connected' : 'Server connected'}</strong><span>{remoteOrigin || (isDesktop() ? 'RielaApp · Local' : location.host)}</span></div>
        </div>
        <Show when={isDesktop()}><DesktopConnection /></Show>
        <Show when={host.data() && !authenticationRequired() && hasBrowserAccessToken()}>
          <button onClick={() => void authRequest('logout').catch(() => {}).finally(() => {
            setBrowserAccessToken('')
            window.location.reload()
          })}>Sign out</button>
        </Show>
      </header>
      <main id="main-content" tabindex="-1">
        <Show when={host.loading() && !host.data()}><div class="center-state"><span class="loader" />Connecting to Riela…</div></Show>
        <Show when={authenticationRequired()}><ServerLoginView connecting={host.loading()} onConnect={token => {
          setBrowserAccessToken(token)
          setConnectionRevision(value => value + 1)
        }} /></Show>
        <Show when={host.error() && !authenticationRequired()}><div class="center-state error-panel"><strong>Could not connect</strong><span>{String(host.error())}</span><button onClick={() => void host.refresh()}>Try again</button></div></Show>
        <Show when={host.data() && !authenticationRequired()}>
          <Switch>
            <Match when={view() === 'logs'}><LogsView profileKey={profileKey()} selectedInstanceId={selectedInstanceId()} onSelectInstance={setSelectedInstanceId} onOpenRun={(execution) => { setSelectedRun({ sessionId: execution.sessionId, workflowId: execution.workflowId }); setView('run-detail') }} /></Match>
            <Match when={view() === 'run-detail' && selectedRun()}><RunDetailView profileKey={profileKey()} instanceId={selectedInstanceId()} sessionId={selectedRun()!.sessionId} workflowId={selectedRun()!.workflowId} onBack={() => setView(selectedSourceId() ? 'workflow-detail' : 'logs')} /></Match>
            <Match when={view() === 'workflows'}>
              <Show when={profileKey()} keyed>{(_workflowsProfileKey) =>
                <WorkflowsView
                  profileKey={profileKey()}
                  profileName={host.data()?.bootstrap?.profile ?? ''}
                  onInspect={(sourceId) => { setSelectedSourceId(sourceId); setSelectedInstanceId(''); setConfigurationTab('settings'); setView('workflow-detail') }}
                />
              }</Show>
            </Match>
            <Match when={view() === 'workflow-detail'}>
              <Show when={`${profileKey()}:${selectedSourceId()}`} keyed>{(_identity) =>
                <WorkflowRunConfigurationsView profileKey={profileKey()} profileName={host.data()?.bootstrap?.profile ?? ''}
                  sourceId={selectedSourceId()} selectedId={selectedInstanceId()} tab={configurationTab()}
                  onSelect={(id, tab) => { setSelectedInstanceId(id); setConfigurationTab(tab) }}
                  onOpenRun={execution => { setSelectedRun({ sessionId: execution.sessionId, workflowId: execution.workflowId }); setView('run-detail') }}
                  onBack={() => setView('workflows')} />
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
                  serverHosted={host.data()?.bootstrap?.hostKind === 'cli-serve'}
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
