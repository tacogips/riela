export interface SearchableWorkflow {
  name: string
  workflowId: string
  description?: string | null
  scope: string
}

export function searchWorkflows<T extends SearchableWorkflow>(items: T[], expression: string): { items: T[]; error: string } {
  if (!expression) return { items, error: '' }
  try {
    const pattern = new RegExp(expression, 'i')
    return { items: items.filter(item => pattern.test([item.name, item.workflowId, item.description ?? '', item.scope].join('\n'))), error: '' }
  } catch (error) {
    return { items: [], error: error instanceof Error ? error.message : String(error) }
  }
}
