import { useEffect, useState } from 'react'

/** Whole seconds left, never below 0. Null when the server gave no usable time. */
export function secondsLeft(expiresAt: string | null, now: number): number | null {
  if (expiresAt === null) return null
  // The backend writes microseconds, which not every browser parses.
  const end = Date.parse(expiresAt.replace(/(\.\d{3})\d+/, '$1'))
  if (Number.isNaN(end)) return null
  return Math.max(0, Math.ceil((end - now) / 1000))
}

export function formatCountdown(seconds: number): string {
  const minutes = Math.floor(seconds / 60)
  const rest = seconds % 60
  return `${String(minutes).padStart(2, '0')}:${String(rest).padStart(2, '0')}`
}

/** Read from the clock on every tick, so a phone that slept shows the true time. */
export function useCountdown(expiresAt: string | null): number | null {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    setNow(Date.now())
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [expiresAt])

  return secondsLeft(expiresAt, now)
}
