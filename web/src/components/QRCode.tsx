import { For, Show, createMemo } from 'solid-js'

import { encodeQRCode, darkModuleRuns, QUIET_ZONE } from './qrEncoding'
export { QRCodeError, alignmentPatternPositions, dataCodewordCount, darkModuleRuns, encodeQRCode, rawDataModuleCount, smallestVersionFor, totalCodewordCount } from './qrEncoding'

export function QRCodeSVG(props: { text: string; size?: number }) {
  const encoded = createMemo(() => {
    try {
      return { matrix: encodeQRCode(props.text) }
    } catch (error) {
      return { failure: error instanceof Error ? error.message : String(error) }
    }
  })
  const extent = () => {
    const matrix = encoded().matrix
    return matrix ? matrix.size + QUIET_ZONE * 2 : 0
  }
  const pixels = () => props.size ?? 180

  return <Show when={encoded().matrix} fallback={<p class="qr-failure">{encoded().failure}</p>}>
    {(matrix) => <svg
      class="qr-code"
      role="img"
      aria-label="Registration QR code"
      width={pixels()}
      height={pixels()}
      viewBox={`0 0 ${extent()} ${extent()}`}
      shape-rendering="crispEdges"
    >
      <rect x="0" y="0" width={extent()} height={extent()} fill="#ffffff" />
      <For each={darkModuleRuns(matrix())}>
        {(run) => <rect x={run.x} y={run.y} width={run.width} height="1" fill="#000000" />}
      </For>
    </svg>}
  </Show>
}
