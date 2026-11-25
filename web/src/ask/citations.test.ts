import { expect, test } from 'bun:test'
import { parseInlineSegments } from '../components/markdownInline'
import { citationHref, citationLinks, renderCitations } from './citations'

test('links session, session-qualified step, bot and known workflows', () => {
  expect(citationHref({ kind: 'session', id: 's/1' }, 'paired')).toBe('#/runs/s%2F1?remote=paired')
  expect(citationHref({ kind: 'step', id: 'build', sessionId: 's1' })).toBe('#/runs/s1')
  expect(citationHref({ kind: 'bot', id: 'b1' }, 'local')).toBe('#/bots/b1?remote=local')
  expect(citationHref({ kind: 'routine', id: 'r1' })).toBeUndefined()
  expect(citationHref({ kind: 'workflow', id: 'w1' }, 'local', () => 'source/w1')).toBe('#/workflows/source%2Fw1')
  expect(citationHref({ kind: 'workflow', id: 'w1' }, 'paired', () => 'source/w1')).toBeUndefined()
})

test('only server-cited markers become navigable', () => {
  const links = citationLinks([{ kind: 'step', id: 'x1', sessionId: 's1' }, { kind: 'session', id: 's2' }], 'paired')
  const text = 'See [[step:s1/x1]], [[session:s2]] or [[session:unlisted]].'
  expect(renderCitations(text, links)).toBe('See [step:s1/x1](#/runs/s1?remote=paired), [session:s2](#/runs/s2?remote=paired) or [[session:unlisted]].')
  const segments = parseInlineSegments('[[session:s2]] [fabricated](#/runs/s2?remote=paired) [outside](https://example.test)', links)
  expect(segments.filter(({ kind }) => kind === 'citation')).toEqual([
    { kind: 'citation', text: 'session:s2', href: '#/runs/s2?remote=paired' },
  ])
  expect(segments.some(({ kind }) => kind === 'link')).toBe(false)
})
