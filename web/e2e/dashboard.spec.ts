import { expect, test, type Locator, type Page, type Route } from '@playwright/test'

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
  notePreviewExactPage?: boolean
  notesDelayByNotebook?: Record<string, number>
  noteResponsesByNotebook?: Record<string, Array<{ delay?: number; title: string }>>
  scopeDelayByTag?: Record<string, number>
  notebookDelayAfterFirst?: number
  initialNotebookProgress?: string
  duplicateNotebookPage?: boolean
}

async function installAPI(page: Page, options: FixtureOptions = {}) {
  const requests: string[] = []
  const unexpectedRequests: string[] = []
  const browserErrors: string[] = []
  const failedRequests: string[] = []
  const badResponses: string[] = []
  const notebookFilters: string[][] = []
  const notebookFilterGroups: string[][][] = []
  const noteRequestCounts = new Map<string, number>()
  let mutationCount = 0
  let notebookRequestCount = 0
  let configuredPort = 19091
  let restartRequired = false
  let noteProgress = options.initialNotebookProgress ?? 'none'
  let folderRemoved = false
  const folder = { tagId: 'folder-work', name: 'Work', classId: 'folder', parentTagId: null, isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const child = { tagId: 'folder-launch', name: 'Launch', classId: 'folder', parentTagId: 'folder-work', isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const topicRoot = { tagId: 'topic-roadmap', name: 'Roadmap', classId: 'topic', parentTagId: null, isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const topicChild = { tagId: 'topic-web', name: 'Web', classId: 'topic', parentTagId: 'topic-roadmap', isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const priority = { tagId: 'priority-high', name: 'High', classId: 'priority', parentTagId: null, isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const classless = { tagId: 'tag-personal', name: 'Personal', classId: null, parentTagId: null, isSystem: false, createdAt: '2026-07-25T00:00:00Z' }
  const foldersByName = new Map([folder, child].map((tag) => [tag.name, tag]))
  const tagsByName = new Map([folder, child, topicRoot, topicChild, priority, classless].map((tag) => [tag.name, tag]))
  let noteTagNames = ['Work', 'Web', 'High', 'Personal']
  const assignments = (names: string[]) => names.flatMap((name) => {
    const tag = tagsByName.get(name)
    return tag ? [{ tag, provenance: 'human', assignedBy: 'riela-web', deletable: tag.tagId !== 'priority-high', createdAt: '2026-07-25T00:00:00Z' }] : []
  })
  const currentNotebook = () => ({
    notebookId: 'notebook-web',
    title: 'Web notebook',
    progress: noteProgress,
    createdAt: '2026-07-25T00:00:00Z',
    updatedAt: '2026-07-25T01:00:00Z',
    tags: assignments(noteTagNames),
    firstNotePreview: 'First **plain-text** launch note',
    noteCount: 3,
  })
  const otherNotebook = () => ({
    notebookId: 'notebook-other',
    title: 'Other notebook',
    progress: 'pending',
    createdAt: '2026-07-25T00:00:00Z',
    updatedAt: '2026-07-25T02:00:00Z',
    tags: assignments(['Work']),
    firstNotePreview: '   ',
    noteCount: 0,
  })
  const matchesScope = (tagFilter: unknown, assignedTagNames: string[]): boolean => {
    if (!Array.isArray(tagFilter) || tagFilter.length === 0) return true
    return tagFilter.some((name) =>
      name === 'Work'
        ? assignedTagNames.some((assigned) => assigned === 'Work' || assigned === 'Launch')
        : name === 'Roadmap'
          ? assignedTagNames.some((assigned) => assigned === 'Roadmap' || assigned === 'Web')
          : typeof name === 'string' && assignedTagNames.includes(name))
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
    if (operation === 'Tags') return result({ tags: { result: accepted, value: [...tagsByName.values()] } })
    if (operation === 'EffectiveKanbanStatuses') {
      return result({ effectiveKanbanStatuses: { result: accepted, value: {
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
      return result({ kanbanStatusSets: { result: accepted, value: [] } })
    }
    if (operation === 'TagClasses') return result({ tagClasses: { result: accepted, value: [
      { classId: 'folder', label: 'Folder', description: null },
      { classId: 'priority', label: 'Priority', description: null },
      { classId: 'topic', label: 'Topic', description: null },
      { classId: 'empty', label: 'Empty class', description: null },
    ] } })
    if (operation === 'Notebooks') {
      notebookRequestCount += 1
      const tagFilter = body.variables?.tagFilter
      const rawGroups = body.variables?.tagFilterGroups
      const groups = Array.isArray(rawGroups)
        ? rawGroups.flatMap((group) => Array.isArray(group)
          ? [group.filter((value): value is string => typeof value === 'string')]
          : [])
        : []
      const legacyFilter = Array.isArray(tagFilter)
        ? tagFilter.filter((value): value is string => typeof value === 'string')
        : []
      const effectiveGroups = groups.length > 0 ? groups : legacyFilter.length > 0 ? [legacyFilter] : []
      notebookFilterGroups.push(effectiveGroups)
      notebookFilters.push(effectiveGroups.flat())
      const requestedTag = effectiveGroups[0]?.[0] ?? ''
      const scopeDelay = options.scopeDelayByTag?.[requestedTag]
      if (scopeDelay) await new Promise((resolve) => setTimeout(resolve, scopeDelay))
      if (notebookRequestCount > 1 && options.notebookDelayAfterFirst) {
        await new Promise((resolve) => setTimeout(resolve, options.notebookDelayAfterFirst))
      }
      if (options.createdFolderDelay && effectiveGroups.some((group) => group.includes('New folder'))) {
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
        { notebook: currentNotebook(), tagNames: noteTagNames },
        ...(options.secondNotebook ? [{ notebook: otherNotebook(), tagNames: ['Work'] }] : []),
      ]
      return result({
        notebooks: {
          result: accepted,
          value: candidates
            .filter((candidate) =>
              effectiveGroups.every((group) => matchesScope(group, candidate.tagNames)))
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
      const noteRequestIndex = noteRequestCounts.get(notebookId) ?? 0
      noteRequestCounts.set(notebookId, noteRequestIndex + 1)
      const noteResponse = options.noteResponsesByNotebook?.[notebookId]?.[noteRequestIndex]
      const notesDelay = noteResponse?.delay ?? options.notesDelayByNotebook?.[notebookId]
      if (notesDelay) await new Promise((resolve) => setTimeout(resolve, notesDelay))
      const offset = Number(body.variables?.offset ?? 0)
      const requestedLimit = Number(body.variables?.limit)
      const limit = Number.isInteger(requestedLimit) && requestedLimit > 0 ? requestedLimit : 0
      const notes = options.notePreviewExactPage
        ? offset === 0
          ? Array.from({ length: limit }, (_, index) => ({
              noteId: `note-${index + 1}`,
              notebookId: 'notebook-web',
              noteNumber: index + 1,
              title: `Brief ${index + 1}`,
              bodyMarkdown: `Launch brief ${index + 1}`,
              readOnly: true,
              createdAt: '2026-07-25T00:00:00Z',
              updatedAt: '2026-07-25T00:00:00Z',
            }))
          : []
        : [{
            noteId: `note-${noteRequestIndex + 1}`,
            notebookId,
            noteNumber: 1,
            title: noteResponse?.title ?? 'Brief',
            bodyMarkdown: noteResponse?.title ?? '# Launch brief',
            readOnly: true,
            createdAt: '2026-07-25T00:00:00Z',
            updatedAt: '2026-07-25T00:00:00Z',
          }]
      return result({ notes: { result: accepted, value: notes } })
    }
    if (operation === 'SetProgress') {
      noteProgress = String(body.variables?.progress ?? noteProgress)
      return result({ setNotebookProgress: { result: accepted, notebook: currentNotebook() } })
    }
    if (operation === 'ApplyNotebookTag') {
      if (options.applyTagMutationDelay) {
        await new Promise((resolve) => setTimeout(resolve, options.applyTagMutationDelay))
      }
      const input = body.variables?.input as { tags?: unknown } | undefined
      const names = Array.isArray(input?.tags)
        ? input.tags.filter((name): name is string => typeof name === 'string' && tagsByName.has(name))
        : []
      noteTagNames = [...new Set([...noteTagNames, ...names])]
      return result({ applyNotebookTags: { result: accepted, notebook: currentNotebook() } })
    }
    if (operation === 'RemoveNotebookTag') {
      if (options.removeFolderMutationDelay) {
        await new Promise((resolve) => setTimeout(resolve, options.removeFolderMutationDelay))
      }
      const tagName = body.variables?.tagName
      if (body.variables?.notebookId === 'notebook-web' && typeof tagName === 'string') {
        noteTagNames = noteTagNames.filter((name) => name !== tagName)
      }
      folderRemoved = true
      const notebook = body.variables?.notebookId === 'notebook-other' ? otherNotebook() : currentNotebook()
      return result({ removeNotebookTag: { result: accepted, notebook } })
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
      foldersByName.set(created.name, created)
      tagsByName.set(created.name, created)
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
    if (url.pathname === '/api/v1/settings/assistant' && request.method() === 'GET') return json({ profile: 'e2e', revision: 1, assistance: '', vendor: 'openai-api', model: 'gpt-5.6' })
    if (url.pathname === '/api/v1/settings/notes' && request.method() === 'GET') return json({ profile: 'e2e', revision: 1, exposesNoteAPI: false, s3ProfileCount: 0 })
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
    removeCatalogTag: (name: string) => { tagsByName.delete(name) },
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
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  const columns = await page.locator('.instance-grid').evaluate((element) => getComputedStyle(element).gridTemplateColumns.split(' ').length)
  expect(columns).toBe(1)
  await captureEvidence(page, 'mobile-instances')
  fixture.assertClean()
})

test('navigates folder-scoped List and Board Notes with detail and progress controls', async ({ page }) => {
  const fixture = await installAPI(page)
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByLabel('Create folder').fill('Work')
  await page.getByRole('button', { name: 'Create', exact: true }).click()
  await expect(page.getByText(/already belongs to a folder/)).toBeVisible()
  expect(fixture.requests).not.toContain('POST /graphql:DefineFolder')
  const listRow = page.getByRole('button', { name: /Web notebook/ })
  await expect(listRow).toBeVisible()
  await listRow.click()
  const detail = page.getByRole('complementary', { name: /Notebook details/ })
  await expect(detail).toBeVisible()
  await detail.getByLabel('Add folder').selectOption({ label: 'Launch' })
  await expect(detail.getByRole('button', { name: 'Remove Launch' })).toBeVisible()
  expect(fixture.requests).toContain('POST /graphql:ApplyNotebookTag')
  await detail.getByRole('button', { name: 'Remove Launch' }).click()
  await expect(detail.getByRole('button', { name: 'Remove Launch' })).toHaveCount(0)
  expect(fixture.requests).toContain('POST /graphql:RemoveNotebookTag')
  await page.getByRole('button', { name: 'Close notebook details' }).click()
  await expect(listRow).toBeFocused()
  const workFolder = page.getByRole('treeitem', { name: /Work/ }).getByRole('button', { name: 'Work', exact: true })
  await workFolder.focus()
  await page.keyboard.press('ArrowRight')
  const launchFolder = page.getByRole('button', { name: 'Launch', exact: true })
  await expect(launchFolder).toBeVisible()
  await page.keyboard.press('ArrowDown')
  await expect(launchFolder).toBeFocused()
  await page.keyboard.press('ArrowLeft')
  await expect(workFolder).toBeFocused()
  await page.keyboard.press('End')
  await expect(launchFolder).toBeFocused()
  await page.keyboard.press('Home')
  await expect(workFolder).toBeFocused()
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
  expect(fixture.requests.filter((request) => request === 'POST /graphql:RemoveNotebookTag')).toHaveLength(2)
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

  await expect.poll(() => fixture.notebookFilterGroups.at(-1)).toEqual([['Work'], ['High']])
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
  await expect(detail.getByRole('button', { name: 'Remove Roadmap' })).toBeVisible()
  await detail.getByRole('button', { name: 'Remove Roadmap' }).click()
  await expect(detail.getByRole('button', { name: 'Remove Roadmap' })).toHaveCount(0)
  expect(fixture.requests).toContain('POST /graphql:ApplyNotebookTag')
  expect(fixture.requests).toContain('POST /graphql:RemoveNotebookTag')
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
  await expect(detail.getByRole('button', { name: 'Remove Web' })).toBeDisabled()
  await expect(detail.getByLabel('Add folder')).toBeDisabled()
  await expect(detail.getByLabel('Tag class')).toBeDisabled()
  await expect(detail.getByLabel('Existing tag')).toBeDisabled()
  await expect(addSelected).toBeDisabled()
  await expect(removePersonal).toHaveCount(0)
  expect(fixture.requests.filter((request) => request === 'POST /graphql:RemoveNotebookTag')).toHaveLength(1)
  fixture.assertClean()
})

test('retains filtered List and Board membership when unrelated tag removal refresh fails', async ({ page }) => {
  const fixture = await installAPI(page, { noteFolderRefreshFailureAfterRemove: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: 'Work', exact: true }).click()
  await expect.poll(() => fixture.notebookFilterGroups.at(-1)).toEqual([['Work']])
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
    .selectOption({ label: 'Launch' })
  await page.getByRole('button', { name: 'Expand Work' }).click()
  await page.getByRole('button', { name: 'Launch', exact: true }).click()

  await expect.poll(() =>
    fixture.notebookFilterGroups.filter((groups) =>
      JSON.stringify(groups) === JSON.stringify([['Launch']])).length,
  ).toBeGreaterThanOrEqual(2)
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  fixture.assertClean()
})

test('refreshes a newer descendant filter after a delayed removal commits', async ({ page }) => {
  const fixture = await installAPI(page, { removeFolderMutationDelay: 500 })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()

  await page.getByRole('button', { name: 'Remove Web' }).click()
  await page.getByRole('tab', { name: 'Tags' }).click()
  await page.getByRole('button', { name: /Topic/ }).click()
  await page.getByRole('button', { name: 'Roadmap', exact: true }).click()

  await expect.poll(() =>
    fixture.notebookFilterGroups.filter((groups) =>
      JSON.stringify(groups) === JSON.stringify([['Roadmap']])).length,
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

  await page.getByRole('button', { name: 'Remove Web' }).click()

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
  await expect(page.getByRole('button', { name: 'Web', exact: true })).toBeFocused()
  await roadmapTag.click()
  await expect(page.locator('.notes-breadcrumb')).toContainText('Topic')
  await expect(page.locator('.notes-breadcrumb')).toContainText('Roadmap')
  await expect(page.getByRole('button', { name: /Web notebook/ })).toBeVisible()
  expect(fixture.notebookFilters).toContainEqual(['Roadmap'])

  await page.getByRole('tab', { name: 'Board' }).click()
  await expect(page.getByRole('region', { name: 'No status notebooks' })).toContainText('Web notebook')
  await page.getByRole('tab', { name: 'Folder', exact: true }).click()
  await page.getByRole('treeitem', { name: /Work/ }).getByRole('button', { name: 'Work', exact: true }).click()
  await expect(page.locator('.notes-breadcrumb')).toContainText('Work')
  await expect(page.locator('.notes-breadcrumb')).not.toContainText('Topic')
  await expect.poll(() => fixture.notebookFilters.some((filter) => filter.length === 1 && filter[0] === 'Work')).toBe(true)
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
  await expect(page.locator('.notes-message')).toContainText('Created folder “New folder”')
  await expect.poll(() => fixture.notebookFilterGroups.at(-1)).toEqual([['New folder']])
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
  await expect.poll(() => fixture.requests.filter((request) => request === 'POST /graphql:RemoveNotebookTag').length).toBe(1)
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
  await expect.poll(() => fixture.requests.filter((request) => request === 'POST /graphql:RemoveNotebookTag').length).toBe(1)
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
  expect(fixture.requests).toContain('POST /graphql:RemoveNotebookTag')
  fixture.assertClean()
})

test('rejects an older preview after closing and reopening the same notebook', async ({ page }) => {
  const fixture = await installAPI(page, {
    noteResponsesByNotebook: {
      'notebook-web': [
        { delay: 500, title: 'Stale preview' },
        { delay: 50, title: 'Fresh preview' },
      ],
    },
  })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  const notebook = page.getByRole('button', { name: /Web notebook/ })
  await notebook.click()
  await page.getByRole('button', { name: 'Close notebook details' }).click()
  await notebook.click()

  const detail = page.getByRole('complementary', { name: /Notebook details/ })
  await expect(detail).toContainText('Fresh preview')
  await page.waitForTimeout(550)
  await expect(detail).toContainText('Fresh preview')
  await expect(detail).not.toContainText('Stale preview')
  fixture.assertClean()
})

test('keeps the newer notebook preview loading when an older notes response arrives', async ({ page }) => {
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
  await expect.poll(() => fixture.requests.filter((request) => request === 'POST /graphql:Notes').length).toBe(2)
  await page.waitForTimeout(700)
  await expect(detail).not.toContainText('No notes in this notebook.')
  await expect(detail).toContainText('Loading notes…')
  await expect(detail).toContainText('Launch brief')
  fixture.assertClean()
})

test('ends note preview paging after an exact full page', async ({ page }) => {
  const fixture = await installAPI(page, { notePreviewExactPage: true })
  await page.goto('/')
  await page.getByRole('button', { name: 'Notes' }).click()
  await page.getByRole('button', { name: /Web notebook/ }).click()
  const detail = page.getByRole('complementary', { name: /Notebook details/ })
  const loadMore = detail.getByRole('button', { name: 'Load more notes' })
  await expect(loadMore).toBeVisible()
  await loadMore.click()
  await expect(loadMore).toHaveCount(0)
  expect(fixture.requests.filter((request) => request === 'POST /graphql:Notes')).toHaveLength(2)
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
