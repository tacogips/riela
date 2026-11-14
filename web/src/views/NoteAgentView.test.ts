import { describe, expect, test } from 'bun:test'
import type { NoteAgentSaveResult, NoteAgentTurn } from '../notes/workspace'
import type { AgentPersistenceClient, AgentTranscriptTurn } from './NoteAgentView'
import {
  assignPersistedNoteIds,
  attachmentFence,
  composeAgentMessage,
  deriveConversationTitle,
  maximumAttachmentBytes,
  persistUnsavedTurns,
  unsavedTurnIndices,
  validateAttachment,
} from './NoteAgentView'

function turn(userMarkdown: string, persistedNoteIds: string[] = []): AgentTranscriptTurn {
  return { turnId: userMarkdown, userMarkdown, assistantMarkdown: 'answer', citations: [], persistedNoteIds }
}

describe('conversation title derivation', () => {
  test('uses the first non-empty line of the first user message', () => {
    expect(deriveConversationTitle([turn('What did I decide?\nMore context')])).toBe('What did I decide?')
    expect(deriveConversationTitle([turn('\n\n  Kanban status sets  ')])).toBe('Kanban status sets')
  })

  test('falls back when there is nothing to derive from', () => {
    expect(deriveConversationTitle([])).toBe('Agent conversation')
    expect(deriveConversationTitle([turn('   \n  ')])).toBe('Agent conversation')
  })

  test('caps the title at 80 characters', () => {
    const title = deriveConversationTitle([turn('x'.repeat(200))])
    expect(title.length).toBe(80)
  })

  test('derives from the typed draft even when attachments follow it', () => {
    const composed = composeAgentMessage('Ask about note-1:', [
      { id: 'a', filename: 'note-1.md', text: 'body' },
    ])
    expect(deriveConversationTitle([turn(composed)])).toBe('Ask about note-1:')
  })
})

describe('attachment fencing', () => {
  test('uses a three backtick fence when the content has no backtick runs', () => {
    expect(attachmentFence('plain text')).toBe('```')
    expect(attachmentFence('inline `code` sample')).toBe('```')
  })

  test('outgrows the longest backtick run inside the content', () => {
    expect(attachmentFence('```\ncode\n```')).toBe('````')
    expect(attachmentFence('a ````` b')).toBe('``````')
  })

  test('inlines every attachment as a labelled fenced block', () => {
    const message = composeAgentMessage('  Summarise these  ', [
      { id: 'a', filename: 'a.md', text: 'alpha' },
      { id: 'b', filename: 'b.md', text: '```\nbeta\n```' },
    ])
    expect(message).toBe([
      'Summarise these',
      'Attached file `a.md`:\n```\nalpha\n```',
      'Attached file `b.md`:\n````\n```\nbeta\n```\n````',
    ].join('\n\n'))
  })

  test('sends attachments alone when the draft is empty', () => {
    expect(composeAgentMessage('   ', [{ id: 'a', filename: 'a.md', text: 'alpha' }]))
      .toBe('Attached file `a.md`:\n```\nalpha\n```')
  })

  test('returns just the trimmed draft when nothing is attached', () => {
    expect(composeAgentMessage('  hello  ', [])).toBe('hello')
  })
})

describe('attachment validation', () => {
  test('accepts utf-8 text within the size cap', () => {
    const bytes = new TextEncoder().encode('héllo — notes')
    expect(validateAttachment('a.md', bytes)).toEqual({ kind: 'attachment', text: 'héllo — notes' })
  })

  test('rejects files over 256 KB', () => {
    const bytes = new Uint8Array(maximumAttachmentBytes + 1)
    expect(validateAttachment('big.md', bytes)).toEqual({
      kind: 'error',
      message: 'big.md is too large to attach (max 256 KB).',
    })
  })

  test('accepts a file exactly at the size cap', () => {
    const bytes = new Uint8Array(maximumAttachmentBytes)
    expect(validateAttachment('edge.md', bytes).kind).toBe('attachment')
  })

  test('rejects content that is not valid utf-8', () => {
    const bytes = new Uint8Array([0x68, 0x69, 0xff, 0xfe, 0x00])
    expect(validateAttachment('image.png', bytes)).toEqual({
      kind: 'error',
      message: 'image.png is not a text file. Only text files can be attached here.',
    })
  })
})

describe('transcript persistence bookkeeping', () => {
  test('reports only turns without persisted notes', () => {
    const turns = [turn('a', ['note-a']), turn('b'), turn('c'), turn('d', ['note-d'])]
    expect(unsavedTurnIndices(turns)).toEqual([1, 2])
  })

  test('assigns returned note ids positionally to the saved turns', () => {
    const turns = [turn('a', ['note-a']), turn('b'), turn('c')]
    const updated = assignPersistedNoteIds(turns, [1, 2], ['note-b', 'note-c'])
    expect(updated.map((entry) => entry.persistedNoteIds)).toEqual([['note-a'], ['note-b'], ['note-c']])
    expect(unsavedTurnIndices(updated)).toEqual([])
  })

  test('leaves the transcript untouched when the host returns a different count', () => {
    const turns = [turn('a'), turn('b')]
    expect(assignPersistedNoteIds(turns, [0, 1], ['note-a'])).toBe(turns)
  })
})

class RecordingPersistenceClient implements AgentPersistenceClient {
  readonly calls: string[] = []
  private counter = 0
  constructor(private readonly failAppendAt?: number) {}

  async saveAgentConversation(title: string, turns: NoteAgentTurn[]): Promise<NoteAgentSaveResult> {
    this.calls.push(`save:${title}:${turns.map((entry) => entry.userMarkdown).join(',')}`)
    return { notebookId: 'nb-1', noteIds: turns.map(() => `note-${(this.counter += 1)}`) }
  }

  async appendAgentTurn(notebookId: string, turn: NoteAgentTurn): Promise<NoteAgentSaveResult> {
    this.calls.push(`append:${notebookId}:${turn.userMarkdown}`)
    this.counter += 1
    if (this.counter === this.failAppendAt) throw new Error('append failed')
    return { notebookId, noteIds: [`note-${this.counter}`] }
  }
}

function transcriptStore(initial: AgentTranscriptTurn[]) {
  let value = initial
  return { read: () => value, apply: (next: AgentTranscriptTurn[]) => { value = next } }
}

describe('unsaved turn persistence', () => {
  test('creates the conversation with every unsaved turn in transcript order', async () => {
    const store = transcriptStore([turn('first'), turn('second'), turn('third')])
    const client = new RecordingPersistenceClient()
    const notebookId = await persistUnsavedTurns(client, store.read, store.apply, '')
    expect(notebookId).toBe('nb-1')
    expect(client.calls).toEqual(['save:first:first,second,third'])
    expect(store.read().map((entry) => entry.persistedNoteIds)).toEqual([['note-1'], ['note-2'], ['note-3']])
  })

  test('prefers an explicit title over the derived one', async () => {
    const store = transcriptStore([turn('first')])
    const client = new RecordingPersistenceClient()
    await persistUnsavedTurns(client, store.read, store.apply, '', '  Weekly review  ')
    expect(client.calls).toEqual(['save:Weekly review:first'])
  })

  test('appends only the unsaved turns, in order, once a notebook exists', async () => {
    const store = transcriptStore([turn('first', ['note-a']), turn('second'), turn('third')])
    const client = new RecordingPersistenceClient()
    const notebookId = await persistUnsavedTurns(client, store.read, store.apply, 'nb-9')
    expect(notebookId).toBe('nb-9')
    expect(client.calls).toEqual(['append:nb-9:second', 'append:nb-9:third'])
    expect(store.read().map((entry) => entry.persistedNoteIds)).toEqual([['note-a'], ['note-1'], ['note-2']])
  })

  test('keeps earlier appends when a later one fails', async () => {
    const store = transcriptStore([turn('first'), turn('second')])
    const client = new RecordingPersistenceClient(2)
    await expect(persistUnsavedTurns(client, store.read, store.apply, 'nb-9')).rejects.toThrow('append failed')
    expect(store.read().map((entry) => entry.persistedNoteIds)).toEqual([['note-1'], []])
  })

  test('does nothing when every turn is already persisted', async () => {
    const store = transcriptStore([turn('first', ['note-a'])])
    const client = new RecordingPersistenceClient()
    expect(await persistUnsavedTurns(client, store.read, store.apply, '')).toBe('')
    expect(client.calls).toEqual([])
  })
})
