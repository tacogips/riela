import { expect, test } from 'bun:test'
import { boardOrder, countsLabel, formatElapsed, groupTitles, sectionOrder, statusLabel } from './boardView'

test('formats only nonzero overview counts', () => {
  expect(countsLabel({ needsYou: 1, working: 2, waiting: 0, planned: 0 })).toBe('1 needs you · 2 working')
  expect(countsLabel({ needsYou: 0, working: 0, waiting: 0, planned: 0 })).toBe('')
})

test('formats elapsed milliseconds compactly', () => {
  expect(formatElapsed(372_000)).toBe('6m 12s')
  expect(formatElapsed(0)).toBe('0s')
})

test('formats runtime statuses as readable labels', () => {
  expect(statusLabel('needsDecision')).toBe('needs decision')
  expect(statusLabel('in_progress')).toBe('in progress')
})

test('uses the projected section and board display order', () => {
  expect(sectionOrder).toEqual(['active', 'working', 'snoozed', 'settled'])
  expect(boardOrder.map((group) => groupTitles[group])).toEqual(['Needs you', 'In progress', 'Waiting', 'Planned', 'Closed'])
})
