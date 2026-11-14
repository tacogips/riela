import { expect, test } from 'bun:test'
import { searchWorkflows } from './search'

const items = [
  { name: 'Review', workflowId: 'repo-a', description: 'Reviews pull requests', scope: 'project' },
  { name: 'Notifications', workflowId: 'repo-b', description: 'Posts results to Slack', scope: 'user' },
]
test('search matches names, ids, descriptions and scope with regular expressions', () => {
  expect(searchWorkflows(items, 'pull.*requests').items).toEqual([items[0]!])
  expect(searchWorkflows(items, '^notifications').items).toEqual([items[1]!])
  expect(searchWorkflows(items, 'repo-[ab]').items).toEqual(items)
  expect(searchWorkflows(items, 'project$').items).toEqual([items[0]!])
})
test('invalid expressions report an error and clearing the query restores the list', () => {
  expect(searchWorkflows(items, '[').error).not.toBe('')
  expect(searchWorkflows(items, '[').items).toEqual([])
  expect(searchWorkflows(items, '').items).toEqual(items)
  expect(searchWorkflows([{ name: 'No description', workflowId: 'plain', scope: 'user' }], 'plain').items).toHaveLength(1)
})
