import { api } from '../api'
import type {
  GraphQLEnvelope,
  HostMode,
  MutationPayload,
  Note,
  Notebook,
  NoteListSort,
  NoteTag,
  NoteTagClass,
  NotebookProgress,
  QueryPayload,
} from './types'

const bearerKey = 'riela-note-bearer'
export const notebookPageLimit = 200

export interface NoteClientEnvironment {
  request(input: RequestInfo | URL, init?: RequestInit): Promise<Response>
  getSessionItem(key: string): string | null
  setSessionItem(key: string, value: string): void
  removeSessionItem(key: string): void
  appHeaders(): Record<string, string>
  currentURL(): string
  replaceURL(value: string): void
}

export class NoteTransportError extends Error {
  constructor(
    message: string,
    readonly kind: 'network' | 'http' | 'graphql' | 'result' | 'registration',
    readonly status?: number,
  ) {
    super(message)
  }
}

export class NoteGraphQLClient {
  private readonly environment: NoteClientEnvironment

  constructor(readonly mode: HostMode, environment?: NoteClientEnvironment) {
    this.environment = environment ?? browserEnvironment()
  }

  async initialize(): Promise<void> {
    if (this.mode !== 'cli-serve') return
    const url = new URL(this.environment.currentURL())
    const code = url.searchParams.get('code')
    if (!code) return
    url.searchParams.delete('code')
    this.environment.replaceURL(`${url.pathname}${url.search}${url.hash}`)
    const response = await this.environment.request('/note/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code, displayName: 'Riela Web' }),
    })
    const value = await parseJSON<{ credential?: { bearerToken?: string }; error?: string }>(response)
    const bearer = value.credential?.bearerToken
    if (!response.ok || !bearer) {
      throw new NoteTransportError(value.error ?? 'Registration failed.', 'registration', response.status)
    }
    this.environment.setSessionItem(bearerKey, bearer)
  }

  hasCredential(): boolean {
    return this.mode === 'riela-app' || Boolean(this.environment.getSessionItem(bearerKey))
  }

  async tags(): Promise<NoteTag[]> {
    return this.queryValue<{ tags: QueryPayload<NoteTag[]> }, NoteTag[]>('Tags', `
      query Tags { tags { result { accepted status diagnostics } value { tagId name classId parentTagId isSystem createdAt } } }
    `, {}, (data) => data.tags)
  }

  async tagClasses(): Promise<NoteTagClass[]> {
    return this.queryValue<{ tagClasses: QueryPayload<NoteTagClass[]> }, NoteTagClass[]>('TagClasses', `
      query TagClasses { tagClasses { result { accepted status diagnostics } value { classId label description } } }
    `, {}, (data) => data.tagClasses)
  }

  async notebooks(
    offset: number,
    sort: NoteListSort,
    tagFilterGroups: string[][],
    limit = notebookPageLimit,
  ): Promise<Notebook[]> {
    const values = await this.queryValue<{ notebooks: QueryPayload<Notebook[]> }, Notebook[]>('Notebooks', `
      query Notebooks($limit: Int, $offset: Int, $sort: NoteListSort, $tagFilter: [String!], $tagFilterGroups: [[String!]!]) {
        notebooks(limit: $limit, offset: $offset, sort: $sort, tagFilter: $tagFilter, tagFilterGroups: $tagFilterGroups) {
          result { accepted status diagnostics }
          value { notebookId title progress createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { limit, offset, sort, tagFilter: [], tagFilterGroups }, (data) => data.notebooks)
    return values.map(normalizeNotebook)
  }

  async notebook(notebookId: string): Promise<Notebook> {
    const value = await this.queryValue<{ notebook: QueryPayload<Notebook> }, Notebook>('Notebook', `
      query Notebook($notebookId: String!) {
        notebook(notebookId: $notebookId) {
          result { accepted status diagnostics }
          value { notebookId title progress createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { notebookId }, (data) => data.notebook)
    return normalizeNotebook(value)
  }

  async notes(notebookId: string, offset: number): Promise<Note[]> {
    return this.queryValue<{ notes: QueryPayload<Note[]> }, Note[]>('Notes', `
      query Notes($notebookId: String!, $limit: Int, $offset: Int) {
        notes(notebookId: $notebookId, limit: $limit, offset: $offset) {
          result { accepted status diagnostics }
          value { noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt }
        }
      }
    `, { notebookId, limit: notebookPageLimit, offset }, (data) => data.notes)
  }

  async defineFolder(name: string, classId: string, parentTagId?: string): Promise<NoteTag> {
    const payload = await this.mutation('DefineFolder', `
      mutation DefineFolder($input: DefineNoteTagInput!) {
        defineNoteTag(input: $input) {
          result { accepted status diagnostics }
          tag { tagId name classId parentTagId isSystem createdAt }
        }
      }
    `, { input: { name, classId, ...(parentTagId ? { parentTagId } : {}), createOnly: true } }, 'defineNoteTag')
    if (!payload.tag) throw new NoteTransportError('The server did not return the created folder.', 'result')
    return payload.tag
  }

  async applyTag(notebookId: string, tagName: string): Promise<Notebook> {
    return this.notebookMutation('ApplyNotebookTag', `
      mutation ApplyNotebookTag($input: ApplyNotebookTagsInput!) {
        applyNotebookTags(input: $input) {
          result { accepted status diagnostics }
          notebook { notebookId title progress createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { input: { notebookId, tags: [tagName], provenance: 'human', assignedBy: 'riela-web' } }, 'applyNotebookTags')
  }

  async removeTag(notebookId: string, tagName: string): Promise<Notebook> {
    return this.notebookMutation('RemoveNotebookTag', `
      mutation RemoveNotebookTag($notebookId: String!, $tagName: String!, $provenance: String) {
        removeNotebookTag(notebookId: $notebookId, tagName: $tagName, provenance: $provenance) {
          result { accepted status diagnostics }
          notebook { notebookId title progress createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { notebookId, tagName, provenance: 'human' }, 'removeNotebookTag')
  }

  async setProgress(notebookId: string, progress: NotebookProgress): Promise<Notebook> {
    return this.notebookMutation('SetProgress', `
      mutation SetProgress($notebookId: String!, $progress: NotebookProgress!) {
        setNotebookProgress(notebookId: $notebookId, progress: $progress) {
          result { accepted status diagnostics }
          notebook { notebookId title progress createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { notebookId, progress }, 'setNotebookProgress')
  }

  private async notebookMutation(
    operationName: string,
    query: string,
    variables: Record<string, unknown>,
    field: string,
  ): Promise<Notebook> {
    const payload = await this.mutation(operationName, query, variables, field)
    if (!payload.notebook) throw new NoteTransportError('The server did not return the notebook.', 'result')
    return normalizeNotebook(payload.notebook)
  }

  private async mutation(
    operationName: string,
    query: string,
    variables: Record<string, unknown>,
    field: string,
  ): Promise<MutationPayload> {
    const data = await this.request<Record<string, MutationPayload>>(operationName, query, variables)
    const payload = data[field]
    if (!payload) throw new NoteTransportError(`GraphQL response omitted ${field}.`, 'graphql')
    ensureAccepted(payload?.result)
    return payload
  }

  private async queryValue<Data, Value>(
    operationName: string,
    query: string,
    variables: Record<string, unknown>,
    select: (data: Data) => QueryPayload<Value>,
  ): Promise<Value> {
    const payload = select(await this.request<Data>(operationName, query, variables))
    ensureAccepted(payload.result)
    return payload.value
  }

  private async request<T>(
    operationName: string,
    query: string,
    variables: Record<string, unknown>,
  ): Promise<T> {
    const headers: Record<string, string> = { 'Content-Type': 'application/json', ...this.environment.appHeaders() }
    if (this.mode === 'cli-serve') {
      const bearer = this.environment.getSessionItem(bearerKey)
      if (!bearer) throw new NoteTransportError('Open the registration URL printed by riela serve.', 'registration')
      headers.Authorization = `Bearer ${bearer}`
    }
    let response: Response
    try {
      response = await this.environment.request('/graphql', {
        method: 'POST',
        credentials: 'same-origin',
        headers,
        body: JSON.stringify({ query, variables, operationName }),
      })
    } catch (error) {
      throw new NoteTransportError(error instanceof Error ? error.message : String(error), 'network')
    }
    const envelope = await parseJSON<GraphQLEnvelope<T>>(response)
    if (response.status === 401 && this.mode === 'cli-serve') this.environment.removeSessionItem(bearerKey)
    if (!response.ok) {
      throw new NoteTransportError(envelope.error ?? `Request failed (${response.status}).`, 'http', response.status)
    }
    if (envelope.errors?.length) {
      throw new NoteTransportError(envelope.errors.map((error) => error.message).join('; '), 'graphql')
    }
    if (!envelope.data) throw new NoteTransportError('GraphQL response did not include data.', 'graphql')
    return envelope.data
  }
}

function normalizeNotebook(notebook: Notebook): Notebook {
  const supported = ['none', 'progress', 'done', 'pending'] as const
  const progress = String(notebook.progress)
  const known = supported.some((value) => value === progress)
  return {
    ...notebook,
    progress: known ? progress as NotebookProgress : 'none',
    progressWasUnknown: !known,
  }
}

function browserEnvironment(): NoteClientEnvironment {
  return {
    request: (input, init) => fetch(input, init),
    getSessionItem: (key) => sessionStorage.getItem(key),
    setSessionItem: (key, value) => sessionStorage.setItem(key, value),
    removeSessionItem: (key) => sessionStorage.removeItem(key),
    appHeaders: () => api.noteHeaders(),
    currentURL: () => window.location.href,
    replaceURL: (value) => history.replaceState(null, '', value),
  }
}

function ensureAccepted(result?: { accepted: boolean; diagnostics: string[]; status: string }): void {
  if (result?.accepted) return
  throw new NoteTransportError(result?.diagnostics.join('; ') || result?.status || 'Note operation failed.', 'result')
}

async function parseJSON<T>(response: Response): Promise<T> {
  const text = await response.text()
  try {
    return JSON.parse(text) as T
  } catch {
    throw new NoteTransportError('The server returned invalid JSON.', 'http', response.status)
  }
}
