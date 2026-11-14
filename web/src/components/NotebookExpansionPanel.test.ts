import { describe, expect, test } from 'bun:test'
import { APIError } from '../api'
import type { NoteExpansionAnswer, NoteExpansionSession } from '../notes/workspace'
import {
  assistantErrorMessage,
  expansionAnswerMarkdown,
  markTurnPersisted,
  notebookExpansionSeedQuestion,
  pendingExpansionTurns,
  seedExpansionTurns,
} from './NotebookExpansionPanel'

const session: NoteExpansionSession = {
  sourceNotebookId: 'notebook-source',
  conversationNotebookId: 'notebook-conversation',
  initialNoteId: 'note-initial',
  compactSummaryMarkdown: '# Summary',
  sourceNoteIds: ['note-1', 'note-2'],
}

describe('expansion transcript seeding', () => {
  test('opens with the compact summary already persisted as the initial note', () => {
    expect(seedExpansionTurns(session)).toEqual([{
      turnId: 'note-initial',
      questionMarkdown: notebookExpansionSeedQuestion,
      assistantMarkdown: '# Summary',
      persisted: true,
    }])
  })

  test('tracks which turns still need to be appended to the conversation notebook', () => {
    const turns = [
      ...seedExpansionTurns(session),
      { turnId: 'turn-1', questionMarkdown: 'why?', assistantMarkdown: 'because', persisted: false },
    ]
    expect(pendingExpansionTurns(turns).map((turn) => turn.turnId)).toEqual(['turn-1'])
    expect(pendingExpansionTurns(markTurnPersisted(turns, 'turn-1'))).toEqual([])
  })
})

describe('expansion answer decoding', () => {
  test('accepts the assistantMarkdown field the host actually sends', () => {
    const answer = { assistantMarkdown: 'from the host' } as unknown as NoteExpansionAnswer
    expect(expansionAnswerMarkdown(answer)).toBe('from the host')
  })

  test('accepts the answerMarkdown field the workspace client declares', () => {
    expect(expansionAnswerMarkdown({ answerMarkdown: 'declared' })).toBe('declared')
  })

  test('returns an empty string for an unrecognised payload', () => {
    expect(expansionAnswerMarkdown({} as NoteExpansionAnswer)).toBe('')
  })
})

describe('assistant error messages', () => {
  test('explains host provider failures in plain language', () => {
    const notConfigured = new APIError('raw', 409, 'provider_not_configured')
    expect(assistantErrorMessage(notConfigured, 'fallback')).toContain('workflow provider configured')
    const sourceChanged = new APIError('raw', 409, 'source_changed')
    expect(assistantErrorMessage(sourceChanged, 'fallback')).toContain('changed while it was being summarized')
    const timedOut = new APIError('raw', 504, 'provider_timeout')
    expect(assistantErrorMessage(timedOut, 'fallback')).toContain('timed out')
  })

  test('passes through other host messages and falls back for opaque failures', () => {
    expect(assistantErrorMessage(new APIError('Notebook is empty', 400, 'note_operation_failed'), 'fallback'))
      .toBe('Notebook is empty')
    expect(assistantErrorMessage('boom', 'fallback')).toBe('fallback')
  })
})
