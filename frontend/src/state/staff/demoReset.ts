/* A reset said once to the whole tab, by a stream or by this tab's own reset button. */

type Listener = () => void

const listeners = new Set<Listener>()

export function announceDemoReset(): void {
  listeners.forEach((listener) => listener())
}

export function onDemoReset(listener: Listener): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}
