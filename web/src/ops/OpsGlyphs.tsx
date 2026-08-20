import { Show } from 'solid-js'

/**
 * Double-ring node glyph used across the command deck scenes, echoing the
 * radial console art direction: outer ring, dark core, glyph, stacked labels.
 */
export function RingNode(props: {
  x: number
  y: number
  radius?: number
  color: string
  glyph: string
  label: string
  sublabel?: string
  pulse?: boolean
  selected?: boolean
  dimmed?: boolean
  badge?: string
  onClick?: () => void
  ariaLabel?: string
}) {
  const radius = () => props.radius ?? 24
  return (
    <g
      class="ops-node"
      transform={`translate(${props.x} ${props.y})`}
      opacity={props.dimmed ? 0.45 : 1}
      role={props.onClick ? 'button' : undefined}
      aria-label={props.ariaLabel ?? props.label}
      onClick={(event) => {
        if (!props.onClick) return
        event.stopPropagation()
        props.onClick()
      }}
    >
      <Show when={props.pulse}>
        <circle class="ops-pulse" r={radius() + 11} fill="none" stroke={props.color} stroke-width="1.5" opacity="0.5" />
      </Show>
      <Show when={props.selected}>
        <circle r={radius() + 7} fill="none" stroke="#dffbfb" stroke-width="1.2" stroke-dasharray="3 4" />
      </Show>
      <circle r={radius()} fill="#060d15" stroke={props.color} stroke-width="1.8" filter="url(#ops-glow)" />
      <circle r={radius() - 5} fill="none" stroke={props.color} stroke-width="0.8" opacity="0.75" />
      <text class="ops-node-glyph" fill={props.color} font-size={`${radius() * 0.62}`}>{props.glyph}</text>
      <text class="ops-node-label" y={radius() + 17}>{props.label}</text>
      <Show when={props.sublabel}>
        <text class="ops-node-sublabel" y={radius() + 30}>{props.sublabel}</text>
      </Show>
      <Show when={props.badge}>
        <g transform={`translate(${radius() - 3} ${-radius() + 3})`}>
          <circle r="8.5" fill={props.color} />
          <text class="ops-badge-text">{props.badge}</text>
        </g>
      </Show>
    </g>
  )
}

export function truncateMiddle(value: string, max = 26): string {
  if (value.length <= max) return value
  const half = Math.floor((max - 1) / 2)
  return `${value.slice(0, half)}…${value.slice(value.length - half)}`
}

export function edgeLabelAnchor(fromX: number, fromY: number, toX: number, toY: number): { x: number; y: number } {
  return { x: (fromX + toX) / 2, y: (fromY + toY) / 2 - 6 }
}
