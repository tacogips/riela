import { describe, expect, test } from 'bun:test'
import { loadNotebookPages, notebookPageLimit } from './paging'
import type { Notebook } from './types'

const notebook = (index: number): Notebook => ({
  notebookId: `book-${index}`,
  title: `Book ${index}`,
  progress: 'none',
  createdAt: '',
  updatedAt: '',
  tags: [],
})

describe('notebook paging', () => {
  test('uses bounded offsets and publishes generation-current partial pages', async () => {
    const offsets: number[] = []
    const snapshots: Array<{ count: number; hasMore: boolean }> = []
    const pages = [
      Array.from({ length: notebookPageLimit }, (_, index) => notebook(index)),
      [notebook(notebookPageLimit)],
    ]
    const result = await loadNotebookPages(
      {
        notebooks: async (offset, sort, tagFilter) => {
          offsets.push(offset)
          expect(sort).toBe('title')
          expect(tagFilter).toEqual(['Work'])
          return pages.shift() ?? []
        },
      },
      'title',
      ['Work'],
      () => true,
      (values, hasMore) => snapshots.push({ count: values.length, hasMore }),
    )
    expect(offsets).toEqual([0, notebookPageLimit])
    expect(snapshots).toEqual([
      { count: notebookPageLimit, hasMore: true },
      { count: notebookPageLimit + 1, hasMore: false },
    ])
    expect(result?.length).toBe(notebookPageLimit + 1)
  })

  test('deduplicates notebooks that shift across page boundaries', async () => {
    const pages = [
      Array.from({ length: notebookPageLimit }, (_, index) => notebook(index)),
      [notebook(notebookPageLimit - 1), notebook(notebookPageLimit)],
    ]
    const result = await loadNotebookPages(
      { notebooks: async () => pages.shift() ?? [] },
      'updatedAtDesc',
      [],
      () => true,
      () => {},
    )
    expect(result?.length).toBe(notebookPageLimit + 1)
    expect(new Set(result?.map((item) => item.notebookId)).size).toBe(notebookPageLimit + 1)
  })

  test('does not publish a stale generation', async () => {
    const snapshots: number[] = []
    const result = await loadNotebookPages(
      { notebooks: async () => [notebook(1)] },
      'updatedAtDesc',
      [],
      () => false,
      (values) => snapshots.push(values.length),
    )
    expect(result).toBeUndefined()
    expect(snapshots).toEqual([])
  })
})
