import { For, Match, Show, Switch, createResource, createSignal } from 'solid-js'
import { api } from './api'
import { InstancesView } from './views/InstancesView'
import { LogsView } from './views/LogsView'
import { SettingsView } from './views/SettingsView'
import { WorkflowsView } from './views/WorkflowsView'

type View = 'instances' | 'logs' | 'workflows' | 'settings'

const navigation: Array<{ id: View; label: string; glyph: string }> = [
  { id: 'instances', label: 'Instances', glyph: '◇' },
  { id: 'logs', label: 'Run logs', glyph: '≋' },
  { id: 'workflows', label: 'Workflows', glyph: '⌘' },
  { id: 'settings', label: 'Settings', glyph: '◉' },
]

export function App() {
  const [view, setView] = createSignal<View>('instances')
  const [bootstrap, { refetch }] = createResource(() => api.bootstrap())

  return (
    <div class="app-shell">
      <a class="skip-link" href="#main-content">Skip to content</a>
      <aside class="sidebar">
        <div class="brand">
          <div class="brand-mark">R</div>
          <div><strong>Riela</strong><span>Local control plane</span></div>
        </div>
        <nav aria-label="Primary navigation">
          <For each={navigation}>{(item) => (
            <button classList={{ active: view() === item.id }} aria-current={view() === item.id ? 'page' : undefined} onClick={() => setView(item.id)}>
              <span class="nav-glyph" aria-hidden="true">{item.glyph}</span>{item.label}
            </button>
          )}</For>
        </nav>
        <div class="server-card" role="status" aria-live="polite">
          <span classList={{ dot: true, live: bootstrap()?.server.state === 'running' }} />
          <div><strong>{bootstrap()?.server.state ?? 'Connecting'}</strong><span>{bootstrap()?.server.boundPort ? `127.0.0.1:${bootstrap()?.server.boundPort}` : 'Local server'}</span></div>
        </div>
      </aside>
      <main id="main-content" tabindex="-1">
        <Show when={bootstrap.loading}><div class="center-state"><span class="loader" />Connecting to Riela…</div></Show>
        <Show when={bootstrap.error}><div class="center-state error-panel"><strong>Could not connect</strong><span>{String(bootstrap.error)}</span><button onClick={() => void refetch()}>Try again</button></div></Show>
        <Show when={bootstrap()}>
          <header class="topbar">
            <div><span class="eyebrow">PROFILE</span><strong>{bootstrap()?.profile}</strong></div>
            <span class="api-pill">API {bootstrap()?.apiVersion}</span>
          </header>
          <Switch>
            <Match when={view() === 'instances'}><InstancesView /></Match>
            <Match when={view() === 'logs'}><LogsView /></Match>
            <Match when={view() === 'workflows'}><WorkflowsView /></Match>
            <Match when={view() === 'settings'}><SettingsView onServerChange={() => void refetch()} /></Match>
          </Switch>
        </Show>
      </main>
    </div>
  )
}
