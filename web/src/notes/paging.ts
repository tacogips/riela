import type { Notebook, NoteListSort } from './types'

export const notebookPageLimit = 200

export interface NotebookPageClient {
  notebooks(offset: number, sort: NoteListSort, tagFilter: string[]): Promise<Notebook[]>
}

export async function loadNotebookPages(
  client: NotebookPageClient,
  sort: NoteListSort,
  tagFilter: string[],
  isCurrent: () => boolean,
  onPage: (notebooks: Notebook[], hasMore: boolean) => void,
): Promise<Notebook[] | undefined> {
  const result: Notebook[] = []
  const seen = new Set<string>()
  let offset = 0
  while (true) {
    const page = await client.notebooks(offset, sort, tagFilter)
    if (!isCurrent()) return undefined
    for (const notebook of page) {
      if (seen.has(notebook.notebookId)) continue
      seen.add(notebook.notebookId)
      result.push(notebook)
    }
    const hasMore = page.length === notebookPageLimit
    onPage([...result], hasMore)
    if (!hasMore) return result
    offset += page.length
  }
}
