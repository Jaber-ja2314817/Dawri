import { api, ApiError } from '../../api/client'
import type { ChatMessage, ChatResponse } from '../../api/types'

export const TURN_TIMEOUT_MS = 45_000
export const MAX_TEXT = 2000

/** Mirrors the backend's NOT_A_QUESTION: the stored slot of a turn that asked nothing. */
export const SUMMARY_SLOT = 'summary'

/** Carries a signal, because the 45 s limit has to end the request. */
export const postTurn = (id: string, text: string, signal: AbortSignal) =>
  api<ChatResponse>(
    'POST',
    `/api/visits/${encodeURIComponent(id)}/chat`,
    { text },
    { signal },
  )

export const isAbort = (cause: unknown) =>
  cause instanceof DOMException && cause.name === 'AbortError'

/** The request may have reached the server, so only the visit can say what happened to it. */
export const isUnknownOutcome = (cause: unknown) =>
  isAbort(cause) || (cause instanceof ApiError && (cause.status === 0 || cause.status >= 500))

/** Only messages past the count from before the send: a patient can say "no" twice. */
export function isStored(messages: ChatMessage[], baseline: number, text: string): boolean {
  return messages.slice(baseline).some((m) => m.role === 'user' && m.content === text)
}

/** The server's read-back ends by asking; the card asks that itself, in the screen's language. */
export function withoutClosingQuestion(summary: string): string {
  return summary.replace(/\s*(Is this right\?|هل هذا صحيح؟)\s*$/, '')
}
