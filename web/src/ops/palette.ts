export interface OpsStatusStyle {
  color: string
  glow: string
  pulse: boolean
  label: string
}

const STATUS_STYLES: Record<string, OpsStatusStyle> = {
  running: { color: '#f2d268', glow: 'rgba(242, 210, 104, .55)', pulse: true, label: 'running' },
  created: { color: '#d4d4d4', glow: 'rgba(212, 212, 212, .35)', pulse: false, label: 'created' },
  completed: { color: '#45d0a3', glow: 'rgba(69, 208, 163, .45)', pulse: false, label: 'completed' },
  skipped: { color: '#a3a3a3', glow: 'rgba(163, 163, 163, .3)', pulse: false, label: 'skipped' },
  failed: { color: '#f4737f', glow: 'rgba(244, 115, 127, .5)', pulse: false, label: 'failed' },
}

export const OPS_IDLE_STYLE: OpsStatusStyle = {
  color: '#737373',
  glow: 'rgba(115, 115, 115, .3)',
  pulse: false,
  label: 'idle',
}

export function statusStyle(status: string | null | undefined): OpsStatusStyle {
  if (!status) return OPS_IDLE_STYLE
  return STATUS_STYLES[status] ?? OPS_IDLE_STYLE
}

export interface OpsKindStyle {
  glyph: string
  color: string
  label: string
}

const KIND_STYLES: Record<string, OpsKindStyle> = {
  task: { glyph: '◈', color: '#f5f5f5', label: 'task' },
  'branch-judge': { glyph: '⑂', color: '#d4d4d4', label: 'branch judge' },
  'loop-judge': { glyph: '↻', color: '#d4d4d4', label: 'loop judge' },
  input: { glyph: '▷', color: '#e5e5e5', label: 'input' },
  output: { glyph: '◨', color: '#e5e5e5', label: 'output' },
}

export const OPS_AGENT_STYLE: OpsKindStyle = { glyph: '◉', color: '#f5f5f5', label: 'agent' }
export const OPS_ADDON_STYLE: OpsKindStyle = { glyph: '✦', color: '#d4d4d4', label: 'add-on' }
export const OPS_MANAGER_STYLE: OpsKindStyle = { glyph: '♜', color: '#e5e5e5', label: 'manager' }

export function kindStyle(kind: string | null, addon: string | null, role: string | null): OpsKindStyle {
  if (role === 'manager') return OPS_MANAGER_STYLE
  if (addon) return OPS_ADDON_STYLE
  if (kind && KIND_STYLES[kind]) return KIND_STYLES[kind]
  return OPS_AGENT_STYLE
}

export const OPS_HUB_COLORS = [
  '#ffffff',
  '#e5e5e5',
  '#d4d4d4',
  '#a3a3a3',
  '#f5f5f5',
  '#737373',
  '#cccccc',
  '#8a8a8a',
]

export function hubColor(index: number): string {
  return OPS_HUB_COLORS[index % OPS_HUB_COLORS.length]!
}
