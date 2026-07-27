import type { Notebook, NotebookProgress } from './types'

import type { NoteTag } from './types'

export type NotebookConstraint =
  | { kind: 'folder'; tagId: string; tagName: string; classId?: string | null }
  | { kind: 'tag'; tagId: string; tagName: string; classId: string | null }

export interface NotebookScope {
  constraints: NotebookConstraint[]
}

export interface NotebookScopeSnapshot {
  generation: number
  scope: NotebookScope
}

export class NotebookScopeController {
  private generation = 0
  private scope: NotebookScope = { constraints: [] }

  current(): NotebookScope {
    return cloneScope(this.scope)
  }

  select(constraint?: NotebookConstraint): NotebookScopeSnapshot {
    return this.replace(constraint ? [constraint] : [])
  }

  add(constraint: NotebookConstraint): NotebookScopeSnapshot {
    if (this.scope.constraints.some((current) => current.tagId === constraint.tagId)) {
      return this.snapshot()
    }
    return this.replace([...this.scope.constraints, constraint])
  }

  remove(tagId: string): NotebookScopeSnapshot {
    return this.replace(this.scope.constraints.filter((constraint) => constraint.tagId !== tagId))
  }

  clear(): NotebookScopeSnapshot {
    return this.replace([])
  }

  reconcile(tags: NoteTag[]): NotebookScopeSnapshot {
    const tagsById = new Map(tags.map((tag) => [tag.tagId, tag]))
    const seen = new Set<string>()
    const constraints: NotebookConstraint[] = []
    for (const constraint of this.scope.constraints) {
      const tag = tagsById.get(constraint.tagId)
      if (!tag || seen.has(tag.tagId)) continue
      seen.add(tag.tagId)
      constraints.push(constraintForTag(tag))
    }
    return sameConstraints(constraints, this.scope.constraints)
      ? this.snapshot()
      : this.replace(constraints)
  }

  snapshot(): NotebookScopeSnapshot {
    return { generation: this.generation, scope: cloneScope(this.scope) }
  }

  isCurrent(snapshot: NotebookScopeSnapshot): boolean {
    return snapshot.generation === this.generation
  }

  tagFilterGroups(snapshot = this.snapshot()): string[][] {
    return snapshot.scope.constraints.map((constraint) => [constraint.tagName])
  }

  private replace(constraints: NotebookConstraint[]): NotebookScopeSnapshot {
    if (sameConstraints(constraints, this.scope.constraints)) return this.snapshot()
    this.generation += 1
    this.scope = { constraints: constraints.map((constraint) => ({ ...constraint })) }
    return this.snapshot()
  }
}

export function constraintForTag(tag: NoteTag): NotebookConstraint {
  return tag.classId === 'folder'
    ? { kind: 'folder', tagId: tag.tagId, tagName: tag.name, classId: tag.classId }
    : { kind: 'tag', tagId: tag.tagId, tagName: tag.name, classId: tag.classId }
}

export function tagRemovalCanAffectConstraints(
  removedTag: Pick<NoteTag, 'tagId' | 'parentTagId'>,
  constraints: NotebookConstraint[],
  tags: NoteTag[],
): boolean {
  const activeIds = new Set(constraints.map((constraint) => constraint.tagId))
  const tagsById = new Map(tags.map((tag) => [tag.tagId, tag]))
  const visited = new Set<string>()
  let tagId: string | null | undefined = removedTag.tagId
  let parentTagId: string | null | undefined = removedTag.parentTagId
  while (tagId && !visited.has(tagId)) {
    if (activeIds.has(tagId)) return true
    visited.add(tagId)
    tagId = parentTagId
    parentTagId = tagId ? tagsById.get(tagId)?.parentTagId : undefined
  }
  return false
}

export function pruneNotebookActivatorEntries<T extends { isConnected: boolean }>(
  activators: Map<string, T>,
  acceptedNotebookIds: Iterable<string>,
): void {
  const acceptedIds = new Set(acceptedNotebookIds)
  for (const [notebookId, activator] of activators) {
    if (!acceptedIds.has(notebookId) || !activator.isConnected) activators.delete(notebookId)
  }
}

function cloneScope(scope: NotebookScope): NotebookScope {
  return { constraints: scope.constraints.map((constraint) => ({ ...constraint })) }
}

function sameConstraints(left: NotebookConstraint[], right: NotebookConstraint[]): boolean {
  return left.length === right.length && left.every((constraint, index) => {
    const current = right[index]
    return current?.kind === constraint.kind
      && current.tagId === constraint.tagId
      && current.tagName === constraint.tagName
      && (current.classId ?? null) === (constraint.classId ?? null)
  })
}

export interface ProgressOperations {
  setProgress(notebookId: string, progress: NotebookProgress): Promise<Notebook>
  readNotebook(notebookId: string): Promise<Notebook>
}

export class NotebookProgressController {
  private canonical = new Map<string, Notebook>()
  private desired = new Map<string, NotebookProgress>()
  private generations = new Map<string, number>()
  private stateVersions = new Map<string, number>()
  private running = new Map<string, Promise<void>>()

  constructor(
    private readonly operations: ProgressOperations,
    private readonly onUpdate: (notebook: Notebook, error?: string) => void,
  ) {}

  snapshot(): ReadonlyMap<string, number> {
    return new Map(this.stateVersions)
  }

  adopt(notebook: Notebook, snapshot?: ReadonlyMap<string, number>): Notebook {
    if (snapshot && (snapshot.get(notebook.notebookId) ?? 0) !== this.stateVersion(notebook.notebookId)) {
      return this.visible(this.canonical.get(notebook.notebookId) ?? notebook)
    }
    this.canonical.set(notebook.notebookId, notebook)
    return this.visible(notebook)
  }

  visible(notebook: Notebook): Notebook {
    const desired = this.desired.get(notebook.notebookId)
    return desired ? { ...notebook, progress: desired } : notebook
  }

  move(notebook: Notebook, progress: NotebookProgress): Promise<void> {
    if (notebook.progress === progress && !this.desired.has(notebook.notebookId)) return Promise.resolve()
    if (!this.canonical.has(notebook.notebookId) || !this.desired.has(notebook.notebookId)) {
      this.canonical.set(notebook.notebookId, notebook)
    }
    this.desired.set(notebook.notebookId, progress)
    this.generations.set(notebook.notebookId, (this.generations.get(notebook.notebookId) ?? 0) + 1)
    this.bumpStateVersion(notebook.notebookId)
    this.onUpdate({ ...notebook, progress })
    const existing = this.running.get(notebook.notebookId)
    if (existing) return existing
    const operation = this.converge(notebook.notebookId).finally(() => this.running.delete(notebook.notebookId))
    this.running.set(notebook.notebookId, operation)
    return operation
  }

  private async converge(notebookId: string): Promise<void> {
    while (this.desired.has(notebookId)) {
      const target = this.desired.get(notebookId) as NotebookProgress
      const generation = this.generations.get(notebookId) ?? 0
      try {
        const canonical = await this.operations.setProgress(notebookId, target)
        this.canonical.set(notebookId, canonical)
        this.bumpStateVersion(notebookId)
        if (this.generations.get(notebookId) === generation && this.desired.get(notebookId) === target) {
          this.desired.delete(notebookId)
          this.onUpdate(canonical)
        } else {
          this.onUpdate(this.visible(canonical))
        }
      } catch (error) {
        const writeError = errorMessage(error)
        try {
          const canonical = await this.operations.readNotebook(notebookId)
          this.canonical.set(notebookId, canonical)
          this.bumpStateVersion(notebookId)
          if (this.generations.get(notebookId) === generation && this.desired.get(notebookId) === target) {
            this.desired.delete(notebookId)
            this.onUpdate(canonical, writeError)
          } else {
            this.onUpdate(this.visible(canonical))
          }
        } catch (readError) {
          const canonical = this.canonical.get(notebookId)
          if (!canonical) throw readError
          const combinedError = `${writeError}; canonical refresh failed: ${errorMessage(readError)}`
          if (this.generations.get(notebookId) === generation && this.desired.get(notebookId) === target) {
            this.desired.delete(notebookId)
            this.bumpStateVersion(notebookId)
            this.onUpdate(canonical, combinedError)
          } else {
            this.onUpdate(this.visible(canonical), combinedError)
          }
        }
      }
    }
  }

  private stateVersion(notebookId: string): number {
    return this.stateVersions.get(notebookId) ?? 0
  }

  private bumpStateVersion(notebookId: string): void {
    this.stateVersions.set(notebookId, this.stateVersion(notebookId) + 1)
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
