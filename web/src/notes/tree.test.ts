import { describe, expect, test } from 'bun:test'
import {
  buildFolderTree,
  folderBreadcrumb,
  folderNameCollision,
  matchesCreatedFolder,
} from './tree'
import type { NoteTag } from './types'

const tag = (tagId: string, name: string, parentTagId: string | null = null, classId: string | null = 'folder'): NoteTag => ({
  tagId,
  name,
  parentTagId,
  classId,
  isSystem: false,
  createdAt: '2026-07-25T00:00:00Z',
})

describe('folder tree', () => {
  test('builds arbitrary depth and promotes invalid parents', () => {
    const tags = [
      tag('root', 'Work'),
      tag('child', 'Project', 'root'),
      tag('grandchild', 'Launch', 'child'),
      tag('orphan', 'Archive', 'missing'),
      tag('topic', 'Not a folder', null, 'topic'),
    ]
    const tree = buildFolderTree(tags, 'en')
    expect(tree.map((node) => node.tag.name)).toEqual(['Archive', 'Work'])
    expect(tree[1]?.children[0]?.children[0]?.tag.name).toBe('Launch')
    expect(folderBreadcrumb(tags, 'grandchild').map((value) => value.name)).toEqual(['Work', 'Project', 'Launch'])
  })

  test('terminates malformed cycles and detects global trimmed-name collisions', () => {
    const tags = [tag('one', 'One', 'two'), tag('two', 'Two', 'one'), tag('topic', ' Shared ', null, 'topic')]
    const tree = buildFolderTree(tags, 'en')
    expect(tree.length).toBeGreaterThan(0)
    expect(folderNameCollision(tags, 'Shared')?.tagId).toBe('topic')
  })

  test('validates the authoritative class and parent returned for creation', () => {
    expect(matchesCreatedFolder(tag('child', 'Child', 'root'), 'folder', 'root')).toBe(true)
    expect(matchesCreatedFolder(tag('child', 'Child', 'other'), 'folder', 'root')).toBe(false)
    expect(matchesCreatedFolder(tag('root', 'Root'), 'folder')).toBe(true)
    expect(matchesCreatedFolder(tag('topic', 'Topic', null, 'topic'), 'folder')).toBe(false)
  })
})
