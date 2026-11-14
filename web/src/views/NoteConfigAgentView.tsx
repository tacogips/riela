import { For, Show, createSignal } from 'solid-js'
import { NoteWorkspaceClient } from '../notes/workspace'
import type { NoteConfigProposal } from '../notes/workspace'
import { MarkdownBody } from '../components/Markdown'
import { ErrorBanner, PageHeader } from '../components/Primitives'
import { assistantErrorMessage } from '../components/NotebookExpansionPanel'
import '../note-agent.css'

// Config agent, mirroring the native RielaNoteConfigAgentViewModel: describe an
// ingestion topic, review the proposed tag class / tag / auto action / ingestion
// workflow, then apply it. The host picks the workflow root, so — unlike the
// native window — there is no root field to edit here.

export interface ConfigWorkflowScaffold {
  workflowId: string
  workflowRoot: string
  workflowPath: string
}

export interface ConfigProposalEntry {
  entryId: string
  proposal: NoteConfigProposal
  applied?: ConfigWorkflowScaffold
}

export function configProposalSummaryRows(
  proposal: NoteConfigProposal,
): Array<{ label: string; value: string }> {
  return [
    { label: 'Class', value: proposal.tagClass.classId },
    { label: 'Tag', value: proposal.tag.name },
    { label: 'Action', value: proposal.autoAction.actionId },
    { label: 'Trigger', value: proposal.autoAction.trigger },
    { label: 'Workflow', value: proposal.ingestionWorkflow.workflowId },
    { label: 'Notebook kind', value: proposal.ingestionWorkflow.notebookKindTag || 'Default' },
    { label: 'Translation', value: proposal.ingestionWorkflow.translationEnabled ? 'Enabled' : 'Disabled' },
  ]
}

export function replaceProposalEntry(
  entries: ConfigProposalEntry[],
  entryId: string,
  applied: ConfigWorkflowScaffold,
): ConfigProposalEntry[] {
  return entries.map((entry) => entry.entryId === entryId ? { ...entry, applied } : entry)
}

export function NoteConfigAgentView(props: { profileName: string }) {
  const client = new NoteWorkspaceClient(() => props.profileName)
  const [entries, setEntries] = createSignal<ConfigProposalEntry[]>([])
  const [draft, setDraft] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [failure, setFailure] = createSignal('')

  const submit = async () => {
    const message = draft().trim()
    if (!message || busy()) return
    setBusy(true)
    setFailure('')
    setDraft('')
    try {
      const proposal = await client.proposeConfigChange(message)
      setEntries((current) => [...current, { entryId: crypto.randomUUID(), proposal }])
    } catch (error) {
      // Restore the typed request so a transient failure does not lose it.
      setDraft(message)
      setFailure(assistantErrorMessage(error, "Couldn't get a configuration proposal. Please try again."))
    } finally {
      setBusy(false)
    }
  }

  const apply = async (entry: ConfigProposalEntry) => {
    if (busy() || entry.applied) return
    setBusy(true)
    setFailure('')
    try {
      const result = await client.applyConfigProposal(entry.proposal)
      setEntries((current) => replaceProposalEntry(current, entry.entryId, result.workflowScaffold))
    } catch (error) {
      setFailure(assistantErrorMessage(error, "Couldn't apply the configuration proposal. Please try again."))
    } finally {
      setBusy(false)
    }
  }

  const discard = (entryId: string) => {
    if (busy()) return
    setEntries((current) => current.filter((entry) => entry.entryId !== entryId))
  }

  return (
    <div class="page">
      <PageHeader
        eyebrow="NOTES"
        title="Note Config"
        description="Describe a topic you want to capture. The agent proposes the tag class, tag, auto action, and ingestion workflow to create."
      />
      <div class="panel assistant-panel">
        <Show when={failure()}><ErrorBanner message={failure()} /></Show>
        <Show when={entries().length === 0}>
          <p class="subtle">
            For example: “collect conference talks about Swift concurrency and summarize each one”.
          </p>
        </Show>
        <div class="assistant-transcript">
          <For each={entries()}>{(entry) => (
            <article class="config-proposal">
              <div class="assistant-message user">
                <span class="assistant-role">You</span>
                <p>{entry.proposal.requestMarkdown}</p>
              </div>
              <div class="assistant-message agent">
                <span class="assistant-role">Config agent</span>
                <MarkdownBody markdown={entry.proposal.assistantMarkdown} />
              </div>
              <dl class="config-proposal-grid">
                <For each={configProposalSummaryRows(entry.proposal)}>{(row) => (
                  <div><dt>{row.label}</dt><dd>{row.value}</dd></div>
                )}</For>
              </dl>
              <Show when={entry.applied} fallback={
                <div class="config-proposal-actions">
                  <button class="secondary" type="button" disabled={busy()} onClick={() => discard(entry.entryId)}>
                    Discard
                  </button>
                  <button type="button" disabled={busy()} onClick={() => void apply(entry)}>
                    Apply
                  </button>
                </div>
              }>{(applied) => (
                <div class="config-proposal-applied">
                  <strong>Applied — created workflow {applied().workflowId}</strong>
                  <span>{applied().workflowPath}</span>
                  <span>Workflow root: {applied().workflowRoot}</span>
                </div>
              )}</Show>
            </article>
          )}</For>
        </div>
        <form class="assistant-composer" onSubmit={(event) => { event.preventDefault(); void submit() }}>
          <label class="grow">
            <span class="sr-only">Ask the config agent</span>
            <input
              type="text"
              placeholder="Ask the config agent"
              value={draft()}
              disabled={busy()}
              onInput={(event) => setDraft(event.currentTarget.value)}
            />
          </label>
          <button type="submit" disabled={busy() || draft().trim().length === 0}>
            {busy() ? 'Working…' : 'Send'}
          </button>
        </form>
      </div>
    </div>
  )
}
