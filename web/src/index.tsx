import { render } from 'solid-js/web'
import { App } from './App'
import './styles.css'

const root = document.getElementById('root')
if (!root) throw new Error('Riela web root was not found')
render(() => <App />, root)
