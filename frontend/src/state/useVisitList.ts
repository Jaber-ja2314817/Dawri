import { useCallback, useEffect, useRef, useState } from 'react'
import { listVisits } from '../api/endpoints'
import type { VisitRow } from '../api/types'

export type ListState = 'loading' | 'ready' | 'error'

export function useVisitList() {
  const [rows, setRows] = useState<VisitRow[]>([])
  const [state, setState] = useState<ListState>('loading')
  const [error, setError] = useState<unknown>(null)
  const controller = useRef<AbortController | null>(null)

  const load = useCallback(async () => {
    controller.current?.abort()
    const mine = new AbortController()
    controller.current = mine
    setState('loading')
    try {
      const next = await listVisits({ signal: mine.signal })
      if (mine.signal.aborted) return
      setRows(next)
      setState('ready')
    } catch (cause) {
      if (mine.signal.aborted) return
      setError(cause)
      setState('error')
    }
  }, [])

  useEffect(() => {
    void load()
    return () => controller.current?.abort()
  }, [load])

  return { rows, state, error, retry: load }
}
