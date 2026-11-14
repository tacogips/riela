import { createEffect, createSignal, onCleanup, onMount, type JSX } from 'solid-js'
import './ops.css'
import type { OpsBounds, OpsCamera } from './scene'
import { cameraTransform, fitCamera, panBy, zoomAt } from './scene'

const GRID_EXTENT = 6000
const GRID_MINOR = 60
const GRID_MAJOR = 300

function gridLines(): JSX.Element {
  const lines: JSX.Element[] = []
  for (let offset = -GRID_EXTENT; offset <= GRID_EXTENT; offset += GRID_MINOR) {
    const major = offset % GRID_MAJOR === 0
    lines.push(<line
      class={major ? 'ops-grid-line major' : 'ops-grid-line'}
      x1={offset} y1={-GRID_EXTENT} x2={offset} y2={GRID_EXTENT}
    />)
    lines.push(<line
      class={major ? 'ops-grid-line major' : 'ops-grid-line'}
      x1={-GRID_EXTENT} y1={offset} x2={GRID_EXTENT} y2={offset}
    />)
  }
  return lines
}

/**
 * Interactive SVG stage: drag to pan, wheel (or the corner controls) to zoom
 * toward the cursor, automatic refit whenever `fitKey` changes.
 */
export function OpsScene(props: {
  bounds: OpsBounds
  fitKey: string
  label: string
  children: JSX.Element
}) {
  let container: HTMLDivElement | undefined
  const [camera, setCamera] = createSignal<OpsCamera>({ offsetX: 0, offsetY: 0, scale: 1 })
  const [viewport, setViewport] = createSignal({ width: 0, height: 0 })
  const [dragging, setDragging] = createSignal(false)
  let lastFitKey: string | undefined
  let pan: { pointerId: number; lastX: number; lastY: number; travel: number } | undefined
  let suppressClick = false

  const fit = () => {
    const size = viewport()
    if (size.width > 0 && size.height > 0) setCamera(fitCamera(props.bounds, size))
  }

  const zoomAtCenter = (factor: number) => {
    const size = viewport()
    setCamera((current) => zoomAt(current, size.width / 2, size.height / 2, factor))
  }

  onMount(() => {
    const host = container!
    const observer = new ResizeObserver(() => {
      setViewport({ width: host.clientWidth, height: host.clientHeight })
    })
    observer.observe(host)
    setViewport({ width: host.clientWidth, height: host.clientHeight })

    const onWheel = (event: WheelEvent) => {
      event.preventDefault()
      const rect = host.getBoundingClientRect()
      const factor = Math.exp(-event.deltaY * 0.0016)
      setCamera((current) => zoomAt(current, event.clientX - rect.left, event.clientY - rect.top, factor))
    }
    const onPointerDown = (event: PointerEvent) => {
      if (event.button !== 0) return
      pan = { pointerId: event.pointerId, lastX: event.clientX, lastY: event.clientY, travel: 0 }
    }
    const onPointerMove = (event: PointerEvent) => {
      if (!pan || event.pointerId !== pan.pointerId) return
      const deltaX = event.clientX - pan.lastX
      const deltaY = event.clientY - pan.lastY
      pan.travel += Math.abs(deltaX) + Math.abs(deltaY)
      pan.lastX = event.clientX
      pan.lastY = event.clientY
      // Capture only once a real drag starts; capturing on pointerdown would
      // reroute the click away from the node the user tapped.
      if (pan.travel > 4 && !dragging()) {
        host.setPointerCapture(event.pointerId)
        setDragging(true)
      }
      if (dragging()) setCamera((current) => panBy(current, deltaX, deltaY))
    }
    const onPointerEnd = (event: PointerEvent) => {
      if (!pan || event.pointerId !== pan.pointerId) return
      suppressClick = pan.travel > 6
      pan = undefined
      setDragging(false)
    }
    const onClickCapture = (event: MouseEvent) => {
      if (suppressClick) {
        event.stopPropagation()
        suppressClick = false
      }
    }
    host.addEventListener('wheel', onWheel, { passive: false })
    host.addEventListener('pointerdown', onPointerDown)
    host.addEventListener('pointermove', onPointerMove)
    host.addEventListener('pointerup', onPointerEnd)
    host.addEventListener('pointercancel', onPointerEnd)
    host.addEventListener('click', onClickCapture, true)
    onCleanup(() => {
      observer.disconnect()
      host.removeEventListener('wheel', onWheel)
      host.removeEventListener('pointerdown', onPointerDown)
      host.removeEventListener('pointermove', onPointerMove)
      host.removeEventListener('pointerup', onPointerEnd)
      host.removeEventListener('pointercancel', onPointerEnd)
      host.removeEventListener('click', onClickCapture, true)
    })
  })

  createEffect(() => {
    const key = props.fitKey
    const size = viewport()
    if (size.width === 0 || size.height === 0) return
    if (key !== lastFitKey) {
      lastFitKey = key
      fit()
    }
  })

  return (
    <div classList={{ 'ops-canvas': true, dragging: dragging() }} ref={container}>
      <svg role="img" aria-label={props.label}>
        <defs>
          <filter id="ops-glow" x="-80%" y="-80%" width="260%" height="260%">
            <feGaussianBlur stdDeviation="5" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>
        <g transform={cameraTransform(camera())}>
          <g aria-hidden="true">{gridLines()}</g>
          {props.children}
        </g>
      </svg>
      <div class="ops-zoom" role="group" aria-label="Zoom controls">
        <button type="button" aria-label="Zoom in" onClick={() => zoomAtCenter(1.35)}>+</button>
        <button type="button" aria-label="Zoom out" onClick={() => zoomAtCenter(1 / 1.35)}>−</button>
        <button type="button" aria-label="Fit view" onClick={fit}>⤢</button>
      </div>
    </div>
  )
}
