import type { APIErrorPayload, Bootstrap } from './contracts'

export class APIError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code: string,
  ) {
    super(message)
  }
}

class RielaAPIClient {
  private csrfToken = ''
  private revision = 0

  async bootstrap(signal?: AbortSignal): Promise<Bootstrap> {
    const value = await this.request<Bootstrap>('/api/v1/bootstrap', { signal })
    this.csrfToken = value.csrfToken
    this.revision = value.revision
    return value
  }

  noteHeaders(): Record<string, string> {
    return this.csrfToken ? { 'X-Riela-CSRF': this.csrfToken } : {}
  }

  async get<T extends { revision?: number }>(path: string, signal?: AbortSignal): Promise<T> {
    const value = await this.request<T>(path, { signal })
    if (typeof value.revision === 'number') this.revision = value.revision
    return value
  }

  async mutate<T extends { revision?: number }>(
    path: string,
    method: 'POST' | 'PUT' | 'DELETE',
    body: Record<string, unknown>,
  ): Promise<T> {
    const value = await this.request<T>(path, {
      method,
      headers: {
        'Content-Type': 'application/json',
        'X-Riela-CSRF': this.csrfToken,
      },
      body: JSON.stringify({ ...body, expectedRevision: this.revision }),
    })
    if (typeof value.revision === 'number') this.revision = value.revision
    return value
  }

  private async request<T>(path: string, init: RequestInit): Promise<T> {
    const response = await fetch(path, { ...init, credentials: 'same-origin' })
    const text = await response.text()
    let value: T | APIErrorPayload
    try {
      value = JSON.parse(text) as T | APIErrorPayload
    } catch {
      if (!response.ok) {
        throw new APIError(`Request failed (${response.status})`, response.status, 'request_failed')
      }
      throw new APIError('The server returned invalid JSON.', response.status, 'invalid_response')
    }
    if (!response.ok) {
      const payload = value as APIErrorPayload
      throw new APIError(payload.error?.message ?? `Request failed (${response.status})`, response.status, payload.error?.code ?? 'request_failed')
    }
    return value as T
  }
}

export const api = new RielaAPIClient()
