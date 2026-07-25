import { describe, expect, test } from 'bun:test'
import {
  NoteGraphQLClient,
  NoteTransportError,
  type NoteClientEnvironment,
} from './client'

function environment(
  responses: unknown[],
  href = 'http://127.0.0.1:8787/',
): { value: NoteClientEnvironment; requests: Array<{ input: string; init?: RequestInit }>; storage: Map<string, string>; replacements: string[] } {
  const requests: Array<{ input: string; init?: RequestInit }> = []
  const storage = new Map<string, string>()
  const replacements: string[] = []
  return {
    requests,
    storage,
    replacements,
    value: {
      request: async (input, init) => {
        requests.push({ input: String(input), init })
        return new Response(JSON.stringify(responses.shift()), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      },
      getSessionItem: (key) => storage.get(key) ?? null,
      setSessionItem: (key, value) => storage.set(key, value),
      removeSessionItem: (key) => { storage.delete(key) },
      appHeaders: () => ({}),
      currentURL: () => href,
      replaceURL: (value) => replacements.push(value),
    },
  }
}

describe('Note GraphQL transport', () => {
  test('sends RielaApp CSRF credentials and bounded folder variables', async () => {
    const harness = environment([{ data: { notebooks: { result: { accepted: true, status: 'ok', diagnostics: [] }, value: [] } } }])
    const client = new NoteGraphQLClient('riela-app', {
      ...harness.value,
      appHeaders: () => ({ 'X-Riela-CSRF': 'csrf' }),
      request: async (input, init) => {
        const headers = new Headers(init?.headers)
        expect(headers.get('X-Riela-CSRF')).toBe('csrf')
        return harness.value.request(input, init)
      },
    })
    await client.notebooks(200, 'updatedAtDesc', ['Work'])
    const body = JSON.parse(String(harness.requests[0]?.init?.body)) as { variables: Record<string, unknown> }
    expect(body.variables).toEqual({ limit: 200, offset: 200, sort: 'updatedAtDesc', tagFilter: ['Work'] })
    expect(harness.requests[0]?.init?.credentials).toBe('same-origin')
  })

  test('redeems CLI code, removes it from the URL, and keeps bearer in session scope', async () => {
    const harness = environment([
      { credential: { bearerToken: 'rn_session' } },
      { data: { tags: { result: { accepted: true, status: 'ok', diagnostics: [] }, value: [] } } },
    ], 'http://127.0.0.1:8787/note/register?code=once')
    const client = new NoteGraphQLClient('cli-serve', harness.value)
    await client.initialize()
    await client.tags()
    expect(harness.replacements).toEqual(['/note/register'])
    expect(harness.storage.get('riela-note-bearer')).toBe('rn_session')
    expect(new Headers(harness.requests[1]?.init?.headers).get('Authorization')).toBe('Bearer rn_session')
    expect(JSON.parse(String(harness.requests[0]?.init?.body))).toEqual({ code: 'once', displayName: 'Riela Web' })
  })

  test('sends explicit human provenance for folder membership', async () => {
    const harness = environment([{ data: { applyNotebookTags: {
      result: { accepted: true, status: 'ok', diagnostics: [] },
      notebook: { notebookId: 'book', title: 'Book', progress: 'none', createdAt: '', updatedAt: '', tags: [] },
    } } }])
    const client = new NoteGraphQLClient('riela-app', harness.value)
    await client.applyFolder('book', 'Work')
    const body = JSON.parse(String(harness.requests[0]?.init?.body)) as { variables: { input: Record<string, unknown> } }
    expect(body.variables.input).toEqual({
      notebookId: 'book',
      tags: ['Work'],
      provenance: 'human',
      assignedBy: 'riela-web',
    })
  })

  test('sends create-only folder variables and human remove provenance', async () => {
    const created = {
      tagId: 'folder-child',
      name: 'Child',
      classId: 'folder',
      parentTagId: 'folder-root',
      isSystem: false,
      createdAt: '',
    }
    const notebook = {
      notebookId: 'book',
      title: 'Book',
      progress: 'none',
      createdAt: '',
      updatedAt: '',
      tags: [],
    }
    const harness = environment([
      { data: { defineNoteTag: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        tag: created,
      } } },
      { data: { removeNotebookTag: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        notebook,
      } } },
    ])
    const client = new NoteGraphQLClient('riela-app', harness.value)

    expect(await client.defineFolder('Child', 'folder', 'folder-root')).toEqual(created)
    await client.removeFolder('book', 'Child')
    const defineBody = requestBody(harness.requests[0])
    const removeBody = requestBody(harness.requests[1])
    expect(defineBody.variables).toEqual({
      input: {
        name: 'Child',
        classId: 'folder',
        parentTagId: 'folder-root',
        createOnly: true,
      },
    })
    expect(removeBody.variables).toEqual({
      notebookId: 'book',
      tagName: 'Child',
      provenance: 'human',
    })
  })

  test('distinguishes rejected results and GraphQL envelope failures', async () => {
    const rejected = environment([
      { data: { tags: {
        result: { accepted: false, status: 'invalid_request', diagnostics: ['tag collision'] },
        value: [],
      } } },
    ])
    await expectErrorKind(new NoteGraphQLClient('riela-app', rejected.value).tags(), 'result')

    const graphQL = environment([{ errors: [{ message: 'schema mismatch' }] }])
    await expectErrorKind(new NoteGraphQLClient('riela-app', graphQL.value).tags(), 'graphql')
  })

  test('distinguishes HTTP failures and clears only the CLI session bearer on 401', async () => {
    const harness = environment([])
    harness.storage.set('riela-note-bearer', 'rn_expired')
    const client = new NoteGraphQLClient('cli-serve', {
      ...harness.value,
      request: async () => new Response(JSON.stringify({ error: 'expired' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }),
    })

    await expectErrorKind(client.tags(), 'http', 401)
    expect(harness.storage.has('riela-note-bearer')).toBe(false)
  })
})

function requestBody(request?: { init?: RequestInit }): {
  variables: Record<string, unknown>
} {
  return JSON.parse(String(request?.init?.body)) as { variables: Record<string, unknown> }
}

async function expectErrorKind(
  promise: Promise<unknown>,
  kind: NoteTransportError['kind'],
  status?: number,
): Promise<void> {
  try {
    await promise
    throw new Error(`expected ${kind} error`)
  } catch (error) {
    expect(error).toBeInstanceOf(NoteTransportError)
    expect((error as NoteTransportError).kind).toBe(kind)
    if (status !== undefined) expect((error as NoteTransportError).status).toBe(status)
  }
}
