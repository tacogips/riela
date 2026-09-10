/** Lossless editing: retain fields the visual editor does not understand. */
export type Document = Record<string, unknown>
export interface Transition extends Document { toStepId: string }
export interface Step extends Document { id: string; nodeId: string; transitions?: Transition[] }
export interface Node extends Document { id: string }
export interface GraphDocument extends Document {
  workflowId: string
  entryStepId: string
  nodes: Node[]
  steps: Step[]
}

export function graphDocument(value: unknown): GraphDocument {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Expected a workflow object.')
  const doc = value as Document
  if (typeof doc.workflowId !== 'string' || !Array.isArray(doc.nodes) || !Array.isArray(doc.steps)) {
    throw new Error('Workflow needs workflowId, nodes and steps.')
  }
  for (const [name, entries] of [['nodes', doc.nodes], ['steps', doc.steps]] as const) {
    const ids = new Set<string>()
    for (const entry of entries) {
      if (!entry || typeof entry !== 'object' || typeof entry.id !== 'string' || !entry.id || ids.has(entry.id)) {
        throw new Error(`${name} must have unique, nonempty IDs.`)
      }
      ids.add(entry.id)
      if (name === 'steps' && (typeof entry.nodeId !== 'string'
        || (entry.transitions !== undefined && (!Array.isArray(entry.transitions)
          || entry.transitions.some((edge: unknown) => !edge || typeof edge !== 'object'
            || typeof (edge as Document).toStepId !== 'string'))))) {
        throw new Error('Steps need nodeId and valid transitions.')
      }
    }
  }
  return structuredClone({ ...doc, entryStepId: typeof doc.entryStepId === 'string' ? doc.entryStepId : '' }) as GraphDocument
}

export function newGraph(): GraphDocument {
  return { workflowId: 'new-workflow', description: '', defaults: { nodeTimeoutMs: 120000, maxLoopIterations: 3 }, entryStepId: '', nodes: [], steps: [] }
}

export function addStep(doc: GraphDocument): GraphDocument {
  let number = 1
  while (doc.steps.some((step) => step.id === `step-${number}`) || doc.nodes.some((node) => node.id === `step-${number}`)) number++
  const id = `step-${number}`
  return {
    ...doc, entryStepId: doc.entryStepId || id,
    nodes: [...doc.nodes, { id, addon: { name: 'riela/codex-sdk-worker', version: '1', config: { promptTemplate: 'Describe the task for this step.' } } }],
    steps: [...doc.steps, { id, nodeId: id, role: 'worker', transitions: [] }],
  }
}

export function connectSteps(doc: GraphDocument, from: string, to: string): GraphDocument {
  if (!doc.steps.some((step) => step.id === from) || !doc.steps.some((step) => step.id === to)) throw new Error('Connection endpoint is missing.')
  return { ...doc, steps: doc.steps.map((step) => step.id !== from || step.transitions?.some((edge) => isLocalTransition(doc, edge) && edge.toStepId === to)
    ? step : { ...step, transitions: [...(step.transitions ?? []), { toStepId: to, label: 'always' }] }) }
}

export function removeStep(doc: GraphDocument, id: string): GraphDocument {
  // Semantic references must be explicitly repaired before deleting a step.
  if (doc.managerStepId === id || doc.steps.some((step) =>
    (step.sessionPolicy as Document | undefined)?.inheritFromStepId === id || step.transitions?.some((edge) =>
      edge.resumeStepId === id || (edge.fanout as Document | undefined)?.joinStepId === id))) {
    throw new Error('Remove manager, fanout join, resume, or session inheritance references before deleting this step.')
  }
  const removed = doc.steps.find((step) => step.id === id)
  const steps = doc.steps.filter((step) => step.id !== id).map((step) => ({
    ...step, transitions: step.transitions?.filter((edge) => !isLocalTransition(doc, edge) || edge.toStepId !== id),
  }))
  return { ...doc, steps, entryStepId: doc.entryStepId === id ? steps[0]?.id ?? '' : doc.entryStepId,
    nodes: doc.nodes.filter((node) => node.id !== removed?.nodeId || steps.some((step) => step.nodeId === node.id)) }
}

export function graphProblems(doc: GraphDocument): string[] {
  const problems: string[] = []
  const defaults = doc.defaults as Record<string, unknown> | undefined
  if (!Number.isInteger(defaults?.nodeTimeoutMs) || Number(defaults?.nodeTimeoutMs) <= 0) problems.push('Set defaults.nodeTimeoutMs to a positive integer.')
  if (!Number.isInteger(defaults?.maxLoopIterations) || Number(defaults?.maxLoopIterations) <= 0) problems.push('Set defaults.maxLoopIterations to a positive integer.')
  if (!doc.workflowId.trim()) problems.push('Enter a workflow ID.')
  if (!doc.steps.some((step) => step.id === doc.entryStepId)) problems.push('Choose an entry step.')
  for (const step of doc.steps) {
    if (!doc.nodes.some((node) => node.id === step.nodeId)) problems.push(`${step.id}: missing node ${step.nodeId}.`)
    for (const edge of step.transitions ?? []) {
      if (isLocalTransition(doc, edge) && !doc.steps.some((target) => target.id === edge.toStepId)) problems.push(`${step.id}: missing target ${edge.toStepId}.`)
    }
  }
  return problems
}

export function isLocalTransition(doc: GraphDocument, edge: Transition): boolean {
  return !edge.toWorkflowId || edge.toWorkflowId === doc.workflowId
}
