import type { Notebook } from './types'

export interface NotebookLockEffects {
  adopt: (updated: Notebook) => void
  isCurrent: (updated: Notebook) => boolean
  clearContentState: () => void
  loadLockedPreview: (updated: Notebook) => Promise<void>
}

export async function applyNotebookLockMutation(
  notebook: Notebook,
  readOnly: boolean,
  mutate: (notebookId: string, readOnly: boolean) => Promise<Notebook>,
  effects: NotebookLockEffects,
): Promise<Notebook> {
  const updated = await mutate(notebook.notebookId, readOnly)
  effects.adopt(updated)
  if (updated.readOnly && effects.isCurrent(updated)) {
    effects.clearContentState()
    await effects.loadLockedPreview(updated)
  }
  return updated
}
