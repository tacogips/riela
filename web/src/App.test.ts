import { describe, expect, test } from 'bun:test'
import { profileViewTransition } from './App'

describe('profile-owned view state', () => {
  test('clears run selection and returns to logs after a profile change', () => {
    expect(profileViewTransition(
      'riela-app:first',
      'riela-app:second',
      'riela-app',
      'run-detail',
    )).toEqual({ clearSelection: true, view: 'logs' })
  })

  test('preserves selection and navigation for the same profile', () => {
    expect(profileViewTransition(
      'riela-app:first',
      'riela-app:first',
      'riela-app',
      'workflows',
    )).toEqual({ clearSelection: false, view: 'workflows' })
  })

  test('forces Notes-only mode and clears profile state for CLI serve', () => {
    expect(profileViewTransition(
      'riela-app:first',
      'cli-serve',
      'cli-serve',
      'workflows',
    )).toEqual({ clearSelection: true, view: 'notes' })
  })
})
