import { expect, test } from 'bun:test'
import { formatBotTime } from './boardView'
import { changeLabel, isDirty } from './memoryPanel'

test('treats whitespace changes as Markdown edits', () => {
  expect(isDirty('## Notes\n', '## Notes\n')).toBe(false)
  expect(isDirty('## Notes\n', '## Notes')).toBe(true)
})

test('labels the actor, reason, and date of an audited change', () => {
  const createdAt = '2026-11-25T00:00:00Z'
  expect(changeLabel({ changeId: '1', actor: 'feedback', reason: 'correction', createdAt }))
    .toBe(`feedback · correction · ${formatBotTime(createdAt)}`)
})
