import {
  For,
  Show,
  createMemo,
  createSignal,
  onCleanup,
  onMount,
} from 'solid-js'
import { NoteGraphQLClient } from '../notes/client'
import {
  NotebookProgressController,
  NotebookScopeController,
  constraintForTag,
  pruneNotebookActivatorEntries,
  tagRemovalCanAffectConstraints,
  type NotebookConstraint,
  type NotebookScope,
} from '../notes/controller'
import {
  NotebookPartialLoadError,
  loadNotebookPages,
  notebookPageLimit,
} from '../notes/paging'
import {
  assignableTagGroups,
  buildFolderTree,
  directFolderAssignments,
  folderBreadcrumb,
  folderNameCollision,
  folderTags,
  groupTagAssignments,
  matchesCreatedFolder,
  navigationTagGroups,
  tagBreadcrumb,
  type TagTreeNode,
} from '../notes/tree'
import type {
  HostMode,
  Note,
  Notebook,
  NoteListSort,
  NoteTag,
  NoteTagClass,
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
  const scopeController = new NotebookScopeController()
  const [tags, setTags] = createSignal<NoteTag[]>([])
  const [tagClasses, setTagClasses] = createSignal<NoteTagClass[]>([])
  const [notebooks, setNotebooks] = createSignal<Notebook[]>([])
  const [activeScope, setActiveScope] = createSignal<NotebookScope>(scopeController.current())
  const [navigationTab, setNavigationTab] = createSignal<'folder' | 'tags'>('folder')
  const [expanded, setExpanded] = createSignal<Set<string>>(new Set())
  const [expandedTagGroups, setExpandedTagGroups] = createSignal<Set<string>>(new Set())
  const [view, setView] = createSignal<'list' | 'board'>('list')
  const [sort, setSort] = createSignal<NoteListSort>('updatedAtDesc')
  const [loading, setLoading] = createSignal(true)
  const [draggingNotebookId, setDraggingNotebookId] = createSignal<string>()
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
  const [focusedTagId, setFocusedTagId] = createSignal<string>()
  const [addGroupKey, setAddGroupKey] = createSignal('')
  const [addTagId, setAddTagId] = createSignal('')
  const notebookActivators = new Map<string, HTMLButtonElement>()
  let detailReturnNotebookId: string | undefined
  let loadGeneration = 0
  let previewGeneration = 0
  let pendingNotebookCommit: { generation: number; notebooks: Notebook[] } | undefined
  let clearAllButton: HTMLButtonElement | undefined
  let contentHeading: HTMLDivElement | undefined

  const controller = new NotebookProgressController(
    {
      setProgress: (notebookId, progress) => client.setProgress(notebookId, progress),
      readNotebook: (notebookId) => client.notebook(notebookId),
    },
    (updated, mutationError) => {
      setNotebooks((current) => replaceNotebook(current, updated))
      if (pendingNotebookCommit) {
        pendingNotebookCommit = {
          ...pendingNotebookCommit,
          notebooks: replaceNotebook(pendingNotebookCommit.notebooks, updated),
        }
      }
      if (mutationError) setMessage(`Progress reconciled to the server value: ${mutationError}`)
    },
  )

  const publishNotebooks = (accepted: Notebook[], generation: number) => {
    if (generation !== loadGeneration) return
    if (draggingNotebookId()) {
      pendingNotebookCommit = { generation, notebooks: accepted }
      return
    }
    pendingNotebookCommit = undefined
    setNotebooks(accepted)
    pruneNotebookActivatorEntries(
      notebookActivators,
      accepted.map((notebook) => notebook.notebookId),
    )
  }

  const finishNotebookDrag = () => {
    setDraggingNotebookId(undefined)
    const pending = pendingNotebookCommit
    pendingNotebookCommit = undefined
    if (!pending || pending.generation !== loadGeneration) return
    setNotebooks(pending.notebooks)
    pruneNotebookActivatorEntries(
      notebookActivators,
      pending.notebooks.map((notebook) => notebook.notebookId),
    )
  }

  const folders = createMemo(() => folderTags(tags()))
  const tree = createMemo(() => buildFolderTree(tags()))
  const tagGroups = createMemo(() => navigationTagGroups(tags(), tagClasses()))
  const pickerGroups = createMemo(() =>
    assignableTagGroups(tags(), tagClasses()).filter((group) => group.knownClass))
  const selectedFolderId = createMemo(() => {
    const constraints = activeScope().constraints
    return constraints.length === 1 && constraints[0]?.kind === 'folder'
      ? constraints[0].tagId
      : undefined
  })
  const selectedTagId = createMemo(() => {
    const constraints = activeScope().constraints
    return constraints.length === 1 && constraints[0]?.kind === 'tag'
      ? constraints[0].tagId
      : undefined
  })
  const activeConstraintIds = createMemo(() =>
    new Set(activeScope().constraints.map((constraint) => constraint.tagId)))
  const selectedFolder = createMemo(() => folders().find((tag) => tag.tagId === selectedFolderId()))
  const selectedScopeTag = createMemo(() => tags().find((tag) => tag.tagId === selectedTagId()))
  const selectedNotebook = createMemo(() =>
    notebooks().find((notebook) => notebook.notebookId === selectedNotebookId()))
  const activeFolderTreeTagId = createMemo(() => {
    const focused = focusedTagId()
    if (focused && folders().some((tag) => tag.tagId === focused)) return focused
    return selectedFolderId() ?? tree()[0]?.tag.tagId
  })
  const hasFolderClass = createMemo(() => tagClasses().some((tagClass) => tagClass.classId === 'folder'))
  const folderPath = createMemo(() => folderBreadcrumb(tags(), selectedFolderId()))
  const selectedTagGroup = createMemo(() =>
    tagGroups().find((group) => group.classId === selectedScopeTag()?.classId))
  const selectedTagPath = createMemo(() => {
    const selected = selectedScopeTag()
    if (!selected) return []
    return selected.classId === null ? [selected] : tagBreadcrumb(tags(), selected.tagId, selected.classId)
  })
  const assignmentGroups = createMemo(() =>
    groupTagAssignments(selectedNotebook()?.tags ?? [], tagClasses()))
  const folderAssignments = createMemo(() =>
    assignmentGroups().find((group) => group.classId === 'folder'))
  const nonFolderAssignmentGroups = createMemo(() =>
    assignmentGroups().filter((group) => group.classId !== 'folder'))
  const selectedPickerGroup = createMemo(() =>
    pickerGroups().find((group) => group.key === addGroupKey()))
  const assignedTagIds = createMemo(() =>
    new Set(selectedNotebook()?.tags.map((assignment) => assignment.tag.tagId) ?? []))
  const assignableTags = createMemo(() =>
    selectedPickerGroup()?.tags.filter((tag) => !assignedTagIds().has(tag.tagId)) ?? [])
  const activeGroupTreeTagId = (
    groupTags: NoteTag[],
    fallbackTagId: string | undefined,
  ): string | undefined => {
    const focused = focusedTagId()
    if (focused && groupTags.some((tag) => tag.tagId === focused)) return focused
    return fallbackTagId
  }

  onMount(() => void refresh({ initialize: true }))

  const refresh = async (
    options: { initialize?: boolean; clearMembership?: boolean } = {},
  ): Promise<RefreshOutcome> => {
    const generation = ++loadGeneration
    pendingNotebookCommit = undefined
    let scopeSnapshot = scopeController.snapshot()
    const progressSnapshot = controller.snapshot()
    let acceptedPartialNotebooks: Notebook[] | undefined
    if (options.clearMembership) {
      setDraggingNotebookId(undefined)
      setNotebooks([])
      pruneNotebookActivatorEntries(notebookActivators, [])
    }
    setLoading(true)
    setError('')
    try {
      if (options.initialize) await client.initialize()
      if (!client.hasCredential()) {
        throw new Error('Open the registration URL printed by the current riela serve process.')
      }
      const [nextTags, classes] = await Promise.all([client.tags(), client.tagClasses()])
      if (generation !== loadGeneration || !scopeController.isCurrent(scopeSnapshot)) return 'superseded'
      const hadActiveConstraints = scopeSnapshot.scope.constraints.length > 0
      const reconciled = scopeController.reconcile(nextTags)
      const catalogClearedScope = hadActiveConstraints
        && reconciled.scope.constraints.length === 0
      if (!scopeController.isCurrent(scopeSnapshot)) {
        scopeSnapshot = reconciled
        setActiveScope(scopeSnapshot.scope)
      }
      if (catalogClearedScope) {
        setSelectedNotebookId(undefined)
        detailReturnNotebookId = undefined
        previewGeneration += 1
        setPreview([])
        setPreviewOffset(0)
        setPreviewHasMore(false)
        setPreviewLoading(false)
        setAddGroupKey('')
        setAddTagId('')
        setNotebooks([])
        pruneNotebookActivatorEntries(notebookActivators, [])
      }
      setTags(nextTags)
      setTagClasses(classes)
      const nextNotebooks = await loadNotebookPages(
        client,
        sort(),
        scopeController.tagFilterGroups(scopeSnapshot),
        () => generation === loadGeneration && scopeController.isCurrent(scopeSnapshot),
        (values) => {
          acceptedPartialNotebooks = values
        },
      )
      if (!nextNotebooks || generation !== loadGeneration || !scopeController.isCurrent(scopeSnapshot)) {
        return 'superseded'
      }
      publishNotebooks(
        nextNotebooks.map((notebook) => controller.adopt(notebook, progressSnapshot)),
        generation,
      )
      return 'completed'
    } catch (refreshError) {
      if (generation !== loadGeneration || !scopeController.isCurrent(scopeSnapshot)) return 'superseded'
      if (refreshError instanceof NotebookPartialLoadError) {
        publishNotebooks(
          (acceptedPartialNotebooks ?? refreshError.notebooks)
            .map((notebook) => controller.adopt(notebook, progressSnapshot)),
          generation,
        )
      }
      setError(errorMessage(refreshError))
      return 'failed'
    } finally {
      if (generation === loadGeneration && scopeController.isCurrent(scopeSnapshot)) setLoading(false)
    }
  }

  const beginScope = (constraint?: NotebookConstraint, append = false) => {
    loadGeneration += 1
    pendingNotebookCommit = undefined
    setDraggingNotebookId(undefined)
    const snapshot = append && constraint
      ? scopeController.add(constraint)
      : scopeController.select(constraint)
    setActiveScope(snapshot.scope)
    setSelectedNotebookId(undefined)
    detailReturnNotebookId = undefined
    previewGeneration += 1
    setPreview([])
    setNotebooks([])
  }

  const selectScope = (tag?: NoteTag) => {
    beginScope(tag ? constraintForTag(tag) : undefined)
    void refresh()
  }

  const addScope = (tag: NoteTag) => {
    beginScope(constraintForTag(tag), true)
    void refresh()
  }

  const removeScope = (tagId: string) => {
    loadGeneration += 1
    pendingNotebookCommit = undefined
    setDraggingNotebookId(undefined)
    const snapshot = scopeController.remove(tagId)
    setActiveScope(snapshot.scope)
    setSelectedNotebookId(undefined)
    detailReturnNotebookId = undefined
    previewGeneration += 1
    setPreview([])
    setNotebooks([])
    void refresh()
  }

  const clearScope = () => {
    beginScope()
    void refresh()
  }

  const selectNotebook = async (notebook: Notebook, activator?: HTMLButtonElement) => {
    previewGeneration += 1
    detailReturnNotebookId = notebook.notebookId
    if (activator) notebookActivators.set(notebook.notebookId, activator)
    setSelectedNotebookId(notebook.notebookId)
    setPreview([])
    setPreviewOffset(0)
    setPreviewHasMore(false)
    setAddGroupKey('')
    setAddTagId('')
    await loadPreview(notebook.notebookId, 0, false, previewGeneration)
  }

  const closeDetail = (restoreFocus = true) => {
    previewGeneration += 1
    const notebookId = detailReturnNotebookId
    setSelectedNotebookId(undefined)
    setPreview([])
    setPreviewHasMore(false)
    setAddGroupKey('')
    setAddTagId('')
    detailReturnNotebookId = undefined
    if (!restoreFocus || !notebookId) return
    queueMicrotask(() => {
      const activator = notebookActivators.get(notebookId)
      if (activator?.isConnected) activator.focus()
    })
  }

  const loadPreview = async (
    notebookId: string,
    offset: number,
    append: boolean,
    generation = previewGeneration,
  ) => {
    setPreviewLoading(true)
    try {
      const values = await client.notes(notebookId, offset)
      if (selectedNotebookId() !== notebookId || generation !== previewGeneration) return
      setPreview((current) => append ? [...current, ...values] : values)
      setPreviewOffset(offset + values.length)
      setPreviewHasMore(values.length === notebookPageLimit)
    } catch (previewError) {
      if (selectedNotebookId() !== notebookId || generation !== previewGeneration) return
      setMessage(`Could not load notes: ${errorMessage(previewError)}`)
    } finally {
      if (selectedNotebookId() === notebookId && generation === previewGeneration) {
        setPreviewLoading(false)
      }
    }
  }

  const createFolder = async () => {
    const name = newFolderName().trim()
    if (!name) return
    const parentTagId = selectedFolderId()
    const scopeSnapshot = scopeController.snapshot()
    const shouldEnterCreatedFolder = scopeSnapshot.scope.constraints.length === 1
      && scopeSnapshot.scope.constraints[0]?.kind === 'folder'
      && scopeSnapshot.scope.constraints[0].tagId === parentTagId
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
      if (shouldEnterCreatedFolder && scopeController.isCurrent(scopeSnapshot)) {
        beginScope(constraintForTag(created))
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

  const applyExistingTag = async (tag: NoteTag) => {
    const notebook = selectedNotebook()
    if (!notebook || membershipBusy()) return
    const scopeSnapshot = scopeController.snapshot()
    const currentTag = tags().find((candidate) =>
      candidate.tagId === tag.tagId && candidate.name === tag.name && candidate.classId === tag.classId)
    if (!currentTag || assignedTagIds().has(currentTag.tagId)) {
      setMessage('That tag is no longer assignable. Refreshing the tag catalog.')
      await refresh()
      return
    }
    const busyKey = `add:${notebook.notebookId}:${currentTag.tagId}`
    setMembershipBusy(busyKey)
    setMessage('')
    try {
      const updated = await client.applyTag(notebook.notebookId, currentTag.name)
      if (selectedNotebookId() !== notebook.notebookId
          || !scopeController.isCurrent(scopeSnapshot)) {
        await refresh()
        return
      }
      setNotebooks((current) => replaceNotebook(current, controller.adopt(updated)))
      setAddTagId('')
      setMessage(`Added “${currentTag.name}”.`)
      await refresh()
    } catch (membershipError) {
      if (selectedNotebookId() === notebook.notebookId) setMessage(errorMessage(membershipError))
    } finally {
      if (membershipBusy() === busyKey) setMembershipBusy('')
    }
  }

  const removeTag = async (tag: NoteTag) => {
    const notebook = selectedNotebook()
    if (!notebook || membershipBusy()) return
    const scopeSnapshot = scopeController.snapshot()
    const busyKey = `remove:${notebook.notebookId}:${tag.tagId}`
    setMembershipBusy(busyKey)
    setMessage('')
    try {
      const updated = await client.removeTag(notebook.notebookId, tag.name)
      if (selectedNotebookId() !== notebook.notebookId
          || !scopeController.isCurrent(scopeSnapshot)) {
        const currentScope = scopeController.current()
        const currentDetailNotebookId = selectedNotebookId()
        const clearMembership = tagRemovalCanAffectConstraints(
          tag,
          currentScope.constraints,
          tags(),
        )
        const refreshOutcome = await refresh({ clearMembership })
        if (clearMembership
            && currentDetailNotebookId
            && refreshOutcome !== 'superseded'
            && selectedNotebookId() === currentDetailNotebookId) {
          const detailRemainsVisible = refreshOutcome === 'completed'
            && notebooks().some((item) => item.notebookId === currentDetailNotebookId)
          if (detailRemainsVisible) {
            focusAfterScopeEjection(
              notebooks(),
              notebookActivators,
              clearAllButton,
              contentHeading,
              currentDetailNotebookId,
            )
          } else {
            closeDetail(false)
            focusAfterScopeEjection(notebooks(), notebookActivators, clearAllButton, contentHeading)
          }
        }
        return
      }
      setNotebooks((current) => replaceNotebook(current, controller.adopt(updated)))
      const clearMembership = tagRemovalCanAffectConstraints(
        tag,
        scopeSnapshot.scope.constraints,
        tags(),
      )
      const refreshOutcome = await refresh({ clearMembership })
      if (refreshOutcome === 'superseded') return
      if (refreshOutcome === 'failed') {
        const removingCurrentDetail = selectedNotebookId() === notebook.notebookId
        if (clearMembership && removingCurrentDetail) {
          closeDetail(false)
          focusAfterScopeEjection(notebooks(), notebookActivators, clearAllButton, contentHeading)
        }
        if (removingCurrentDetail) {
          setMessage(`Removed “${tag.name}”, but the notebook scope could not be refreshed.`)
        }
        return
      }
      if (!notebooks().some((item) => item.notebookId === notebook.notebookId)) {
        if (selectedNotebookId() === notebook.notebookId) {
          closeDetail(false)
          focusAfterScopeEjection(notebooks(), notebookActivators, clearAllButton, contentHeading)
        }
        if (!selectedNotebookId() || selectedNotebookId() === notebook.notebookId) {
          setMessage(`Removed “${tag.name}”; the notebook left the active filter.`)
        }
      } else if (selectedNotebookId() === notebook.notebookId) {
        setMessage(`Removed “${tag.name}”.`)
      }
    } catch (membershipError) {
      if (selectedNotebookId() === notebook.notebookId) setMessage(errorMessage(membershipError))
    } finally {
      if (membershipBusy() === busyKey) setMembershipBusy('')
    }
  }

  const availableFolders = createMemo(() => {
    const assigned = new Set(selectedNotebook() ? directFolderAssignments(selectedNotebook()!).map((tag) => tag.tagId) : [])
    return folders().filter((folder) => !assigned.has(folder.tagId))
  })
  const registerNotebookActivator = (notebookId: string, element: HTMLButtonElement) => {
    notebookActivators.set(notebookId, element)
    onCleanup(() => {
      if (notebookActivators.get(notebookId) === element) notebookActivators.delete(notebookId)
    })
  }

  return <section class="notes-workspace">
    <aside class="folder-pane" aria-label="Notes navigation">
      <div class="folder-pane-header"><span class="eyebrow">NOTES</span><h1>Workspace</h1></div>
      <div class="folder-tab" role="tablist" aria-label="Notes navigation mode">
        <button role="tab" aria-selected={navigationTab() === 'folder'} classList={{ active: navigationTab() === 'folder' }} onClick={() => setNavigationTab('folder')}>Folder</button>
        <button role="tab" aria-selected={navigationTab() === 'tags'} classList={{ active: navigationTab() === 'tags' }} onClick={() => setNavigationTab('tags')}>Tags</button>
      </div>
      <button classList={{ 'folder-root': true, selected: activeScope().constraints.length === 0 }} onClick={clearScope}>
        <span aria-hidden="true">▣</span> All notebooks
      </button>
      <Show when={navigationTab() === 'folder'}>
        <div class="folder-tree" role="tree" aria-label="Folder tree">
          <For each={tree()}>{(node) =>
            <TagTreeItem
              node={node}
              level={1}
              expanded={expanded()}
              activeIds={activeConstraintIds()}
              focusedId={activeFolderTreeTagId()}
              icon="▰"
              onToggle={(tagId) => setExpanded((current) => toggleSet(current, tagId))}
              onSelect={selectScope}
              onAdd={addScope}
              onFocus={setFocusedTagId}
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
      </Show>
      <Show when={navigationTab() === 'tags'}>
        <div class="tag-groups" aria-label="Tag groups">
          <For each={tagGroups()}>{(group) => {
            const isExpanded = () => expandedTagGroups().has(group.key)
            return <section class="tag-group">
              <button class="tag-group-toggle" aria-expanded={isExpanded()} onClick={() => setExpandedTagGroups((current) => toggleSet(current, group.key))}>
                <span>{isExpanded() ? '⌄' : '›'} {group.label}</span><span>{group.tags.length}</span>
              </button>
              <Show when={isExpanded()}>
                <Show when={group.classId !== null} fallback={<div class="folder-tree" role="tree" aria-label={`${group.label} tags`}>
                  <For each={group.tags}>{(tag) => <TagTreeItem node={{ tag, children: [] }} level={1} expanded={expanded()} activeIds={activeConstraintIds()} focusedId={activeGroupTreeTagId(group.tags, group.tags[0]?.tagId)} icon="●" onToggle={() => {}} onSelect={selectScope} onAdd={addScope} onFocus={setFocusedTagId} />}</For>
                </div>}>
                  <div class="folder-tree" role="tree" aria-label={`${group.label} tags`}>
                    <For each={group.tree}>{(node) => <TagTreeItem node={node} level={1} expanded={expanded()} activeIds={activeConstraintIds()} focusedId={activeGroupTreeTagId(group.tags, group.tree[0]?.tag.tagId)} icon="◆" onToggle={(tagId) => setExpanded((current) => toggleSet(current, tagId))} onSelect={selectScope} onAdd={addScope} onFocus={setFocusedTagId} />}</For>
                  </div>
                </Show>
              </Show>
            </section>
          }}</For>
        </div>
      </Show>
    </aside>

    <div class="notes-content">
      <header class="notes-header">
        <div class="notes-breadcrumb" aria-label="Notebook scope breadcrumb">
          <button onClick={clearScope}>All notebooks</button>
          <Show when={activeScope().constraints.length > 1}>
            <span aria-hidden="true">/</span><span>Filtered notebooks</span>
          </Show>
          <Show when={activeScope().constraints.length === 1 && activeScope().constraints[0]?.kind === 'folder'}>
            <For each={folderPath()}>{(tag) => <><span aria-hidden="true">/</span><button onClick={() => selectScope(tag)}>{tag.name}</button></>}</For>
          </Show>
          <Show when={activeScope().constraints.length === 1 && activeScope().constraints[0]?.kind === 'tag'}>
            <span aria-hidden="true">/</span><span>{selectedTagGroup()?.label ?? 'Tags'}</span>
            <For each={selectedTagPath()}>{(tag) => <><span aria-hidden="true">/</span><button onClick={() => selectScope(tag)}>{tag.name}</button></>}</For>
          </Show>
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
      <Show when={activeScope().constraints.length > 0}>
        <div class="filter-bar" aria-label="Active notebook filters">
          <For each={activeScope().constraints}>{(constraint) =>
            <span class="filter-chip">
              <span>{constraint.kind === 'folder' ? 'Folder' : 'Tag'}: {constraint.tagName}</span>
              <button aria-label={`Remove ${constraint.tagName} filter`} onClick={() => removeScope(constraint.tagId)}>×</button>
            </span>}
          </For>
          <button ref={clearAllButton} class="secondary filter-clear" onClick={clearScope}>Clear all</button>
        </div>
      </Show>
      <Show when={message()}><div class="notes-message" role="status" aria-live="polite">{message()}<button aria-label="Dismiss message" onClick={() => setMessage('')}>×</button></div></Show>
      <Show when={error()}><div class="error-banner" role="alert">{error()} <button class="secondary" onClick={() => void refresh()}>Retry</button></div></Show>
      <Show when={loading() && notebooks().length === 0}><div class="loading-state"><span class="loader" />Loading notebooks and final board counts…</div></Show>
      <Show when={loading() && notebooks().length > 0}><div class="loading-state" role="status"><span class="loader" />Counts updating…</div></Show>
      <Show when={!loading() && !error() && notebooks().length === 0}><div ref={contentHeading} class="empty-state" tabIndex={-1}><span>◇</span><strong>No notebooks in this scope</strong><p>Select another folder or tag scope.</p></div></Show>
      <Show when={view() === 'list' && notebooks().length > 0}>
        <div class="notebook-list" aria-label="Notebooks">
          <For each={notebooks()}>{(notebook) => <button ref={(element) => registerNotebookActivator(notebook.notebookId, element)} classList={{ 'notebook-row': true, selected: selectedNotebookId() === notebook.notebookId }} onClick={(event) => void selectNotebook(notebook, event.currentTarget)}>
            <div class="notebook-row-copy">
              <strong>{notebook.title}</strong>
              <div class="notebook-row-meta"><span>{formatDate(notebook.updatedAt)}</span><Show when={normalizedNoteCount(notebook.noteCount) !== null}><span>{noteCountLabel(normalizedNoteCount(notebook.noteCount) ?? 0)}</span></Show></div>
              <Show when={normalizedPreview(notebook.firstNotePreview)}>{(value) => <span class="notebook-preview list-preview">{value()}</span>}</Show>
            </div>
            <span class={`progress-pill ${notebook.progress}`}>{progressLabels[notebook.progress]}</span>
            <Show when={notebook.progressWasUnknown}><span class="unknown-progress">Unknown status · shown in None</span></Show>
            <FolderChips notebook={notebook} />
          </button>}</For>
        </div>
      </Show>
      <Show when={view() === 'board'}>
        <div class="notebook-board">
          <For each={progressOrder}>{(progress) => {
            const column = () => notebooks().filter((notebook) => notebook.progress === progress)
            return <section class={`board-column ${progress}`} aria-label={`${progressLabels[progress]} notebooks`} onDragOver={(event) => event.preventDefault()} onDrop={(event) => {
              const notebook = notebooks().find((item) => item.notebookId === event.dataTransfer?.getData('text/plain'))
              finishNotebookDrag()
              if (notebook && notebook.progress !== progress) void moveProgress(notebook, progress)
            }}>
              <header><strong>{progressLabels[progress]}</strong><span>{column().length}</span></header>
              <div class="board-cards"><For each={column()}>{(notebook) => <article class="board-card" draggable="true" onDragStart={(event) => {
                event.dataTransfer?.setData('text/plain', notebook.notebookId)
                setDraggingNotebookId(notebook.notebookId)
              }} onDragEnd={finishNotebookDrag}>
                <button ref={(element) => registerNotebookActivator(notebook.notebookId, element)} class="board-card-open" onClick={(event) => void selectNotebook(notebook, event.currentTarget)}>
                  <strong>{notebook.title}</strong>
                  <Show when={normalizedPreview(notebook.firstNotePreview)}>{(value) => <span class="notebook-preview board-preview">{value()}</span>}</Show>
                  <div class="board-card-meta"><span>{formatDate(notebook.updatedAt)}</span><Show when={normalizedNoteCount(notebook.noteCount) !== null}><span>{noteCountLabel(normalizedNoteCount(notebook.noteCount) ?? 0)}</span></Show></div>
                  <FolderChips notebook={notebook} />
                  <Show when={notebook.progressWasUnknown}><span class="unknown-progress">Unknown status · shown in None</span></Show>
                </button>
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
      <section class="assignment-group"><h3>Folder</h3>
        <Show when={folderAssignments()}>{(group) => <div class="detail-chips"><For each={group().assignments}>{(assignment) => <TagChip assignment={assignment} busy={membershipBusy()} onRemove={removeTag} />}</For></div>}</Show>
        <label><span>Add folder</span><select value="" disabled={Boolean(membershipBusy()) || availableFolders().length === 0} onChange={(event) => {
          const folder = folders().find((candidate) => candidate.tagId === event.currentTarget.value)
          if (folder) void applyExistingTag(folder)
        }}><option value="">Choose a folder…</option><For each={availableFolders()}>{(folder) => <option value={folder.tagId}>{folder.name}</option>}</For></select></label>
      </section>
      <For each={nonFolderAssignmentGroups()}>{(group) => <section class="assignment-group"><h3>{group.label}</h3><div class="detail-chips"><For each={group.assignments}>{(assignment) => <TagChip assignment={assignment} busy={membershipBusy()} onRemove={removeTag} />}</For></div></section>}</For>
      <section class="tag-add-flow"><h3>Add tag</h3>
        <label><span>Tag class</span><select aria-label="Tag class" value={addGroupKey()} disabled={Boolean(membershipBusy())} onChange={(event) => { setAddGroupKey(event.currentTarget.value); setAddTagId('') }}>
          <option value="">Choose a tag class…</option><For each={pickerGroups()}>{(group) => <option value={group.key}>{group.label}</option>}</For>
        </select></label>
        <label><span>Existing tag</span><select aria-label="Existing tag" value={addTagId()} disabled={!selectedPickerGroup() || assignableTags().length === 0 || Boolean(membershipBusy())} onChange={(event) => setAddTagId(event.currentTarget.value)}>
          <option value="">Choose an existing tag…</option><For each={assignableTags()}>{(tag) => <option value={tag.tagId}>{tag.name}</option>}</For>
        </select></label>
        <Show when={selectedPickerGroup() && assignableTags().length === 0}><p class="tag-picker-help">No existing tag in this group is available to assign.</p></Show>
        <button disabled={!addTagId() || Boolean(membershipBusy())} onClick={() => {
          const tag = assignableTags().find((candidate) => candidate.tagId === addTagId())
          if (tag) void applyExistingTag(tag)
        }}>Add selected tag</button>
      </section>
      <section class="note-preview"><h3>Read-only notes</h3><Show when={preview().length === 0 && !previewLoading()}><p>No notes in this notebook.</p></Show><For each={preview()}>{(note) => <article><div><strong>{note.title ?? `Note ${note.noteNumber}`}</strong><span>{formatDate(note.updatedAt)}</span></div><pre>{note.bodyMarkdown}</pre></article>}</For>
        <Show when={previewLoading()}><div class="loading-state"><span class="loader" />Loading notes…</div></Show>
        <Show when={previewHasMore()}><button class="secondary" disabled={previewLoading()} onClick={() => void loadPreview(notebook().notebookId, previewOffset(), true)}>Load more notes</button></Show>
      </section>
    </aside>}</Show>
  </section>
}

function TagTreeItem(props: {
  node: TagTreeNode
  level: number
  expanded: Set<string>
  activeIds: Set<string>
  focusedId?: string
  icon: string
  onToggle: (tagId: string) => void
  onSelect: (tag: NoteTag) => void
  onAdd: (tag: NoteTag) => void
  onFocus: (tagId: string) => void
}) {
  const isExpanded = () => props.expanded.has(props.node.tag.tagId)
  const isActive = () => props.activeIds.has(props.node.tag.tagId)
  return <div>
    <div classList={{ 'folder-row': true, selected: isActive() }} role="treeitem" aria-level={props.level} aria-expanded={props.node.children.length ? isExpanded() : undefined} aria-selected={isActive()} style={{ '--folder-level': props.level }}>
      <Show when={props.node.children.length > 0} fallback={<span class="tree-spacer" />}><button class="tree-toggle" aria-label={`${isExpanded() ? 'Collapse' : 'Expand'} ${props.node.tag.name}`} onClick={() => props.onToggle(props.node.tag.tagId)}>{isExpanded() ? '⌄' : '›'}</button></Show>
      <button
        class="tree-select"
        data-tag-id={props.node.tag.tagId}
        tabIndex={props.focusedId === props.node.tag.tagId ? 0 : -1}
        onFocus={() => props.onFocus(props.node.tag.tagId)}
        onKeyDown={(event) => handleTreeKeyDown(event, props)}
        onClick={() => props.onSelect(props.node.tag)}
      ><span aria-hidden="true">{props.icon}</span>{props.node.tag.name}</button>
      <button
        class="tree-add-filter"
        aria-label={`Add ${props.node.tag.name} to filter`}
        disabled={isActive()}
        onClick={(event) => {
          event.stopPropagation()
          props.onAdd(props.node.tag)
        }}
      >+</button>
    </div>
    <Show when={isExpanded()}><div role="group"><For each={props.node.children}>{(child) => <TagTreeItem {...props} node={child} level={props.level + 1} />}</For></div></Show>
  </div>
}

function TagChip(props: {
  assignment: Notebook['tags'][number]
  busy: string
  onRemove: (tag: NoteTag) => void
}) {
  const busyKey = () => props.busy.endsWith(`:${props.assignment.tag.tagId}`)
  return <span class="folder-chip">{props.assignment.tag.name}<Show when={busyKey()}><span class="sr-only">Updating</span></Show><Show when={props.assignment.deletable}><button aria-label={`Remove ${props.assignment.tag.name}`} disabled={Boolean(props.busy)} onClick={() => props.onRemove(props.assignment.tag)}>×</button></Show></span>
}

function FolderChips(props: { notebook: Notebook }) {
  return <span class="folder-chips"><For each={directFolderAssignments(props.notebook)}>{(tag) => <span class="folder-chip">{tag.name}</span>}</For></span>
}

function replaceNotebook(notebooks: Notebook[], replacement: Notebook): Notebook[] {
  return notebooks.map((notebook) => notebook.notebookId === replacement.notebookId
    ? {
        ...replacement,
        firstNotePreview: replacement.firstNotePreview ?? notebook.firstNotePreview,
        noteCount: replacement.noteCount ?? notebook.noteCount,
      }
    : notebook)
}

function focusAfterScopeEjection(
  notebooks: Notebook[],
  activators: Map<string, HTMLButtonElement>,
  clearAllButton?: HTMLButtonElement,
  contentHeading?: HTMLDivElement,
  preferredNotebookId?: string,
): void {
  queueMicrotask(() => {
    const orderedNotebooks = preferredNotebookId
      ? [
          ...notebooks.filter((notebook) => notebook.notebookId === preferredNotebookId),
          ...notebooks.filter((notebook) => notebook.notebookId !== preferredNotebookId),
        ]
      : notebooks
    for (const notebook of orderedNotebooks) {
      const activator = activators.get(notebook.notebookId)
      if (activator?.isConnected) {
        activator.focus()
        return
      }
    }
    if (clearAllButton?.isConnected) clearAllButton.focus()
    else contentHeading?.focus()
  })
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
    node: TagTreeNode
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

function normalizedPreview(value: string | null | undefined): string | undefined {
  const normalized = value?.trim()
  return normalized ? normalized : undefined
}

function normalizedNoteCount(value: number | null | undefined): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : null
}

function noteCountLabel(value: number): string {
  return `${value} ${value === 1 ? 'note' : 'notes'}`
}

function formatDate(value: string): string {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date)
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
