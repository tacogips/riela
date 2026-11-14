import { Show, createSignal, onCleanup } from 'solid-js'
import { desktopServerOrigin } from '../transport'
import { authError, authRequest, openDesktopLogin, signInWithPasskey, type AuthResult, type DesktopLogin } from '../auth/passkeys'

export function ServerLoginView(props: { connecting: boolean; onConnect: (token: string) => void }) {
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal('')
  const [desktop, setDesktop] = createSignal<DesktopLogin>()
  let operation: AbortController | undefined
  let timer: ReturnType<typeof setTimeout> | undefined
  const cancel = () => {
    operation?.abort()
    clearTimeout(timer)
    const current = desktop()
    if (current) void authRequest('device/cancel', current).catch(() => {})
    setDesktop(undefined)
    setBusy(false)
  }
  onCleanup(cancel)
  const connect = async () => {
    cancel()
    const controller = new AbortController()
    operation = controller
    setBusy(true)
    setError('')
    try {
      if (!desktopServerOrigin()) {
        const result = await signInWithPasskey(undefined, controller.signal)
        if (!controller.signal.aborted && result.token) props.onConnect(result.token)
        return
      }
      const login = await authRequest<DesktopLogin>('device/start', {}, controller.signal)
      if (controller.signal.aborted) return
      setDesktop(login)
      await openDesktopLogin(login)
      const poll = async () => {
        try {
          const result = await authRequest<AuthResult>('device/poll', login, controller.signal)
          if (controller.signal.aborted) return
          if (result.token) {
            setDesktop(undefined)
            setBusy(false)
            props.onConnect(result.token)
          } else {
            timer = setTimeout(() => void poll(), 1500)
          }
        } catch (error) {
          if (!controller.signal.aborted) { setError(authError(error)); cancel() }
        }
      }
      void poll()
    } catch (error) {
      if (!controller.signal.aborted) { setError(authError(error)); cancel() }
    } finally {
      if (!controller.signal.aborted && !desktop()) setBusy(false)
    }
  }
  return <section class="center-state auth-panel">
    <h1>Connect to Riela</h1>
    <p>Sign in with a Passkey registered on this server.</p>
    <Show when={desktopServerOrigin()}><p>{desktopServerOrigin()}</p></Show>
    <Show when={error()}><p role="alert">{error()}</p></Show>
    <Show when={desktop()} fallback={<button onClick={() => void connect()} disabled={busy() || props.connecting}>
      {busy() ? 'Signing in…' : desktopServerOrigin() ? 'Sign in using browser' : 'Sign in with Passkey'}
    </button>}>{login => <>
      <p>Confirm this code in your browser:</p><strong>{login().code}</strong>
      <p>Waiting for Passkey sign-in…</p>
      <button onClick={() => void openDesktopLogin(login()).catch(error => setError(authError(error)))}>Open browser again</button>
      <button onClick={cancel}>Cancel</button>
    </>}</Show>
    <p>First time here? Ask the server administrator for a registration link.</p>
  </section>
}
