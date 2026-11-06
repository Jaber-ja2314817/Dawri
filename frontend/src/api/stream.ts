export interface VisitStreamHandlers {
  onOpen: () => void
  onEvent: () => void
  onError: () => void
}

export interface VisitStream {
  close: () => void
}

/** The token goes in the URL because EventSource cannot send headers. */
export function streamUrl(id: string, token: string): string {
  return `/api/visits/${encodeURIComponent(id)}/stream?token=${encodeURIComponent(token)}`
}

/**
 * Events are small and carry nothing a screen should trust, so any of them just means
 * "read the visit again". The caller decides when to retry, so an error closes the stream
 * instead of leaving EventSource's own reconnection running beside the caller's.
 */
export function openVisitStream(
  id: string,
  token: string,
  handlers: VisitStreamHandlers,
): VisitStream | null {
  if (typeof EventSource === 'undefined') return null
  const source = new EventSource(streamUrl(id, token))
  source.onopen = () => handlers.onOpen()
  source.onmessage = () => handlers.onEvent()
  source.onerror = () => {
    source.close()
    handlers.onError()
  }
  return { close: () => source.close() }
}
