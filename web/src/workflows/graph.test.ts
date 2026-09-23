import { describe, expect, test } from 'bun:test'
import { addStep, connectSteps, graphDocument, graphProblems, newGraph, removeStep } from './graph'
import { layoutKey, readLayout, writeLayout } from './layout'

describe('graph authoring', () => {
  test('preserves external transitions when deleting a local step with the same ID', () => {
    const doc = addStep(addStep(newGraph()))
    doc.steps[0]!.transitions = [{ toWorkflowId: 'other', toStepId: 'step-2', resumeStepId: 'step-1' }]
    const removed = removeStep(doc, 'step-2')
    expect(removed.steps[0]?.transitions).toEqual(doc.steps[0]!.transitions)
    expect(graphProblems(removed)).toEqual([])
    expect(connectSteps(doc, 'step-1', 'step-2').steps[0]?.transitions).toHaveLength(2)
  })
  test('adds and connects runnable step references while preserving unknown fields', () => {
    const doc = addStep(addStep({ ...newGraph(), futurePolicy: { retained: true } }))
    const connected = connectSteps(doc, 'step-1', 'step-2')
    expect(graphProblems(connected)).toEqual([])
    expect(connected.futurePolicy).toEqual({ retained: true })
    expect(connectSteps(connected, 'step-1', 'step-2')).toEqual(connected)
    expect(removeStep(connected, 'step-2').steps[0]?.transitions).toEqual([])
    expect(doc.steps[0]?.transitions).toEqual([])
  })
  test('retains shared nodes and blocks deleting a join or manager', () => {
    const doc = addStep(newGraph())
    doc.steps.push({ id: 'reuse', nodeId: 'step-1' })
    expect(removeStep(doc, 'step-1').nodes).toHaveLength(1)
    expect(() => removeStep({ ...doc, managerStepId: 'step-1' }, 'step-1')).toThrow('manager')
    doc.steps[0]!.transitions = [{ toStepId: 'reuse', fanout: { joinStepId: 'reuse' } }]
    expect(() => removeStep(doc, 'reuse')).toThrow('fanout')
  })
  test('blocks deleting resume and session-inheritance targets', () => {
    const doc = addStep(addStep(newGraph()))
    doc.steps[0]!.transitions = [{ toWorkflowId: 'other', toStepId: 'work', resumeStepId: 'step-2' }]
    expect(() => removeStep(doc, 'step-2')).toThrow('resume')
    doc.steps[0]!.transitions = []
    doc.steps[0]!.sessionPolicy = { mode: 'reuse', inheritFromStepId: 'step-2' }
    expect(() => removeStep(doc, 'step-2')).toThrow('session inheritance')
  })
  test('preserves step-file metadata on explicit step definitions', () => {
    const doc = addStep(addStep(newGraph()))
    doc.steps[0]!.stepFile = 'steps/work.json'
    const connected = connectSteps(graphDocument(doc), 'step-1', 'step-2')
    expect(connected.steps[0]?.stepFile).toBe('steps/work.json')
    expect(removeStep(connected, 'step-2').steps[0]?.stepFile).toBe('steps/work.json')
  })
  test('rejects malformed graph input without changing the original', () => {
    expect(graphProblems({ ...addStep(newGraph()), defaults: {} })).toContain('Set defaults.nodeTimeoutMs to a positive integer.')
    expect(() => graphDocument({ workflowId: 'a', nodes: [], steps: [null] })).toThrow()
    expect(() => graphDocument({ workflowId: 'a', nodes: [], steps: [{ id: 's', nodeId: 'n', transitions: [null] }] })).toThrow()
    const doc = addStep(newGraph())
    const parsed = graphDocument(doc)
    parsed.nodes[0]!.id = 'changed'
    expect(doc.nodes[0]!.id).toBe('step-1')
  })
})

describe('separate layout persistence', () => {
  test('isolates profiles/origins and never changes execution JSON', () => {
    const values = new Map<string, string>()
    const storage = { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => { values.set(key, value) } }
    const doc = addStep(newGraph())
    const before = JSON.stringify(doc)
    const key = layoutKey('profile-a', 'origin-a')
    expect(writeLayout(storage, key, { version: 1, positions: { 'step-1': { x: 55, y: 66 } } })).toBe(true)
    expect(readLayout(storage, key).positions['step-1']).toEqual({ x: 55, y: 66 })
    expect(readLayout(storage, layoutKey('profile-b', 'origin-a')).positions).toEqual({})
    expect(readLayout(storage, layoutKey('profile-a', 'origin-b')).positions).toEqual({})
    expect(JSON.stringify(doc)).toBe(before)
  })
  test('survives corrupt storage and denied writes', () => {
    expect(readLayout({ getItem: () => '{' }, 'key').positions).toEqual({})
    expect(writeLayout({ setItem: () => { throw new Error('quota') } }, 'key', { version: 1, positions: {} })).toBe(false)
  })
})
