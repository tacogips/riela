import { expect, test, type Locator, type Page, type Route } from '@playwright/test'
import { readerPageSize } from '../src/components/NoteDetailLogic'

const compositeId = 'project-workflow:/tmp/riela:review-loop'
const plantedSecret = 'SENTINEL_SECRET_MUST_NOT_RENDER'

const instance = {
  id: compositeId,
  name: 'Review loop',
  workflowId: 'review-loop',
  source: 'project workflow',
  sourceKind: 'directory',
  status: 'stopped',
  statusDetail: 'Inactive',
  active: false,
  enabledAtLaunch: true,
  workingDirectory: null,
  environmentFilePath: null,
  environmentVariables: [{ name: 'API_KEY', isSet: true, masked: '••••••••' }],
  requiredEnvironment: [{ name: 'API_KEY', description: 'Provider credential', required: true, secret: true, source: 'workflow', present: true }],
  workflowVariables: {},
  nodePatchCount: 0,
  nodePatches: {},
  eventSources: [],
}

const missingSourceInstance = {
  ...instance,
  id: 'removed-workflow',
  name: 'Removed workflow',
  workflowId: 'removed-source',
  source: 'Missing source: removed-source',
  sourceKind: 'missing',
  status: 'needsSource',
  statusDetail: 'The configured workflow source is unavailable. Relink it in the native app.',
  environmentVariables: [],
  requiredEnvironment: [],
}

type FixtureOptions = {
  instancesDelay?: number
  workflowMode?: 'empty' | 'malformed'
  mutationMode?: 'success' | 'malformed' | 'conflict'
  noteFolderFailure?: boolean
  noteFolderRefreshFailureAfterRemove?: boolean
  createdFolderDelay?: number
  defineFolderMutationDelay?: number
  applyTagMutationDelay?: number
  removeFolderMutationDelay?: number
  secondNotebook?: boolean
  /** The reader window for `notebook-web` comes back exactly one page full, so
   * the server still claims more notes are available. */
  readerExactPage?: boolean
  /** Delay applied to every `first-note` read of that notebook. */
  notesDelayByNotebook?: Record<string, number>
  /** Scripted `first-note` reads of a notebook, applied in request order. */
  noteResponsesByNotebook?: Record<string, Array<{ delay?: number; title: string }>>
  scopeDelayByTag?: Record<string, number>
  notebookDelayAfterFirst?: number
  initialNotebookProgress?: string
  duplicateNotebookPage?: boolean
  systemMemoryNotebook?: boolean
  sameNamedSystemMemoryFolder?: boolean
  notebookLockMutationFailure?: boolean
}

async function installAPI(page: Page, options: FixtureOptions = {}) {
  const requests: string[] = []
  const unexpectedRequests: string[] = []
  const browserErrors: string[] = []
  const failedRequests: string[] = []
  const badResponses: string[] = []
  const notebookFilters: string[][] = []
  const notebookFilterGroups: string[][][] = []
  const firstNoteRequestCounts = new Map<string, number>()
  let mutationCount = 0
  let notebookRequestCount = 0
  let configuredPort = 19091
  let restartRequired = false
  let noteProgress = options.initialNotebookProgress ?? 'none'
  let notebookReadOnly = options.systemMemoryNotebook ?? false
  let folderRemoved = false
  const folder = { tagId: 'folder-work', name: 'Work', classId: 'folder', parentTagId: null, isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const child = { tagId: 'folder-launch', name: 'Launch', classId: 'folder', parentTagId: 'folder-work', isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const archive = { tagId: 'folder-archive', name: 'Archive', classId: 'folder', parentTagId: null, isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const archiveChild = { tagId: 'folder-archive-launch', name: 'Launch', classId: 'folder', parentTagId: 'folder-archive', isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const topicRoot = { tagId: 'topic-roadmap', name: 'Roadmap', classId: 'topic', parentTagId: null, isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const topicChild = { tagId: 'topic-web', name: 'Web', classId: 'topic', parentTagId: 'topic-roadmap', isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const priority = { tagId: 'priority-high', name: 'High', classId: 'priority', parentTagId: null, isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const classless = { tagId: 'tag-personal', name: 'Personal', classId: null, parentTagId: null, isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const systemMemory = { tagId: 'notebook-kind-system-memory', name: 'notebook-kind:system-memory', classId: 'notebook-kind', parentTagId: null, isSystem: true, createdAt: '2026-08-01T00:00:00Z' }
  const sameNamedSystemMemoryFolder = { tagId: 'folder-system-memory-name', name: 'notebook-kind:system-memory', classId: 'folder', parentTagId: null, isSystem: false, createdAt: '2026-08-01T00:00:00Z' }
  const branchBoard = {
    setId: 'kanban-branch',
    name: 'Branch board',
    isSystem: false,
    statuses: [
      { statusId: 'kanban-branch-queued', name: 'queued', category: 'pending', position: 0 },
      { statusId: 'kanban-branch-done', name: 'done', category: 'done', position: 1 },
    ],
  }
  const catalogTags = [
    folder,
    child,
    archive,
    archiveChild,
    topicRoot,
    topicChild,
    priority,
    classless,
    ...(options.sameNamedSystemMemoryFolder ? [sameNamedSystemMemoryFolder] : []),
  ]
  const tagsById = new Map(catalogTags.map((tag) => [tag.tagId, tag]))
  const notebookTagMutationIds: string[] = []
  const kanbanAssignments: Array<{ tagId: string; setId: string | null }> = []
  let noteTagIds = [
    'folder-work',
    'topic-web',
    'priority-high',
    'tag-personal',
    ...(options.sameNamedSystemMemoryFolder ? [sameNamedSystemMemoryFolder.tagId] : []),
  ]
  const assignments = (tagIds: string[]) => tagIds.flatMap((tagId) => {
    const tag = tagsById.get(tagId)
    return tag ? [{ tag, provenance: 'human', assignedBy: 'riela-web', deletable: tag.tagId !== 'priority-high', createdAt: '2026-07-25T00:00:00Z' }] : []
  })
  const currentNotebook = () => ({
    notebookId: 'notebook-web',
    title: options.systemMemoryNotebook ? 'Riela System Memory' : 'Web notebook',
    progress: noteProgress,
    readOnly: notebookReadOnly,
    createdAt: '2026-07-25T00:00:00Z',
    updatedAt: '2026-07-25T01:00:00Z',
    tags: [
      ...assignments(noteTagIds),
      ...(options.systemMemoryNotebook ? [{
        tag: systemMemory,
        provenance: 'system',
        assignedBy: 'riela-note',
        deletable: false,
        createdAt: '2026-08-01T00:00:00Z',
      }] : []),
    ],
    firstNotePreview: 'First **plain-text** launch note',
    noteCount: 3,
  })
  const otherNotebook = () => ({
    notebookId: 'notebook-other',
    title: 'Other notebook',
    progress: 'pending',
    readOnly: false,
    createdAt: '2026-07-25T00:00:00Z',
    updatedAt: '2026-07-25T02:00:00Z',
    tags: assignments(['folder-work']),
    firstNotePreview: '   ',
    noteCount: 0,
  })
  // One shared note fixture backs both the GraphQL `Notes` paging query and the
  // REST reader endpoints, so the reader shows the same bodies either way.
  const noteFixture = (notebookId: string, index: number, title: string, bodyMarkdown: string) => ({
    noteId: `${notebookId}-note-${index + 1}`,
    notebookId,
    noteNumber: index + 1,
    title,
    bodyMarkdown,
    readOnly: options.systemMemoryNotebook ? false : true,
    createdAt: '2026-07-25T00:00:00Z',
    updatedAt: '2026-07-25T00:00:00Z',
  })
  const notesInNotebook = (notebookId: string) => {
    if (options.readerExactPage && notebookId === 'notebook-web') {
      return Array.from({ length: readerPageSize }, (_, index) =>
        noteFixture(notebookId, index, `Brief ${index + 1}`, `Launch brief ${index + 1}`))
    }
    if (notebookId === 'notebook-other') return [noteFixture(notebookId, 0, 'Other brief', '# Other brief')]
    return [noteFixture(notebookId, 0, 'Brief', '# Launch brief')]
  }
  const notebookIdForNote = (noteId: string) => /^(.+)-note-\d+$/.exec(noteId)?.[1] ?? 'notebook-web'
  const noteDetailEnvelope = (note: ReturnType<typeof noteFixture>) => ({
    profile: 'e2e',
    revision: 1,
    detail: { note, comments: [], links: [], linkedNotes: {}, files: [] },
  })
  const tagIsWithinScope = (assignedTagId: string, scopeTagId: string): boolean => {
    const visited = new Set<string>()
    let current = tagsById.get(assignedTagId)
    while (current && !visited.has(current.tagId)) {
      if (current.tagId === scopeTagId) return true
      visited.add(current.tagId)
      current = current.parentTagId ? tagsById.get(current.parentTagId) : undefined
    }
    return false
  }
  const matchesScope = (tagFilter: unknown, assignedTagIds: string[]): boolean => {
    if (!Array.isArray(tagFilter) || tagFilter.length === 0) return true
    return tagFilter.some((tagId) => typeof tagId === 'string'
      && assignedTagIds.some((assignedTagId) => tagIsWithinScope(assignedTagId, tagId)))
  }
  page.on('console', (message) => {
    if (message.type() !== 'error') return
    const expectedConflictNoise = options.mutationMode === 'conflict'
      && message.text().includes('409 (Conflict)')
    const expectedNoteFailureNoise = (options.noteFolderFailure || options.noteFolderRefreshFailureAfterRemove)
      && message.text().includes('503 (Service Unavailable)')
    if (!expectedConflictNoise && !expectedNoteFailureNoise) browserErrors.push(message.text())
  })
  page.on('pageerror', (error) => browserErrors.push(error.message))
  page.on('requestfailed', (request) => {
    // Long-poll /note/events requests are held open by design and abort when
    // the page closes; they are not failures.
    if (new URL(request.url()).pathname === '/note/events') return
    failedRequests.push(`${request.method()} ${request.url()}: ${request.failure()?.errorText ?? 'failed'}`)
  })
  page.on('response', (response) => {
    const url = new URL(response.url())
    const expectedConflict = options.mutationMode === 'conflict' && response.status() === 409 && url.pathname === '/api/v1/workflows/sources/directories'
    const expectedNoteFailure = (options.noteFolderFailure || options.noteFolderRefreshFailureAfterRemove)
      && response.status() === 503
      && url.pathname === '/graphql'
    if (response.status() >= 400 && !expectedConflict && !expectedNoteFailure) badResponses.push(`${response.status()} ${response.request().method()} ${url.pathname}`)
  })
  await page.route('**/graphql', async (route: Route) => {
    const request = route.request()
    const body = request.postDataJSON() as { operationName?: string; variables?: Record<string, unknown> }
    const operation = body.operationName ?? 'Unknown'
    requests.push(`POST /graphql:${operation}`)
    const result = (value: unknown) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ data: value }) })
    const accepted = { accepted: true, status: 'ok', diagnostics: [] }
    if (operation === 'Tags') return result({ tags: { result: accepted, value: [...tagsById.values()] } })
    if (operation === 'EffectiveKanbanStatuses' || operation === 'EffectiveKanbanStatusesByTagId') {
      const field = operation === 'EffectiveKanbanStatuses'
        ? 'effectiveKanbanStatuses'
        : 'effectiveKanbanStatusesByTagId'
      return result({ [field]: { result: accepted, value: {
        setId: 'kanban-default',
        name: 'default',
        isSystem: true,
        statuses: [
          { statusId: 'kanban-default-none', name: 'none', category: 'none', position: 0 },
          { statusId: 'kanban-default-pending', name: 'pending', category: 'pending', position: 1 },
          { statusId: 'kanban-default-progress', name: 'progress', category: 'progress', position: 2 },
          { statusId: 'kanban-default-review', name: 'review', category: 'review', position: 3 },
          { statusId: 'kanban-default-done', name: 'done', category: 'done', position: 4 },
        ],
      } } })
    }
    if (operation === 'KanbanStatusSets') {
      return result({ kanbanStatusSets: { result: accepted, value: [branchBoard] } })
    }
    if (operation === 'AssignKanbanStatusSetByTagId') {
      const tagId = typeof body.variables?.tagId === 'string' ? body.variables.tagId : ''
      const setId = typeof body.variables?.setId === 'string' ? body.variables.setId : null
      kanbanAssignments.push({ tagId, setId })
      const tag = tagsById.get(tagId)
      return result({ assignKanbanStatusSetByTagId: {
        result: accepted,
        tag: tag ? { ...tag, statusSetId: setId } : null,
      } })
    }
    if (operation === 'TagClasses') return result({ tagClasses: { result: accepted, value: [
      { classId: 'folder', label: 'Folder', description: null },
      { classId: 'priority', label: 'Priority', description: null },
      { classId: 'topic', label: 'Topic', description: null },
      { classId: 'empty', label: 'Empty class', description: null },
    ] } })
    if (operation === 'Notebooks') {
      notebookRequestCount += 1
      const rawGroups = body.variables?.tagFilterIdGroups
      const groups = Array.isArray(rawGroups)
        ? rawGroups.flatMap((group) => Array.isArray(group)
          ? [group.filter((value): value is string => typeof value === 'string')]
          : [])
        : []
      notebookFilterGroups.push(groups)
      notebookFilters.push(groups.flat())
      const effectiveGroups = groups
      const requestedTagId = groups[0]?.[0] ?? ''
      const requestedTag = tagsById.get(requestedTagId)?.name ?? requestedTagId
      const scopeDelay = options.scopeDelayByTag?.[requestedTag]
      if (scopeDelay) await new Promise((resolve) => setTimeout(resolve, scopeDelay))
      if (notebookRequestCount > 1 && options.notebookDelayAfterFirst) {
        await new Promise((resolve) => setTimeout(resolve, options.notebookDelayAfterFirst))
      }
      if (options.createdFolderDelay && effectiveGroups.some((group) => group.includes('new-folder'))) {
        await new Promise((resolve) => setTimeout(resolve, options.createdFolderDelay))
      }
      if (
        effectiveGroups.length > 0
        && (options.noteFolderFailure || (options.noteFolderRefreshFailureAfterRemove && folderRemoved))
      ) {
        return route.fulfill({ status: 503, contentType: 'application/json', body: JSON.stringify({ error: 'folder unavailable' }) })
      }
      if (options.duplicateNotebookPage) {
        const requestedLimit = Number(body.variables?.limit)
        const limit = Number.isInteger(requestedLimit) && requestedLimit > 0 ? requestedLimit : 0
        return result({
          notebooks: {
            result: accepted,
            value: Array.from({ length: limit }, (_, index) => ({
              notebookId: `notebook-page-${index + 1}`,
              title: `Paged notebook ${index + 1}`,
              progress: 'none',
              createdAt: '2026-07-25T00:00:00Z',
              updatedAt: '2026-07-25T01:00:00Z',
              tags: [],
            })),
          },
        })
      }
      const candidates = [
        { notebook: currentNotebook(), tagIds: noteTagIds },
        ...(options.secondNotebook ? [{ notebook: otherNotebook(), tagIds: ['folder-work'] }] : []),
      ]
      return result({
        notebooks: {
          result: accepted,
          value: candidates
            .filter((candidate) =>
              effectiveGroups.every((group) => matchesScope(group, candidate.tagIds)))
            .map((candidate) => candidate.notebook),
        },
      })
    }
    if (operation === 'Notebook') {
      const value = body.variables?.notebookId === 'notebook-other' ? otherNotebook() : currentNotebook()
      return result({ notebook: { result: accepted, value } })
    }
    if (operation === 'Notes') {
      const notebookId = String(body.variables?.notebookId ?? '')
      const offset = Number(body.variables?.offset ?? 0)
      const requestedLimit = Number(body.variables?.limit)
      const limit = Number.isInteger(requestedLimit) && requestedLimit > 0 ? requestedLimit : 0
      const notes = notesInNotebook(notebookId).slice(offset, offset + limit)
      return result({ notes: { result: accepted, value: notes } })
    }
    if (operation === 'SearchNotes') {
      return result({ searchNotes: { result: accepted, value: [{
        note: notesInNotebook('notebook-web')[0],
        snippet: 'Duplicate launch folders',
        rank: 1,
        matchedTags: [child, archiveChild],
        isLinkedNeighbor: false,
      }] } })
    }
    if (operation === 'SetProgress') {
      noteProgress = String(body.variables?.progress ?? noteProgress)
      return result({ setNotebookProgress: { result: accepted, notebook: currentNotebook() } })
    }
    if (operation === 'SetNotebookReadOnly') {
      if (options.notebookLockMutationFailure) {
        return result({
          setNotebookReadOnly: {
            result: {
              accepted: false,
              status: 'unavailable',
              diagnostics: ['lock service unavailable'],
            },
            notebook: null,
          },
        })
      }
      notebookReadOnly = Boolean(body.variables?.readOnly)
      return result({ setNotebookReadOnly: { result: accepted, notebook: currentNotebook() } })
    }
    if (operation === 'ApplyNotebookTagIds') {
      if (options.applyTagMutationDelay) {
        await new Promise((resolve) => setTimeout(resolve, options.applyTagMutationDelay))
      }
      const input = body.variables?.input as { tagIds?: unknown } | undefined
      const tagIds = Array.isArray(input?.tagIds)
        ? input.tagIds.filter((tagId): tagId is string => typeof tagId === 'string' && tagsById.has(tagId))
        : []
      notebookTagMutationIds.push(...tagIds)
      noteTagIds = [...new Set([...noteTagIds, ...tagIds])]
      return result({ applyNotebookTagIds: { result: accepted, notebook: currentNotebook() } })
    }
    if (operation === 'RemoveNotebookTagById') {
      if (options.removeFolderMutationDelay) {
        await new Promise((resolve) => setTimeout(resolve, options.removeFolderMutationDelay))
      }
      const tagId = body.variables?.tagId
      if (body.variables?.notebookId === 'notebook-web' && typeof tagId === 'string') {
        notebookTagMutationIds.push(tagId)
        noteTagIds = noteTagIds.filter((candidate) => candidate !== tagId)
      }
      folderRemoved = true
      const notebook = body.variables?.notebookId === 'notebook-other' ? otherNotebook() : currentNotebook()
      return result({ removeNotebookTagById: { result: accepted, notebook } })
    }
    if (operation === 'DefineFolder') {
      if (options.defineFolderMutationDelay) {
        await new Promise((resolve) => setTimeout(resolve, options.defineFolderMutationDelay))
      }
      const input = body.variables?.input as { name?: unknown; classId?: unknown; parentTagId?: unknown } | undefined
      const created = {
        ...child,
        tagId: 'new-folder',
        name: typeof input?.name === 'string' ? input.name : 'New folder',
        classId: typeof input?.classId === 'string' ? input.classId : 'folder',
        parentTagId: typeof input?.parentTagId === 'string' ? input.parentTagId : null,
      }
      tagsById.set(created.tagId, created)
      return result({ defineNoteTag: { result: accepted, tag: created } })
    }
    if (operation === 'WebMutableWorkflows') {
      return result({ workflows: { workflows: [], errors: [] } })
    }
    unexpectedRequests.push(`POST /graphql:${operation}`)
    return route.fulfill({ status: 418, contentType: 'application/json', body: JSON.stringify({ error: 'unexpected GraphQL operation' }) })
  })
  await page.route('**/note/events**', async () => {
    // Never fulfilled: real long-polls are held open until a change or the
    // 25s timeout; tests finish first and the abort is filtered above.
  })
  await page.route('**/api/v1/**', async (route: Route) => {
    const request = route.request()
    const url = new URL(request.url())
    requests.push(`${request.method()} ${url.pathname}`)
    const json = (value: unknown) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(value) })
    if (url.pathname === '/api/v1/bootstrap') return json({ apiVersion: 'v1', profile: 'e2e', csrfToken: 'csrf', revision: 1, capabilities: [], server: { revision: 1, isEnabled: true, configuredPort: 19091, boundPort: 19091, restartRequired: false, state: 'running' } })
    if (url.pathname === '/api/v1/instances' && request.method() === 'GET') {
      if (options.instancesDelay) await new Promise((resolve) => setTimeout(resolve, options.instancesDelay))
      return json({ profile: 'e2e', revision: 1, items: [instance, missingSourceInstance] })
    }
    if (url.pathname === `/api/v1/instances/${encodeURIComponent(compositeId)}/executions`) return json({ revision: 1, instanceId: compositeId, items: [], diagnostics: [], truncated: false })
    if (url.pathname === `/api/v1/instances/${encodeURIComponent(compositeId)}/configuration`) {
      mutationCount += 1
      return json({ profile: 'e2e', revision: 2, item: instance })
    }
    if (url.pathname === '/api/v1/workflows/sources') {
      if (options.workflowMode === 'malformed') return route.fulfill({ status: 200, contentType: 'application/json', body: '{' })
      return json({ profile: 'e2e', revision: 1, directories: [], projectDirectories: [], repositories: [], discovered: [] })
    }
    if (url.pathname === '/api/v1/workflows/sources/directories') {
      mutationCount += 1
      if (options.mutationMode === 'conflict') return route.fulfill({ status: 409, contentType: 'application/json', body: JSON.stringify({ error: { code: 'revision_conflict', message: 'Changed elsewhere' }, revision: 2 }) })
      return json({ profile: 'e2e', revision: 2, directories: [], projectDirectories: [], repositories: [], discovered: [] })
    }
    // Reader endpoints (riela-app only): the pane reads the notebook's first
    // note, then the window around it for paging.
    const firstNotePath = /^\/api\/v1\/notes\/notebooks\/([^/]+)\/first-note$/.exec(url.pathname)
    if (firstNotePath && request.method() === 'GET') {
      const notebookId = decodeURIComponent(firstNotePath[1] ?? '')
      const requestIndex = firstNoteRequestCounts.get(notebookId) ?? 0
      firstNoteRequestCounts.set(notebookId, requestIndex + 1)
      const scripted = options.noteResponsesByNotebook?.[notebookId]?.[requestIndex]
      const delay = scripted?.delay ?? options.notesDelayByNotebook?.[notebookId]
      if (delay) await new Promise((resolve) => setTimeout(resolve, delay))
      const first = notesInNotebook(notebookId)[0]
      if (!first) return json({ profile: 'e2e', revision: 1, detail: null })
      return json(noteDetailEnvelope(scripted
        ? { ...first, title: scripted.title, bodyMarkdown: `# ${scripted.title}` }
        : first))
    }
    const notePath = /^\/api\/v1\/notes\/([^/]+)\/(detail|window)$/.exec(url.pathname)
    if (notePath && request.method() === 'GET') {
      const noteId = decodeURIComponent(notePath[1] ?? '')
      const notes = notesInNotebook(notebookIdForNote(noteId))
      if (notePath[2] === 'detail') {
        const note = notes.find((candidate) => candidate.noteId === noteId)
        if (!note) return route.fulfill({ status: 404, contentType: 'application/json', body: JSON.stringify({ error: { code: 'not_found', message: noteId }, revision: 1 }) })
        return json(noteDetailEnvelope(note))
      }
      const pageSize = Number(url.searchParams.get('pageSize')) || readerPageSize
      const page = notes.slice(0, pageSize)
      return json({
        profile: 'e2e',
        revision: 1,
        notes: page,
        startOffset: 0,
        hasEarlierNotes: false,
        // An exactly full page leaves the server claiming more notes exist.
        hasMoreNotes: page.length >= pageSize,
      })
    }
    if (url.pathname === '/api/v1/settings/assistant' && request.method() === 'GET') return json({ profile: 'e2e', revision: 1, assistance: '', vendor: 'openai-api', model: 'gpt-5.6' })
    if (url.pathname === '/api/v1/settings/notes' && request.method() === 'GET') return json({ profile: 'e2e', revision: 1, noteRoot: '/tmp/riela/notes', exposesNoteAPI: false, s3ProfileCount: 0, s3Profiles: [] })
    if (url.pathname === '/api/v1/settings/notes/clients' && request.method() === 'GET') return json({ profile: 'e2e', revision: 1, items: [] })
    if (url.pathname === '/api/v1/settings/appearance' && request.method() === 'GET') return json({ profile: 'e2e', revision: 1, colorScheme: 'dark', options: ['dark', 'light'] })
    if (url.pathname === '/api/v1/settings/web-server' && request.method() === 'GET') return json({ revision: 1, isEnabled: true, configuredPort, boundPort: 19091, restartRequired, state: 'running' })
    if (url.pathname === '/api/v1/settings/assistant' && request.method() === 'PUT') {
      mutationCount += 1
      if (options.mutationMode === 'malformed') return route.fulfill({ status: 200, contentType: 'application/json', body: '{' })
      return json({ profile: 'e2e', revision: 2, assistance: '', vendor: 'openai-api', model: 'gpt-5.6' })
    }
    if (url.pathname === '/api/v1/settings/web-server' && request.method() === 'PUT') {
      mutationCount += 1
      configuredPort = (request.postDataJSON() as { port?: number }).port ?? configuredPort
      restartRequired = true
      return json({ revision: 2, isEnabled: true, configuredPort, boundPort: 19091, restartRequired, state: 'running' })
    }
    unexpectedRequests.push(`${request.method()} ${url.pathname}`)
    return route.fulfill({ status: 418, contentType: 'application/json', body: JSON.stringify({ error: { code: 'unexpected_request', message: `${request.method()} ${url.pathname}` }, revision: 1 }) })
  })
  return {
    requests,
    notebookFilters,
    notebookFilterGroups,
    notebookTagMutationIds,
    kanbanAssignments,
    removeCatalogTag: (name: string) => {
      const tag = [...tagsById.values()].find((candidate) => candidate.name === name)
      if (tag) tagsById.delete(tag.tagId)
    },
    mutationCount: () => mutationCount,
    assertClean: () => {
      expect(unexpectedRequests, 'unexpected API requests').toEqual([])
      expect(browserErrors, 'browser console and page errors').toEqual([])
      expect(failedRequests, 'failed network requests').toEqual([])
      expect(badResponses, 'unexpected HTTP error responses').toEqual([])
    },
  }
}

async function captureEvidence(page: Page, name: string, target?: Locator) {
  await (target ?? page.locator('.app-shell')).screenshot({
    path: `../tmp/web-dashboard-e2e/screenshots/${name}.png`,
    animations: 'disabled',
  })
}

test('suppresses empty ids and resolves encoded ids for logs and configuration', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'Run logs' }).click()
  await expect(page.locator('.empty-state').getByText('Choose an instance', { exact: true })).toBeVisible()
  expect(fixture.requests.some((request) => request.includes('/instances//executions'))).toBe(false)
  await page.getByLabel('Instance').selectOption(compositeId)
  await expect(page.getByText('No persisted runs', { exact: true })).toBeVisible()
  expect(fixture.requests).toContain(`GET /api/v1/instances/${encodeURIComponent(compositeId)}/executions`)
  await captureEvidence(page, 'run-logs-empty-history')

  await page.getByRole('button', { name: 'Instances' }).click()
  await page.getByRole('button', { name: /Review loop/ }).click()
  await page.getByRole('button', { name: 'Save changes' }).click()
  await expect(page.getByText(/Saved\. Active instances/)).toBeVisible()
  expect(fixture.requests).toContain(`PUT /api/v1/instances/${encodeURIComponent(compositeId)}/configuration`)
  expect(await page.locator('body').innerText()).not.toContain(plantedSecret)
  await page.getByRole('button', { name: /Removed workflow/ }).click()
  await expect(page.getByText('This configured instance cannot find its workflow source.')).toBeVisible()
  await captureEvidence(page, 'instances-missing-source')
  fixture.assertClean()
})

test('shows loading, empty, error, and mutation recovery states', async ({ page }) => {
  const fixture = await installAPI(page, { instancesDelay: 250, workflowMode: 'empty', mutationMode: 'conflict' })
  await page.goto('/')
  await expect(page.getByText('Loading workflow instances…')).toBeVisible()
  await expect(page.getByRole('button', { name: /Review loop/ })).toBeVisible()
  await page.getByRole('button', { name: 'Workflows' }).click()
  await expect(page.getByText('No sources configured')).toBeVisible()
  await expect(page.getByText('Nothing discovered')).toBeVisible()
  await page.getByLabel('Additional workflow directory').fill('/tmp/workflows')
  await page.getByRole('button', { name: 'Add directory' }).click()
  await expect(page.getByText(/Changed elsewhere — refresh/)).toBeVisible()
  await expect(page.getByLabel('Additional workflow directory')).toHaveValue('/tmp/workflows')
  const sourceReadsBeforeRefresh = fixture.requests.filter((request) =>
    request === 'GET /api/v1/workflows/sources').length
  await page.getByRole('button', { name: 'Refresh', exact: true }).last().click()
  await expect.poll(() => fixture.requests.filter((request) =>
    request === 'GET /api/v1/workflows/sources').length).toBeGreaterThan(sourceReadsBeforeRefresh)
  await expect(page.getByRole('button', { name: 'Add directory', exact: true })).toBeEnabled()
  await captureEvidence(page, 'workflows-conflict-recovery')
  fixture.assertClean()
})

test('renders resource and settings mutation failures', async ({ page }) => {
  const fixture = await installAPI(page, { workflowMode: 'malformed', mutationMode: 'malformed' })
  await page.goto('/')
  await page.getByRole('button', { name: 'Workflows' }).click()
  await expect(page.getByRole('alert')).toBeVisible()
  await page.getByRole('button', { name: 'Settings' }).click()
  await page.getByRole('button', { name: 'Save assistant' }).click()
  await expect(page.getByText(/JSON|Unexpected end/i)).toBeVisible()
  await captureEvidence(page, 'settings-mutation-error', page.locator('.settings-panel').filter({ hasText: 'Assistant' }))
  fixture.assertClean()
})

test('confirms a port change and keeps success and restart feedback visible', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'Settings' }).click()
  await expect(page.getByLabel('Note root')).toHaveValue('/tmp/riela/notes')
  await expect(page.getByRole('heading', { name: 'S3 storage profile' })).toBeVisible()
  await expect(page.getByLabel('Endpoint', { exact: true })).toHaveValue('')
  await expect(page.getByRole('heading', { name: 'Registered clients' })).toBeVisible()
  await expect(page.getByText('No registered clients.')).toBeVisible()
  await expect(page.getByLabel('Native window appearance')).toHaveValue('dark')
  await page.getByLabel('Configured port').fill('19092')
  await page.getByRole('button', { name: 'Save server' }).click()
  await expect(page.getByText('Type CHANGE PORT to confirm that this page may become unreachable.')).toBeVisible()
  await page.getByLabel('Port-change confirmation').fill('CHANGE PORT')
  await page.getByRole('button', { name: 'Save server' }).click()
  await expect(page.getByText('Server port saved. Restart from the Riela menu to apply it.')).toBeVisible()
  await expect(page.getByText('Restart required from the Riela menu-bar app.')).toBeVisible()
  await captureEvidence(page, 'settings-port-restart-required', page.locator('.settings-panel').filter({ hasText: 'Web server' }))
  fixture.assertClean()
})

test('keeps narrow navigation, focus, and content usable', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  const fixture = await installAPI(page)
  await page.goto('/')
  await expect(page.getByRole('button', { name: 'Instances' })).toHaveAttribute('aria-current', 'page')
  await page.keyboard.press('Tab')
  await expect(page.getByRole('link', { name: 'Skip to content' })).toBeFocused()
  // The full navigation is wider than a phone viewport, so it has to scroll
  // inside its own strip instead of widening the document.
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  expect(await page.locator('.sidebar nav').evaluate((element) =>
    element.scrollWidth > element.clientWidth && getComputedStyle(element).overflowX === 'auto')).toBe(true)
  const columns = await page.locator('.instance-grid').evaluate((element) => getComputedStyle(element).gridTemplateColumns.split(' ').length)
  expect(columns).toBe(1)
  await captureEvidence(page, 'mobile-instances')
  fixture.assertClean()
})
