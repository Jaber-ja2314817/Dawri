import { useCallback, useEffect, useRef, useState } from 'react'
import { ApiError } from '../../api/client'
import { openEventStream, type EventStream } from '../../api/stream'

export type LiveState = 'loading' | 'ready' | 'error' | 'gone'
export type LiveMode = 'live' | 'polling'

const REOPEN_MS = 15_000

export interface UseLiveOptions<T> {
  /** A new key starts over with no data. */
  key: string
  load: (signal: AbortSignal) => Promise<T>
  /** The stream's whole URL. Null polls and never opens one. */
  stream: string | null
  pollMs?: number
  backstopMs?: number
}

export interface UseLive<T> {
  data: T | null
  state: LiveState
  error: unknown
  refetch: () => Promise<void>
  live: LiveMode
  updatedAt: number | null
}

/**
 * useVisit, for anything a console reads. Any event means "read again", the newest answer wins,
 * and a failed refresh keeps the last good data on screen.
 *
 * This holds one EventSource at most, and none while the page is hidden. Browsers allow six
 * HTTP/1.1 connections to an origin across all tabs, and each open stream keeps one for good,
 * so several console tabs on the demo laptop would otherwise leave API calls waiting forever.
 */
export function useLive<T>({
  key,
  load,
  stream: streamUrl,
  pollMs = 4_000,
  backstopMs = 20_000,
}: UseLiveOptions<T>): UseLive<T> {
  const [data, setData] = useState<T | null>(null)
  const [state, setState] = useState<LiveState>('loading')
  const [error, setError] = useState<unknown>(null)
  const [live, setLive] = useState<LiveMode>('polling')
  const [updatedAt, setUpdatedAt] = useState<number | null>(null)
  const refetchRef = useRef<() => Promise<void>>(async () => {})
  const loadRef = useRef(load)
  useEffect(() => {
    loadRef.current = load
  })

  useEffect(() => {
    const controller = new AbortController()
    let closed = false
    let asked = 0
    let answered = 0
    let stream: EventStream | null = null
    let pollTimer: ReturnType<typeof setInterval> | null = null
    let reopenTimer: ReturnType<typeof setTimeout> | null = null
    let backstop: ReturnType<typeof setInterval> | null = null

    setData(null)
    setState('loading')
    setError(null)
    setLive('polling')
    setUpdatedAt(null)

    const stopPolling = () => {
      if (pollTimer !== null) clearInterval(pollTimer)
      pollTimer = null
    }
    const startPolling = () => {
      if (pollTimer === null) pollTimer = setInterval(() => void refetch(), pollMs)
    }
    const stopReopen = () => {
      if (reopenTimer !== null) clearTimeout(reopenTimer)
      reopenTimer = null
    }
    const closeStream = () => {
      stream?.close()
      stream = null
    }
    const shutDown = () => {
      closed = true
      stopPolling()
      stopReopen()
      closeStream()
      if (backstop !== null) clearInterval(backstop)
      document.removeEventListener('visibilitychange', onVisibility)
    }

    const refetch = async () => {
      if (closed) return
      const ticket = ++asked
      try {
        const next = await loadRef.current(controller.signal)
        if (closed || ticket < answered) return // A newer answer is already on screen.
        answered = ticket
        setData(next)
        setState('ready')
        setError(null)
        setUpdatedAt(Date.now())
      } catch (cause) {
        if (closed || ticket < answered) return
        answered = ticket
        if (cause instanceof ApiError && cause.status === 404) {
          // What a demo reset leaves behind. Nothing here can come back.
          shutDown()
          controller.abort()
          setData(null)
          setState('gone')
          return
        }
        setError(cause)
        // A failed refresh keeps the last good data on screen.
        setState((current) => (current === 'ready' ? current : 'error'))
      }
    }
    refetchRef.current = refetch

    const open = () => {
      stopReopen()
      closeStream()
      if (streamUrl === null || document.visibilityState === 'hidden') {
        startPolling()
        return
      }
      const mine: EventStream | null = openEventStream(streamUrl, {
        onOpen: () => {
          if (stream !== mine) return
          stopPolling()
          stopReopen()
          setLive('live')
          void refetch() // Whatever happened while no stream was open.
        },
        onEvent: () => {
          if (stream === mine) void refetch()
        },
        onError: () => {
          if (stream !== mine) return
          stream = null
          setLive('polling')
          startPolling()
          if (!closed && reopenTimer === null) reopenTimer = setTimeout(open, REOPEN_MS)
        },
      })
      stream = mine
      if (mine === null) startPolling()
    }

    const onVisibility = () => {
      if (document.visibilityState === 'hidden') {
        stopReopen()
        closeStream()
        setLive('polling')
        startPolling()
        return
      }
      open()
      void refetch()
    }

    if (streamUrl !== null) backstop = setInterval(() => void refetch(), backstopMs)
    document.addEventListener('visibilitychange', onVisibility)
    void refetch()
    open()

    return () => {
      shutDown()
      controller.abort()
    }
  }, [key, streamUrl, pollMs, backstopMs])

  const refetch = useCallback(() => refetchRef.current(), [])

  return { data, state, error, refetch, live, updatedAt }
}
