import { expect, test } from 'bun:test'
import { addStep, connectSteps, graphDocument, graphProblems, newGraph } from './graph'
import { placementProblems, updatePlacement } from './placement'

test('worker placement survives graph parsing, unrelated edits and explicit local reset', () => {
  const doc = addStep(addStep(newGraph()))
  doc.steps[0] = updatePlacement(doc.steps[0]!, { workspace: 'project', target: { workerId: 'linux-1', group: 'build' }, exports: ['report.json'] })
  const edited = connectSteps(graphDocument(doc), 'step-1', 'step-2')
  expect(edited.steps[0]?.placement).toEqual(doc.steps[0]?.placement)
  expect(graphProblems(edited)).toEqual([])
  const changed = updatePlacement(edited.steps[0]!, { workspace: 'other' })
  expect(changed.placement).toEqual({ workspace: 'other', target: { workerId: 'linux-1', group: 'build' }, exports: ['report.json'] })
  expect(updatePlacement(changed, null)).not.toHaveProperty('placement')
  expect(doc.steps[0]?.placement).toHaveProperty('workspace', 'project')
})

test('invalid placement prevents a graph save', () => {
  for (const placement of [null, {}, { workspace: '', target: {} }, { workspace: 'project', target: { workerId: '' } },
    { workspace: 'project', target: {}, exports: ['../secret'] }, { workspace: 'project', target: {}, exports: ['a', 'a'] }]) {
    expect(placementProblems(placement).length).toBeGreaterThan(0)
  }
  expect(placementProblems(undefined)).toEqual([])
  expect(placementProblems({ workspace: 'project', target: {} })).toEqual([])
})
