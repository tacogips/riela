import type { Notebook, NotebookProgress } from './types'

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
