import { describe, expect, test } from 'bun:test'
import { validateJSONObject } from './validation'

describe('validateJSONObject', () => {
  test('accepts objects', () => {
    expect(validateJSONObject('{"enabled":true}')).toEqual({ value: { enabled: true } })
  })

  test('rejects malformed, empty, and non-object values', () => {
    expect(validateJSONObject('').error).toBe('Enter a JSON object.')
    expect(validateJSONObject('[1]').error).toBe('The value must be a JSON object.')
    expect(validateJSONObject('null').error).toBe('The value must be a JSON object.')
    expect(validateJSONObject('{').error).toStartWith('Invalid JSON:')
  })
})
