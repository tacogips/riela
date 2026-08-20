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

  test('clears profile state and lands on instances for CLI serve', () => {
    expect(profileViewTransition(
      'riela-app:first',
      'cli-serve',
      'cli-serve',
      'workflows',
    )).toEqual({ clearSelection: true, view: 'instances' })
  })
})
