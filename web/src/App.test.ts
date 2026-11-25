import { describe, expect, test } from 'bun:test'
import { profileViewTransition } from './profileViewState'

test('exposes Bots in primary navigation for both hosts', async () => {
  const app = await Bun.file(new URL('./App.tsx', import.meta.url)).text()
  expect(app).toMatch(/\{ id: 'bots', label: 'Bots', icon: '\w+' \}/)
  const hiddenViews = app.split('\n').find((line) => line.startsWith('const CLI_SERVE_HIDDEN_VIEWS'))
  expect(hiddenViews).toBeDefined()
  expect(hiddenViews).not.toContain("'bots'")
})

describe('profile-owned view state', () => {
  test('returns from a discovered definition to workflows on profile changes', () => {
    expect(profileViewTransition('riela-app:first', 'riela-app:second', 'riela-app', 'workflow-detail'))
      .toEqual({ clearSelection: true, view: 'workflows' })
  })

  test('clears run selection and returns to logs after a profile change', () => {
    expect(profileViewTransition(
      'riela-app:first',
      'riela-app:second',
      'riela-app',
      'run-detail',
    )).toEqual({ clearSelection: true, view: 'workflows' })
  })

  test('preserves selection and navigation for the same profile', () => {
    expect(profileViewTransition(
      'riela-app:first',
      'riela-app:first',
      'riela-app',
      'workflows',
    )).toEqual({ clearSelection: false, view: 'workflows' })
  })

  test('returns to the command deck after a profile change while inspecting an ops run', () => {
    expect(profileViewTransition(
      'riela-app:first',
      'riela-app:second',
      'riela-app',
      'ops-run',
    )).toEqual({ clearSelection: true, view: 'ops' })
  })

  test('keeps the command deck view for the same profile', () => {
    expect(profileViewTransition(
      'riela-app:first',
      'riela-app:first',
      'riela-app',
      'ops',
    )).toEqual({ clearSelection: false, view: 'ops' })
  })

  test('returns from a bot detail to Bots on profile change and preserves an initial deep link', () => {
    expect(profileViewTransition('riela-app:first', 'riela-app:second', 'riela-app', 'bot-detail'))
      .toEqual({ clearSelection: true, view: 'bots' })
    expect(profileViewTransition(undefined, 'riela-app:first', 'riela-app', 'bot-detail'))
      .toEqual({ clearSelection: false, view: 'bot-detail' })
  })

  test('clears profile state and lands on workflows for CLI serve', () => {
    expect(profileViewTransition(
      'riela-app:first',
      'cli-serve',
      'cli-serve',
      'workflows',
    )).toEqual({ clearSelection: true, view: 'workflows' })
  })
})

test('exposes Models in primary navigation for both hosts', async () => {
  const app = await Bun.file(new URL('./App.tsx', import.meta.url)).text()
  expect(app).toMatch(/\{ id: 'models', label: 'Models', icon: '\w+' \}/)
  const hiddenViews = app.split('\n').find((line) => line.startsWith('const CLI_SERVE_HIDDEN_VIEWS'))
  expect(hiddenViews).toBeDefined()
  expect(hiddenViews).not.toContain("'models'")
})
