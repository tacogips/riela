import { createSignal, onCleanup, onMount, splitProps, type JSX } from 'solid-js'

const symbols: Array<[RegExp, string]> = [
  [/undo/i, 'M9 4L3 10l6 6 M3 10h11a6 6 0 0 1 6 6v4'],
  [/redo/i, 'M15 4l6 6-6 6 M21 10H10a6 6 0 0 0-6 6v4'],
  [/json/i, 'M8 3H6v7l-3 2 3 2v7h2 M16 3h2v7l3 2-3 2v7h-2'],
  [/sign out|logout/i, 'M9 3H3v18h6 M10 12h11 M17 8l4 4-4 4'],
  [/retry|try again|reload/i, 'M20 4v6h-6 M20 10a8 8 0 1 0 0 6'],
  [/generate|apply|validate/i, 'M5 13l4 4L20 6'],
  [/download|export/i, 'M12 3v12 M7 10l5 5 5-5 M4 16v5h16v-5'],
  [/refresh|更新|再読込/i, 'M20 7v5h-5 M4 17v-5h5 M6 7a7 7 0 0 1 12-2l2 2 M4 17l2 2a7 7 0 0 0 12-2'],
  [/back|一覧へ|戻る|previous/i, 'M15 5l-7 7 7 7'],
  [/next/i, 'M9 5l7 7-7 7'],
  [/cancel|close|dismiss|キャンセル|閉じる/i, 'M6 6l12 12 M18 6L6 18'],
  [/delete|remove|clear|削除|解除/i, 'M4 7h16 M9 7V4h6v3 M6 7l1 13h10l1-13 M10 10v7 M14 10v7'],
  [/save|保存/i, 'M5 3h12l4 4v14H3V3h2 M7 3v6h10V3 M7 21v-8h10v8'],
  [/restart|再実行/i, 'M20 4v6h-6 M20 10a8 8 0 1 0 0 6'],
  [/stop|停止/i, 'M5 5h14v14H5z'],
  [/run|start|実行|開始/i, 'M7 4l14 8-14 8z'],
  [/add|create|register|new|追加|作成|登録/i, 'M12 4v16 M4 12h16'],
  [/edit|編集/i, 'M4 16v4h4L20 8l-4-4z M14 6l4 4'],
  [/copy/i, 'M8 8h12v12H8z M16 8V4H4v12h4'],
  [/import|directory/i, 'M3 7V4h7l2 3h9v13H3z M12 10v7 M9 14l3 3 3-3'],
  [/connect|接続/i, 'M8 12H4v-3a4 4 0 0 1 4-4h3 M16 12h4v3a4 4 0 0 1-4 4h-3 M8 12h8'],
  [/settings|設定/i, 'M12 3v3 M12 18v3 M3 12h3 M18 12h3 M5 5l2 2 M17 17l2 2 M5 19l2-2 M17 7l2-2 M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0'],
  [/history|履歴/i, 'M3 4v5h5 M3 9a9 9 0 1 1 1 9 M12 7v5l3 2'],
  [/workflow|ワークフロー/i, 'M3 3h6v6H3z M15 15h6v6h-6z M6 9v9h9 M9 6h9v9'],
  [/deck/i, 'M12 2l3 7 7 3-7 3-3 7-3-7-7-3 7-3z'],
  [/enable|disable|launch/i, 'M12 3v8 M6 6a9 9 0 1 0 12 0'],
  [/zoom in|拡大/i, 'M12 4v16 M4 12h16'],
  [/zoom out|縮小/i, 'M4 12h16'],
  [/fit/i, 'M4 9V4h5 M15 4h5v5 M20 15v5h-5 M9 20H4v-5'],
]

/** Compact action with its original accessible name and a native tooltip. */
export function ActionButton(props: JSX.ButtonHTMLAttributes<HTMLButtonElement>) {
  const [local, attributes] = splitProps(props, ['children', 'class', 'classList', 'title'])
  const [label, setLabel] = createSignal('')
  let caption!: HTMLSpanElement
  onMount(() => {
    const update = () => setLabel(caption.textContent?.trim() ?? '')
    update()
    const observer = new MutationObserver(update)
    observer.observe(caption, { childList: true, characterData: true, subtree: true })
    onCleanup(() => observer.disconnect())
  })
  const path = () => symbols.find(([pattern]) => pattern.test(String(props['aria-label'] ?? label())))?.[1]
    ?? 'M5 12h14 M13 6l6 6-6 6'
  return <button {...attributes} class={`action-icon-button ${local.class ?? ''}`} classList={local.classList} title={local.title ?? String(props['aria-label'] ?? label())}>
    <svg aria-hidden="true" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d={path()} /></svg>
    <span class="action-button-caption" ref={caption}>{local.children}</span>
  </button>
}
