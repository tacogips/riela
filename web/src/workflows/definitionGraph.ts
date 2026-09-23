import type { WorkflowDefinitionResponse } from '../contracts'
import { layoutFan } from '../ops/layout'

export interface DefinitionGraphNode {
  id: string
  title: string
  nodeId: string
  caption: string
  entry: boolean
  kind: 'step' | 'external' | 'unused'
  x: number
  y: number
}
export interface DefinitionGraphEdge { from: string; to: string; label: string }

type Definition = WorkflowDefinitionResponse['definition']
export interface DefinitionGraphInput {
  workflowId: string
  definition: {
    entryStepId: string
    steps: Array<Pick<Definition['steps'][number], 'id' | 'nodeId' | 'role'> & {
      transitions: Array<{ toStepId: string; toWorkflowId?: string | null; label: string | null }>
    }>
    nodes: Array<Pick<Definition['nodes'][number], 'id' | 'kind' | 'role'>>
  }
}

export function definitionGraph(workflow: DefinitionGraphInput) {
  const definition = workflow.definition
  const steps = definition.steps
  const knownSteps = new Set(steps.map(step => step.id))
  const external = (edge: typeof steps[number]['transitions'][number]) =>
    Boolean(edge.toWorkflowId && edge.toWorkflowId !== workflow.workflowId) || !knownSteps.has(edge.toStepId)
  const fan = layoutFan(steps.map(step => ({ ...step, transitions: step.transitions.filter(edge => !external(edge)) })), definition.entryStepId)
  const nodes: DefinitionGraphNode[] = fan.nodes.map(position => {
    const step = steps.find(step => step.id === position.id)!
    const node = definition.nodes.find(node => node.id === step.nodeId)
    return { id: `step:${step.id}`, title: step.id, nodeId: step.nodeId,
      caption: [node?.kind ?? 'agent', step.role].filter(Boolean).join(' · '),
      entry: step.id === definition.entryStepId, kind: 'step', x: position.x * 1.6, y: -position.y * 1.2 }
  })
  const edges: DefinitionGraphEdge[] = []
  const boundaryX = Math.max(0, ...nodes.map(node => node.x)) + 370
  for (const step of steps) for (const transition of step.transitions) {
    let to = `step:${transition.toStepId}`
    if (external(transition)) {
      to = `external:${JSON.stringify([transition.toWorkflowId ?? '', transition.toStepId])}`
      if (!nodes.some(node => node.id === to)) nodes.push({
        id: to, title: transition.toStepId, nodeId: transition.toWorkflowId ?? 'Outside displayed definition',
        caption: 'Workflow transition', entry: false, kind: 'external',
        x: boundaryX, y: 240 + nodes.filter(node => node.kind === 'external').length * 220,
      })
    }
    edges.push({ from: `step:${step.id}`, to, label: transition.label ?? '' })
  }
  const used = new Set(steps.map(step => step.nodeId))
  const unusedY = Math.max(240, ...nodes.map(node => node.y)) + 240
  definition.nodes.filter(node => !used.has(node.id)).forEach((node, index) => {
    nodes.push({ id: `unused:${node.id}`, title: node.id, nodeId: node.id,
      caption: 'Unused node', entry: false, kind: 'unused', x: index * 340, y: unusedY })
  })
  const points = nodes.length ? nodes : [{ x: 0, y: 0 }]
  return { nodes, edges, bounds: {
    minX: Math.min(...points.map(node => node.x)) - 210,
    maxX: Math.max(...points.map(node => node.x)) + 210,
    minY: Math.min(...points.map(node => node.y)) - 100,
    maxY: Math.max(...points.map(node => node.y)) + 100,
  } }
}

export function definitionEdgePath(from: DefinitionGraphNode, to: DefinitionGraphNode): string {
  if (to.y <= from.y) {
    const side = Math.max(from.x, to.x) + 185
    return `M ${from.x + 130} ${from.y + 18} C ${side} ${from.y + 95}, ${side} ${to.y - 95}, ${to.x + 130} ${to.y - 18}`
  }
  const middle = (from.y + to.y) / 2
  return `M ${from.x} ${from.y + 62} C ${from.x} ${middle}, ${to.x} ${middle}, ${to.x} ${to.y - 62}`
}
