import { Show } from 'solid-js'
import type { Document, Step } from './graph'
import { placementRecord, updatePlacement } from './placement'

export function WorkflowPlacementSettings(props: { step: Step; onChange: (step: Step) => void }) {
  const placement = () => placementRecord(props.step.placement)
  const text = (value: unknown) => typeof value === 'string' ? value : ''
  const update = (patch: Document | null) => props.onChange(updatePlacement(props.step, patch))
  const setTarget = (key: 'workerId' | 'group', value: string) => {
    const target = { ...placementRecord(placement().target) }
    if (value === '') delete target[key]
    else target[key] = value
    update({ target })
  }
  return <>
    <h4>Execution location</h4>
    <label>Run on<select aria-label="Run on" value={props.step.placement === undefined ? 'local' : 'remote'} onChange={event =>
      update(event.currentTarget.value === 'local' ? null : { workspace: '', target: {} })}>
      <option value="local">This controller</option><option value="remote">Remote worker</option>
    </select></label>
    <Show when={props.step.placement !== undefined}>
      <label>Worker workspace<input value={text(placement().workspace)} placeholder="project"
        onChange={event => update({ workspace: event.currentTarget.value })} /></label>
      <label>Worker ID (optional)<input value={text(placementRecord(placement().target).workerId)} placeholder="linux-1"
        onChange={event => setTarget('workerId', event.currentTarget.value)} /></label>
      <label>Worker group (optional)<input value={text(placementRecord(placement().target).group)} placeholder="build"
        onChange={event => setTarget('group', event.currentTarget.value)} /></label>
      <p>Both ID and group must match when supplied. Leave both empty for any remote worker. An unavailable worker never falls back to this controller.</p>
      <label>Export files (one per line)<textarea rows="3" value={Array.isArray(placement().exports) ? (placement().exports as unknown[]).map(text).join('\n') : ''}
        placeholder="build/report.json" onChange={event => update({ exports: event.currentTarget.value.split('\n').filter(path => path !== '') })} /></label>
      <p>Paths are relative to the worker workspace. Up to 16 regular files, 512 KiB total.</p>
    </Show>
  </>
}
