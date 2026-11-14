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

test('navigates folder-scoped List and Board Notes with detail and progress controls', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: 'All notebooks' }).first().click()
  await page.getByLabel('Create folder').fill('Work')
  await page.getByRole('button', { name: 'Create', exact: true }).click()
  await expect(page.getByText(/sibling folder named “Work” already exists/)).toBeVisible()
  expect(fixture.requests).not.toContain('POST /graphql:DefineFolder')
  const listRow = page.getByRole('button', { name: /Web notebook/ })
  await expect(listRow).toBeVisible()
  await listRow.click()
  const detail = page.getByRole('complementary', { name: /Notebook details/ })
  await expect(detail).toBeVisible()
  await detail.getByLabel('Add folder').selectOption({ label: 'Work / Launch' })
  await expect(detail.getByRole('button', { name: 'Remove Work / Launch' })).toBeVisible()
  expect(fixture.requests).toContain('POST /graphql:ApplyNotebookTagIds')
  await detail.getByRole('button', { name: 'Remove Work / Launch' }).click()
  await expect(detail.getByRole('button', { name: 'Remove Work / Launch' })).toHaveCount(0)
  expect(fixture.requests).toContain('POST /graphql:RemoveNotebookTagById')
  await page.getByRole('button', { name: 'Close notebook details' }).click()
  await expect(listRow).toBeFocused()
  const workFolder = page.getByRole('treeitem', { name: /Work/ }).getByRole('button', { name: 'Work', exact: true })
  await workFolder.focus()
  await page.keyboard.press('ArrowRight')
  const launchFolder = page.getByRole('button', { name: 'Work / Launch', exact: true })
  await expect(launchFolder).toBeVisible()
  await page.keyboard.press('ArrowDown')
  await expect(launchFolder).toBeFocused()
  await page.keyboard.press('ArrowLeft')
  await expect(workFolder).toBeFocused()
  await page.keyboard.press('End')
  await expect(launchFolder).toBeFocused()
  await page.keyboard.press('Home')
  await expect(page.getByRole('button', { name: 'Archive', exact: true })).toBeFocused()
  await workFolder.click()
  await expect(page.getByText('Work', { exact: true }).first()).toBeVisible()
  await page.getByRole('tab', { name: 'Board' }).click()
  await expect(page.getByRole('region', { name: 'No status notebooks' })).toContainText('Web notebook')
  await expect(page.getByRole('region', { name: 'No status notebooks' }).getByRole('combobox')).toBeDisabled()
  await page.getByRole('button', { name: 'Locked' }).click()
  await page.getByRole('region', { name: 'No status notebooks' }).getByRole('combobox').selectOption('done')
  await expect(page.getByRole('region', { name: 'Done notebooks' })).toContainText('Web notebook')
  await page.getByRole('button', { name: /Web notebook/ }).click()
  await expect(page.getByRole('complementary', { name: /Notebook details/ })).toContainText('Launch brief')
  await captureEvidence(page, 'notes-folder-board-detail')
  await page.getByRole('button', { name: 'Remove Work', exact: true }).click()
  await expect(page.getByRole('complementary', { name: /Notebook details/ })).toHaveCount(0)
  await expect(page.locator('.notes-message')).toContainText('the notebook left the active filter')
  await expect(page.getByRole('button', { name: /Web notebook/ })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Clear all' })).toBeFocused()
  expect(fixture.requests).toContain('POST /graphql:SetProgress')
  expect(fixture.requests.filter((request) => request === 'POST /graphql:RemoveNotebookTagById')).toHaveLength(2)
  fixture.assertClean()
})

test('keeps duplicate folder branches ID-scoped and qualifies picker and search labels', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()

  await page.getByRole('button', { name: 'Expand Archive' }).click()
  await page.getByRole('button', { name: 'Expand Work' }).click()
  await expect(page.getByRole('button', { name: 'Archive / Launch', exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Work / Launch', exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Add Archive / Launch to filter' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Add Work / Launch to filter' })).toBeVisible()

  await page.getByRole('button', { name: /Web notebook/ }).click()
  const detail = page.getByRole('complementary', { name: /Notebook details/ })
  const picker = detail.getByLabel('Add folder')
  await expect(picker.locator('option', { hasText: 'Archive / Launch' })).toHaveCount(1)
  await expect(picker.locator('option', { hasText: 'Work / Launch' })).toHaveCount(1)
  await picker.selectOption({ label: 'Archive / Launch' })
  await expect(detail.getByRole('button', { name: 'Remove Archive / Launch' })).toBeVisible()
  expect(fixture.notebookTagMutationIds).toContain('folder-archive-launch')

  await page.getByRole('tab', { name: 'Tags' }).click()
  const kanbanManager = page.getByRole('region', { name: 'Kanban status sets' })
  await kanbanManager.getByRole('combobox', { name: 'Bind folder' }).selectOption({ label: 'Archive / Launch' })
  await kanbanManager.getByRole('combobox', { name: 'Status set' }).selectOption({ label: 'Branch board' })
  await kanbanManager.getByRole('button', { name: 'Apply binding' }).click()
  await expect.poll(() => fixture.kanbanAssignments.at(-1)).toEqual({
    tagId: 'folder-archive-launch',
    setId: 'kanban-branch',
  })
  expect(fixture.requests).toContain('POST /graphql:AssignKanbanStatusSetByTagId')

  await page.getByRole('button', { name: 'Close notebook details' }).click()
  await page.getByRole('button', { name: 'Search notes' }).click()
  const search = page.getByRole('dialog', { name: 'Search notes' })
  await search.getByLabel('Search full note text').fill('launch')
  await search.getByRole('button', { name: 'Search', exact: true }).click()
  await expect(search).toContainText('Work / Launch')
  await expect(search).toContainText('Archive / Launch')
  fixture.assertClean()
})

test('renders and persists system-memory Lock and Unlock controls', async ({ page }) => {
  const fixture = await installAPI(page, { systemMemoryNotebook: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: /Riela System Memory/ }).click()

  const detail = page.getByRole('complementary', { name: /Notebook details/ })
  await expect(detail.getByText('Read-only', { exact: true })).toBeVisible()
  await expect(detail.getByRole('button', { name: 'Add note' })).toBeDisabled()
  await expect(detail.getByRole('button', { name: 'Edit' })).toBeDisabled()

  await detail.getByRole('button', { name: 'Unlock' }).click()
  await expect(detail.getByText('Read-only', { exact: true })).toHaveCount(0)
  await expect(detail.getByRole('button', { name: 'Add note' })).toBeEnabled()
  await expect(detail.getByRole('button', { name: 'Edit' })).toBeEnabled()
  await expect(page.getByText('System memory is unlocked.')).toBeVisible()

  await detail.locator(':scope > button.secondary', { hasText: 'Lock' }).click()
  await expect(detail.getByText('Read-only', { exact: true })).toBeVisible()
  await expect(detail.getByRole('button', { name: 'Add note' })).toBeDisabled()
  await expect(detail.getByRole('button', { name: 'Edit' })).toBeDisabled()
  await expect(page.getByText('System memory is locked.')).toBeVisible()
  expect(fixture.requests.filter((request) => request === 'POST /graphql:SetNotebookReadOnly')).toHaveLength(2)
  fixture.assertClean()
})

test('does not expose system-memory controls for a same-named folder', async ({ page }) => {
  const fixture = await installAPI(page, { sameNamedSystemMemoryFolder: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()

  const detail = page.getByRole('complementary', { name: /Notebook details/ })
  await expect(detail.getByRole('button', { name: 'Lock', exact: true })).toHaveCount(0)
  await expect(detail.getByRole('button', { name: 'Unlock', exact: true })).toHaveCount(0)
  expect(fixture.requests).not.toContain('POST /graphql:SetNotebookReadOnly')
  fixture.assertClean()
})

test('retains the locked system-memory UI when Unlock fails', async ({ page }) => {
  const fixture = await installAPI(page, {
    systemMemoryNotebook: true,
    notebookLockMutationFailure: true,
  })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: /Riela System Memory/ }).click()

  const detail = page.getByRole('complementary', { name: /Notebook details/ })
  await detail.getByRole('button', { name: 'Unlock' }).click()
  await expect(detail.getByText('Read-only', { exact: true })).toBeVisible()
  await expect(detail.getByRole('button', { name: 'Add note' })).toBeDisabled()
  await expect(detail.getByRole('button', { name: 'Edit' })).toBeDisabled()
  await expect(page.getByText('Could not change notebook lock: lock service unavailable')).toBeVisible()
  expect(fixture.requests.filter((request) => request === 'POST /graphql:SetNotebookReadOnly')).toHaveLength(1)
  fixture.assertClean()
})

test('intersects ordered notebook filter groups across List and Board', async ({ page }) => {
  const fixture = await installAPI(page, { secondNotebook: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()

  await page.getByRole('button', { name: 'Work', exact: true }).click()
  await page.getByRole('tab', { name: 'Tags' }).click()
  await page.getByRole('button', { name: /Priority/ }).click()
  const addHigh = page.getByRole('button', { name: 'Add High to filter' })
  await expect(addHigh).toBeEnabled()
  await addHigh.focus()
  await page.keyboard.press('Enter')
  await expect(addHigh).toBeDisabled()

  await expect.poll(() => fixture.notebookFilterGroups.at(-1)).toEqual([['folder-work'], ['priority-high']])
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  await expect(page.getByRole('button', { name: /Other notebook/ })).toHaveCount(0)
  await page.getByRole('tab', { name: 'Board' }).click()
  await expect(page.getByRole('region', { name: 'No status notebooks' })).toContainText('Web notebook')
  await expect(page.locator('.notebook-board')).not.toContainText('Other notebook')

  const removeHigh = page.getByRole('button', { name: 'Remove High filter' })
  await removeHigh.focus()
  await page.keyboard.press('Enter')
  await expect(page.getByRole('button', { name: /Other notebook/ })).toBeVisible()
  const clearAll = page.getByRole('button', { name: 'Clear all' })
  await clearAll.focus()
  await page.keyboard.press('Enter')
  await expect.poll(() => fixture.notebookFilterGroups.at(-1)).toEqual([])
  fixture.assertClean()
})

test('retains Board columns and the dragged card through delayed refresh', async ({ page }) => {
  const fixture = await installAPI(page, { notebookDelayAfterFirst: 500 })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  await page.getByRole('tab', { name: 'Board' }).click()
  await page.getByRole('button', { name: 'Locked' }).click()
  const card = page.locator('.board-card').filter({ hasText: 'Web notebook' })
  await expect(page.locator('.board-column')).toHaveCount(5)
  await card.evaluate((element) => {
    element.dispatchEvent(new DragEvent('dragstart', {
      bubbles: true,
      cancelable: true,
      dataTransfer: new DataTransfer(),
    }))
  })
  await page.evaluate(() => {
    const retained = globalThis as typeof globalThis & {
      __retainedBoard?: Element
      __retainedCard?: Element
    }
    retained.__retainedBoard = document.querySelector('.notebook-board') ?? undefined
    retained.__retainedCard = [...document.querySelectorAll('.board-card')]
      .find((element) => element.textContent?.includes('Web notebook'))
  })

  await page.getByRole('button', { name: 'Refresh' }).click()
  await expect(page.getByText('Counts updating…')).toBeVisible()
  await expect.poll(() =>
    fixture.requests.filter((request) => request === 'POST /graphql:Notebooks').length,
  ).toBe(2)
  await page.waitForTimeout(600)
  await expect(page.getByText('Counts updating…')).toHaveCount(0)
  expect(await page.evaluate(() => {
    const retained = globalThis as typeof globalThis & {
      __retainedBoard?: Element
      __retainedCard?: Element
    }
    return {
      board: retained.__retainedBoard?.isConnected === true
        && retained.__retainedBoard === document.querySelector('.notebook-board'),
      card: retained.__retainedCard?.isConnected === true
        && retained.__retainedCard === [...document.querySelectorAll('.board-card')]
          .find((element) => element.textContent?.includes('Web notebook')),
    }
  })).toEqual({ board: true, card: true })

  await card.evaluate((element) => {
    element.dispatchEvent(new DragEvent('dragend', { bubbles: true, cancelable: true }))
  })
  await expect(page.locator('.board-card').filter({ hasText: 'Web notebook' })).toBeVisible()
  fixture.assertClean()
})

test('keeps Board columns mounted during fail-closed membership reconciliation', async ({ page }) => {
  const fixture = await installAPI(page, { notebookDelayAfterFirst: 500 })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: 'Work', exact: true }).click()
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  await page.getByRole('tab', { name: 'Board' }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()
  await page.getByRole('button', { name: 'Remove Work', exact: true }).click()

  await expect.poll(() =>
    fixture.requests.filter((request) => request === 'POST /graphql:Notebooks').length,
  ).toBe(3)
  await expect(page.locator('.notebook-board')).toBeVisible()
  await expect(page.locator('.board-column')).toHaveCount(5)
  await expect(page.locator('.board-card')).toHaveCount(0)
  await expect(page.getByText('Loading notebooks and final board counts…')).toBeVisible()
  await expect(page.getByText('No notebooks in this scope')).toBeVisible()
  await expect(page.locator('.board-column')).toHaveCount(5)
  fixture.assertClean()
})

test('retains accepted partial notebooks when paging makes no forward progress', async ({ page }) => {
  const fixture = await installAPI(page, { duplicateNotebookPage: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()

  await expect(page.getByRole('alert')).toContainText('no forward progress')
  await expect(page.getByText('Paged notebook 1', { exact: true })).toBeVisible()
  expect(fixture.requests.filter((request) => request === 'POST /graphql:Notebooks')).toHaveLength(2)
  fixture.assertClean()
})

test('keeps custom status names verbatim and groups them into the fallback column', async ({ page }) => {
  const fixture = await installAPI(page, { initialNotebookProgress: 'future-status' })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()

  const listRow = page.getByRole('button', { name: /Web notebook/ })
  await expect(listRow).toContainText('future-status')
  await expect(listRow).not.toContainText('Unknown status')

  await page.getByRole('tab', { name: 'Board' }).click()
  const noneColumn = page.getByRole('region', { name: 'No status notebooks' })
  await expect(noneColumn).toContainText('Web notebook')
  fixture.assertClean()
})

test('renders notebook preview and count metadata while omitting empty previews', async ({ page }) => {
  const fixture = await installAPI(page, { secondNotebook: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  const webRow = page.getByRole('button', { name: /Web notebook/ })
  const otherRow = page.getByRole('button', { name: /Other notebook/ })
  await expect(webRow).toContainText('3 notes')
  await expect(webRow.locator('.list-preview')).toHaveText('First **plain-text** launch note')
  await expect(otherRow).toContainText('0 notes')
  await expect(otherRow.locator('.notebook-preview')).toHaveCount(0)

  await page.getByRole('tab', { name: 'Board' }).click()
  const webCard = page.locator('.board-card').filter({ hasText: 'Web notebook' })
  const otherCard = page.locator('.board-card').filter({ hasText: 'Other notebook' })
  await expect(webCard.locator('.board-preview')).toHaveText('First **plain-text** launch note')
  await expect(webCard).toContainText('3 notes')
  await expect(otherCard.locator('.notebook-preview')).toHaveCount(0)
  fixture.assertClean()
})

test('groups all-class detail chips and only applies existing assignable tags', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()
  const detail = page.getByRole('complementary', { name: /Notebook details/ })
  await expect(detail.locator('.assignment-group h3')).toHaveText(['Folder', 'Priority', 'Topic', 'Tags'])
  await expect(detail.getByText('High', { exact: true })).toBeVisible()
  await expect(detail.getByRole('button', { name: 'Remove High' })).toHaveCount(0)

  await detail.getByLabel('Tag class').selectOption({ label: 'Empty class' })
  await expect(detail.getByLabel('Existing tag')).toBeDisabled()
  await expect(detail.locator('.tag-picker-help')).toContainText('No existing tag')

  await detail.getByLabel('Tag class').selectOption({ label: 'Topic' })
  await expect(detail.getByLabel('Existing tag').locator('option', { hasText: 'Web' })).toHaveCount(0)
  await detail.getByLabel('Existing tag').selectOption({ label: 'Roadmap' })
  await detail.getByRole('button', { name: 'Add selected tag' }).click()
  await expect(detail.getByRole('button', { name: 'Remove Roadmap', exact: true })).toBeVisible()
  await detail.getByRole('button', { name: 'Remove Roadmap', exact: true }).click()
  await expect(detail.getByRole('button', { name: 'Remove Roadmap', exact: true })).toHaveCount(0)
  expect(fixture.requests).toContain('POST /graphql:ApplyNotebookTagIds')
  expect(fixture.requests).toContain('POST /graphql:RemoveNotebookTagById')
  fixture.assertClean()
})

test('serializes all notebook membership controls behind one in-flight mutation', async ({ page }) => {
  const fixture = await installAPI(page, { removeFolderMutationDelay: 500 })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()
  const detail = page.getByRole('complementary', { name: /Notebook details/ })

  await detail.getByLabel('Tag class').selectOption({ label: 'Topic' })
  await detail.getByLabel('Existing tag').selectOption({ label: 'Roadmap' })
  const addSelected = detail.getByRole('button', { name: 'Add selected tag' })
  await expect(addSelected).toBeEnabled()

  const removePersonal = detail.getByRole('button', { name: 'Remove Personal' })
  await removePersonal.click()
  await expect(removePersonal).toBeDisabled()
  await expect(detail.getByRole('button', { name: 'Remove Work', exact: true })).toBeDisabled()
  await expect(detail.getByRole('button', { name: 'Remove Roadmap / Web' })).toBeDisabled()
  await expect(detail.getByLabel('Add folder')).toBeDisabled()
  await expect(detail.getByLabel('Tag class')).toBeDisabled()
  await expect(detail.getByLabel('Existing tag')).toBeDisabled()
  await expect(addSelected).toBeDisabled()
  await expect(removePersonal).toHaveCount(0)
  expect(fixture.requests.filter((request) => request === 'POST /graphql:RemoveNotebookTagById')).toHaveLength(1)
  fixture.assertClean()
})

test('retains filtered List and Board membership when unrelated tag removal refresh fails', async ({ page }) => {
  const fixture = await installAPI(page, { noteFolderRefreshFailureAfterRemove: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: 'Work', exact: true }).click()
  await expect.poll(() => fixture.notebookFilterGroups.at(-1)).toEqual([['folder-work']])
  await page.getByRole('tab', { name: 'Board' }).click()
  const boardCard = page.getByRole('region', { name: 'No status notebooks' })
    .getByRole('button', { name: /Web notebook/ })
  await expect(boardCard).toBeVisible()
  await boardCard.click()

  await page.getByRole('button', { name: 'Remove Personal' }).click()

  await expect(page.getByRole('alert')).toContainText('folder unavailable')
  await expect(page.locator('.notebook-board')).toBeVisible()
  await expect(page.locator('.board-column')).toHaveCount(5)
  await expect(boardCard).toBeVisible()
  await expect(page.getByRole('complementary', { name: /Notebook details/ }))
    .toContainText('Web notebook')
  await page.getByRole('tab', { name: 'List' }).click()
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  await expect(page.locator('.notes-message')).toContainText('scope could not be refreshed')
  fixture.assertClean()
})

test('refreshes a newer filter after a delayed tag addition commits', async ({ page }) => {
  const fixture = await installAPI(page, { applyTagMutationDelay: 500 })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()

  await page.getByRole('complementary', { name: /Notebook details/ })
    .getByLabel('Add folder')
    .selectOption({ label: 'Work / Launch' })
  await page.getByRole('button', { name: 'Expand Work' }).click()
  await page.getByRole('button', { name: 'Work / Launch', exact: true }).click()

  await expect.poll(() =>
    fixture.notebookFilterGroups.filter((groups) =>
      JSON.stringify(groups) === JSON.stringify([['folder-launch']])).length,
  ).toBeGreaterThanOrEqual(2)
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  fixture.assertClean()
})

test('refreshes a newer descendant filter after a delayed removal commits', async ({ page }) => {
  const fixture = await installAPI(page, { removeFolderMutationDelay: 500 })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()

  await page.getByRole('button', { name: 'Remove Roadmap / Web' }).click()
  await page.getByRole('tab', { name: 'Tags' }).click()
  await page.getByRole('button', { name: /Topic/ }).click()
  await page.getByRole('button', { name: 'Roadmap', exact: true }).click()

  await expect.poll(() =>
    fixture.notebookFilterGroups.filter((groups) =>
      JSON.stringify(groups) === JSON.stringify([['topic-roadmap']])).length,
  ).toBeGreaterThanOrEqual(2)
  await expect(page.getByRole('button', { name: /Web notebook/ })).toHaveCount(0)
  await expect(page.getByText('No notebooks in this scope')).toBeVisible()
  fixture.assertClean()
})

test('fails closed when removing a non-folder descendant and refresh fails', async ({ page }) => {
  const fixture = await installAPI(page, { noteFolderRefreshFailureAfterRemove: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('tab', { name: 'Tags' }).click()
  await page.getByRole('button', { name: /Topic/ }).click()
  await page.getByRole('button', { name: 'Roadmap', exact: true }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()

  await page.getByRole('button', { name: 'Remove Roadmap / Web' }).click()

  await expect(page.getByRole('alert')).toContainText('folder unavailable')
  await expect(page.getByRole('button', { name: /Web notebook/ })).toHaveCount(0)
  await expect(page.getByRole('complementary', { name: /Notebook details/ })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Clear all' })).toBeFocused()
  fixture.assertClean()
})

test('focuses the first surviving notebook after the selected notebook leaves the filter', async ({ page }) => {
  const fixture = await installAPI(page, { secondNotebook: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: 'Work', exact: true }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()

  await page.getByRole('button', { name: 'Remove Work', exact: true }).click()

  await expect(page.getByRole('complementary', { name: /Notebook details/ })).toHaveCount(0)
  await expect(page.getByRole('button', { name: /Other notebook/ })).toBeFocused()
  await expect(page.getByRole('button', { name: /Web notebook/ })).toHaveCount(0)
  fixture.assertClean()
})

test('scopes List and Board from classed tag trees with breadcrumb and mutual clearing', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('treeitem', { name: /Work/ }).getByRole('button', { name: 'Work', exact: true }).focus()
  await page.getByRole('tab', { name: 'Tags', exact: true }).click()
  await expect(page.locator('.tag-group-toggle')).toHaveText(['› Priority1', '› Topic2', '› Tags1'])
  const topicGroup = page.getByRole('button', { name: /Topic/ })
  await topicGroup.click()
  await topicGroup.focus()
  await page.keyboard.press('Tab')
  await expect(page.getByRole('button', { name: 'Expand Roadmap' })).toBeFocused()
  await page.keyboard.press('Tab')
  const roadmapTag = page.getByRole('button', { name: 'Roadmap', exact: true })
  await expect(roadmapTag).toBeFocused()
  await page.keyboard.press('ArrowRight')
  await page.keyboard.press('ArrowDown')
  await expect(page.getByRole('button', { name: 'Roadmap / Web', exact: true })).toBeFocused()
  await roadmapTag.click()
  await expect(page.locator('.notes-breadcrumb')).toContainText('Topic')
  await expect(page.locator('.notes-breadcrumb')).toContainText('Roadmap')
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  expect(fixture.notebookFilters).toContainEqual(['topic-roadmap'])

  await page.getByRole('tab', { name: 'Board' }).click()
  await expect(page.getByRole('region', { name: 'No status notebooks' })).toContainText('Web notebook')
  await page.getByRole('tab', { name: 'Folder', exact: true }).click()
  await page.getByRole('treeitem', { name: /Work/ }).getByRole('button', { name: 'Work', exact: true }).click()
  await expect(page.locator('.notes-breadcrumb')).toContainText('Work')
  await expect(page.locator('.notes-breadcrumb')).not.toContainText('Topic')
  await expect.poll(() => fixture.notebookFilters.some((filter) => filter.length === 1 && filter[0] === 'folder-work')).toBe(true)
  await page.getByRole('button', { name: 'All notebooks' }).first().click()
  await expect.poll(() => fixture.notebookFilters.at(-1)).toEqual([])
  fixture.assertClean()
})

test('clears tag scope and stale detail when the selected catalog tag disappears', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('tab', { name: 'Tags', exact: true }).click()
  await page.getByRole('button', { name: /Topic/ }).click()
  await page.getByRole('button', { name: 'Roadmap', exact: true }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()
  const detail = page.getByRole('complementary', { name: /Notebook details/ })
  await expect(detail).toContainText('Launch brief')

  fixture.removeCatalogTag('Roadmap')
  await page.getByRole('button', { name: 'Refresh' }).click()
  await expect.poll(() => fixture.notebookFilters.at(-1)).toEqual([])
  await expect(detail).toHaveCount(0)
  await expect(page.getByText('Launch brief')).toHaveCount(0)
  await expect(page.locator('.notes-breadcrumb')).not.toContainText('Roadmap')
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  fixture.assertClean()
})

test('rejects a delayed tag-scope completion after a newer folder selection', async ({ page }) => {
  const fixture = await installAPI(page, { scopeDelayByTag: { Roadmap: 500 } })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('tab', { name: 'Tags', exact: true }).click()
  await page.getByRole('button', { name: /Topic/ }).click()
  await page.getByRole('button', { name: 'Roadmap', exact: true }).click()
  await page.getByRole('tab', { name: 'Folder', exact: true }).click()
  await page.getByRole('treeitem', { name: /Work/ }).getByRole('button', { name: 'Work', exact: true }).click()
  await expect(page.locator('.notes-breadcrumb')).toContainText('Work')
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  await page.waitForTimeout(650)
  await expect(page.locator('.notes-breadcrumb')).toContainText('Work')
  await expect(page.locator('.notes-breadcrumb')).not.toContainText('Topic')
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  fixture.assertClean()
})

test('keeps All notebooks selected after creating a root folder', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  await page.getByLabel('Create folder').fill('New folder')
  await page.getByRole('button', { name: 'Create', exact: true }).click()
  await expect(page.getByRole('button', { name: 'All notebooks' }).first()).toHaveClass(/selected/)
  await expect(page.locator('.folder-row.selected')).toHaveCount(0)
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  await expect(page.locator('.notes-message')).toContainText('Created folder “New folder”')
  expect(fixture.requests).toContain('POST /graphql:DefineFolder')
  fixture.assertClean()
})

test('enters a new child folder only from its matching parent-folder scope', async ({ page }) => {
  const fixture = await installAPI(page, { createdFolderDelay: 250 })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: 'Work', exact: true }).click()
  await page.getByLabel('Create child folder').fill('New folder')
  await page.getByRole('button', { name: 'Create', exact: true }).click()

  await expect(page.locator('.folder-row.selected')).toContainText('New folder')
  await expect(page.getByRole('button', { name: /Web notebook/ })).toHaveCount(0)
  await expect(page.getByText('No notebooks in this scope')).toBeVisible()
  await expect(page.locator('.notes-message')).toContainText('Created folder “Work / New folder”')
  await expect.poll(() => fixture.notebookFilterGroups.at(-1)).toEqual([['new-folder']])
  fixture.assertClean()
})

test('preserves newer folder navigation while creation completes', async ({ page }) => {
  const fixture = await installAPI(page, { defineFolderMutationDelay: 500 })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByLabel('Create folder').fill('New folder')
  await page.getByRole('button', { name: 'Create', exact: true }).click()
  await expect.poll(() => fixture.requests.filter((request) => request === 'POST /graphql:DefineFolder').length).toBe(1)
  const workFolder = page.getByRole('treeitem', { name: /Work/ }).getByRole('button', { name: 'Work', exact: true })
  await workFolder.click()
  await expect(page.locator('.folder-row.selected')).toContainText('Work')
  await expect(page.locator('.notes-message')).toContainText('Created folder “New folder”')
  await expect(page.locator('.folder-row.selected')).toContainText('Work')
  await expect(page.locator('.notes-message')).not.toContainText('did not match')
  fixture.assertClean()
})

test('preserves a newer notebook detail while an older folder removal completes', async ({ page }) => {
  const fixture = await installAPI(page, {
    removeFolderMutationDelay: 500,
    secondNotebook: true,
  })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('treeitem', { name: /Work/ }).getByRole('button', { name: 'Work', exact: true }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()
  await page.getByRole('button', { name: 'Remove Work', exact: true }).click()
  await expect.poll(() => fixture.requests.filter((request) => request === 'POST /graphql:RemoveNotebookTagById').length).toBe(1)
  await page.getByRole('button', { name: /Other notebook/ }).click()
  const detail = page.getByRole('complementary', { name: /Notebook details/ })
  await expect(detail).toContainText('Other notebook')
  await expect(page.getByRole('button', { name: /Web notebook/ })).toHaveCount(0)
  await expect(detail).toContainText('Other notebook')
  await expect(page.getByRole('button', { name: /Other notebook/ })).toBeFocused()
  fixture.assertClean()
})

test('clears newer detail and restores focus when stale removal refresh fails', async ({ page }) => {
  const fixture = await installAPI(page, {
    noteFolderRefreshFailureAfterRemove: true,
    removeFolderMutationDelay: 500,
    secondNotebook: true,
  })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('treeitem', { name: /Work/ }).getByRole('button', { name: 'Work', exact: true }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()
  await page.getByRole('button', { name: 'Remove Work', exact: true }).click()
  await expect.poll(() => fixture.requests.filter((request) => request === 'POST /graphql:RemoveNotebookTagById').length).toBe(1)
  await page.getByRole('button', { name: /Other notebook/ }).click()
  await expect(page.getByRole('complementary', { name: /Notebook details/ })).toContainText('Other notebook')

  await expect(page.getByRole('alert')).toContainText('folder unavailable')
  await expect(page.getByRole('complementary', { name: /Notebook details/ })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Clear all' })).toBeFocused()
  fixture.assertClean()
})

test('fails closed when scope refresh fails after folder removal', async ({ page }) => {
  const fixture = await installAPI(page, { noteFolderRefreshFailureAfterRemove: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('treeitem', { name: /Work/ }).getByRole('button', { name: 'Work', exact: true }).click()
  const listRow = page.getByRole('button', { name: /Web notebook/ })
  await expect(listRow).toBeVisible()
  await listRow.click()
  await page.getByRole('button', { name: 'Remove Work', exact: true }).click()
  await expect(page.getByRole('alert')).toContainText('folder unavailable')
  await expect(page.getByRole('complementary', { name: /Notebook details/ })).toHaveCount(0)
  await expect(listRow).toHaveCount(0)
  await expect(page.locator('.notes-message')).toContainText('scope could not be refreshed')
  await expect(page.getByRole('button', { name: 'Clear all' })).toBeFocused()
  expect(fixture.requests).toContain('POST /graphql:RemoveNotebookTagById')
  fixture.assertClean()
})

test('rejects an older note read after closing and reopening the same notebook', async ({ page }) => {
  const fixture = await installAPI(page, {
    noteResponsesByNotebook: {
      'notebook-web': [
        { delay: 500, title: 'Stale note' },
        { delay: 50, title: 'Fresh note' },
      ],
    },
  })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  const notebook = page.getByRole('button', { name: /Web notebook/ })
  await notebook.click()
  await page.getByRole('button', { name: 'Close notebook details' }).click()
  await notebook.click()

  const reader = page.getByRole('complementary', { name: /Notebook details/ }).locator('.note-reader')
  await expect(reader).toContainText('Fresh note')
  await page.waitForTimeout(550)
  await expect(reader).toContainText('Fresh note')
  await expect(reader).not.toContainText('Stale note')
  fixture.assertClean()
})

test('keeps the newer note reader loading when an older first-note response arrives', async ({ page }) => {
  const fixture = await installAPI(page, {
    secondNotebook: true,
    notesDelayByNotebook: { 'notebook-web': 500, 'notebook-other': 1500 },
  })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()
  await page.getByRole('button', { name: /Other notebook/ }).click()
  const detail = page.getByRole('complementary', { name: /Notebook details/ })
  await expect(detail).toContainText('Other notebook')
  await expect.poll(() =>
    fixture.requests.filter((request) => request.endsWith('/first-note')).length).toBe(2)

  // The notebook-web read lands at ~500ms and must not resolve the newer read.
  await page.waitForTimeout(700)
  await expect(detail).not.toContainText('This notebook has no notes yet.')
  await expect(detail).not.toContainText('Launch brief')
  await expect(detail).toContainText('Loading note…')
  await expect(detail).toContainText('Other brief')
  fixture.assertClean()
})

test('ends reader paging after an exact full page', async ({ page }) => {
  const fixture = await installAPI(page, { readerExactPage: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()
  const reader = page.getByRole('complementary', { name: /Notebook details/ }).locator('.note-reader')
  const position = reader.locator('.note-reader-position')
  const nextNote = reader.getByRole('button', { name: 'Next note' })

  // The full window claims more notes, so paging is still offered at its end.
  await expect(position).toHaveText(`1 of ${readerPageSize}+`)
  for (let step = 1; step < readerPageSize; step += 1) await nextNote.click()
  await expect(position).toHaveText(`${readerPageSize} of ${readerPageSize}+`)
  expect(fixture.requests.filter((request) => request === 'POST /graphql:Notes')).toHaveLength(0)

  await nextNote.click()
  await expect(nextNote).toBeDisabled()
  await expect(position).toHaveText(`${readerPageSize} of ${readerPageSize}`)
  expect(fixture.requests.filter((request) => request === 'POST /graphql:Notes')).toHaveLength(1)
  fixture.assertClean()
})

test('fails closed instead of showing the previous notebook scope', async ({ page }) => {
  const fixture = await installAPI(page, { noteFolderFailure: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  await page.getByRole('treeitem', { name: /Work/ }).getByRole('button', { name: 'Work', exact: true }).click()
  await expect(page.getByRole('alert')).toContainText('folder unavailable')
  await expect(page.getByRole('button', { name: /Web notebook/ })).toHaveCount(0)
  fixture.assertClean()
})
