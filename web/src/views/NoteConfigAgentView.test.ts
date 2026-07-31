import { describe, expect, test } from 'bun:test'
import type { NoteConfigProposal } from '../notes/workspace'
import type { ConfigProposalEntry } from './NoteConfigAgentView'
import { configProposalSummaryRows, replaceProposalEntry } from './NoteConfigAgentView'

const proposal: NoteConfigProposal = {
  requestMarkdown: 'collect swift concurrency talks',
  assistantMarkdown: 'Here is the plan.',
  tagClass: { classId: 'topic', label: 'Topic', description: null },
  tag: { name: 'swift-concurrency', classId: 'topic' },
  autoAction: {
    actionId: 'config-agent-auto-tagging-swift',
    trigger: 'NOTE_CREATED',
    workflowId: 'note-ingest-swift',
    filterJSON: null,
    enabled: true,
    position: 0,
  },
  ingestionWorkflow: {
    workflowId: 'note-ingest-swift',
    notebookKindTag: 'notebook-kind:imported-material',
    translationEnabled: true,
  },
}

describe('config proposal summary', () => {
  test('summarises what applying the proposal will create', () => {
    expect(configProposalSummaryRows(proposal)).toEqual([
      { label: 'Class', value: 'topic' },
      { label: 'Tag', value: 'swift-concurrency' },
      { label: 'Action', value: 'config-agent-auto-tagging-swift' },
      { label: 'Trigger', value: 'NOTE_CREATED' },
      { label: 'Workflow', value: 'note-ingest-swift' },
      { label: 'Notebook kind', value: 'notebook-kind:imported-material' },
      { label: 'Translation', value: 'Enabled' },
    ])
  })

  test('reads a missing notebook kind and translation flag as host defaults', () => {
    const rows = configProposalSummaryRows({
      ...proposal,
      ingestionWorkflow: { workflowId: 'note-ingest-swift' },
    })
    expect(rows).toContainEqual({ label: 'Notebook kind', value: 'Default' })
    expect(rows).toContainEqual({ label: 'Translation', value: 'Disabled' })
  })
})

describe('applied proposal tracking', () => {
  test('marks only the applied proposal with its workflow scaffold', () => {
    const entries: ConfigProposalEntry[] = [
      { entryId: 'a', proposal },
      { entryId: 'b', proposal },
    ]
    const scaffold = {
      workflowId: 'note-ingest-swift',
      workflowRoot: '/notes/workflows',
      workflowPath: '/notes/workflows/note-ingest-swift/workflow.json',
    }
    const updated = replaceProposalEntry(entries, 'b', scaffold)
    expect(updated[0]?.applied).toBeUndefined()
    expect(updated[1]?.applied).toEqual(scaffold)
  })
})
