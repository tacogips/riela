export interface OpsStatusStyle {
  color: string
  glow: string
  pulse: boolean
  label: string
}

const STATUS_STYLES: Record<string, OpsStatusStyle> = {
  running: { color: '#f2d268', glow: 'rgba(242, 210, 104, .55)', pulse: true, label: 'running' },
  created: { color: '#63b7dd', glow: 'rgba(99, 183, 221, .45)', pulse: false, label: 'created' },
  completed: { color: '#45d0a3', glow: 'rgba(69, 208, 163, .45)', pulse: false, label: 'completed' },
  skipped: { color: '#7e8ea0', glow: 'rgba(126, 142, 160, .35)', pulse: false, label: 'skipped' },
  failed: { color: '#f4737f', glow: 'rgba(244, 115, 127, .5)', pulse: false, label: 'failed' },
}

export const OPS_IDLE_STYLE: OpsStatusStyle = {
  color: '#5c7186',
  glow: 'rgba(92, 113, 134, .3)',
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
  task: { glyph: '◈', color: '#7de5e5', label: 'task' },
  'branch-judge': { glyph: '⑂', color: '#c9a7e8', label: 'branch judge' },
  'loop-judge': { glyph: '↻', color: '#c9a7e8', label: 'loop judge' },
  input: { glyph: '▷', color: '#8fd6a5', label: 'input' },
  output: { glyph: '◨', color: '#8fd6a5', label: 'output' },
}

export const OPS_AGENT_STYLE: OpsKindStyle = { glyph: '◉', color: '#7de5e5', label: 'agent' }
export const OPS_ADDON_STYLE: OpsKindStyle = { glyph: '✦', color: '#f08f7a', label: 'add-on' }
export const OPS_MANAGER_STYLE: OpsKindStyle = { glyph: '♜', color: '#e8c46b', label: 'manager' }

export function kindStyle(kind: string | null, addon: string | null, role: string | null): OpsKindStyle {
  if (role === 'manager') return OPS_MANAGER_STYLE
  if (addon) return OPS_ADDON_STYLE
  if (kind && KIND_STYLES[kind]) return KIND_STYLES[kind]
  return OPS_AGENT_STYLE
}

export const OPS_HUB_COLORS = [
  '#7de5e5',
  '#f2d268',
  '#c9a7e8',
  '#8fd6a5',
  '#f08f7a',
  '#63b7dd',
  '#e8a2c8',
  '#a9d16e',
]

export function hubColor(index: number): string {
  return OPS_HUB_COLORS[index % OPS_HUB_COLORS.length]!
}
