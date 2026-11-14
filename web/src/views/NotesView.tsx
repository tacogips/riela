import {
  For,
  Show,
  createMemo,
  createSignal,
  onMount,
} from 'solid-js'
import { NoteGraphQLClient } from '../notes/client'
import { NotebookProgressController } from '../notes/controller'
import { loadNotebookPages } from '../notes/paging'
import {
  buildFolderTree,
  directFolderAssignments,
  folderBreadcrumb,
  folderNameCollision,
  folderTags,
  matchesCreatedFolder,
  type FolderNode,
} from '../notes/tree'
import type {
  HostMode,
  Note,
  Notebook,
  NoteListSort,
  NoteTag,
  NotebookProgress,
} from '../notes/types'

const progressOrder: NotebookProgress[] = ['none', 'progress', 'done', 'pending']
const progressLabels: Record<NotebookProgress, string> = {
  none: 'No status',
  progress: 'In progress',
  done: 'Done',
  pending: 'Pending',
}
type RefreshOutcome = 'completed' | 'failed' | 'superseded'

export function NotesView(props: { mode: HostMode }) {
  const client = new NoteGraphQLClient(props.mode)
  const [tags, setTags] = createSignal<NoteTag[]>([])
  const [tagClasses, setTagClasses] = createSignal<string[]>([])
  const [notebooks, setNotebooks] = createSignal<Notebook[]>([])
  const [selectedFolderId, setSelectedFolderId] = createSignal<string>()
  const [expanded, setExpanded] = createSignal<Set<string>>(new Set())
  const [view, setView] = createSignal<'list' | 'board'>('list')
  const [sort, setSort] = createSignal<NoteListSort>('updatedAtDesc')
  const [loading, setLoading] = createSignal(true)
  const [partialLoading, setPartialLoading] = createSignal(false)
  const [error, setError] = createSignal('')
  const [message, setMessage] = createSignal('')
  const [selectedNotebookId, setSelectedNotebookId] = createSignal<string>()
  const [preview, setPreview] = createSignal<Note[]>([])
  const [previewOffset, setPreviewOffset] = createSignal(0)
  const [previewHasMore, setPreviewHasMore] = createSignal(false)
  const [previewLoading, setPreviewLoading] = createSignal(false)
  const [newFolderName, setNewFolderName] = createSignal('')
  const [creatingFolder, setCreatingFolder] = createSignal(false)
  const [membershipBusy, setMembershipBusy] = createSignal('')
  const [focusedFolderId, setFocusedFolderId] = createSignal<string>()
  const notebookActivators = new Map<string, HTMLButtonElement>()
  let detailReturnNotebookId: string | undefined
  let loadGeneration = 0
  let folderScopeGeneration = 0

  const controller = new NotebookProgressController(
    {
      setProgress: (notebookId, progress) => client.setProgress(notebookId, progress),
      readNotebook: (notebookId) => client.notebook(notebookId),
    },
    (updated, mutationError) => {
      setNotebooks((current) => replaceNotebook(current, updated))
      if (mutationError) setMessage(`Progress reconciled to the server value: ${mutationError}`)
    },
  )

  const folders = createMemo(() => folderTags(tags()))
  const tree = createMemo(() => buildFolderTree(tags()))
  const activeTreeFolderId = createMemo(() => focusedFolderId() ?? tree()[0]?.tag.tagId)
  const selectedFolder = createMemo(() => folders().find((tag) => tag.tagId === selectedFolderId()))
  const breadcrumb = createMemo(() => folderBreadcrumb(tags(), selectedFolderId()))
  const selectedNotebook = createMemo(() =>
    notebooks().find((notebook) => notebook.notebookId === selectedNotebookId()))
  const hasFolderClass = createMemo(() => tagClasses().includes('folder'))

  onMount(() => void refresh({ initialize: true }))

  const refresh = async (
    options: { initialize?: boolean; clearMembership?: boolean } = {},
  ): Promise<RefreshOutcome> => {
    const generation = ++loadGeneration
    const progressSnapshot = controller.snapshot()
    if (options.clearMembership) {
      setNotebooks([])
      setPartialLoading(false)
    }
    setLoading(true)
    setError('')
    try {
      if (options.initialize) await client.initialize()
      if (!client.hasCredential()) {
        throw new Error('Open the registration URL printed by the current riela serve process.')
      }
      const [nextTags, classes] = await Promise.all([client.tags(), client.tagClasses()])
      if (generation !== loadGeneration) return 'superseded'
      const requestedFolderId = selectedFolderId()
      const requestedFolder = nextTags.find((tag) =>
        tag.tagId === requestedFolderId && tag.classId === 'folder')
      if (requestedFolderId && !requestedFolder) {
        setSelectedFolderId(undefined)
        setNotebooks([])
      }
      setTags(nextTags)
      setTagClasses(classes.map((tagClass) => tagClass.classId))
      const nextNotebooks = await loadNotebookPages(
        client,
        sort(),
        requestedFolder ? [requestedFolder.name] : [],
        () => generation === loadGeneration,
        (values, hasMore) => {
          setPartialLoading(hasMore)
          setNotebooks(values.map((notebook) => controller.adopt(notebook, progressSnapshot)))
        },
      )
      if (!nextNotebooks || generation !== loadGeneration) return 'superseded'
      setPartialLoading(false)
      return 'completed'
    } catch (refreshError) {
      if (generation !== loadGeneration) return 'superseded'
      setError(errorMessage(refreshError))
      setPartialLoading(false)
      return 'failed'
    } finally {
      if (generation === loadGeneration) setLoading(false)
    }
  }

  const beginFolderScope = (tag?: NoteTag) => {
    folderScopeGeneration += 1
    setSelectedFolderId(tag?.tagId)
    setSelectedNotebookId(undefined)
    detailReturnNotebookId = undefined
    setPreview([])
    setNotebooks([])
    setPartialLoading(false)
  }

  const selectFolder = (tag?: NoteTag) => {
    beginFolderScope(tag)
    void refresh()
  }

  const selectNotebook = async (notebook: Notebook, activator?: HTMLButtonElement) => {
    detailReturnNotebookId = notebook.notebookId
    if (activator) notebookActivators.set(notebook.notebookId, activator)
    setSelectedNotebookId(notebook.notebookId)
    setPreview([])
    setPreviewOffset(0)
    setPreviewHasMore(false)
    await loadPreview(notebook.notebookId, 0, false)
  }

  const closeDetail = (restoreFocus = true) => {
    const notebookId = detailReturnNotebookId
    setSelectedNotebookId(undefined)
    setPreview([])
    setPreviewHasMore(false)
    detailReturnNotebookId = undefined
    if (!restoreFocus || !notebookId) return
    queueMicrotask(() => {
      const activator = notebookActivators.get(notebookId)
      if (activator?.isConnected) activator.focus()
    })
  }

  const loadPreview = async (notebookId: string, offset: number, append: boolean) => {
    setPreviewLoading(true)
    try {
      const values = await client.notes(notebookId, offset)
      if (selectedNotebookId() !== notebookId) return
      setPreview((current) => append ? [...current, ...values] : values)
      setPreviewOffset(offset + values.length)
      setPreviewHasMore(values.length === 200)
    } catch (previewError) {
      if (selectedNotebookId() !== notebookId) return
      setMessage(`Could not load notes: ${errorMessage(previewError)}`)
    } finally {
      const current = selectedNotebookId()
      if (current === notebookId || current === undefined) setPreviewLoading(false)
    }
  }

  const createFolder = async () => {
    const name = newFolderName().trim()
    if (!name) return
    const parentTagId = selectedFolderId()
    const scopeGeneration = folderScopeGeneration
    const collision = folderNameCollision(tags(), name)
    if (collision) {
      setMessage(`“${name}” already belongs to ${collision.classId === 'folder' ? 'a folder' : 'another tag class'}.`)
      return
    }
    setCreatingFolder(true)
    setMessage('')
    try {
      const created = await client.defineFolder(name, 'folder', parentTagId)
      if (!matchesCreatedFolder(created, 'folder', parentTagId)) {
        throw new Error('The returned folder did not match the requested class and parent.')
      }
      setTags((current) =>
        current.some((tag) => tag.tagId === created.tagId) ? current : [...current, created])
      setExpanded((current) => new Set(current).add(parentTagId ?? created.tagId))
      setNewFolderName('')
      setMessage(`Created folder “${created.name}”.`)
      if (scopeGeneration === folderScopeGeneration && selectedFolderId() === parentTagId) {
        beginFolderScope(created)
        await refresh()
      }
    } catch (creationError) {
      setMessage(errorMessage(creationError))
      try {
        setTags(await client.tags())
      } catch {
        // Keep the creation error as the actionable message.
      }
    } finally {
      setCreatingFolder(false)
    }
  }

  const moveProgress = async (notebook: Notebook, progress: NotebookProgress) => {
    setMessage('')
    await controller.move(notebook, progress)
  }

  const applyFolder = async (tagName: string) => {
    const notebook = selectedNotebook()
    if (!notebook || !tagName) return
    setMembershipBusy(`add:${tagName}`)
    try {
      const updated = await client.applyFolder(notebook.notebookId, tagName)
      setNotebooks((current) => replaceNotebook(current, controller.adopt(updated)))
      setMessage(`Added “${tagName}”.`)
      await refresh()
    } catch (membershipError) {
      setMessage(errorMessage(membershipError))
    } finally {
      setMembershipBusy('')
    }
  }

  const removeFolder = async (tagName: string) => {
    const notebook = selectedNotebook()
    if (!notebook) return
    setMembershipBusy(`remove:${tagName}`)
    try {
      const updated = await client.removeFolder(notebook.notebookId, tagName)
      setNotebooks((current) => replaceNotebook(current, controller.adopt(updated)))
      const scoped = Boolean(selectedFolderId())
      const refreshOutcome = await refresh({ clearMembership: scoped })
      if (refreshOutcome === 'superseded') return
      if (refreshOutcome === 'failed') {
        if (scoped && selectedNotebookId() === notebook.notebookId) closeDetail(false)
        setMessage(`Removed “${tagName}”, but the notebook scope could not be refreshed.`)
        return
      }
      if (!notebooks().some((item) => item.notebookId === notebook.notebookId)) {
        if (selectedNotebookId() === notebook.notebookId) closeDetail(false)
        setMessage(`Removed “${tagName}”; the notebook left this folder scope.`)
      } else {
        setMessage(`Removed “${tagName}”.`)
      }
    } catch (membershipError) {
      setMessage(errorMessage(membershipError))
    } finally {
      setMembershipBusy('')
    }
  }

  const availableFolders = createMemo(() => {
    const assigned = new Set(selectedNotebook() ? directFolderAssignments(selectedNotebook()!).map((tag) => tag.tagId) : [])
    return folders().filter((folder) => !assigned.has(folder.tagId))
  })

  return <section class="notes-workspace">
    <aside class="folder-pane" aria-label="Notes folders">
      <div class="folder-pane-header"><span class="eyebrow">NOTES</span><h1>Workspace</h1></div>
      <div class="folder-tab" role="tablist" aria-label="Notes navigation"><button role="tab" aria-selected="true">Folder</button></div>
      <button classList={{ 'folder-root': true, selected: !selectedFolderId() }} onClick={() => selectFolder()}>
        <span aria-hidden="true">▣</span> All notebooks
      </button>
      <div class="folder-tree" role="tree" aria-label="Folder tree">
        <For each={tree()}>{(node) =>
          <FolderTreeNode
            node={node}
            level={1}
            expanded={expanded()}
            selectedId={selectedFolderId()}
            focusedId={activeTreeFolderId()}
            onToggle={(tagId) => setExpanded((current) => toggleSet(current, tagId))}
            onSelect={selectFolder}
            onFocus={setFocusedFolderId}
          />}
        </For>
      </div>
      <div class="folder-create">
        <label><span>Create {selectedFolder() ? 'child folder' : 'folder'}</span>
          <input value={newFolderName()} disabled={!hasFolderClass() || creatingFolder()} onInput={(event) => setNewFolderName(event.currentTarget.value)} onKeyDown={(event) => { if (event.key === 'Enter') void createFolder() }} />
        </label>
        <button disabled={!hasFolderClass() || !newFolderName().trim() || creatingFolder()} onClick={() => void createFolder()}>{creatingFolder() ? 'Creating…' : 'Create'}</button>
        <Show when={!hasFolderClass()}><span class="folder-repair">The seeded folder tag class is missing. Repair the Note store before creating folders.</span></Show>
      </div>
    </aside>

    <div class="notes-content">
      <header class="notes-header">
        <div class="notes-breadcrumb" aria-label="Folder breadcrumb">
          <button onClick={() => selectFolder()}>All notebooks</button>
          <For each={breadcrumb()}>{(tag) => <><span aria-hidden="true">/</span><button onClick={() => selectFolder(tag)}>{tag.name}</button></>}</For>
        </div>
        <div class="notes-toolbar">
          <div class="view-tabs" role="tablist" aria-label="Notebook view">
            <button role="tab" aria-selected={view() === 'list'} classList={{ active: view() === 'list' }} onClick={() => setView('list')}>List</button>
            <button role="tab" aria-selected={view() === 'board'} classList={{ active: view() === 'board' }} onClick={() => setView('board')}>Board</button>
          </div>
          <label class="sort-control"><span>Sort</span><select value={sort()} onChange={(event) => { setSort(event.currentTarget.value as NoteListSort); void refresh() }}>
            <option value="updatedAtDesc">Recently updated</option><option value="title">Title</option><option value="createdAtDesc">Newest</option><option value="createdAtAsc">Oldest</option>
          </select></label>
          <button class="secondary" onClick={() => void refresh()}>Refresh</button>
        </div>
      </header>
      <Show when={message()}><div class="notes-message" role="status" aria-live="polite">{message()}<button aria-label="Dismiss message" onClick={() => setMessage('')}>×</button></div></Show>
      <Show when={error()}><div class="error-banner" role="alert">{error()} <button class="secondary" onClick={() => void refresh()}>Retry</button></div></Show>
      <Show when={loading() && notebooks().length === 0}><div class="loading-state"><span class="loader" />Loading notebooks and final board counts…</div></Show>
      <Show when={loading() && notebooks().length > 0}><div class="loading-state" role="status"><span class="loader" />Loaded {notebooks().length} notebooks; loading the next bounded page…</div></Show>
      <Show when={!loading() && !error() && notebooks().length === 0}><div class="empty-state"><span>◇</span><strong>No notebooks in this scope</strong><p>Select another folder or add a folder tag to a notebook.</p></div></Show>
      <Show when={view() === 'list' && notebooks().length > 0}>
        <div class="notebook-list" aria-label="Notebooks">
          <For each={notebooks()}>{(notebook) => <button ref={(element) => { notebookActivators.set(notebook.notebookId, element) }} classList={{ 'notebook-row': true, selected: selectedNotebookId() === notebook.notebookId }} onClick={(event) => void selectNotebook(notebook, event.currentTarget)}>
            <div><strong>{notebook.title}</strong><span>{formatDate(notebook.updatedAt)}</span></div>
            <span class={`progress-pill ${notebook.progress}`}>{progressLabels[notebook.progress]}</span>
            <FolderChips notebook={notebook} />
          </button>}</For>
        </div>
      </Show>
      <Show when={!loading() && !partialLoading() && view() === 'board'}>
        <div class="notebook-board">
          <For each={progressOrder}>{(progress) => {
            const column = () => notebooks().filter((notebook) => notebook.progress === progress)
            return <section class={`board-column ${progress}`} aria-label={`${progressLabels[progress]} notebooks`} onDragOver={(event) => event.preventDefault()} onDrop={(event) => {
              const notebook = notebooks().find((item) => item.notebookId === event.dataTransfer?.getData('text/plain'))
              if (notebook && notebook.progress !== progress) void moveProgress(notebook, progress)
            }}>
              <header><strong>{progressLabels[progress]}</strong><span>{column().length}</span></header>
              <div class="board-cards"><For each={column()}>{(notebook) => <article class="board-card" draggable="true" onDragStart={(event) => event.dataTransfer?.setData('text/plain', notebook.notebookId)}>
                <button ref={(element) => { notebookActivators.set(notebook.notebookId, element) }} class="board-card-open" onClick={(event) => void selectNotebook(notebook, event.currentTarget)}><strong>{notebook.title}</strong><span>{formatDate(notebook.updatedAt)}</span><FolderChips notebook={notebook} /></button>
                <label><span class="sr-only">Move {notebook.title} to progress</span><select value={notebook.progress} onChange={(event) => void moveProgress(notebook, event.currentTarget.value as NotebookProgress)}>
                  <For each={progressOrder}>{(value) => <option value={value}>{progressLabels[value]}</option>}</For>
                </select></label>
              </article>}</For></div>
            </section>
          }}</For>
        </div>
      </Show>
    </div>

    <Show when={selectedNotebook()}>{(notebook) => <aside class="note-detail" aria-label={`Notebook details for ${notebook().title}`}>
      <header><div><span class="eyebrow">NOTEBOOK</span><h2>{notebook().title}</h2></div><button class="detail-close secondary" aria-label="Close notebook details" onClick={() => closeDetail()}>×</button></header>
      <dl><div><dt>Progress</dt><dd><select value={notebook().progress} onChange={(event) => void moveProgress(notebook(), event.currentTarget.value as NotebookProgress)}><For each={progressOrder}>{(value) => <option value={value}>{progressLabels[value]}</option>}</For></select></dd></div><div><dt>Updated</dt><dd>{formatDate(notebook().updatedAt)}</dd></div></dl>
      <section><h3>Folders</h3><div class="detail-chips"><For each={notebook().tags.filter((assignment) => assignment.tag.classId === 'folder')}>{(assignment) => <span class="folder-chip">{assignment.tag.name}<Show when={assignment.deletable}><button aria-label={`Remove ${assignment.tag.name}`} disabled={membershipBusy() === `remove:${assignment.tag.name}`} onClick={() => void removeFolder(assignment.tag.name)}>×</button></Show></span>}</For></div>
        <label><span>Add folder</span><select value="" disabled={membershipBusy().startsWith('add:') || availableFolders().length === 0} onChange={(event) => void applyFolder(event.currentTarget.value)}><option value="">Choose a folder…</option><For each={availableFolders()}>{(folder) => <option value={folder.name}>{folder.name}</option>}</For></select></label>
      </section>
      <section class="note-preview"><h3>Read-only notes</h3><Show when={preview().length === 0 && !previewLoading()}><p>No notes in this notebook.</p></Show><For each={preview()}>{(note) => <article><div><strong>{note.title ?? `Note ${note.noteNumber}`}</strong><span>{formatDate(note.updatedAt)}</span></div><pre>{note.bodyMarkdown}</pre></article>}</For>
        <Show when={previewLoading()}><div class="loading-state"><span class="loader" />Loading notes…</div></Show>
        <Show when={previewHasMore()}><button class="secondary" disabled={previewLoading()} onClick={() => void loadPreview(notebook().notebookId, previewOffset(), true)}>Load more notes</button></Show>
      </section>
    </aside>}</Show>
  </section>
}

function FolderTreeNode(props: {
  node: FolderNode
  level: number
  expanded: Set<string>
  selectedId?: string
  focusedId?: string
  onToggle: (tagId: string) => void
  onSelect: (tag: NoteTag) => void
  onFocus: (tagId: string) => void
}) {
  const isExpanded = () => props.expanded.has(props.node.tag.tagId)
  return <div>
    <div classList={{ 'folder-row': true, selected: props.selectedId === props.node.tag.tagId }} role="treeitem" aria-level={props.level} aria-expanded={props.node.children.length ? isExpanded() : undefined} aria-selected={props.selectedId === props.node.tag.tagId} style={{ '--folder-level': props.level }}>
      <Show when={props.node.children.length > 0} fallback={<span class="tree-spacer" />}><button class="tree-toggle" aria-label={`${isExpanded() ? 'Collapse' : 'Expand'} ${props.node.tag.name}`} onClick={() => props.onToggle(props.node.tag.tagId)}>{isExpanded() ? '⌄' : '›'}</button></Show>
      <button
        class="tree-select"
        data-folder-id={props.node.tag.tagId}
        tabIndex={props.focusedId === props.node.tag.tagId ? 0 : -1}
        onFocus={() => props.onFocus(props.node.tag.tagId)}
        onKeyDown={(event) => handleTreeKeyDown(event, props)}
        onClick={() => props.onSelect(props.node.tag)}
      ><span aria-hidden="true">▰</span>{props.node.tag.name}</button>
    </div>
    <Show when={isExpanded()}><div role="group"><For each={props.node.children}>{(child) => <FolderTreeNode {...props} node={child} level={props.level + 1} />}</For></div></Show>
  </div>
}

function FolderChips(props: { notebook: Notebook }) {
  return <span class="folder-chips"><For each={directFolderAssignments(props.notebook)}>{(tag) => <span class="folder-chip">{tag.name}</span>}</For></span>
}

function replaceNotebook(notebooks: Notebook[], replacement: Notebook): Notebook[] {
  return notebooks.map((notebook) => notebook.notebookId === replacement.notebookId ? replacement : notebook)
}

function toggleSet(current: Set<string>, value: string): Set<string> {
  const next = new Set(current)
  if (next.has(value)) next.delete(value)
  else next.add(value)
  return next
}

function handleTreeKeyDown(
  event: KeyboardEvent & { currentTarget: HTMLButtonElement },
  props: {
    node: FolderNode
    level: number
    expanded: Set<string>
    onToggle: (tagId: string) => void
  },
): void {
  const tree = event.currentTarget.closest('[role="tree"]')
  if (!tree) return
  const buttons = Array.from(tree.querySelectorAll<HTMLButtonElement>('.tree-select'))
  const currentIndex = buttons.indexOf(event.currentTarget)
  const focus = (button?: HTMLButtonElement) => {
    if (!button) return
    button.focus()
  }
  switch (event.key) {
  case 'ArrowDown':
    event.preventDefault()
    focus(buttons[currentIndex + 1])
    break
  case 'ArrowUp':
    event.preventDefault()
    focus(buttons[currentIndex - 1])
    break
  case 'Home':
    event.preventDefault()
    focus(buttons[0])
    break
  case 'End':
    event.preventDefault()
    focus(buttons.at(-1))
    break
  case 'ArrowRight':
    event.preventDefault()
    if (!props.node.children.length) return
    if (!props.expanded.has(props.node.tag.tagId)) {
      props.onToggle(props.node.tag.tagId)
    } else {
      buttons[currentIndex + 1]?.focus()
    }
    break
  case 'ArrowLeft':
    event.preventDefault()
    if (props.node.children.length && props.expanded.has(props.node.tag.tagId)) {
      props.onToggle(props.node.tag.tagId)
      return
    }
    for (let index = currentIndex - 1; index >= 0; index -= 1) {
      const level = Number(buttons[index]?.closest('[role="treeitem"]')?.getAttribute('aria-level'))
      if (level < props.level) {
        focus(buttons[index])
        return
      }
    }
    break
  }
}

function formatDate(value: string): string {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date)
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
