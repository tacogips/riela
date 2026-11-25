import { createMemo, createResource, createSignal } from 'solid-js'
import { APIError } from '../api'
import { botsClient } from './client'
import type { RemoteList } from './contracts'

const storageKey = 'riela.bots.remote'

export function resolveRemoteSelection(stored: string | null, registry: RemoteList): string {
  const selection = stored ?? registry.active
  return selection === '*' || registry.remotes.some(({ name }) => name === selection) ? selection : 'local'
}

export function remoteArgument(selection: string, itemRemote?: string): string {
  return itemRemote ?? selection
}

export function managementError(error: unknown): string {
  return error instanceof APIError ? error.code : 'request_failed'
}

export function createRemoteSelection(profileKey: () => string, linkedRemote?: () => string | undefined) {
  const [registry, { mutate, refetch }] = createResource(profileKey, () => botsClient.getRemotes())
  const [stored, setStored] = createSignal(sessionStorage.getItem(storageKey))
  const snapshot = () => registry.error ? undefined : registry.latest
  const selection = createMemo(() => {
    const value = snapshot()
    const current = value ? resolveRemoteSelection(stored(), value) : 'local'
    const linked = linkedRemote?.()
    return linked && current !== '*' && value?.remotes.some(({ name }) => name === linked) ? linked : current
  })

  return {
    registry, snapshot, selection, mutate, refetch,
    select: (next: string) => {
      sessionStorage.setItem(storageKey, next)
      setStored(next)
    },
    targets: () => {
      const remote = selection()
      return remote === '*' ? ['local', ...(snapshot()?.remotes.map(({ name }) => name).sort() ?? [])] : [remote]
    },
  }
}

export type RemoteSelection = ReturnType<typeof createRemoteSelection>

export async function readRemoteTargets<T>(targets: string[], load: (remote: string) => Promise<T>) {
  const results = await Promise.allSettled(targets.map(load))
  return {
    values: results.flatMap((result) => result.status === 'fulfilled' ? [result.value] : []),
    failures: results.flatMap((result, index) => result.status === 'rejected'
      ? [{ remote: targets[index]!, code: managementError(result.reason) }] : []),
  }
}
