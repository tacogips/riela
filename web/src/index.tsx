import { render } from 'solid-js/web'
import { App } from './App'
import { installDesktopHost, isDesktopRuntime } from './desktop/host'
import './styles.css'

const root = document.getElementById('root')
if (!root) throw new Error('Riela web root was not found')

async function main(): Promise<void> {
  if (isDesktopRuntime()) {
    try {
      await installDesktopHost()
    } catch (error) {
      console.error('Riela desktop host unavailable; falling back to browser fetch', error)
    }
  }
  render(() => <App />, root!)
}

void main()
