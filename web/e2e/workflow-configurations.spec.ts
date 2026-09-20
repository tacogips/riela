import { expect, test, type Page } from '@playwright/test'

const sourceId = 'project-workflow:/repos/a:review'
const otherSource = 'project-workflow:/repos/b:review'
const configuration = (id: string, source = sourceId, name = '標準設定') => ({
  id, sourceId: source, isDefault: id === source, name, workflowId: 'review', source: 'project',
  sourceKind: 'directory', status: 'stopped', statusDetail: 'Stopped', active: false, enabledAtLaunch: false,
  workingDirectory: null, environmentFilePath: null, environmentVariables: [], requiredEnvironment: [],
  workflowVariables: {}, nodePatchCount: 0, nodePatches: {}, eventSources: [],
})

async function fixture(page: Page, withRun = false) {
  page.on('pageerror', error => { throw error })
  const items = [configuration(sourceId), configuration(otherSource, otherSource), configuration('other-named', otherSource, '別リポジトリ専用')]
  const mutations: Array<{ path: string; body: Record<string, unknown> }> = []
  let revision = 1
  await page.route('**/graphql', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ data: { workflows: { workflows: [], errors: [] } } }) }))
  await page.route('**/api/v1/**', async route => {
    const request = route.request()
    const path = new URL(request.url()).pathname
    const json = (value: unknown, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(value) })
    if (path === '/api/v1/bootstrap') return json({ apiVersion: 'v1', profile: 'test', csrfToken: 'test', revision, capabilities: [], server: { state: 'running' } })
    if (path === '/api/v1/workflows/sources') return json({ profile: 'test', revision, directories: [], projectDirectories: [], repositories: [], discovered: [
      { id: sourceId, name: 'Repository A', workflowId: 'review', scope: 'project', sourceKind: 'directory' },
      { id: otherSource, name: 'Repository B', workflowId: 'review', scope: 'project', sourceKind: 'directory' },
    ] })
    if (path.endsWith('/definition')) return json({ revision, sourceId, workflowId: 'review', name: 'Repository A', scope: 'project', sourceKind: 'directory', definitionRevision: '1',
      definition: { description: 'Review then publish', descriptionTruncated: false, entryStepId: 'review', managerStepId: null,
        steps: [{ id: 'review', nodeId: 'review', role: 'worker', transitions: [{ toStepId: 'publish', label: null, fanoutJoinStepId: null }], transitionsTotalCount: 1, transitionsTruncated: false },
          { id: 'publish', nodeId: 'publish', role: 'worker', transitions: [], transitionsTotalCount: 0, transitionsTruncated: false }], stepsTotalCount: 2, stepsTruncated: false,
        nodes: [{ id: 'review', kind: 'agent' }, { id: 'publish', kind: 'output' }], nodesTotalCount: 2, nodesTruncated: false, transitionsTotalCount: 1, transitionsTruncated: false },
      diagnostics: [], diagnosticsTotalCount: 0, diagnosticsTruncated: false, truncated: false })
    if (request.method() === 'POST') {
      const body = request.postDataJSON()
      mutations.push({ path, body })
      expect(body.expectedProfile).toBe('test')
      expect(body.expectedRevision).toBe(revision)
      revision += 1
      if (path === '/api/v1/instances') {
        items.push(configuration('named-a', body.sourceId, body.name))
        return json({ profile: 'test', revision, identity: 'named-a' }, 201)
      }
      return json({ profile: 'test', revision })
    }
    if (path === '/api/v1/instances') return json({ profile: 'test', revision, items })
    if (path.endsWith('/executions')) return json({ revision, items: withRun ? [{ sessionId: 'run-1', workflowId: 'review', status: 'completed', updatedAt: '2026-09-10T00:00:00Z', currentStepId: null, activeStepIds: [] }] : [], diagnostics: [], truncated: false })
    if (path.endsWith('/executions/run-1')) return json({ revision, session: { sessionId: 'run-1', workflowId: 'review', status: 'completed', updatedAt: '2026-09-10T00:00:00Z', currentStepId: null }, steps: [], stepsTotalCount: 0, logs: [], gates: [], gatesTotalCount: 0, recovery: null, diagnostics: [] })
    return json({ error: { message: `Unexpected ${path}` } }, 418)
  })
  return mutations
}

test('workflow contains isolated default and named configurations, actions and history', async ({ page }) => {
  const mutations = await fixture(page)
  await page.goto('/')
  await expect(page).toHaveURL(/#\/workflows$/)
  await expect(page.getByRole('navigation', { name: 'Primary navigation' })).not.toContainText('Instances')
  await page.getByRole('button', { name: 'ワークフローを開く Repository A' }).click()
  await expect(page.getByRole('heading', { name: '実行設定', exact: true })).toBeVisible()
  await expect(page.getByRole('group', { name: 'Workflow graph Repository A' })).toBeVisible()
  await expect(page.getByRole('button', { name: /別リポジトリ専用/ })).toHaveCount(0)
  expect(mutations).toEqual([])
  await page.getByRole('button', { name: /標準設定/ }).click()
  await page.getByRole('button', { name: '実行', exact: true }).click()
  await expect.poll(() => mutations.length).toBe(1)
  expect(mutations[0]?.path).toBe(`/api/v1/instances/${encodeURIComponent(sourceId)}/actions`)
  expect(mutations[0]?.body.action).toBe('start')
  await page.getByRole('button', { name: '履歴', exact: true }).click()
  await expect(page.getByText('No persisted runs', { exact: true })).toBeVisible()
  await page.reload()
  await expect(page.getByText('No persisted runs', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: '実行設定を追加' }).click()
  await page.getByLabel('実行設定の名前').fill('夜間レビュー')
  await page.getByRole('button', { name: '追加', exact: true }).click()
  await expect(page.getByRole('heading', { name: '夜間レビュー', exact: true })).toBeVisible()
  expect(mutations).toHaveLength(2)
  expect(mutations[1]?.body.sourceId).toBe(sourceId)
  await expect(page.getByRole('button', { name: /標準設定/ })).toBeVisible()
  await expect(page.getByRole('button', { name: /別リポジトリ専用/ })).toHaveCount(0)
  await page.getByRole('button', { name: 'ワークフロー一覧へ' }).click()
  await page.getByRole('button', { name: 'ワークフローを開く Repository B' }).click()
  await expect(page.getByRole('button', { name: /別リポジトリ専用/ })).toBeVisible()
  await expect(page.getByRole('button', { name: /夜間レビュー/ })).toHaveCount(0)
})

test('compact workflow and configuration screens preserve navigation', async ({ page }) => {
  await fixture(page)
  await page.setViewportSize({ width: 640, height: 780 })
  await page.goto('/')
  await expect(page.getByRole('button', { name: 'ワークフローを開く Repository A' })).toBeVisible()
  await page.screenshot({ path: '../tmp/workflow-navigation/workflows.png' })
  await page.getByRole('button', { name: 'ワークフローを開く Repository A' }).click()
  await page.getByRole('button', { name: /標準設定/ }).click()
  await page.screenshot({ path: '../tmp/workflow-navigation/configuration.png', fullPage: true })
  await expect(page.getByRole('button', { name: '実行', exact: true })).toBeVisible()
  const width = await page.evaluate(() => ({ content: document.documentElement.scrollWidth, viewport: innerWidth }))
  expect(width.content).toBeLessThanOrEqual(width.viewport)
  await page.goBack()
  await expect(page.getByRole('heading', { name: '実行設定', exact: true })).toBeVisible()
  await page.goBack()
  await expect(page.getByRole('button', { name: 'ワークフローを開く Repository A' })).toBeVisible()
})


test('central graph stays visible beside configuration history and nodes can be arranged', async ({ page }) => {
  await fixture(page)
  await page.setViewportSize({ width: 1440, height: 1000 })
  await page.goto('/')
  await page.getByRole('button', { name: 'ワークフローを開く Repository A' }).click()
  const graph = page.getByRole('group', { name: 'Workflow graph Repository A' })
  const right = page.getByRole('complementary', { name: '実行設定', exact: true })
  await expect(graph).toBeVisible()
  const graphBox = await graph.boundingBox()
  const rightBox = await right.boundingBox()
  expect(graphBox!.x + graphBox!.width).toBeLessThanOrEqual(rightBox!.x)
  const node = page.getByRole('button', { name: 'Inspect node review', exact: true })
  const before = await node.boundingBox()
  await page.mouse.move(before!.x + before!.width / 2, before!.y + before!.height / 2)
  await page.mouse.down()
  await page.mouse.move(before!.x + before!.width / 2 + 60, before!.y + before!.height / 2 + 30, { steps: 5 })
  await page.mouse.up()
  const after = await node.boundingBox()
  expect(after!.x).toBeGreaterThan(before!.x + 40)
  await page.getByRole('button', { name: /標準設定/ }).click()
  await page.getByRole('button', { name: '履歴', exact: true }).click()
  await expect(graph).toBeVisible()
  await expect(right.getByText('No persisted runs')).toBeVisible()
  await page.screenshot({ path: '../tmp/workflow-navigation/graph-workspace.png' })
})


test('run reload and browser back-forward retain the parent configuration history', async ({ page }) => {
  await fixture(page, true)
  await page.goto('/')
  await page.getByRole('button', { name: 'ワークフローを開く Repository A' }).click()
  await page.getByRole('button', { name: /標準設定/ }).click()
  await page.getByRole('button', { name: '履歴', exact: true }).click()
  await page.getByRole('button', { name: 'Open run run-1' }).click()
  await expect(page).toHaveURL(new RegExp('/configurations/.*?/runs/run-1$'))
  await page.reload()
  await expect(page.getByRole('heading', { name: 'run-1', exact: true })).toBeVisible()
  await page.goBack()
  await expect(page.getByRole('button', { name: 'Open run run-1' })).toBeVisible()
  await page.goForward()
  await expect(page.getByRole('heading', { name: 'run-1', exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Back to Run logs' }).click()
  await expect(page.getByRole('button', { name: 'Open run run-1' })).toBeVisible()
  await expect(page.getByRole('group', { name: 'Workflow graph Repository A' })).toBeVisible()
})


test('invalid graph shows a recoverable error without breaking configuration selection', async ({ page }) => {
  await fixture(page)
  await page.route('**/api/v1/workflows/sources/*/definition', route => route.fulfill({ status: 422, contentType: 'application/json', body: JSON.stringify({ error: { code: 'invalid_workflow', message: 'The workflow definition is invalid' } }) }))
  await page.goto('/')
  await page.getByRole('button', { name: 'ワークフローを開く Repository A' }).click()
  await expect(page.getByRole('alert')).toHaveText('Error: The workflow definition is invalid')
  await expect(page.getByText('Loading workflow graph…')).toHaveCount(0)
  await page.getByRole('button', { name: /標準設定/ }).click()
  await expect(page.getByRole('button', { name: '実行', exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'ワークフロー一覧へ' }).click()
  await expect(page.getByRole('button', { name: 'ワークフローを開く Repository A' })).toBeVisible()
})

test('graph does not wait for slow metadata or load the closed management registry', async ({ page }) => {
  await fixture(page)
  let metadataReads = 0
  let registryReads = 0
  let releaseMetadata: () => void = () => {}
  const metadataGate = new Promise<void>(resolve => { releaseMetadata = resolve })
  await page.route('**/graphql', route => {
    registryReads += 1
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify({ data: { workflows: { workflows: [], errors: [] } } }) })
  })
  await page.route('**/api/v1/workflows/sources', async route => {
    metadataReads += 1
    if (metadataReads > 1) await metadataGate
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify({ profile: 'test', revision: 1, directories: [], projectDirectories: [], repositories: [], discovered: [{ id: sourceId, name: 'Repository A', workflowId: 'review', scope: 'project', sourceKind: 'directory' }] }) })
  })
  await page.goto('/')
  await page.getByRole('button', { name: 'ワークフローを開く Repository A' }).click()
  try {
    await expect(page.getByRole('group', { name: 'Workflow graph Repository A' })).toBeVisible({ timeout: 1500 })
    await expect(page.getByText('ソースが見つからないためグラフを表示できません。')).toHaveCount(0)
    expect(registryReads).toBe(0)
  } finally { releaseMetadata() }
})
