import tailwindcss from '@tailwindcss/vite'
import { defineConfig } from 'vite'
import solid from 'vite-plugin-solid'

// The Tauri CLI sets TAURI_ENV_PLATFORM (build) and optionally TAURI_DEV_HOST
// (mobile/remote dev). Only then does the dev server switch to Tauri's fixed
// port; the browser dashboard and the Playwright suite (which starts vite on
// --port 4174) keep Vite's defaults.
const tauriDevHost = process.env.TAURI_DEV_HOST
const isTauri = Boolean(process.env.TAURI_ENV_PLATFORM || tauriDevHost)

export default defineConfig({
  plugins: [solid(), tailwindcss()],
  build: {
    target: 'es2022',
    sourcemap: true,
  },
  ...(isTauri
    ? {
        clearScreen: false,
        server: {
          port: 1420,
          strictPort: true,
          host: tauriDevHost || false,
          hmr: tauriDevHost ? { protocol: 'ws', host: tauriDevHost, port: 1421 } : undefined,
          watch: { ignored: ['**/src-tauri/**'] },
        },
      }
    : {}),
})
