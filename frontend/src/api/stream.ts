export interface EventStreamHandlers {
  onOpen: () => void
  onEvent: () => void
  onError: () => void
}

export interface EventStream {
  close: () => void
}

export type VisitStreamHandlers = EventStreamHandlers
export type VisitStream = EventStream

/** The token goes in the URL because EventSource cannot send headers. */
export function streamUrl(id: string, token: string): string {
  return `/api/visits/${encodeURIComponent(id)}/stream?token=${encodeURIComponent(token)}`
}

/**
 * Events are small and carry nothing a screen should trust, so any of them just means
 * "read it again". The caller decides when to retry, so an error closes the stream
 * instead of leaving EventSource's own reconnection running beside the caller's.
 */
export function openEventStream(url: string, handlers: EventStreamHandlers): EventStream | null {
  if (typeof EventSource === 'undefined') return null
  const source = new EventSource(url)
  source.onopen = () => handlers.onOpen()
  source.onmessage = () => handlers.onEvent()
  source.onerror = () => {
    source.close()
    handlers.onError()
  }
  return { close: () => source.close() }
}

export function openVisitStream(
  id: string,
  token: string,
  handlers: VisitStreamHandlers,
): VisitStream | null {
  return openEventStream(streamUrl(id, token), handlers)
}
