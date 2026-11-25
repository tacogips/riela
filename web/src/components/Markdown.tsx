import { For, Show } from 'solid-js'
import type { JSX } from 'solid-js'
import { parseInlineSegments } from './markdownInline'
export { parseInlineSegments } from './markdownInline'

// Block-level markdown model mirroring the native RielaNoteMarkdownBodyView:
// headings, fenced code, lists, quotes, rules, and paragraphs, with a small
// inline grammar (bold, italic, inline code, links). Rendering builds DOM
// nodes directly — raw HTML in note bodies is never interpreted.

export type MarkdownBlock =
  | { kind: 'heading'; level: number; text: string }
  | { kind: 'code'; text: string; language: string | null }
  | { kind: 'list'; items: string[]; ordered: boolean }
  | { kind: 'quote'; text: string }
  | { kind: 'rule' }
  | { kind: 'paragraph'; text: string }

export function parseMarkdownBlocks(markdown: string): MarkdownBlock[] {
  const blocks: MarkdownBlock[] = []
  const lines = markdown.replace(/\r\n/g, '\n').split('\n')
  let index = 0
  let paragraph: string[] = []
  const flushParagraph = () => {
    const text = paragraph.join('\n').trim()
    paragraph = []
    if (text) blocks.push({ kind: 'paragraph', text })
  }
  while (index < lines.length) {
    const line = lines[index] ?? ''
    const trimmed = line.trim()
    const fence = /^(```|~~~)\s*(\S*)\s*$/.exec(trimmed)
    if (fence) {
      flushParagraph()
      const marker = fence[1] ?? '```'
      const language = fence[2] || null
      const buffer: string[] = []
      index += 1
      while (index < lines.length && !(lines[index] ?? '').trim().startsWith(marker)) {
        buffer.push(lines[index] ?? '')
        index += 1
      }
      index += 1
      blocks.push({ kind: 'code', text: buffer.join('\n'), language })
      continue
    }
    if (!trimmed) {
      flushParagraph()
      index += 1
      continue
    }
    const heading = /^(#{1,6})\s+(.*)$/.exec(trimmed)
    if (heading) {
      flushParagraph()
      blocks.push({ kind: 'heading', level: (heading[1] ?? '#').length, text: heading[2] ?? '' })
      index += 1
      continue
    }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
      flushParagraph()
      blocks.push({ kind: 'rule' })
      index += 1
      continue
    }
    if (trimmed.startsWith('>')) {
      flushParagraph()
      const buffer: string[] = []
      while (index < lines.length && (lines[index] ?? '').trim().startsWith('>')) {
        buffer.push((lines[index] ?? '').trim().replace(/^>\s?/, ''))
        index += 1
      }
      blocks.push({ kind: 'quote', text: buffer.join('\n') })
      continue
    }
    const unordered = /^[-*+]\s+/.test(trimmed)
    const ordered = /^\d+[.)]\s+/.test(trimmed)
    if (unordered || ordered) {
      flushParagraph()
      const items: string[] = []
      const matcher = unordered ? /^[-*+]\s+(.*)$/ : /^\d+[.)]\s+(.*)$/
      while (index < lines.length) {
        const itemLine = (lines[index] ?? '').trim()
        const match = matcher.exec(itemLine)
        if (!match) break
        items.push(match[1] ?? '')
        index += 1
      }
      blocks.push({ kind: 'list', items, ordered })
      continue
    }
    paragraph.push(line)
    index += 1
  }
  flushParagraph()
  return blocks
}

function isSafeHref(href: string): boolean {
  return /^(https?:|mailto:|#|\/)/i.test(href)
}

function InlineText(props: { text: string; citations?: ReadonlyMap<string, string> }): JSX.Element {
  return (
    <For each={parseInlineSegments(props.text, props.citations)}>{(segment) => {
      switch (segment.kind) {
        case 'bold': return <strong>{segment.text}</strong>
        case 'italic': return <em>{segment.text}</em>
        case 'code': return <code class="md-inline-code">{segment.text}</code>
        case 'citation': return <a href={segment.href}>{segment.text}</a>
        case 'link':
          return !props.citations && isSafeHref(segment.href)
            ? <a href={segment.href} target="_blank" rel="noopener noreferrer">{segment.text}</a>
            : <span>{segment.text}</span>
        default: return <>{segment.text}</>
      }
    }}</For>
  )
}

export function MarkdownBody(props: { markdown: string; citations?: ReadonlyMap<string, string> }): JSX.Element {
  return (
    <div class="markdown-body">
      <For each={parseMarkdownBlocks(props.markdown)}>{(block) => {
        switch (block.kind) {
          case 'heading': {
            const level = Math.min(Math.max(block.level, 1), 6)
            return level <= 1
              ? <h3 class="md-heading"><InlineText citations={props.citations} text={block.text} /></h3>
              : <h4 class="md-heading"><InlineText citations={props.citations} text={block.text} /></h4>
          }
          case 'code':
            return <pre class="md-code" data-language={block.language ?? undefined}><code>{block.text}</code></pre>
          case 'list':
            return block.ordered
              ? <ol><For each={block.items}>{(item) => <li><InlineText citations={props.citations} text={item} /></li>}</For></ol>
              : <ul><For each={block.items}>{(item) => <li><InlineText citations={props.citations} text={item} /></li>}</For></ul>
          case 'quote':
            return <blockquote class="md-quote"><InlineText citations={props.citations} text={block.text} /></blockquote>
          case 'rule':
            return <hr />
          default:
            return <p class="md-paragraph"><Show when={block.text} fallback={null}><InlineText citations={props.citations} text={block.text} /></Show></p>
        }
      }}</For>
    </div>
  )
}
