import { useEffect, useState } from 'react'

const WIDE = '(min-width: 768px)'

const query = () => (typeof window.matchMedia === 'function' ? window.matchMedia(WIDE) : null)

/** Whether there is room for the list and the map side by side. */
export function useWide(): boolean {
  const [wide, setWide] = useState(() => query()?.matches ?? false)

  useEffect(() => {
    const media = query()
    if (media === null) return
    const onChange = () => setWide(media.matches)
    onChange()
    media.addEventListener('change', onChange)
    return () => media.removeEventListener('change', onChange)
  }, [])

  return wide
}
