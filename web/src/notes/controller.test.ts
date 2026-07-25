import { describe, expect, test } from 'bun:test'
import { NotebookProgressController, NotebookScopeController } from './controller'
import type { Notebook, NotebookProgress } from './types'

const notebook = (progress: NotebookProgress): Notebook => ({
  notebookId: 'book-1',
  title: 'Launch',
  progress,
  createdAt: '2026-07-25T00:00:00Z',
  updatedAt: '2026-07-25T00:00:00Z',
  tags: [],
})

describe('progress convergence', () => {
  test('serializes writes and replays the newest intent outside view context', async () => {
    const writes: NotebookProgress[] = []
    let releaseFirst: (() => void) | undefined
    const firstGate = new Promise<void>((resolve) => { releaseFirst = resolve })
    const updates: NotebookProgress[] = []
    const controller = new NotebookProgressController({
      setProgress: async (_id, progress) => {
        writes.push(progress)
        if (writes.length === 1) await firstGate
        return notebook(progress)
      },
      readNotebook: async () => notebook('none'),
    }, (updated) => updates.push(updated.progress))

    const first = controller.move(notebook('none'), 'progress')
    const second = controller.move(notebook('progress'), 'done')
    releaseFirst?.()
    await Promise.all([first, second])
    expect(writes).toEqual(['progress', 'done'])
    expect(updates.at(-1)).toBe('done')
  })

  test('reconciles canonical state after current failure', async () => {
    const updates: Array<{ progress: NotebookProgress; error?: string }> = []
    const controller = new NotebookProgressController({
      setProgress: async () => { throw new Error('offline') },
      readNotebook: async () => notebook('pending'),
    }, (updated, error) => updates.push({ progress: updated.progress, error }))
    await controller.move(notebook('none'), 'done')
    expect(updates.at(-1)).toEqual({ progress: 'pending', error: 'offline' })
  })

  test('falls back to the last canonical state when write and refresh both fail', async () => {
    const updates: Array<{ progress: NotebookProgress; error?: string }> = []
    const controller = new NotebookProgressController({
      setProgress: async () => { throw new Error('write offline') },
      readNotebook: async () => { throw new Error('read offline') },
    }, (updated, error) => updates.push({ progress: updated.progress, error }))
    controller.adopt(notebook('none'))

    await controller.move(notebook('none'), 'done')
    expect(updates.at(-1)).toEqual({
      progress: 'none',
      error: 'write offline; canonical refresh failed: read offline',
    })
  })

  test('rejects a refresh snapshot older than a completed progress mutation', async () => {
    const controller = new NotebookProgressController({
      setProgress: async (_id, progress) => notebook(progress),
      readNotebook: async () => notebook('none'),
    }, () => {})
    controller.adopt(notebook('none'))
    const refreshSnapshot = controller.snapshot()

    await controller.move(notebook('none'), 'done')

    expect(controller.adopt(notebook('none'), refreshSnapshot).progress).toBe('done')
    expect(controller.adopt(notebook('done'), controller.snapshot()).progress).toBe('done')
  })
})

describe('notebook scope generation', () => {
  test('keeps one mutually exclusive folder, tag, or all-notebooks scope', () => {
    const controller = new NotebookScopeController()
    expect(controller.tagFilter()).toEqual([])

    controller.select({ kind: 'folder', tagId: 'folder-work', tagName: 'Work' })
    expect(controller.current()).toEqual({ kind: 'folder', tagId: 'folder-work', tagName: 'Work' })
    expect(controller.tagFilter()).toEqual(['Work'])

    controller.select({ kind: 'tag', tagId: 'topic-launch', tagName: 'Launch', classId: 'topic' })
    expect(controller.current()).toEqual({
      kind: 'tag',
      tagId: 'topic-launch',
      tagName: 'Launch',
      classId: 'topic',
    })
    expect(controller.tagFilter()).toEqual(['Launch'])

    controller.select({ kind: 'all' })
    expect(controller.tagFilter()).toEqual([])
  })

  test('invalidates older folder-to-tag and tag-to-folder completions', () => {
    const controller = new NotebookScopeController()
    const folder = controller.select({ kind: 'folder', tagId: 'folder-work', tagName: 'Work' })
    const tag = controller.select({ kind: 'tag', tagId: 'topic-launch', tagName: 'Launch', classId: 'topic' })
    expect(controller.isCurrent(folder)).toBe(false)
    expect(controller.isCurrent(tag)).toBe(true)

    const newerFolder = controller.select({ kind: 'folder', tagId: 'folder-archive', tagName: 'Archive' })
    expect(controller.isCurrent(tag)).toBe(false)
    expect(controller.isCurrent(newerFolder)).toBe(true)
  })
})
