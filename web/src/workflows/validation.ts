export interface JSONValidation {
  value?: Record<string, unknown>
  error?: string
}

export function validateJSONObject(source: string): JSONValidation {
  if (!source.trim()) return { error: 'Enter a JSON object.' }
  try {
    const value = JSON.parse(source) as unknown
    if (value === null || Array.isArray(value) || typeof value !== 'object') {
      return { error: 'The value must be a JSON object.' }
    }
    return { value: value as Record<string, unknown> }
  } catch (error) {
    const detail = error instanceof Error ? error.message : 'Invalid JSON.'
    return { error: `Invalid JSON: ${detail}` }
  }
}
