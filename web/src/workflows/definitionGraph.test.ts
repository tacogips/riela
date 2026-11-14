import { expect, test } from 'bun:test'
import { definitionEdgePath, definitionGraph, type DefinitionGraphInput } from './definitionGraph'

test('shows branching, loops, external workflow boundaries and unused nodes', () => {
  const input: DefinitionGraphInput = {
    workflowId: 'flow',
    definition: {
      entryStepId: 'a',
      steps: [
        { id: 'a', nodeId: 'worker', role: 'worker', transitions: [
          { toStepId: 'b', label: 'success' }, { toStepId: 'c', label: 'failure' },
          { toStepId: 'a', toWorkflowId: 'other-flow', label: 'delegate' },
        ] },
        { id: 'b', nodeId: 'worker', role: 'worker', transitions: [{ toStepId: 'a', label: 'retry' }] },
        { id: 'c', nodeId: 'worker', role: 'worker', transitions: [{ toStepId: 'c', label: 'repeat' }] },
      ],
      nodes: [{ id: 'worker', kind: 'agent', role: 'worker' }, { id: 'unused', kind: 'agent', role: 'worker' }],
    },
  }
  const graph = definitionGraph(input)
  expect(graph.nodes).toHaveLength(5)
  expect(graph.edges).toHaveLength(5)
  const entry = graph.nodes.find(node => node.id === 'step:a')!
  const branch = graph.nodes.find(node => node.id === 'step:b')!
  expect(entry.entry).toBe(true)
  expect(branch.y).toBeGreaterThan(entry.y)
  const boundary = graph.nodes.find(node => node.kind === 'external')!
  expect(boundary.nodeId).toBe('other-flow')
  expect(graph.edges.find(edge => edge.label === 'delegate')?.to).toBe(boundary.id)
  expect(graph.nodes.find(node => node.kind === 'unused')?.title).toBe('unused')
  expect(definitionEdgePath(branch, entry)).not.toContain('NaN')
  expect(definitionEdgePath(entry, entry)).not.toContain('NaN')
  expect(definitionGraph(input)).toEqual(graph)
})

test('empty graphs retain finite bounds and missing targets remain visible', () => {
  const empty = definitionGraph({ workflowId: 'empty', definition: { entryStepId: '', steps: [], nodes: [] } })
  expect(Object.values(empty.bounds).every(Number.isFinite)).toBe(true)
  const graph = definitionGraph({ workflowId: 'bounded', definition: {
    entryStepId: 'a', nodes: [],
    steps: [{ id: 'a', nodeId: 'worker', role: null, transitions: [{ toStepId: 'omitted', label: null }] }],
  } })
  expect(graph.nodes.find(node => node.kind === 'external')?.title).toBe('omitted')
  expect(graph.edges).toHaveLength(1)
})
