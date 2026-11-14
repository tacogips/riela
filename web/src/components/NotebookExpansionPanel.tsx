import { For, Show, createSignal, onMount } from 'solid-js'
import { APIError } from '../api'
import { NoteWorkspaceClient } from '../notes/workspace'
import type { NoteExpansionAnswer, NoteExpansionSession } from '../notes/workspace'
import { MarkdownBody } from './Markdown'
import { ErrorBanner, LoadingState } from './Primitives'
import '../note-agent.css'

// Notebook expansion mirrors the native RielaNoteLibraryViewModel+NotebookExpand
// flow: prepare compacts the notebook into a summary and creates a conversation
// notebook, then every question is answered against that summary and appended to
// the conversation. Answers are shown before they are persisted so a storage
// failure never discards an answer the workflow already paid for.

export const notebookExpansionSeedQuestion =
  'Expand this notebook into useful key points and follow-up directions.'

export interface NotebookExpansionTurn {
  turnId: string
  questionMarkdown: string
  assistantMarkdown: string
  persisted: boolean
}

export function seedExpansionTurns(session: NoteExpansionSession): NotebookExpansionTurn[] {
  return [{
    turnId: session.initialNoteId,
    questionMarkdown: notebookExpansionSeedQuestion,
    assistantMarkdown: session.compactSummaryMarkdown,
    persisted: true,
  }]
}

export function markTurnPersisted(
  turns: NotebookExpansionTurn[],
  turnId: string,
): NotebookExpansionTurn[] {
  return turns.map((turn) => turn.turnId === turnId ? { ...turn, persisted: true } : turn)
}

export function pendingExpansionTurns(turns: NotebookExpansionTurn[]): NotebookExpansionTurn[] {
  return turns.filter((turn) => !turn.persisted)
}

// Turns a workspace API failure into a sentence a reader can act on. The
// assistant routes share the host's provider error codes, so the same mapping
// serves the agent, config agent, and expansion surfaces.
export function assistantErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof APIError) {
    switch (error.code) {
      case 'provider_not_configured':
        return 'This assistant feature needs its riela workflow provider configured on the host.'
      case 'source_changed':
        return 'The notebook changed while it was being summarized. Try again.'
      case 'provider_timeout':
        return 'The assistant workflow timed out. Try again.'
      case 'profile_conflict':
        return 'The active profile changed. Reload the page before continuing.'
      default:
        return error.message || fallback
    }
  }
  return error instanceof Error && error.message ? error.message : fallback
}

// The host encodes the expansion answer as `assistantMarkdown` while the
// workspace client types it as `answerMarkdown`; accept either so the panel
// keeps working whichever name the shared client settles on.
export function expansionAnswerMarkdown(answer: NoteExpansionAnswer): string {
  const record = answer as unknown as Record<string, unknown>
  const value = record.assistantMarkdown ?? record.answerMarkdown
  return typeof value === 'string' ? value : ''
}

export function NotebookExpansionPanel(props: {
  profileName: string
  notebookId: string
  notebookTitle: string
  onClose: () => void
}) {
  const client = new NoteWorkspaceClient(() => props.profileName)
  const [session, setSession] = createSignal<NoteExpansionSession>()
  const [turns, setTurns] = createSignal<NotebookExpansionTurn[]>([])
  const [preparing, setPreparing] = createSignal(true)
  const [prepareError, setPrepareError] = createSignal('')
  const [failure, setFailure] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [draft, setDraft] = createSignal('')

  const prepare = async () => {
    setPreparing(true)
    setPrepareError('')
    try {
      const prepared = await client.prepareExpansion(props.notebookId)
      setSession(prepared)
      setTurns(seedExpansionTurns(prepared))
    } catch (error) {
      setPrepareError(assistantErrorMessage(error, 'Could not expand this notebook. Please try again.'))
    } finally {
      setPreparing(false)
    }
  }

  onMount(() => { void prepare() })

  const persistTurn = async (turn: NotebookExpansionTurn) => {
    const active = session()
    if (!active) return
    await client.appendExpansionTurn(active.conversationNotebookId, {
      turnId: turn.turnId,
      questionMarkdown: turn.questionMarkdown,
      assistantMarkdown: turn.assistantMarkdown,
      sourceNoteIds: active.sourceNoteIds,
    })
    setTurns((current) => markTurnPersisted(current, turn.turnId))
  }

  const persistPendingTurns = async () => {
    for (const turn of pendingExpansionTurns(turns())) await persistTurn(turn)
  }

  const submit = async () => {
    const active = session()
    const question = draft().trim()
    if (!active || !question || busy()) return
    setBusy(true)
    setFailure('')
    setDraft('')
    const turnCountBefore = turns().length
    try {
      await persistPendingTurns()
      const answer = await client.expansionAnswer(
        active.sourceNotebookId,
        active.compactSummaryMarkdown,
        question,
      )
      const turn: NotebookExpansionTurn = {
        turnId: crypto.randomUUID(),
        questionMarkdown: question,
        assistantMarkdown: expansionAnswerMarkdown(answer),
        persisted: false,
      }
      setTurns((current) => [...current, turn])
      await persistTurn(turn)
    } catch (error) {
      if (turns().length === turnCountBefore) setDraft(question)
      setFailure(assistantErrorMessage(error, 'Could not answer that question. Please try again.'))
    } finally {
      setBusy(false)
    }
  }

  const retryPersist = async () => {
    if (busy()) return
    setBusy(true)
    setFailure('')
    try {
      await persistPendingTurns()
    } catch (error) {
      setFailure(assistantErrorMessage(error, 'Could not save the conversation. Please try again.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section class="assistant-panel expansion-panel" aria-label={`Expand ${props.notebookTitle}`}>
      <header class="assistant-panel-header">
        <div>
          <span class="eyebrow">EXPAND WITH AGENT</span>
          <strong>{props.notebookTitle}</strong>
        </div>
        <div class="assistant-panel-actions">
          <Show when={pendingExpansionTurns(turns()).length > 0}>
            <button class="secondary" type="button" disabled={busy()} onClick={() => void retryPersist()}>
              Save pending
            </button>
          </Show>
          <button class="secondary" type="button" onClick={props.onClose}>Close</button>
        </div>
      </header>
      <Show when={prepareError()}>
        <div class="assistant-panel-alert">
          <ErrorBanner message={prepareError()} />
          <button class="secondary" type="button" onClick={() => void prepare()}>Try again</button>
        </div>
      </Show>
      <Show when={failure()}><ErrorBanner message={failure()} /></Show>
      <Show when={preparing()}><LoadingState label="Summarizing this notebook…" /></Show>
      <Show when={!preparing() && session()}>
        <div class="assistant-transcript">
          <For each={turns()}>{(turn) => (
            <article class="assistant-turn">
              <div class="assistant-message user">
                <span class="assistant-role">You</span>
                <p>{turn.questionMarkdown}</p>
              </div>
              <div class="assistant-message agent">
                <span class="assistant-role">Agent</span>
                <MarkdownBody markdown={turn.assistantMarkdown} />
              </div>
              <Show when={!turn.persisted}>
                <span class="assistant-unsaved">Not saved to the conversation notebook yet</span>
              </Show>
            </article>
          )}</For>
        </div>
        <form
          class="assistant-composer"
          onSubmit={(event) => { event.preventDefault(); void submit() }}
        >
          <label class="grow">
            <span class="sr-only">Ask about this notebook</span>
            <input
              type="text"
              placeholder="Ask about this notebook"
              value={draft()}
              disabled={busy()}
              onInput={(event) => setDraft(event.currentTarget.value)}
            />
          </label>
          <button type="submit" disabled={busy() || draft().trim().length === 0}>
            {busy() ? 'Asking…' : 'Ask'}
          </button>
        </form>
      </Show>
    </section>
  )
}
