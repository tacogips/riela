import { onCleanup, onMount, type JSX } from 'solid-js'
import { ActionButton } from './ActionButton'

export function ConfirmationDialog(props: {
  title: string; children: JSX.Element; confirmLabel: string; danger?: boolean
  onConfirm: () => void; onCancel: () => void
}) {
  let dialog!: HTMLDialogElement
  onMount(() => dialog.showModal())
  onCleanup(() => dialog.close())
  return <dialog ref={dialog} class="settings-confirmation" aria-label={props.title}
    onCancel={(event) => { event.preventDefault(); props.onCancel() }}>
    <h2>{props.title}</h2>
    <div class="confirmation-content">{props.children}</div>
    <div class="confirmation-actions">
      <ActionButton class="secondary" autofocus onClick={props.onCancel}>Cancel</ActionButton>
      <ActionButton class={props.danger ? 'danger' : ''} onClick={props.onConfirm}>{props.confirmLabel}</ActionButton>
    </div>
  </dialog>
}
