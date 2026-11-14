import type { JSX } from 'solid-js'

export function PageHeader(props: { eyebrow: string; title: string; description: string; actions?: JSX.Element }) {
  return <div class="page-header"><div><span class="eyebrow">{props.eyebrow}</span><h1>{props.title}</h1><p>{props.description}</p></div><div class="header-actions">{props.actions}</div></div>
}

export function EmptyState(props: { title: string; detail: string }) {
  return <div class="empty-state"><span>◇</span><strong>{props.title}</strong><p>{props.detail}</p></div>
}

export function ErrorBanner(props: { message: string }) {
  return <div class="error-banner" role="alert">{props.message}</div>
}
