import { Show, createSignal, onCleanup, onMount } from 'solid-js'
import { App } from '../App'
import { isDesktop, setBrowserAccessToken } from '../transport'
import { authError, authRequest, registerPasskey, signInWithPasskey } from './passkeys'

interface AuthRoute { kind: 'register' | 'device'; secret: string }

export function authRoute(hash: string): AuthRoute | undefined {
  const match = /^#\/auth\/(register|device)\/([A-Za-z0-9_-]{43})$/.exec(hash)
  return match ? { kind: match[1] as AuthRoute['kind'], secret: match[2]! } : undefined
}

export function AuthEntry() {
  const [route, setRoute] = createSignal<AuthRoute | undefined>(isDesktop() ? undefined : authRoute(location.hash))
  const readRoute = () => {
    const route = isDesktop() ? undefined : authRoute(location.hash)
    setRoute(route)
    // Invitations stay in memory, not browser history, referrers or server logs.
    if (route) history.replaceState(null, '', `/#/auth/${route.kind}`)
  }
  onMount(() => {
    readRoute()
    window.addEventListener('hashchange', readRoute)
  })
  onCleanup(() => window.removeEventListener('hashchange', readRoute))
  return <Show when={route()} keyed fallback={<App />}>{current => <AuthLanding route={current} onConnected={token => {
    setBrowserAccessToken(token)
    history.replaceState(null, '', '/#/workflows')
    setRoute(undefined)
  }} />}</Show>
}

function AuthLanding(props: { route: AuthRoute; onConnected: (token: string) => void }) {
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal('')
  const [code, setCode] = createSignal('')
  const [done, setDone] = createSignal(false)
  const controller = new AbortController()
  onCleanup(() => controller.abort())
  onMount(() => {
    if (props.route.kind === 'device') void authRequest<{ code: string }>('device/info', { deviceID: props.route.secret }, controller.signal)
      .then(value => setCode(value.code)).catch(error => setError(authError(error)))
  })
  const submit = async () => {
    setBusy(true)
    setError('')
    try {
      const result = props.route.kind === 'register'
        ? await registerPasskey(props.route.secret, controller.signal)
        : await signInWithPasskey(props.route.secret, controller.signal)
      if (controller.signal.aborted) return
      if (result.token) props.onConnected(result.token)
      else setDone(true)
    } catch (error) {
      if (!controller.signal.aborted) setError(authError(error))
    } finally { if (!controller.signal.aborted) setBusy(false) }
  }
  return <main class="center-state auth-panel">
    <h1>{props.route.kind === 'register' ? 'Register a Passkey' : 'Sign in to Riela desktop'}</h1>
    <p>{location.origin}</p>
    <Show when={!done()} fallback={<p>Desktop sign-in approved. Return to Riela. You can close this tab.</p>}>
      <Show when={props.route.kind === 'register'} fallback={<>
        <p>Continue only if you started this sign-in in Riela and the code matches your desktop window.</p>
        <strong>{code()}</strong>
      </>}><p>Create a Passkey for this server. Your device keeps the private key; no password is needed.</p></Show>
      <Show when={error()}><p role="alert">{error()}</p></Show>
      <button disabled={busy() || (props.route.kind === 'device' && !code())} onClick={() => void submit()}>
        {busy() ? 'Waiting for your Passkey…' : props.route.kind === 'register' ? 'Create Passkey' : 'Code matches — sign in with Passkey'}
      </button>
    </Show>
  </main>
}
