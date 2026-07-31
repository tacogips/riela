import { For, Show, createEffect, createMemo, createSignal, on } from 'solid-js'
import { NoteWorkspaceClient } from '../notes/workspace'
import type { NoteAgentCitation, NoteAgentSaveResult, NoteAgentTurn } from '../notes/workspace'
import { MarkdownBody } from '../components/Markdown'
import { ErrorBanner, PageHeader } from '../components/Primitives'
import { assistantErrorMessage } from '../components/NotebookExpansionPanel'
import '../note-agent.css'

// Chat over the note library, mirroring the native RielaNoteAgentViewModel: each
// turn is answered first and persisted second, so a storage failure never
// discards an answer. The first non-temporary save creates a conversation
// notebook; later turns are appended to it.

const agentSearchLimit = 5

/// Inlined attachment text is capped so a huge file cannot blow up the agent
/// prompt; larger files should be attached to a note instead.
export const maximumAttachmentBytes = 256 * 1024

export interface AgentDraftAttachment {
  id: string
  filename: string
  text: string
}

export interface AgentTranscriptTurn {
  turnId: string
  userMarkdown: string
  assistantMarkdown: string
  citations: NoteAgentCitation[]
  persistedNoteIds: string[]
  /** What the transcript shows: the typed draft, without the inlined attachments. */
  displayMarkdown?: string
  attachmentNames?: string[]
}

export function deriveConversationTitle(turns: AgentTranscriptTurn[]): string {
  const seed = turns[0]?.userMarkdown ?? ''
  const firstLine = seed.split('\n').find((line) => line.trim().length > 0) ?? ''
  const trimmed = firstLine.trim()
  return trimmed.length === 0 ? 'Agent conversation' : trimmed.slice(0, 80)
}

/** A fence longer than any backtick run inside the content keeps the block
    well-formed even when the attached file itself contains fenced code. */
export function attachmentFence(text: string): string {
  let longestRun = 0
  let currentRun = 0
  for (const character of text) {
    if (character === '`') {
      currentRun += 1
      longestRun = Math.max(longestRun, currentRun)
    } else {
      currentRun = 0
    }
  }
  return '`'.repeat(Math.max(3, longestRun + 1))
}

/** The message actually sent to the agent: the typed draft followed by each
    attachment inlined as a fenced block labelled with its filename. */
export function composeAgentMessage(draft: string, attachments: AgentDraftAttachment[]): string {
  const trimmedDraft = draft.trim()
  if (attachments.length === 0) return trimmedDraft
  const sections = attachments.map((attachment) => {
    const fence = attachmentFence(attachment.text)
    return `Attached file \`${attachment.filename}\`:\n${fence}\n${attachment.text}\n${fence}`
  })
  return [trimmedDraft, ...sections].filter((section) => section.length > 0).join('\n\n')
}

export type AttachmentValidation =
  | { kind: 'attachment'; text: string }
  | { kind: 'error'; message: string }

export function validateAttachment(filename: string, bytes: Uint8Array): AttachmentValidation {
  if (bytes.byteLength > maximumAttachmentBytes) {
    return { kind: 'error', message: `${filename} is too large to attach (max ${maximumAttachmentBytes / 1024} KB).` }
  }
  try {
    return { kind: 'attachment', text: new TextDecoder('utf-8', { fatal: true }).decode(bytes) }
  } catch {
    return { kind: 'error', message: `${filename} is not a text file. Only text files can be attached here.` }
  }
}

export function unsavedTurnIndices(turns: AgentTranscriptTurn[]): number[] {
  return turns.flatMap((turn, index) => turn.persistedNoteIds.length === 0 ? [index] : [])
}

export function assignPersistedNoteIds(
  turns: AgentTranscriptTurn[],
  indices: number[],
  noteIds: string[],
): AgentTranscriptTurn[] {
  if (indices.length !== noteIds.length) return turns
  const assigned = new Map(indices.map((index, offset) => [index, noteIds[offset] ?? '']))
  return turns.map((turn, index) => {
    const noteId = assigned.get(index)
    return noteId ? { ...turn, persistedNoteIds: [noteId] } : turn
  })
}

function agentTurnPayload(turn: AgentTranscriptTurn): NoteAgentTurn {
  return {
    userMarkdown: turn.userMarkdown,
    assistantMarkdown: turn.assistantMarkdown,
    citations: turn.citations,
  }
}

export interface AgentPersistenceClient {
  saveAgentConversation(title: string, turns: NoteAgentTurn[]): Promise<NoteAgentSaveResult>
  appendAgentTurn(notebookId: string, turn: NoteAgentTurn): Promise<NoteAgentSaveResult>
}

/** Persists every unsaved turn in transcript order and returns the conversation
    notebook id. Each turn is marked persisted as soon as the host confirms it,
    so a failure part-way through keeps the earlier work. */
export async function persistUnsavedTurns(
  client: AgentPersistenceClient,
  read: () => AgentTranscriptTurn[],
  apply: (turns: AgentTranscriptTurn[]) => void,
  notebookId: string,
  title?: string,
): Promise<string> {
  const indices = unsavedTurnIndices(read())
  if (indices.length === 0) return notebookId
  if (notebookId) {
    for (const index of indices) {
      const turn = read()[index]
      if (!turn) continue
      const appended = await client.appendAgentTurn(notebookId, agentTurnPayload(turn))
      apply(assignPersistedNoteIds(read(), [index], appended.noteIds))
    }
    return notebookId
  }
  // The first save persists every unsaved turn, not just the newest, so leaving
  // temporary mode never strands earlier turns.
  const current = read()
  const unsaved = indices
    .map((index) => current[index])
    .filter((turn): turn is AgentTranscriptTurn => turn !== undefined)
  const saved = await client.saveAgentConversation(
    title?.trim() || deriveConversationTitle(current),
    unsaved.map(agentTurnPayload),
  )
  apply(assignPersistedNoteIds(read(), indices, saved.noteIds))
  return saved.notebookId
}

export interface NoteAgentPrefill {
  draft: string
  attachment?: { name: string; content: string }
}

export function NoteAgentView(props: {
  profileName: string
  prefill?: NoteAgentPrefill | undefined
  onPrefillConsumed?: () => void
}) {
  const client = new NoteWorkspaceClient(() => props.profileName)
  const [turns, setTurns] = createSignal<AgentTranscriptTurn[]>([])
  const [conversationNotebookId, setConversationNotebookId] = createSignal('')
  const [temporary, setTemporary] = createSignal(false)
  const [draft, setDraft] = createSignal('')
  const [titleDraft, setTitleDraft] = createSignal('')
  const [attachments, setAttachments] = createSignal<AgentDraftAttachment[]>([])
  const [attachmentError, setAttachmentError] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [failure, setFailure] = createSignal('')
  let composerInput: HTMLInputElement | undefined
  let fileInput: HTMLInputElement | undefined

  const pendingCount = createMemo(() => unsavedTurnIndices(turns()).length)
  const defaultTitle = createMemo(() => deriveConversationTitle(turns()))
  const canSubmit = createMemo(() => !busy() && (draft().trim().length > 0 || attachments().length > 0))

  const persistPending = async (title?: string) => {
    const notebookId = await persistUnsavedTurns(client, turns, setTurns, conversationNotebookId(), title)
    setConversationNotebookId(notebookId)
  }

  const submit = async () => {
    if (!canSubmit()) return
    const typed = draft().trim()
    const attached = attachments()
    const message = composeAgentMessage(draft(), attached)
    if (!message) return
    setBusy(true)
    setFailure('')
    setDraft('')
    setAttachments([])
    setAttachmentError('')
    try {
      const answered = await client.agentTurn(message, agentSearchLimit)
      setTurns((current) => [...current, {
        turnId: crypto.randomUUID(),
        userMarkdown: answered.userMarkdown || message,
        displayMarkdown: typed,
        attachmentNames: attached.map((attachment) => attachment.filename),
        assistantMarkdown: answered.assistantMarkdown,
        citations: answered.citations ?? [],
        persistedNoteIds: [],
      }])
      if (!temporary()) await persistPending()
    } catch (error) {
      setFailure(assistantErrorMessage(error, "Couldn't complete the agent turn. Please try again."))
    } finally {
      setBusy(false)
    }
  }

  const saveConversation = async () => {
    if (busy() || pendingCount() === 0) return
    setBusy(true)
    setFailure('')
    try {
      await persistPending(titleDraft())
      setTemporary(false)
      setTitleDraft('')
    } catch (error) {
      setFailure(assistantErrorMessage(error, "Couldn't save the conversation. Please try again."))
    } finally {
      setBusy(false)
    }
  }

  // Leaving temporary mode persists what accumulated while it was on, so the
  // turns typed as temporary are never stranded behind the newer ones.
  const changeTemporary = async (next: boolean) => {
    setTemporary(next)
    if (next || busy() || pendingCount() === 0) return
    await saveConversation()
  }

  const attachFiles = async (files: FileList | null) => {
    if (!files) return
    for (const file of Array.from(files)) {
      let bytes: Uint8Array
      try {
        bytes = new Uint8Array(await file.arrayBuffer())
      } catch {
        setAttachmentError(`Could not read ${file.name}.`)
        continue
      }
      const validated = validateAttachment(file.name, bytes)
      if (validated.kind === 'error') {
        setAttachmentError(validated.message)
        continue
      }
      setAttachmentError('')
      setAttachments((current) => [...current, {
        id: crypto.randomUUID(),
        filename: file.name,
        text: validated.text,
      }])
    }
  }

  const removeAttachment = (id: string) => {
    setAttachments((current) => current.filter((attachment) => attachment.id !== id))
    setAttachmentError('')
  }

  const startNewConversation = () => {
    if (busy()) return
    setTurns([])
    setConversationNotebookId('')
    setDraft('')
    setTitleDraft('')
    setAttachments([])
    setAttachmentError('')
    setTemporary(false)
    setFailure('')
  }

  createEffect(on(() => props.prefill, (prefill) => {
    if (!prefill) return
    setDraft(prefill.draft)
    setAttachments(prefill.attachment
      ? [{ id: crypto.randomUUID(), filename: prefill.attachment.name, text: prefill.attachment.content }]
      : [])
    setAttachmentError('')
    composerInput?.focus()
    props.onPrefillConsumed?.()
  }))

  return (
    <div class="page">
      <PageHeader
        eyebrow="NOTES"
        title="Note Agent"
        description="Ask questions across the note library. Answers cite the notes they came from."
        actions={
          <div class="assistant-panel-actions">
            <button class="secondary" type="button" disabled={busy() || turns().length === 0} onClick={startNewConversation}>
              New chat
            </button>
            <button type="button" disabled={busy() || pendingCount() === 0} onClick={() => void saveConversation()}>
              Save conversation
            </button>
          </div>
        }
      />
      <div class="panel assistant-panel">
        <div class="assistant-toolbar">
          <label class="check-row">
            <input
              type="checkbox"
              checked={temporary()}
              disabled={busy()}
              onChange={(event) => void changeTemporary(event.currentTarget.checked)}
            />
            Temporary chat (not saved automatically)
          </label>
          <Show when={conversationNotebookId()} fallback={
            <Show when={turns().length > 0}>
              <label class="assistant-title-field">
                Conversation title
                <input
                  type="text"
                  placeholder={defaultTitle()}
                  value={titleDraft()}
                  disabled={busy()}
                  onInput={(event) => setTitleDraft(event.currentTarget.value)}
                />
              </label>
            </Show>
          }>
            <span class="assistant-notebook-chip">Saved to notebook {conversationNotebookId()}</span>
          </Show>
        </div>
        <Show when={failure()}><ErrorBanner message={failure()} /></Show>
        <Show when={turns().length === 0}>
          <p class="subtle">Ask anything about your notes — for example “what did I decide about the kanban status sets?”</p>
        </Show>
        <div class="assistant-transcript">
          <For each={turns()}>{(turn) => (
            <article class="assistant-turn">
              <div class="assistant-message user">
                <span class="assistant-role">You</span>
                <Show when={(turn.displayMarkdown ?? turn.userMarkdown).length > 0}>
                  <p>{turn.displayMarkdown ?? turn.userMarkdown}</p>
                </Show>
                <Show when={(turn.attachmentNames ?? []).length > 0}>
                  <ul class="assistant-turn-files">
                    <For each={turn.attachmentNames}>{(filename) => <li>{filename}</li>}</For>
                  </ul>
                </Show>
              </div>
              <div class="assistant-message agent">
                <span class="assistant-role">Agent</span>
                <MarkdownBody markdown={turn.assistantMarkdown} />
              </div>
              <Show when={turn.citations.length > 0}>
                <ul class="assistant-citations">
                  <For each={turn.citations}>{(citation) => (
                    <li title={citation.snippet ?? undefined}>{citation.title || citation.noteId}</li>
                  )}</For>
                </ul>
              </Show>
              <Show when={turn.persistedNoteIds.length === 0}>
                <span class="assistant-unsaved">Not saved yet</span>
              </Show>
            </article>
          )}</For>
        </div>
        <Show when={attachmentError()}>
          <p class="assistant-attachment-error">{attachmentError()}</p>
        </Show>
        <Show when={attachments().length > 0}>
          <ul class="assistant-attachments">
            <For each={attachments()}>{(attachment) => (
              <li class="assistant-attachment-chip">
                <span>{attachment.filename}</span>
                <button
                  type="button"
                  class="assistant-attachment-remove"
                  aria-label={`Remove ${attachment.filename}`}
                  disabled={busy()}
                  onClick={() => removeAttachment(attachment.id)}
                >
                  ×
                </button>
              </li>
            )}</For>
          </ul>
        </Show>
        <form class="assistant-composer" onSubmit={(event) => { event.preventDefault(); void submit() }}>
          <input
            ref={fileInput}
            class="assistant-file-input"
            type="file"
            multiple
            onChange={(event) => {
              const input = event.currentTarget
              void attachFiles(input.files).finally(() => { input.value = '' })
            }}
          />
          <button
            type="button"
            class="secondary assistant-attach-button"
            disabled={busy()}
            title="Attach text files"
            aria-label="Attach files"
            onClick={() => fileInput?.click()}
          >
            Attach
          </button>
          <label class="grow">
            <span class="sr-only">Ask Riela Note</span>
            <input
              ref={composerInput}
              type="text"
              placeholder="Ask Riela Note"
              value={draft()}
              disabled={busy()}
              onInput={(event) => setDraft(event.currentTarget.value)}
            />
          </label>
          <button type="submit" disabled={!canSubmit()}>
            {busy() ? 'Sending…' : 'Send'}
          </button>
        </form>
      </div>
    </div>
  )
}
