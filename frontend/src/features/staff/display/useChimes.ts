import { useCallback, useEffect, useRef, useState } from 'react'
import type { DisplaySnapshot } from '../../../api/staffTypes'
import { servingChanges } from './changes'
import { playChime, unlockSound } from './chime'

const MARK_MS = 6_000
const NONE: ReadonlySet<string> = new Set()

export interface Chimes {
  /** Every change so far, heard or not. */
  chimes: number
  /** Counter ids marked for the last few seconds. */
  marked: ReadonlySet<string>
  sound: boolean
  soundFailed: boolean
  toggleSound: () => void
}

/** Reads each snapshot once, in order, and answers the changes in it with one chime. */
export function useChimes(snapshot: DisplaySnapshot | null): Chimes {
  const [chimes, setChimes] = useState(0)
  const [marked, setMarked] = useState(NONE)
  const [sound, setSound] = useState(false)
  const [soundFailed, setSoundFailed] = useState(false)
  const last = useRef<DisplaySnapshot | null>(null)
  const soundOn = useRef(false)
  const timers = useRef(new Map<string, ReturnType<typeof setTimeout>>())

  useEffect(() => {
    soundOn.current = sound
  }, [sound])

  useEffect(() => {
    if (snapshot === null || snapshot === last.current) return
    const changes = servingChanges(last.current, snapshot)
    last.current = snapshot
    if (changes.length === 0) return

    setChimes((count) => count + changes.length)
    setMarked((current) => new Set([...current, ...changes.map((change) => change.counterId)]))
    for (const { counterId } of changes) {
      clearTimeout(timers.current.get(counterId))
      timers.current.set(
        counterId,
        setTimeout(() => {
          timers.current.delete(counterId)
          setMarked((current) => new Set([...current].filter((id) => id !== counterId)))
        }, MARK_MS),
      )
    }
    if (soundOn.current) playChime()
  }, [snapshot])

  useEffect(() => {
    const pending = timers.current
    return () => {
      pending.forEach((timer) => clearTimeout(timer))
      pending.clear()
    }
  }, [])

  const toggleSound = useCallback(() => {
    if (soundOn.current) {
      setSound(false)
      return
    }
    void unlockSound().then((ready) => {
      setSound(ready)
      setSoundFailed(!ready)
      if (ready) playChime() // So whoever set up the screen hears the volume.
    })
  }, [])

  return { chimes, marked, sound, soundFailed, toggleSound }
}
