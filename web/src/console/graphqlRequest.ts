import { APIError } from '../api'
import type { ConsoleClientEnvironment } from './client'

interface GraphQLResponse<T> {
  data?: T
  errors?: { message: string; extensions?: { code?: string } }[]
}

export async function graphqlRequest<T>(
  environment: ConsoleClientEnvironment, operationName: string, query: string,
  variables: Record<string, unknown>, signal?: AbortSignal,
): Promise<T> {
  const response = await environment.request('/graphql', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...environment.appHeaders() },
    body: JSON.stringify({ operationName, query, variables }),
    signal,
  })
  const body = await response.text()
  let payload: GraphQLResponse<T> | null
  try {
    payload = JSON.parse(body) as GraphQLResponse<T> | null
  } catch {
    throw new APIError('The console returned invalid JSON.', response.status, 'invalid_response')
  }
  const error = payload?.errors?.[0]
  if (!response.ok || error || !payload?.data) {
    throw new APIError(
      error?.message ?? `Console request failed (${response.status})`,
      response.status,
      error?.extensions?.code ?? 'console_request_failed',
    )
  }
  return payload.data
}
