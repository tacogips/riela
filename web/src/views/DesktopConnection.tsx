import { Show, createSignal } from 'solid-js'
import { desktopServerOrigin, switchDesktopConnection } from '../transport'

export function DesktopConnection() {
  const [mode, setMode] = createSignal(desktopServerOrigin() ? 'web' : 'local')
  const [endpoint, setEndpoint] = createSignal(desktopServerOrigin())
  const [error, setError] = createSignal('')
  return <details class="desktop-connection">
    <summary>Connection: {desktopServerOrigin() ? 'Web mode' : 'Local'}</summary>
    <form onSubmit={event => {
      event.preventDefault()
      try { switchDesktopConnection(mode() === 'web' ? endpoint() : '') }
      catch (error) { setError(String(error)) }
    }}>
      <label>Connection mode<select value={mode()} onChange={event => setMode(event.currentTarget.value)}>
        <option value="local">Local</option><option value="web">Web mode</option>
      </select></label>
      <Show when={mode() === 'web'}><label>Riela server URL<input type="url" required
        placeholder="https://riela.example" value={endpoint()} onInput={event => setEndpoint(event.currentTarget.value)} /></label></Show>
      <p>Changing connection reloads the console. Save edits first.</p>
      <Show when={error()}><p role="alert">{error()}</p></Show>
      <button type="submit">Connect</button>
    </form>
  </details>
}
