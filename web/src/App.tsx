import { For, Match, Show, Switch, createEffect, createMemo, createResource, createSignal } from 'solid-js'
import { APIError, api } from './api'
import type { Bootstrap } from './contracts'
import type { HostMode } from './notes/types'
import { InstancesView } from './views/InstancesView'
import { LogsView } from './views/LogsView'
import { NotesView } from './views/NotesView'
import { SettingsView } from './views/SettingsView'
import { WorkflowsView } from './views/WorkflowsView'

type View = 'notes' | 'instances' | 'logs' | 'workflows' | 'settings'

const navigation: Array<{ id: View; label: string; glyph: string }> = [
  { id: 'notes', label: 'Notes', glyph: '▤' },
  { id: 'instances', label: 'Instances', glyph: '◇' },
  { id: 'logs', label: 'Run logs', glyph: '≋' },
  { id: 'workflows', label: 'Workflows', glyph: '⌘' },
  { id: 'settings', label: 'Settings', glyph: '◉' },
]

export function App() {
  const [view, setView] = createSignal<View>('instances')
  const [host, { refetch }] = createResource(discoverHost)
  const visibleNavigation = createMemo(() => host()?.mode === 'cli-serve' ? navigation.filter((item) => item.id === 'notes') : navigation)
  createEffect(() => {
    if (host()?.mode === 'cli-serve') setView('notes')
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
            <button classList={{ active: view() === item.id }} aria-current={view() === item.id ? 'page' : undefined} onClick={() => setView(item.id)}>
              <span class="nav-glyph" aria-hidden="true">{item.glyph}</span>{item.label}
            </button>
          )}</For>
        </nav>
        <div class="server-card" role="status" aria-live="polite">
          <span classList={{ dot: true, live: host()?.mode === 'cli-serve' || host()?.bootstrap?.server.state === 'running' }} />
          <div><strong>{host()?.mode === 'cli-serve' ? 'CLI serve' : host()?.bootstrap?.server.state ?? 'Connecting'}</strong><span>{host()?.bootstrap?.server.boundPort ? `127.0.0.1:${host()?.bootstrap?.server.boundPort}` : 'Local server'}</span></div>
        </div>
      </aside>
      <main id="main-content" tabindex="-1">
        <Show when={host.loading}><div class="center-state"><span class="loader" />Connecting to Riela…</div></Show>
        <Show when={host.error}><div class="center-state error-panel"><strong>Could not connect</strong><span>{String(host.error)}</span><button onClick={() => void refetch()}>Try again</button></div></Show>
        <Show when={host()}>
          <header class="topbar">
            <div><span class="eyebrow">{host()?.mode === 'cli-serve' ? 'HOST' : 'PROFILE'}</span><strong>{host()?.bootstrap?.profile ?? 'riela serve'}</strong></div>
            <span class="api-pill">{host()?.mode === 'cli-serve' ? 'NOTE API' : `API ${host()?.bootstrap?.apiVersion}`}</span>
          </header>
          <Switch>
            <Match when={view() === 'notes'}><NotesView mode={host()!.mode} /></Match>
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

async function discoverHost(): Promise<{ mode: HostMode; bootstrap?: Bootstrap }> {
  try {
    return { mode: 'riela-app', bootstrap: await api.bootstrap() }
  } catch (error) {
    if (error instanceof APIError && error.status === 404) return { mode: 'cli-serve' }
    throw error
  }
}
