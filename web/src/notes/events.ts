export interface NoteChangeEvent {
  revision: number
  kind: string
  notebookId?: string | null
  tagNames?: string[] | null
}

export interface NoteEventStreamOptions {
  /** Returns headers for the stream request (bearer / app headers). */
  headers(): Record<string, string>
  /** Called for every decoded note-change event. */
  onEvent(event: NoteChangeEvent): void
  /** Called on (re)connect; the subscriber should refresh once. */
  onConnect(): void
  /** Called when the stream is unavailable and retries are exhausted for now. */
  onUnavailable?(): void
  fetchImpl?: typeof fetch
  /** Base reconnect delay in ms (doubles up to 30s). */
  reconnectDelayMs?: number
}

/**
 * Subscribes to the same-origin `/note/events` SSE feed using fetch streaming
 * rather than EventSource, because the cli-serve transport authenticates with
 * an Authorization header that EventSource cannot send. Events only schedule
 * refreshes on the caller's side; a dropped or unavailable stream degrades to
 * the caller's manual refresh behavior.
 */
export function subscribeNoteEvents(options: NoteEventStreamOptions): () => void {
  const fetchImpl = options.fetchImpl ?? fetch.bind(globalThis)
  const baseDelay = options.reconnectDelayMs ?? 1000
  let closed = false
  let attempt = 0
  let abort = new AbortController()

  const run = async (): Promise<void> => {
    while (!closed) {
      abort = new AbortController()
      try {
        const response = await fetchImpl('/note/events', {
          method: 'GET',
          credentials: 'same-origin',
          headers: { Accept: 'text/event-stream', ...options.headers() },
          signal: abort.signal,
        })
        if (!response.ok || !response.body) {
          throw new Error(`note event stream unavailable (${response.status})`)
        }
        attempt = 0
        options.onConnect()
        await readStream(response.body, options.onEvent, () => closed)
      } catch {
        if (closed) return
      }
      if (closed) return
      attempt += 1
      if (attempt >= 5) options.onUnavailable?.()
      const delay = Math.min(baseDelay * 2 ** Math.min(attempt, 5), 30_000)
      await new Promise((resolve) => setTimeout(resolve, delay))
    }
  }
  void run()

  return () => {
    closed = true
    abort.abort()
  }
}

async function readStream(
  body: ReadableStream<Uint8Array>,
  onEvent: (event: NoteChangeEvent) => void,
  isClosed: () => boolean,
): Promise<void> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done || isClosed()) return
      buffer += decoder.decode(value, { stream: true })
      let boundary = buffer.indexOf('\n\n')
      while (boundary >= 0) {
        const frame = buffer.slice(0, boundary)
        buffer = buffer.slice(boundary + 2)
        const event = parseFrame(frame)
        if (event) onEvent(event)
        boundary = buffer.indexOf('\n\n')
      }
    }
  } finally {
    reader.releaseLock()
  }
}

export function parseFrame(frame: string): NoteChangeEvent | null {
  let eventName = ''
  const dataLines: string[] = []
  for (const rawLine of frame.split('\n')) {
    const line = rawLine.endsWith('\r') ? rawLine.slice(0, -1) : rawLine
    if (line.startsWith(':')) continue
    if (line.startsWith('event:')) eventName = line.slice(6).trim()
    else if (line.startsWith('data:')) dataLines.push(line.slice(5).trim())
  }
  if (eventName !== 'note-change' || dataLines.length === 0) return null
  try {
    const parsed = JSON.parse(dataLines.join('\n')) as Partial<NoteChangeEvent>
    if (typeof parsed.revision !== 'number' || typeof parsed.kind !== 'string') return null
    return {
      revision: parsed.revision,
      kind: parsed.kind,
      notebookId: parsed.notebookId ?? null,
      tagNames: parsed.tagNames ?? null,
    }
  } catch {
    return null
  }
}

/** True when the event could affect a board scoped to the given tag names. */
export function eventAffectsScope(event: NoteChangeEvent, scopeTagNames: string[]): boolean {
  if (!event.tagNames || event.tagNames.length === 0) return true
  if (scopeTagNames.length === 0) return true
  const scope = new Set(scopeTagNames)
  return event.tagNames.some((name) => scope.has(name))
}
