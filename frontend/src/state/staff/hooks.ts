import { useCallback } from 'react'
import { counterQueue, display, staffVisit, stats } from '../../api/staff'
import { getStaffToken } from './staffToken'
import { useLive } from './useLive'

const STATS_POLL_MS = 5_000

/** EventSource cannot send headers, so the token goes in the URL. */
function streamOf(path: string, on: boolean): string | null {
  const token = getStaffToken()
  if (!on || token === null) return null
  return `${path}?token=${encodeURIComponent(token)}`
}

/** A page holds one stream. Beside another stream, pass `stream: false`. */
export function useCounterQueue(counterId: string, { stream = true }: { stream?: boolean } = {}) {
  const load = useCallback((signal: AbortSignal) => counterQueue(counterId, { signal }), [counterId])
  return useLive({
    key: `counter:${counterId}`,
    load,
    stream: streamOf(`/api/counters/${encodeURIComponent(counterId)}/stream`, stream),
  })
}

/** A page holds one stream. Beside a queue stream, pass `stream: false` and refetch on its data. */
export function useStaffVisit(visitId: string, { stream = true }: { stream?: boolean } = {}) {
  const load = useCallback((signal: AbortSignal) => staffVisit(visitId, { signal }), [visitId])
  return useLive({
    key: `visit:${visitId}`,
    load,
    stream: streamOf(`/api/visits/${encodeURIComponent(visitId)}/stream`, stream),
  })
}

export function useDisplay(centreId: string) {
  const load = useCallback((signal: AbortSignal) => display(centreId, { signal }), [centreId])
  return useLive({
    key: `display:${centreId}`,
    load,
    stream: streamOf(`/api/display/${encodeURIComponent(centreId)}/stream`, true),
  })
}

/** Poll only: a refill or an emergency publishes no event a dashboard could hear. */
export function useStats(centreId: string) {
  const load = useCallback((signal: AbortSignal) => stats(centreId, { signal }), [centreId])
  return useLive({ key: `stats:${centreId}`, load, stream: null, pollMs: STATS_POLL_MS })
}
