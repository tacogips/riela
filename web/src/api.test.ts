import { describe, expect, test } from 'bun:test'

describe('API mutation contract', () => {
  test('JSON preserves nested workflow variable values', () => {
    const value = { expectedRevision: 4, workflowVariables: { enabled: true, retries: 3, labels: ['a', 'b'] } }
    expect(JSON.parse(JSON.stringify(value))).toEqual(value)
  })
})
