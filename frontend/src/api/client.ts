import type { Lang, Translate } from '../i18n'
import { clearToken, getToken } from '../state/token'

export class ApiError extends Error {
  status: number
  code: string
  messageAr: string | undefined
  extra: Record<string, unknown>

  constructor(
    status: number,
    code: string,
    message: string,
    messageAr?: string,
    extra: Record<string, unknown> = {},
  ) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.code = code
    this.messageAr = messageAr
    this.extra = extra
  }
}

/** Where a request's bearer token comes from, and what a 401 ends. */
export interface TokenSource {
  get(): string | null
  clear(): void
}

const patientSource: TokenSource = { get: getToken, clear: clearToken }

interface ApiOptions {
  signal?: AbortSignal
  auth?: TokenSource
}

async function readJson(response: Response): Promise<unknown> {
  const text = await response.text()
  if (text === '') return null
  try {
    return JSON.parse(text)
  } catch {
    return undefined // A proxy's HTML page, for example.
  }
}

function toApiError(status: number, payload: unknown): ApiError {
  if (payload === null || typeof payload !== 'object' || !('error' in payload)) {
    return new ApiError(status, 'internal_error', 'Unexpected response from the server.')
  }
  const { error, message, message_ar, ...extra } = payload as Record<string, unknown>
  return new ApiError(
    status,
    String(error),
    typeof message === 'string' ? message : String(error),
    typeof message_ar === 'string' ? message_ar : undefined,
    extra,
  )
}

export async function api<T>(
  method: string,
  path: string,
  body?: unknown,
  { signal, auth = patientSource }: ApiOptions = {},
): Promise<T> {
  const token = auth.get()
  const headers: Record<string, string> = {}
  if (token !== null) headers.Authorization = `Bearer ${token}`

  let sent: BodyInit | undefined
  if (body instanceof FormData) {
    sent = body // The browser writes the multipart boundary.
  } else if (body !== undefined) {
    headers['Content-Type'] = 'application/json'
    sent = JSON.stringify(body)
  }

  let response: Response
  try {
    response = await fetch(path, { method, headers, body: sent, signal })
  } catch (cause) {
    if (cause instanceof DOMException && cause.name === 'AbortError') throw cause
    throw new ApiError(0, 'network', 'The network request failed.')
  }

  const payload = await readJson(response)
  if (response.ok) return payload as T

  const error = toApiError(response.status, payload)
  // invalid_otp is also a 401, and it is not the session ending.
  if (error.code === 'unauthorized' && token !== null && token === auth.get()) auth.clear()
  throw error
}

/** A sentence for the screen. Raw backend English never lands on an Arabic screen. */
export function errorText(err: unknown, t: Translate, lang: Lang): string {
  if (err instanceof ApiError) {
    if (err.messageAr !== undefined) return lang === 'ar' ? err.messageAr : err.message
    const key = `error.${err.code}`
    const text = t(key)
    if (text !== key) return text
  }
  return t('error.generic')
}
