import type { TileLayer } from 'leaflet'

export const TILE_ERROR_LIMIT = 3
export const TILE_TIMEOUT_MS = 5_000
/** A burst of errors or one offline reading can be a blip, so a good tile still gets a moment. */
export const TILE_GRACE_MS = 1_000

export type MapFailure = 'tiles' | 'offline' | 'timeout' | 'code'

/**
 * The venue may have no tiles at all, and a grey map must not stand between a patient and
 * checking in. Any tile that loads ends the watch. Returns the function that stops it.
 */
export function watchTiles(
  layer: TileLayer,
  onFail: (reason: MapFailure) => void,
): () => void {
  let errors = 0
  let timer: ReturnType<typeof setTimeout> | undefined
  let grace: ReturnType<typeof setTimeout> | undefined

  const onLoad = () => stop()
  const onError = () => {
    errors += 1
    if (errors >= TILE_ERROR_LIMIT) failSoon('tiles')
  }
  const stop = () => {
    clearTimeout(timer)
    clearTimeout(grace)
    layer.off('tileload', onLoad)
    layer.off('tileerror', onError)
  }
  const fail = (reason: MapFailure) => {
    stop()
    onFail(reason)
  }
  const failSoon = (reason: MapFailure) => {
    if (grace === undefined) grace = setTimeout(() => fail(reason), TILE_GRACE_MS)
  }

  layer.on('tileload', onLoad)
  layer.on('tileerror', onError)
  timer = setTimeout(() => fail('timeout'), TILE_TIMEOUT_MS)
  if (navigator.onLine === false) failSoon('offline')
  return stop
}
