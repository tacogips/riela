import { describe, expect, test } from 'bun:test'
import { applyNotebookLockMutation } from './notebookLock'
import type { Notebook } from './types'

const notebook = (readOnly: boolean): Notebook => ({
  notebookId: 'system-memory',
  title: 'System Memory',
  progress: 'none',
  readOnly,
  createdAt: '2026-08-01T00:00:00Z',
  updatedAt: '2026-08-01T00:00:00Z',
  tags: [],
})

describe('system-memory notebook lock UI', () => {
  test('adopts unlock without clearing content state', async () => {
    const effects: string[] = []
    const updated = await applyNotebookLockMutation(
      notebook(true),
      false,
      async () => notebook(false),
      {
        adopt: () => effects.push('adopt'),
        isCurrent: () => true,
        clearContentState: () => effects.push('clear'),
        loadLockedPreview: async () => { effects.push('preview') },
      },
    )
    expect(updated.readOnly).toBe(false)
    expect(effects).toEqual(['adopt'])
  })

  test('relock closes stale composer state and disables content actions', async () => {
    let composeOpen = true
    let activeNoteId: string | undefined = 'note-1'
    const effects: string[] = []
    const updated = await applyNotebookLockMutation(
      notebook(false),
      true,
      async () => notebook(true),
      {
        adopt: () => effects.push('adopt'),
        isCurrent: () => true,
        clearContentState: () => {
          composeOpen = false
          activeNoteId = undefined
          effects.push('clear')
        },
        loadLockedPreview: async () => { effects.push('preview') },
      },
    )
    expect(composeOpen).toBe(false)
    expect(activeNoteId).toBeUndefined()
    expect(updated.readOnly).toBe(true)
    expect(effects).toEqual(['adopt', 'clear', 'preview'])
  })

  test('failed lock mutation preserves composer and visible state', async () => {
    const effects: string[] = []
    await expect(applyNotebookLockMutation(
      notebook(false),
      true,
      async () => { throw new Error('offline') },
      {
        adopt: () => effects.push('adopt'),
        isCurrent: () => true,
        clearContentState: () => effects.push('clear'),
        loadLockedPreview: async () => { effects.push('preview') },
      },
    )).rejects.toThrow('offline')
    expect(effects).toEqual([])
  })

  test('uses the canonical response when it differs from the requested state', async () => {
    const effects: string[] = []
    const updated = await applyNotebookLockMutation(
      notebook(true),
      false,
      async () => notebook(true),
      {
        adopt: () => effects.push('adopt'),
        isCurrent: () => true,
        clearContentState: () => effects.push('clear'),
        loadLockedPreview: async () => { effects.push('preview') },
      },
    )
    expect(updated.readOnly).toBe(true)
    expect(effects).toEqual(['adopt', 'clear', 'preview'])
  })

  test('stale relock adopts canonical state without clearing a newly selected notebook', async () => {
    const effects: string[] = []
    const updated = await applyNotebookLockMutation(
      notebook(false),
      true,
      async () => notebook(true),
      {
        adopt: () => effects.push('adopt'),
        isCurrent: () => false,
        clearContentState: () => effects.push('clear'),
        loadLockedPreview: async () => { effects.push('preview') },
      },
    )
    expect(updated.readOnly).toBe(true)
    expect(effects).toEqual(['adopt'])
  })
})
