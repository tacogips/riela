import type { Notebook } from './types'

export interface NotebookLockEffects {
  adopt: (updated: Notebook) => void
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
  if (updated.readOnly) {
    effects.clearContentState()
    await effects.loadLockedPreview(updated)
  }
  return updated
}

export function notebookContentActionsDisabled(notebook: Notebook): boolean {
  return notebook.readOnly
}
