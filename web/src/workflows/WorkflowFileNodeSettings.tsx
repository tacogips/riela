import { rielaFetch } from '../transport'
import { Show, createSignal, onCleanup } from 'solid-js'
import { api } from '../api'
import type { RegistryWorkflow } from './types'

interface Settings { assetRevision: string; prompt?: string; model?: string; promptHidden: boolean; modelHidden: boolean }

export function WorkflowFileNodeSettings(props: {
  target?: RegistryWorkflow
  nodeId: string
  disabled: boolean
  onSaved: (workflow: RegistryWorkflow) => void
}) {
  let dialog: HTMLDialogElement | undefined
  let alive = true
  let controller: AbortController | undefined
  onCleanup(() => { alive = false; controller?.abort() })
  const [settings, setSettings] = createSignal<Settings>()
  const [prompt, setPrompt] = createSignal('')
  const [model, setModel] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal('')
  const dirty = () => Boolean(settings() && (prompt() !== (settings()!.prompt ?? '') || model() !== (settings()!.model ?? '')))
  const request = async (extra: Record<string, unknown>) => {
    const target = props.target!
    controller = new AbortController()
    const response = await rielaFetch('/api/v1/workflow-editor/node-settings', {
      method: 'POST', signal: controller.signal, credentials: 'same-origin',
      headers: { ...api.noteHeaders(), 'Content-Type': 'application/json' },
      body: JSON.stringify({ workflowId: target.workflowId, originId: target.originId,
        definitionRevision: target.definitionRevision, nodeId: props.nodeId, ...extra }),
    })
    const data = await response.json()
    if (!response.ok) throw new Error(data.error?.message ?? 'Could not update node settings.')
    return data
  }
  const open = async () => {
    setBusy(true); setError(''); setSettings(undefined); dialog?.showModal()
    try {
      const data = await request({ action: 'load' }) as Settings
      if (alive) { setSettings(data); setPrompt(data.prompt ?? ''); setModel(data.model ?? '') }
    } catch (failure) { if (alive) setError(String(failure)) }
    finally { if (alive) setBusy(false) }
  }
  const close = () => {
    if (busy() || (dirty() && !window.confirm('Discard the unsaved node settings?'))) return
    dialog?.close()
  }
  const save = async () => {
    if (!dirty() || busy()) return
    setBusy(true); setError('')
    try {
      const data = await request({ action: 'save', assetRevision: settings()!.assetRevision,
        ...(prompt() !== (settings()!.prompt ?? '') ? { prompt: prompt() } : {}),
        ...(model() !== (settings()!.model ?? '') ? { model: model() } : {}),
      }) as RegistryWorkflow
      if (alive) { dialog?.close(); props.onSaved(data) }
    } catch (failure) { if (alive) setError(String(failure)) }
    finally { if (alive) setBusy(false) }
  }
  return <>
    <button disabled={props.disabled || !props.target} onClick={() => void open()}>Edit file-backed node settings</button>
    <Show when={props.disabled || !props.target}><p>Save the graph before editing the node file.</p></Show>
    <dialog ref={dialog} class="editor-node-dialog" aria-label="File-backed node settings" onCancel={(event) => { event.preventDefault(); close() }}>
      <h3>File-backed node settings · {props.nodeId}</h3>
      <p>Save creates a separate node file and updates this workflow atomically. Original files and other settings remain unchanged.</p>
      <Show when={busy()}><p role="status">Working…</p></Show>
      <Show when={error()}><p role="alert">{error()}</p></Show>
      <Show when={settings()}>{(data) => <>
        <Show when={data().promptHidden || data().modelHidden}><p>Protected values are hidden and retained unless you type a replacement.</p></Show>
        <label>Node file prompt<textarea rows="10" disabled={busy()} value={prompt()} onInput={(event) => setPrompt(event.currentTarget.value)} /></label>
        <label>Node file model<input disabled={busy()} value={model()} onInput={(event) => setModel(event.currentTarget.value)} /></label>
        <button disabled={busy() || !dirty()} onClick={() => void save()}>Save node settings</button>
      </>}</Show>
      <button class="secondary" disabled={busy()} onClick={close}>Cancel node settings</button>
    </dialog>
  </>
}
