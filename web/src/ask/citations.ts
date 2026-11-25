import { viewHash } from '../routes'
import type { AskRef } from './contracts'

export function citationHref(ref: AskRef, remote?: string, sourceForWorkflow?: (id: string) => string | undefined): string | undefined {
  if (ref.kind === 'session') return viewHash({ view: 'run-detail', sessionId: ref.id, remote })
  if (ref.kind === 'step' && ref.sessionId) return viewHash({ view: 'run-detail', sessionId: ref.sessionId, remote })
  if (ref.kind === 'bot') return viewHash({ view: 'bot-detail', botId: ref.id, remote })
  if (ref.kind === 'workflow' && (!remote || remote === 'local')) {
    const sourceId = sourceForWorkflow?.(ref.id)
    if (sourceId) return viewHash({ view: 'workflow-detail', sourceId })
  }
}

export function citationLinks(citations: AskRef[], remote?: string, sourceForWorkflow?: (id: string) => string | undefined) {
  const links = new Map<string, string>()
  for (const ref of citations) {
    const href = citationHref(ref, remote, sourceForWorkflow)
    if (!href) continue
    const id = ref.kind === 'step' && ref.sessionId ? `${ref.sessionId}/${ref.id}` : ref.id
    links.set(`${ref.kind}:${id}`, href)
  }
  return links
}

export function renderCitations(text: string, citations: ReadonlyMap<string, string>): string {
  return text.replace(/\[\[([^\]\r\n]+)\]\]/g, (marker: string, key: string) => {
    const href = citations.get(key)
    return href ? `[${key}](${href.replaceAll('(', '%28').replaceAll(')', '%29')})` : marker
  })
}
