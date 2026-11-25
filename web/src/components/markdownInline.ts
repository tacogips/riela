type InlineSegment =
  | { kind: 'text'; text: string }
  | { kind: 'bold'; text: string }
  | { kind: 'italic'; text: string }
  | { kind: 'code'; text: string }
  | { kind: 'link' | 'citation'; text: string; href: string }

export function parseInlineSegments(text: string, citations?: ReadonlyMap<string, string>): InlineSegment[] {
  const segments: InlineSegment[] = []
  const pattern = /(\[\[([^\]\r\n]+)\]\])|(`[^`]+`)|(\*\*[^*]+\*\*)|(__[^_]+__)|(\*[^*\s][^*]*\*)|(_[^_\s][^_]*_)|(\[([^\]]+)\]\(([^)\s]+)\))/g
  let cursor = 0
  for (let match = pattern.exec(text); match; match = pattern.exec(text)) {
    if (match.index > cursor) segments.push({ kind: 'text', text: text.slice(cursor, match.index) })
    const token = match[0] ?? ''
    if (match[1] !== undefined) {
      const key = match[2]!
      const href = citations?.get(key)
      segments.push(href ? { kind: 'citation', text: key, href } : { kind: 'text', text: token })
    } else if (token.startsWith('`')) {
      segments.push({ kind: 'code', text: token.slice(1, -1) })
    } else if (token.startsWith('**') || token.startsWith('__')) {
      segments.push({ kind: 'bold', text: token.slice(2, -2) })
    } else if (token.startsWith('[') && match[9] !== undefined && match[10] !== undefined) {
      segments.push(citations ? { kind: 'text', text: token } : { kind: 'link', text: match[9], href: match[10] })
    } else {
      segments.push({ kind: 'italic', text: token.slice(1, -1) })
    }
    cursor = match.index + token.length
  }
  if (cursor < text.length) segments.push({ kind: 'text', text: text.slice(cursor) })
  return segments
}
