import { useCallback, useRef, useState } from 'react'
import { walkIn } from '../../../api/staff'
import type { WalkInResponse } from '../../../api/staffTypes'

export interface WalkInState {
  /** Resolves true when the server answered 200, with a ticket or an emergency. */
  submit: (qid: string, complaint: string) => Promise<boolean>
  clear: () => void
  busy: boolean
  error: unknown
  result: WalkInResponse | null
}

/** One registration at a time, so an Enter on top of a click cannot register twice. */
export function useWalkIn(onDone: () => void): WalkInState {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)
  const [result, setResult] = useState<WalkInResponse | null>(null)
  const running = useRef(false)

  const submit = useCallback(
    async (qid: string, complaint: string) => {
      if (running.current) return false
      running.current = true
      setBusy(true)
      setError(null)
      setResult(null)
      try {
        setResult(await walkIn(qid, complaint))
        onDone()
        return true
      } catch (cause) {
        setError(cause)
        return false
      } finally {
        running.current = false
        setBusy(false)
      }
    },
    [onDone],
  )

  const clear = useCallback(() => setResult(null), [])

  return { submit, clear, busy, error, result }
}
