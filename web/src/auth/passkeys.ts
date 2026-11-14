import { desktopServerOrigin, rielaFetch } from '../transport'

export interface AuthResult { token?: string; user?: string; status?: string }
export interface DesktopLogin { deviceID: string; deviceSecret: string; code: string; verificationURL: string }

export async function authRequest<T>(path: string, body: unknown = {}, signal?: AbortSignal): Promise<T> {
  const response = await rielaFetch(`/api/v1/auth/${path}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal,
  })
  const result = await response.json()
  if (!response.ok) throw new Error(result.error?.message ?? `Authentication failed (${response.status}).`)
  return result as T
}

export function decodeBase64URL(value: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(value.replace(/-/g, '+').replace(/_/g, '/')), char => char.charCodeAt(0))
}

export function encodeBase64URL(value: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(value))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function requireWebAuthn() {
  if (!window.isSecureContext || !window.PublicKeyCredential || !navigator.credentials) {
    throw new Error('Passkeys require HTTPS and a browser that supports WebAuthn. Open the server’s HTTPS URL in a supported browser.')
  }
}

function serialize(credential: PublicKeyCredential) {
  const response = credential.response
  const shared = { id: credential.id, rawId: encodeBase64URL(credential.rawId), type: credential.type }
  if (response instanceof AuthenticatorAttestationResponse) {
    return { ...shared, response: { clientDataJSON: encodeBase64URL(response.clientDataJSON), attestationObject: encodeBase64URL(response.attestationObject) } }
  }
  const assertion = response as AuthenticatorAssertionResponse
  return { ...shared, response: {
    clientDataJSON: encodeBase64URL(assertion.clientDataJSON), authenticatorData: encodeBase64URL(assertion.authenticatorData),
    signature: encodeBase64URL(assertion.signature), userHandle: assertion.userHandle ? encodeBase64URL(assertion.userHandle) : null,
  } }
}

export async function registerPasskey(invitation: string, signal?: AbortSignal): Promise<AuthResult> {
  requireWebAuthn()
  const options = await authRequest<{
    ceremonyID: string; excludeCredentials: string[];
    publicKey: Omit<PublicKeyCredentialCreationOptions, 'challenge' | 'user'> & {
      challenge: string; user: Omit<PublicKeyCredentialUserEntity, 'id'> & { id: string }
    }
  }>('register/options', { invitation }, signal)
  const credential = await navigator.credentials.create({ publicKey: {
    ...options.publicKey, challenge: decodeBase64URL(options.publicKey.challenge),
    user: { ...options.publicKey.user, id: decodeBase64URL(options.publicKey.user.id) },
    authenticatorSelection: { residentKey: 'required', requireResidentKey: true, userVerification: 'required' },
    excludeCredentials: options.excludeCredentials.map(id => ({ type: 'public-key', id: decodeBase64URL(id) })),
  }, signal }) as PublicKeyCredential | null
  if (!credential) throw new Error('Passkey registration was cancelled.')
  return authRequest('register/finish', { ceremonyID: options.ceremonyID, credential: serialize(credential) }, signal)
}

export async function signInWithPasskey(deviceID?: string, signal?: AbortSignal): Promise<AuthResult> {
  requireWebAuthn()
  const options = await authRequest<{
    ceremonyID: string; publicKey: Omit<PublicKeyCredentialRequestOptions, 'challenge'> & { challenge: string }
  }>('login/options', { deviceID }, signal)
  const credential = await navigator.credentials.get({ publicKey: {
    ...options.publicKey, challenge: decodeBase64URL(options.publicKey.challenge),
  }, signal }) as PublicKeyCredential | null
  if (!credential) throw new Error('Passkey sign-in was cancelled.')
  return authRequest('login/finish', { ceremonyID: options.ceremonyID, credential: serialize(credential) }, signal)
}

export async function openDesktopLogin(login: DesktopLogin): Promise<void> {
  const native = (window as typeof window & { __TAURI__?: { core: { invoke: (name: string, args: unknown) => Promise<void> } } }).__TAURI__
  if (!native) throw new Error('Desktop login is only available in Tauri.')
  await native.core.invoke('riela_open_passkey_login', { endpoint: desktopServerOrigin(), deviceId: login.deviceID })
}

export function authError(error: unknown): string {
  if (error instanceof DOMException && (error.name === 'NotAllowedError' || error.name === 'AbortError')) {
    return 'Passkey sign-in was cancelled or timed out. You can try again.'
  }
  return error instanceof Error ? error.message : String(error)
}
