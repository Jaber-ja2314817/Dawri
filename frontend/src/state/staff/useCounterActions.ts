import { useCallback, useEffect, useRef, useState } from 'react'
import { callNext, notHere as markNotHere, serveTicket } from '../../api/staff'
import type { CallNext, StaffTicket } from '../../api/staffTypes'
import { onDemoReset } from './demoReset'

export interface CounterActions {
  /** Resolves to null on failure: the reason is in `error`, for errorText. */
  callNext: () => Promise<CallNext | null>
  serve: (ticketId: string) => Promise<StaffTicket | null>
  notHere: (ticketId: string) => Promise<StaffTicket | null>
  busy: boolean
  error: unknown
  /**
   * The last call's result, kept for "handled by a colleague" and for a call that found nobody.
   * A demo reset clears it: the tickets it names are back in the queue.
   */
  lastCall: CallNext | null
}

/** One action at a time. A second tap while one runs does nothing. */
export function useCounterActions(counterId: string, onDone?: () => void): CounterActions {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)
  const [lastCall, setLastCall] = useState<CallNext | null>(null)
  const running = useRef(false)

  useEffect(() => onDemoReset(() => setLastCall(null)), [])

  const run = useCallback(
    async <T,>(action: () => Promise<T>): Promise<T | null> => {
      if (running.current) return null
      running.current = true
      setBusy(true)
      setError(null)
      try {
        const result = await action()
        onDone?.()
        return result
      } catch (cause) {
        setError(cause)
        return null
      } finally {
        running.current = false
        setBusy(false)
      }
    },
    [onDone],
  )

  const call = useCallback(async () => {
    const result = await run(() => callNext(counterId))
    if (result !== null) setLastCall(result)
    return result
  }, [run, counterId])
  const serve = useCallback((ticketId: string) => run(() => serveTicket(ticketId)), [run])
  const notHere = useCallback((ticketId: string) => run(() => markNotHere(ticketId)), [run])

  return { callNext: call, serve, notHere, busy, error, lastCall }
}
