import { expect, test, type Page } from '@playwright/test'

async function installStudio(page: Page, existing?: Record<string, unknown>) {
  let definition: Record<string, unknown> | undefined = existing
  let revision = 0
  let generationPolls = 0
  const savedDefinitions: unknown[] = []
  const generationRequests: Array<{ history?: Array<{ role: string; text: string }> }> = []
  const workflow = () => ({ originId: 'user:studio', workflowId: 'studio', name: 'Studio workflow',
    scope: 'USER', provenance: 'MUTABLE', mutable: true, activationState: 'ACTIVE', valid: true,
    definitionRevision: `rev-${revision}`, definition, diagnostics: [] })
  await page.route('**/graphql', async (route) => {
    const body = route.request().postDataJSON()
    const result = (data: unknown) => route.fulfill({ json: { data } })
    switch (body.operationName) {
      case 'WebMutableWorkflows': return result({ workflows: { workflows: definition ? [workflow()] : [], errors: [] } })
      case 'WebMutableWorkflow': return result({ workflow: { workflow: workflow(), errors: [] } })
      case 'WebRegisterMutableWorkflow':
      case 'WebUpdateMutableWorkflow': {
        if (body.operationName === 'WebUpdateMutableWorkflow') expect(body.variables.input.expectedDefinitionRevision).toBe(`rev-${revision}`)
        definition = body.variables.input.definition
        savedDefinitions.push(definition)
        revision++
        // Real mutation responses are metadata-only. A fresh editor read is
        // required before another save or launch can use the new revision.
        return result({ [body.operationName === 'WebRegisterMutableWorkflow' ? 'registerMutableWorkflow' : 'updateMutableWorkflow']: {
          accepted: true, workflow: { ...workflow(), definition: null, definitionRevision: null }, errors: [],
        } })
      }
      default: return route.fulfill({ status: 418, body: body.operationName })
    }
  })
  await page.route('**/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname
    if (path === '/api/v1/bootstrap') return route.fulfill({ json: { apiVersion: 'v1', profile: 'studio', csrfToken: 'csrf', revision: 1,
      capabilities: [], server: { revision: 1, isEnabled: true, configuredPort: 19091, state: 'running' } } })
    if (path === '/api/v1/instances') return route.fulfill({ json: { profile: 'studio', revision: 1, items: [] } })
    if (path === '/api/v1/ops/overview') return route.fulfill({ json: { profile: 'studio', revision: 1, workflows: [], instances: [], runs: [], diagnostics: [] } })
    if (path === '/api/v1/workflow-editor/definition') return route.fulfill({ json: workflow() })
    if (path === '/api/v1/workflow-editor/generations') {
      generationRequests.push(route.request().postDataJSON())
      expect(route.request().headers()['x-riela-profile']).toBe('studio')
      definition = route.request().postDataJSON().definition
      return route.fulfill({ json: { id: 'generation-1', profile: 'studio', revision: 0, status: 'running', definition, messages: [] } })
    }
    if (path.endsWith('/generations/generation-1')) {
      generationPolls++
      const generated = { ...definition, entryStepId: 'research', nodes: [{ id: 'research', addon: { name: 'riela/codex-sdk-worker', version: '1', config: { promptTemplate: 'Research' } } }], steps: [{ id: 'research', nodeId: 'research', role: 'worker', transitions: [] }] }
      return route.fulfill({ json: { id: 'generation-1', profile: 'studio', revision: 1,
        status: route.request().method() === 'DELETE' ? 'cancelled' : 'running', definition: generated, messages: ['Added research.'] } })
    }
    return route.fulfill({ status: 404, json: { error: { message: path } } })
  })
  await page.goto('/')
  await page.getByRole('button', { name: 'Command deck', exact: true }).click()
  await page.getByRole('button', { name: 'Create / edit workflow', exact: true }).click()
  if (existing) await page.getByRole('button', { name: /Studio workflow/ }).click()
  else await page.getByRole('button', { name: 'New workflow', exact: true }).click()
  return { savedDefinitions, generationPolls: () => generationPolls, generationRequests, workflow }
}

test('creates and connects steps, saves, and reopens separate layout', async ({ page }) => {
  const state = await installStudio(page)
  await page.getByLabel('Workflow ID', { exact: true }).fill('studio')
  await page.getByRole('button', { name: 'Add agent step', exact: true }).click()
  await page.getByRole('button', { name: 'Add agent step', exact: true }).click()
  await page.getByRole('button', { name: 'Connect from step-1', exact: true }).click()
  await page.getByRole('button', { name: 'Connect to step-2', exact: true }).click()
  await page.getByRole('button', { name: 'Save workflow', exact: true }).click()
  await expect(page.getByText('Workflow saved.', { exact: true })).toBeVisible()
  expect(state.savedDefinitions).toHaveLength(1)
  expect(JSON.stringify(state.savedDefinitions[0])).not.toMatch(/positions|offsetX|offsetY/)
  expect(state.savedDefinitions[0]).toMatchObject({ steps: [{ transitions: [{ toStepId: 'step-2' }] }, { id: 'step-2' }] })
  const node = page.locator('[data-canvas-interactive]').first()
  const rect = await node.boundingBox()
  if (!rect) throw new Error('Node is missing')
  await page.mouse.move(rect.x + 60, rect.y + 25)
  await page.mouse.down()
  await page.mouse.move(rect.x + 110, rect.y + 75, { steps: 5 })
  await page.mouse.up()
  expect(state.savedDefinitions).toHaveLength(1)
  const transform = await node.getAttribute('transform')
  expect(transform).not.toBe('translate(0,0)')
  await page.getByRole('button', { name: 'Save workflow', exact: true }).click()
  await expect.poll(() => state.savedDefinitions.length).toBe(2)
  page.on('dialog', (dialog) => void dialog.accept())
  await page.getByRole('button', { name: 'Back to graph', exact: true }).click()
  await page.getByRole('button', { name: /Studio workflow/ }).click()
  await expect(page.locator('[data-canvas-interactive]').first()).toHaveAttribute('transform', transform!)
})

test('shows agent changes while still running and restores draft with undo after stop', async ({ page }) => {
  const state = await installStudio(page)
  await page.getByLabel('Ask the agent', { exact: true }).fill('Add a research step')
  await page.getByRole('button', { name: 'Send to agent', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Edit research', exact: true })).toBeVisible()
  await expect(page.getByText('Agent working · live preview', { exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Save workflow', exact: true })).toBeDisabled()
  expect(state.generationPolls()).toBeGreaterThan(0)
  expect(state.savedDefinitions).toHaveLength(0)
  await page.getByRole('button', { name: 'Stop generation', exact: true }).click()
  await page.getByRole('button', { name: 'Undo', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Edit research', exact: true })).toHaveCount(0)
  await page.getByLabel('Ask the agent', { exact: true }).fill('Use the same research instructions again')
  await page.getByRole('button', { name: 'Send to agent', exact: true }).click()
  await expect.poll(() => state.generationRequests.length).toBe(2)
  expect(state.generationRequests[1]?.history).toEqual([
    { role: 'user', text: 'Add a research step' }, { role: 'assistant', text: 'Added research.' },
  ])
  await page.getByRole('button', { name: 'Stop generation', exact: true }).click()
})

test('inspects actual input and output per run attempt without leaving the graph', async ({ page }) => {
  await installStudio(page)
  await page.route('**/api/v1/workflow-editor/runs/**', (route) => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/steps/exec-failed')) return route.fulfill({ json: {
      input: { request: 'first attempt' }, output: null, inputRecorded: true, outputRecorded: false, failureReason: 'Provider failed',
    } })
    if (path.endsWith('/steps/exec-success')) return route.fulfill({ json: {
      input: { request: 'second attempt' }, output: { result: 42 }, inputRecorded: true, outputRecorded: true, responseText: 'Completed successfully',
    } })
    return route.fulfill({ json: { sessionId: 'run-evidence', workflowId: 'new-workflow', status: 'completed', currentStepId: null, stepsTotalCount: 2,
      steps: [{ executionId: 'exec-failed', stepId: 'work', nodeId: 'node', attempt: 1, status: 'failed' },
        { executionId: 'exec-success', stepId: 'work', nodeId: 'node', attempt: 2, status: 'completed' }] } })
  })
  await page.getByLabel('Run session ID', { exact: true }).fill('run-evidence')
  await page.getByRole('button', { name: 'Open run', exact: true }).click()
  await expect(page.getByText('"result": 42', { exact: false })).toBeVisible()
  await expect(page.getByRole('img', { name: 'Editable workflow new-workflow', exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'work · attempt 1 · failed', exact: true }).click()
  await expect(page.getByText('"request": "first attempt"', { exact: false })).toBeVisible()
  await expect(page.getByText('No accepted output recorded yet.', { exact: true })).toBeVisible()
  await expect(page.getByText('Provider failed', { exact: true })).toBeVisible()
  await expect(page.getByText('"result": 42', { exact: false })).toHaveCount(0)
})

test('runs the saved revision and automatically opens its persisted values', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 1440, height: 1000 })
  await installStudio(page)
  let submitted: Record<string, unknown> | undefined
  await page.route('**/api/v1/workflow-editor/launches**', (route) => {
    if (route.request().method() === 'POST') submitted = route.request().postDataJSON()
    return route.fulfill({ json: { id: 'launch-1', status: 'completed', sessionId: 'started-session', error: null } })
  })
  await page.route('**/api/v1/workflow-editor/runs/**', (route) => {
    if (route.request().url().includes('/steps/')) return route.fulfill({ json: {
      input: { request: 'run from graph' }, output: { done: true }, inputRecorded: true, outputRecorded: true,
    } })
    return route.fulfill({ json: { sessionId: 'started-session', workflowId: 'studio', status: 'completed', currentStepId: null,
      stepsTotalCount: 1, steps: [{ executionId: 'exec-1', stepId: 'step-1', nodeId: 'step-1', attempt: 1, status: 'completed' }] } })
  })
  await page.getByRole('button', { name: 'Add agent step', exact: true }).click()
  await page.getByLabel('Workflow ID', { exact: true }).fill('studio')
  await page.getByLabel('Execution working directory', { exact: true }).fill('/work/project')
  await page.getByLabel('Execution input JSON', { exact: true }).fill('{"request":"run from graph"}')
  await expect(page.getByRole('button', { name: 'Run workflow', exact: true })).toBeDisabled()
  await page.getByRole('button', { name: 'Save workflow', exact: true }).click()
  await expect(page.getByLabel('Entry step', { exact: true })).toHaveValue('step-1')
  await expect(page.getByRole('button', { name: 'Run workflow', exact: true })).toBeEnabled()
  await page.getByRole('button', { name: 'Run workflow', exact: true }).click()
  await expect(page.getByLabel('Run session ID', { exact: true })).toHaveValue('started-session')
  await expect(page.getByText('"done": true', { exact: false })).toBeVisible()
  await expect(page.locator('[data-canvas-interactive]').first()).toContainText('completed')
  await page.locator('.workflow-editor').screenshot({ path: testInfo.outputPath('studio-desktop.png') })
  await page.setViewportSize({ width: 390, height: 844 })
  await page.getByRole('button', { name: 'Fit view', exact: true }).click()
  await expect(page.getByText('"done": true', { exact: false })).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  await page.locator('.workflow-editor').screenshot({ path: testInfo.outputPath('studio-narrow.png') })
  expect(submitted).toMatchObject({ originId: 'user:studio', definitionRevision: 'rev-1', workingDirectory: '/work/project', variables: { request: 'run from graph' } })
  await page.getByRole('button', { name: 'Add agent step', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Run workflow', exact: true })).toBeDisabled()
})

test('opens another workflow run without mislabeling the current graph', async ({ page }) => {
  await installStudio(page)
  await page.getByRole('button', { name: 'Add agent step', exact: true }).click()
  await page.route('**/api/v1/workflow-editor/runs/**', (route) => {
    if (route.request().url().includes('/steps/')) return route.fulfill({ json: {
      input: { other: true }, output: { result: 'other workflow result' }, inputRecorded: true, outputRecorded: true,
    } })
    return route.fulfill({ json: { sessionId: 'other-session', workflowId: 'other-workflow', status: 'failed', currentStepId: null,
      stepsTotalCount: 1, steps: [{ executionId: 'other-exec', stepId: 'step-1', nodeId: 'step-1', attempt: 1, status: 'failed' }] } })
  })
  await page.getByLabel('Run session ID', { exact: true }).fill('other-session')
  await page.getByRole('button', { name: 'Open run', exact: true }).click()
  await expect(page.getByText('This run belongs to another workflow.', { exact: false })).toBeVisible()
  await expect(page.getByText('other workflow result', { exact: false })).toBeVisible()
  await expect(page.locator('[data-canvas-interactive]').first()).not.toContainText('failed')
})

test('keeps a conflicting node edit until explicit reload of the saved revision', async ({ page }) => {
  await installStudio(page)
  await page.getByRole('button', { name: 'Add agent step', exact: true }).click()
  await page.getByRole('button', { name: 'Save workflow', exact: true }).click()
  await expect(page.getByText('Workflow saved.', { exact: true })).toBeVisible()
  await page.getByLabel('Prompt', { exact: true }).fill('My unsaved prompt')
  await page.route('**/graphql', (route) => {
    if (route.request().postDataJSON().operationName !== 'WebUpdateMutableWorkflow') return route.fallback()
    return route.fulfill({ json: { data: { updateMutableWorkflow: { accepted: false, workflow: null,
      errors: [{ code: 'REGISTRY_CONFLICT', message: 'The workflow changed elsewhere.' }] } } } })
  })
  await page.getByRole('button', { name: 'Save workflow', exact: true }).click()
  await expect(page.getByText('The workflow changed elsewhere.', { exact: true })).toBeVisible()
  await expect(page.getByLabel('Prompt', { exact: true })).toHaveValue('My unsaved prompt')
  page.once('dialog', (dialog) => void dialog.dismiss())
  await page.getByRole('button', { name: 'Reload saved workflow', exact: true }).click()
  await expect(page.getByLabel('Prompt', { exact: true })).toHaveValue('My unsaved prompt')
  page.once('dialog', (dialog) => void dialog.accept())
  await page.getByRole('button', { name: 'Reload saved workflow', exact: true }).click()
  await page.getByRole('button', { name: 'Edit step-1', exact: true }).click()
  await expect(page.getByLabel('Prompt', { exact: true })).toHaveValue('Describe the task for this step.')
})

test('recovers a post-save reload failure without registering a second workflow', async ({ page }) => {
  const state = await installStudio(page)
  await page.getByRole('button', { name: 'Add agent step', exact: true }).click()
  let failRead = true
  await page.route('**/api/v1/workflow-editor/definition', (route) => failRead
    ? route.fulfill({ status: 503, json: { error: { message: 'Temporary read failure' } } }) : route.fallback())
  await page.getByRole('button', { name: 'Save workflow', exact: true }).click()
  await expect(page.getByText('Temporary read failure', { exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Save workflow', exact: true })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Run workflow', exact: true })).toBeDisabled()
  expect(state.savedDefinitions).toHaveLength(1)
  failRead = false
  page.once('dialog', (dialog) => void dialog.accept())
  await page.getByRole('button', { name: 'Reload saved workflow', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Save workflow', exact: true })).toBeEnabled()
  await page.getByRole('button', { name: 'Save workflow', exact: true }).click()
  await expect(page.getByText('Workflow saved.', { exact: true })).toBeVisible()
  expect(state.savedDefinitions).toHaveLength(2)
})

test('edits a saved file-backed prompt in the graph and adopts its new revision', async ({ page }, testInfo) => {
  const definition = { workflowId: 'studio', defaults: { nodeTimeoutMs: 120000, maxLoopIterations: 3 }, entryStepId: 'step-1',
    nodes: [{ id: 'step-1', nodeFile: 'nodes/work.json' }], steps: [{ id: 'step-1', nodeId: 'step-1', role: 'worker' }] }
  const state = await installStudio(page, definition)
  let edited = false
  await page.route('**/api/v1/workflow-editor/node-settings', (route) => {
    const body = route.request().postDataJSON()
    expect(body.definitionRevision).toBe(edited ? 'node-revision-1' : 'rev-0')
    if (body.action === 'load') return route.fulfill({ json: { assetRevision: 'asset-1',
      prompt: edited ? 'Updated file prompt' : 'Original file prompt', model: 'test-model', promptHidden: false, modelHidden: false } })
    expect(body).toMatchObject({ action: 'save', nodeId: 'step-1', assetRevision: 'asset-1', prompt: 'Updated file prompt' })
    expect(body.model).toBeUndefined()
    edited = true
    return route.fulfill({ json: { ...state.workflow(), definitionRevision: 'node-revision-1',
      definition: { ...definition, nodes: [{ id: 'step-1', nodeFile: 'editor-node-content-address.json' }] } } })
  })
  await page.getByRole('button', { name: 'Edit step-1', exact: true }).click()
  await page.getByRole('button', { name: 'Edit file-backed node settings', exact: true }).click()
  const dialog = page.getByRole('dialog', { name: 'File-backed node settings', exact: true })
  await expect(page.getByLabel('Node file prompt', { exact: true })).toHaveValue('Original file prompt')
  await page.getByLabel('Node file prompt', { exact: true }).fill('Updated file prompt')
  await dialog.screenshot({ path: testInfo.outputPath('file-node-settings.png') })
  await page.getByRole('button', { name: 'Save node settings', exact: true }).click()
  await expect(dialog).not.toBeVisible()
  await expect(page.getByText('Node settings saved.', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Edit file-backed node settings', exact: true }).click()
  await expect(page.getByLabel('Node file prompt', { exact: true })).toHaveValue('Updated file prompt')
  await page.getByRole('button', { name: 'Cancel node settings', exact: true }).click()
  await expect(page.getByLabel('Node definition', { exact: true })).toHaveValue(/editor-node-content-address.json/)
})
