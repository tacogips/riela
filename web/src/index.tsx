import { render } from 'solid-js/web'
import { AuthEntry } from './auth/AuthEntry'
import './styles.css'
import './auth/auth.css'
import './monochrome-theme.css'
import './responsive-layout.css'

const root = document.getElementById('root')
if (!root) throw new Error('Riela web root was not found')
render(() => <AuthEntry />, root)
