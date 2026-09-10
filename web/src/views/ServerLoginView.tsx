import { Show, createSignal } from 'solid-js'

export function ServerLoginView(props: { connecting: boolean; rejected: boolean; onConnect: (token: string) => void }) {
  const [token, setToken] = createSignal('')
  return <form class="center-state" onSubmit={event => {
    event.preventDefault()
    props.onConnect(token())
    setToken('')
  }}>
    <h1>Connect to Riela</h1>
    <p>Enter the access token configured for this server.</p>
    <Show when={props.rejected}><p role="alert">Access token was not accepted. Try again.</p></Show>
    <label>Server access token<input type="password" autocomplete="off" required
      value={token()} onInput={event => setToken(event.currentTarget.value)} /></label>
    <button type="submit" disabled={props.connecting || !token()}>{props.connecting ? 'Connecting…' : 'Connect'}</button>
    <p>The token is kept only until this page is closed or reloaded.</p>
  </form>
}
