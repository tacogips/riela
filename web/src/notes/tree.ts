import type { NoteTag } from './types'

export interface FolderNode {
  tag: NoteTag
  children: FolderNode[]
}

export function folderTags(tags: NoteTag[]): NoteTag[] {
  return tags.filter((tag) => tag.classId === 'folder')
}

export function buildFolderTree(tags: NoteTag[], locale?: string): FolderNode[] {
  const folders = folderTags(tags)
  const byId = new Map(folders.map((tag) => [tag.tagId, tag]))
  const children = new Map<string, NoteTag[]>()
  const roots: NoteTag[] = []
  for (const tag of folders) {
    const parentId = tag.parentTagId
    if (!parentId || !byId.has(parentId) || parentId === tag.tagId) {
      roots.push(tag)
    } else {
      children.set(parentId, [...(children.get(parentId) ?? []), tag])
    }
  }
  const collator = new Intl.Collator(locale, { sensitivity: 'base' })
  const sort = (values: NoteTag[]) => [...values].sort((left, right) =>
    collator.compare(left.name, right.name) || left.tagId.localeCompare(right.tagId))
  const visited = new Set<string>()
  const makeNode = (tag: NoteTag, ancestry: Set<string>): FolderNode => {
    if (ancestry.has(tag.tagId)) return { tag, children: [] }
    const nextAncestry = new Set(ancestry).add(tag.tagId)
    visited.add(tag.tagId)
    return {
      tag,
      children: sort(children.get(tag.tagId) ?? []).map((child) => makeNode(child, nextAncestry)),
    }
  }
  const nodes = sort(roots).map((tag) => makeNode(tag, new Set()))
  for (const orphan of sort(folders.filter((tag) => !visited.has(tag.tagId)))) {
    nodes.push(makeNode(orphan, new Set()))
  }
  return nodes
}

export function folderBreadcrumb(tags: NoteTag[], selectedId?: string): NoteTag[] {
  if (!selectedId) return []
  const byId = new Map(folderTags(tags).map((tag) => [tag.tagId, tag]))
  const path: NoteTag[] = []
  const visited = new Set<string>()
  let current = byId.get(selectedId)
  while (current && !visited.has(current.tagId)) {
    visited.add(current.tagId)
    path.unshift(current)
    current = current.parentTagId ? byId.get(current.parentTagId) : undefined
  }
  return path
}

export function folderNameCollision(tags: NoteTag[], candidate: string): NoteTag | undefined {
  const normalized = candidate.trim()
  return tags.find((tag) => tag.name.trim() === normalized)
}

export function matchesCreatedFolder(
  tag: NoteTag,
  classId: string,
  parentTagId?: string,
): boolean {
  return tag.classId === classId && tag.parentTagId === (parentTagId ?? null)
}

export function directFolderAssignments(notebook: { tags: Array<{ tag: NoteTag }> }): NoteTag[] {
  return notebook.tags.map((assignment) => assignment.tag).filter((tag) => tag.classId === 'folder')
}
