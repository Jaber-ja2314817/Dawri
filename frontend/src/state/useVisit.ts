import { useCallback, useEffect, useRef, useState } from 'react'
import { ApiError } from '../api/client'
import { getVisit } from '../api/endpoints'
import { openVisitStream, type VisitStream } from '../api/stream'
import type { Visit } from '../api/types'
import { getToken } from './token'

export type VisitState = 'loading' | 'ready' | 'error' | 'gone'
export type LiveMode = 'live' | 'polling'

const POLL_MS = 4_000
const REOPEN_MS = 15_000
const BACKSTOP_MS = 20_000

export interface UseVisit {
  visit: Visit | null
  state: VisitState
  error: unknown
  refetch: () => Promise<void>
  live: LiveMode
  updatedAt: number | null
}

export function useVisit(id: string): UseVisit {
  const [visit, setVisit] = useState<Visit | null>(null)
  const [state, setState] = useState<VisitState>('loading')
  const [error, setError] = useState<unknown>(null)
  const [live, setLive] = useState<LiveMode>('polling')
  const [updatedAt, setUpdatedAt] = useState<number | null>(null)
  const refetchRef = useRef<() => Promise<void>>(async () => {})

  useEffect(() => {
    const controller = new AbortController()
    let closed = false
    let asked = 0
    let answered = 0
    let stream: VisitStream | null = null
    let pollTimer: ReturnType<typeof setInterval> | null = null
    let reopenTimer: ReturnType<typeof setTimeout> | null = null

    setVisit(null)
    setState('loading')
    setError(null)
    setLive('polling')
    setUpdatedAt(null)

    const stopPolling = () => {
      if (pollTimer !== null) clearInterval(pollTimer)
      pollTimer = null
    }
    const stopReopen = () => {
      if (reopenTimer !== null) clearTimeout(reopenTimer)
      reopenTimer = null
    }
    const shutDown = () => {
      closed = true
      stopPolling()
      stopReopen()
      clearInterval(backstop)
      stream?.close()
      stream = null
      document.removeEventListener('visibilitychange', onVisibility)
    }

    const refetch = async () => {
      if (closed) return
      const ticket = ++asked
      try {
        const next = await getVisit(id, { signal: controller.signal })
        if (closed || ticket < answered) return // A newer answer is already on screen.
        answered = ticket
        setVisit(next)
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
          setVisit(null)
          setState('gone')
          return
        }
        setError(cause)
        // A failed refresh keeps the last good visit on screen.
        setState((current) => (current === 'ready' ? current : 'error'))
      }
    }
    refetchRef.current = refetch

    const startPolling = () => {
      if (pollTimer === null) pollTimer = setInterval(() => void refetch(), POLL_MS)
    }

    const open = () => {
      stopReopen()
      const token = getToken()
      stream =
        token === null
          ? null
          : openVisitStream(id, token, {
              onOpen: () => {
                stopPolling()
                stopReopen()
                setLive('live')
                void refetch() // Whatever happened while no stream was open.
              },
              onEvent: () => void refetch(),
              onError: () => {
                stream = null
                setLive('polling')
                startPolling()
                if (!closed && reopenTimer === null) reopenTimer = setTimeout(open, REOPEN_MS)
              },
            })
      if (stream === null) startPolling()
    }

    const onVisibility = () => {
      if (document.visibilityState === 'visible') void refetch()
    }

    const backstop = setInterval(() => void refetch(), BACKSTOP_MS)
    document.addEventListener('visibilitychange', onVisibility)
    void refetch()
    open()

    return () => {
      shutDown()
      controller.abort()
    }
  }, [id])

  const refetch = useCallback(() => refetchRef.current(), [])

  return { visit, state, error, refetch, live, updatedAt }
}
