import { Show, createSignal, onCleanup, onMount, splitProps, type JSX } from 'solid-js'
import { actionIconPaths, inferActionIcon, type ActionIconName } from './ActionIcons'

export interface ActionButtonProps extends JSX.ButtonHTMLAttributes<HTMLButtonElement> {
  icon?: ActionIconName | false
  iconOnly?: boolean
  variant?: 'primary' | 'secondary' | 'danger'
}

/** Visible action names are the default; compact toolbars explicitly opt into iconOnly. */
export function ActionButton(props: ActionButtonProps) {
  const [local, attributes] = splitProps(props, ['children', 'class', 'classList', 'title', 'icon', 'iconOnly', 'variant'])
  const [label, setLabel] = createSignal('')
  let caption!: HTMLSpanElement
  onMount(() => {
    const update = () => setLabel(caption.textContent?.trim() ?? '')
    update()
    const observer = new MutationObserver(update)
    observer.observe(caption, { childList: true, characterData: true, subtree: true })
    onCleanup(() => observer.disconnect())
  })
  const name = () => String(props['aria-label'] ?? label())
  const icon = () => local.icon === false ? undefined : local.icon ?? inferActionIcon(name())
  const compact = () => Boolean(local.iconOnly && icon())
  return <button {...attributes} class={`action-icon-button ${compact() ? 'action-icon-only' : ''} ${local.variant ?? ''} ${local.class ?? ''}`} classList={local.classList} title={local.title ?? name()}>
    <Show when={icon()}>{(value) => <svg aria-hidden="true" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d={actionIconPaths[value()]} /></svg>}</Show>
    <span class="action-button-caption" ref={caption}>{local.children}</span>
  </button>
}
