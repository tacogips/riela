import { Show } from 'solid-js'
import { ActionButton } from '../components/ActionButton'
import type { BotListState, SetBotListStateInput } from './contracts'

type ListChange = Pick<SetBotListStateInput, 'pinned' | 'snoozedUntil' | 'clearSnooze' | 'settled'>
const hourMs = 3_600_000

export function BotListActions(props: {
  state: BotListState
  snoozed: boolean
  canSettle: boolean
  busy: boolean
  onChange: (change: ListChange) => void
}) {
  const snooze = (duration: number) =>
    props.onChange({ snoozedUntil: new Date(Date.now() + duration).toISOString() })
  return <div class="bot-actions">
    <ActionButton type="button" disabled={props.busy} onClick={() => props.onChange({ pinned: !props.state.pinned })}>
      {props.state.pinned ? 'Unpin' : 'Pin'}
    </ActionButton>
    <Show when={!props.snoozed}>
      <ActionButton type="button" disabled={props.busy} onClick={() => snooze(hourMs)}>Snooze 1 hour</ActionButton>
      <ActionButton type="button" disabled={props.busy} onClick={() => snooze(24 * hourMs)}>Snooze 1 day</ActionButton>
    </Show>
    <Show when={props.state.snoozedUntil}>
      <ActionButton type="button" disabled={props.busy} onClick={() => props.onChange({ clearSnooze: true })}>Unsnooze</ActionButton>
    </Show>
    <Show when={props.state.settledBy === 'auto'}><span class="bots-meta">Auto-settled</span></Show>
    <Show when={props.state.settledBy !== 'auto' && (props.canSettle || props.state.settledAt)}>
      <ActionButton type="button" disabled={props.busy} onClick={() => props.onChange({ settled: !props.state.settledAt })}>
        {props.state.settledAt ? 'Unsettle' : 'Settle'}
      </ActionButton>
    </Show>
  </div>
}
