import { createResource, createSignal, For, onCleanup, onMount, Show } from 'solid-js'
import { APIError } from '../../api'
import { ActionButton } from '../../components/ActionButton'
import { ErrorBanner, LoadingState } from '../../components/Primitives'
import { historyClient, type Diff, type Proposal } from './historyClient'
import './history.css'

type Action = { kind: 'restore'; versionId: string } | { kind: 'undo'; versionId: string } | { kind: 'approve' | 'reject'; proposal: Proposal }
const short = (id: string) => id.slice(0, 12)
function format(value: string | null) {
  if (value === null) return '—'
  try { return JSON.stringify(JSON.parse(value), null, 2) } catch { return value }
}
function DiffEntries(props: { entries: Diff[] }) {
  return <Show when={props.entries.length} fallback={<p>No changes.</p>}><For each={props.entries}>{entry => <div class="history-diff"><strong>{entry.op} {entry.path}</strong><div class="history-diff-values"><pre>{format(entry.before)}</pre><pre>{format(entry.after)}</pre></div></div>}</For></Show>
}
function Confirm(props: { action: Action; head: string; workflowName: string; busy: boolean; onCancel: () => void; onConfirm: (reason: string) => void }) {
  let dialog!: HTMLDialogElement
  const [reason, setReason] = createSignal('')
  const target = (): [string, string] | undefined => (props.action.kind === 'restore' || props.action.kind === 'undo') ? [props.head, props.action.versionId] : props.action.kind === 'approve' ? [props.action.proposal.regressedVersionId, props.action.proposal.rollbackToVersionId] : undefined
  const [diff] = createResource(target, ids => historyClient.diff(props.workflowName, ids[0], ids[1]))
  onMount(() => dialog.showModal())
  onCleanup(() => dialog.close())
  return <dialog ref={dialog} class="settings-confirmation" onCancel={event => { event.preventDefault(); props.onCancel() }}>
    <h2>{props.action.kind === 'restore' ? 'Restore version' : props.action.kind === 'undo' ? 'Undo last change' : props.action.kind === 'approve' ? 'Approve rollback' : 'Reject rollback'}</h2>
    <Show when={props.action.kind === 'restore' || props.action.kind === 'undo'}><p>Restores the service definition; workflow files are unchanged.</p></Show>
    <Show when={target()}><Show when={!diff.loading} fallback={<LoadingState label="Loading diff…" />}><Show when={!diff.error} fallback={<ErrorBanner message={String(diff.error)} />}><DiffEntries entries={diff() ?? []} /></Show></Show></Show>
    <label>Reason {props.action.kind === 'approve' ? '(optional)' : '(required)'}<textarea value={reason()} onInput={event => setReason(event.currentTarget.value)} /></label>
    <div class="confirmation-actions"><ActionButton class="secondary" disabled={props.busy} onClick={props.onCancel}>Cancel</ActionButton><ActionButton class="danger" disabled={props.busy || (props.action.kind !== 'approve' && !reason().trim()) || Boolean(target() && (diff.loading || diff.error))} onClick={() => props.onConfirm(reason().trim())}>Confirm</ActionButton></div>
  </dialog>
}
export function WorkflowVersionsView(props: { workflowName: string }) {
  const [generation, setGeneration] = createSignal(0)
  const [data] = createResource(() => [props.workflowName, generation()] as const, async ([name]) => {
    const [history, head, proposals] = await Promise.all([historyClient.history(name), historyClient.head(name), historyClient.proposals(name)])
    return { history, head, proposals }
  })
  const [from, setFrom] = createSignal('')
  const [to, setTo] = createSignal('current')
  const [action, setAction] = createSignal<Action>()
  const [error, setError] = createSignal<unknown>()
  const [busy, setBusy] = createSignal(false)
  const [diff] = createResource(() => {
    const head = data()?.head?.versionId
    const source = from() || data()?.history.find(row => row.retained && row.versionId !== head)?.versionId || head
    const target = to() === 'current' ? head : to()
    return source && target ? [props.workflowName, source, target] as const : undefined
  }, ([name, source, target]) => historyClient.diff(name, source, target))
  const reload = () => { setError(undefined); setGeneration(value => value + 1) }
  const perform = async (reason: string) => {
    const current = action(); const head = data()?.head?.versionId
    if (!current || !head || busy() || (current.kind !== 'approve' && !reason.trim())) return
    setBusy(true); setError(undefined)
    try {
      if (current.kind === 'restore') await historyClient.restore(props.workflowName, current.versionId, reason, head)
      else if (current.kind === 'undo') await historyClient.undo(props.workflowName, reason, head)
      else if (current.kind === 'approve') await historyClient.approve(props.workflowName, current.proposal.proposalId, reason)
      else await historyClient.reject(props.workflowName, current.proposal.proposalId, reason)
      setAction(undefined); reload()
    } catch (failure) { setAction(undefined); setError(failure) } finally { setBusy(false) }
  }
  const undoTarget = () => data()?.history.find(row => row.versionId === data()?.head?.versionId && row.previousVersionId && row.previousVersionId !== row.versionId)?.previousVersionId
  const failure = () => error() ?? data.error ?? diff.error
  const stale = () => failure() instanceof APIError && ['DEFINITION_STALE', 'DEFINITION_STALE_REVISION', 'ROLLBACK_SUPERSEDED', 'DEFINITION_ROLLBACK_IN_PROGRESS'].includes((failure() as APIError).code ?? '')
  return <section class="workflow-versions"><div class="section-title"><h2>Versions</h2><ActionButton class="secondary" onClick={reload}>Reload</ActionButton></div>
    <Show when={failure()}><ErrorBanner message={failure() instanceof Error ? (failure() as Error).message : String(failure())} /><Show when={stale()}><p>History changed — reload.</p></Show></Show>
    <Show when={!data.loading || data()} fallback={<LoadingState label="Loading versions…" />}><Show when={data()}>{state => <>
      <ActionButton class="secondary" disabled={!state().head || !undoTarget() || busy()} onClick={() => { const versionId = undoTarget(); if (versionId) setAction({ kind: 'undo', versionId }) }}>Undo</ActionButton>
      <ul class="history-list"><For each={state().history}>{row => <li><strong>{row.operation}</strong> {row.actor.kind}{row.actor.id ? ` / ${row.actor.id}` : ''} · {row.reason} · {new Date(row.createdAt).toLocaleString()} · {short(row.versionId)}
        <Show when={row.versionId === state().head?.versionId}> · current</Show><Show when={!row.retained}> · not retained</Show><Show when={row.versionId === row.previousVersionId}> · no definition change</Show>
        <Show when={row.evidence.length}><div>{row.evidence.join(', ')}</div></Show>
        <Show when={row.retained && row.versionId !== state().head?.versionId}><ActionButton class="secondary" disabled={busy()} onClick={() => setAction({ kind: 'restore', versionId: row.versionId })}>Restore</ActionButton></Show>
      </li>}</For></ul>
      <h3>Compare versions</h3><div class="filter-row"><label>From <select value={from()} onChange={event => setFrom(event.currentTarget.value)}><option value="">Previous version</option><For each={state().history.filter(row => row.retained)}>{row => <option value={row.versionId}>{short(row.versionId)} · {row.operation}</option>}</For></select></label>
      <label>To <select value={to()} onChange={event => setTo(event.currentTarget.value)}><option value="current">Current</option><For each={state().history.filter(row => row.retained)}>{row => <option value={row.versionId}>{short(row.versionId)} · {row.operation}</option>}</For></select></label></div>
      <Show when={!diff.loading} fallback={<LoadingState label="Loading diff…" />}><Show when={diff()}>{entries => <DiffEntries entries={entries()} />}</Show></Show>
      <h3>Pending rollback proposals</h3><Show when={state().proposals.length} fallback={<p>No pending proposals.</p>}><ul class="history-list"><For each={state().proposals}>{proposal => <li><strong>{short(proposal.regressedVersionId)} → {short(proposal.rollbackToVersionId)}</strong> · {proposal.policy}<div>Baseline: {proposal.baselineSessionId} · Target: {proposal.targetSessionId}</div><ul><For each={proposal.regressions}>{regression => <li>{regression.kind} {regression.gateId} {regression.detail}</li>}</For></ul><ActionButton disabled={busy()} onClick={() => setAction({ kind: 'approve', proposal })}>Approve</ActionButton> <ActionButton class="secondary" disabled={busy()} onClick={() => setAction({ kind: 'reject', proposal })}>Reject</ActionButton></li>}</For></ul></Show>
      <Show when={action() && state().head}><Confirm action={action()!} head={state().head!.versionId} workflowName={props.workflowName} busy={busy()} onCancel={() => setAction(undefined)} onConfirm={reason => void perform(reason)} /></Show>
    </>}</Show></Show>
  </section>
}
