import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { translate, type Lang } from '../i18n'
import { clearToken, getToken, setToken } from '../state/token'
import { api, ApiError, errorText, type TokenSource } from './client'
import { transcribe } from './endpoints'

const respond = (status: number, body: unknown) =>
  new Response(typeof body === 'string' ? body : JSON.stringify(body), { status })

const fetchMock = vi.fn<typeof fetch>()

const textIn = (lang: Lang, err: unknown) =>
  errorText(err, (key, vars) => translate(lang, key, vars), lang)

beforeEach(() => {
  clearToken()
  fetchMock.mockReset()
  vi.stubGlobal('fetch', fetchMock)
})
afterEach(() => vi.unstubAllGlobals())

describe('api', () => {
  it('adds the bearer token and sends JSON', async () => {
    setToken('abc')
    fetchMock.mockResolvedValue(respond(200, { ok: true }))
    await expect(api('POST', '/api/x', { a: 1 })).resolves.toEqual({ ok: true })
    const [path, init] = fetchMock.mock.calls[0]
    expect(path).toBe('/api/x')
    expect(init?.body).toBe('{"a":1}')
    expect(init?.headers).toMatchObject({
      Authorization: 'Bearer abc',
      'Content-Type': 'application/json',
    })
  })

  it('leaves multipart to the browser', async () => {
    fetchMock.mockResolvedValue(respond(200, { text: 'hello' }))
    await transcribe(new Blob(['RIFF'], { type: 'audio/wav' }))
    const init = fetchMock.mock.calls[0][1]
    expect(init?.body).toBeInstanceOf(FormData)
    const audio = (init?.body as FormData).get('audio') as File
    expect(audio.name).toBe('audio.wav')
    expect(init?.headers).not.toHaveProperty('Content-Type')
  })

  it('throws the backend error with its extras', async () => {
    fetchMock.mockResolvedValue(
      respond(409, { error: 'too_far', message: 'Not there yet', distance_m: 200 }),
    )
    const err = await api('POST', '/api/x').catch((cause: ApiError) => cause)
    expect(err).toBeInstanceOf(ApiError)
    expect(err).toMatchObject({ status: 409, code: 'too_far', message: 'Not there yet' })
    expect((err as ApiError).extra).toEqual({ distance_m: 200 })
  })

  it('carries message_ar', async () => {
    fetchMock.mockResolvedValue(respond(503, { error: 'asr_unavailable', message: 'No', message_ar: 'لا' }))
    const err = await api('POST', '/api/asr').catch((cause: ApiError) => cause)
    expect((err as ApiError).messageAr).toBe('لا')
  })

  it('gives code network when the request never lands', async () => {
    fetchMock.mockRejectedValue(new TypeError('Failed to fetch'))
    await expect(api('GET', '/api/x')).rejects.toMatchObject({ status: 0, code: 'network' })
  })

  it('does not turn a cancelled request into a network error', async () => {
    fetchMock.mockRejectedValue(new DOMException('stopped', 'AbortError'))
    await expect(api('GET', '/api/x')).rejects.toMatchObject({ name: 'AbortError' })
  })

  it('handles a page that is not JSON', async () => {
    fetchMock.mockResolvedValue(respond(502, '<html>Bad gateway</html>'))
    await expect(api('GET', '/api/x')).rejects.toMatchObject({ code: 'internal_error' })
  })

  it('clears the session on a 401', async () => {
    setToken('abc')
    fetchMock.mockResolvedValue(respond(401, { error: 'unauthorized', message: 'No' }))
    await expect(api('GET', '/api/me')).rejects.toBeInstanceOf(ApiError)
    expect(getToken()).toBeNull()
  })

  it('keeps a newer session when an old request comes back 401', async () => {
    setToken('old')
    fetchMock.mockImplementation(async () => {
      setToken('new')
      return respond(401, { error: 'unauthorized', message: 'No' })
    })
    await expect(api('GET', '/api/me')).rejects.toBeInstanceOf(ApiError)
    expect(getToken()).toBe('new')
  })

  it('treats a wrong code as a wrong code, not a lost session', async () => {
    setToken('abc')
    fetchMock.mockResolvedValue(respond(401, { error: 'invalid_otp', message: 'No' }))
    await expect(api('POST', '/api/auth/verify')).rejects.toMatchObject({ code: 'invalid_otp' })
    expect(getToken()).toBe('abc')
  })
})

describe('api with another token source', () => {
  const staffSide = (start: string | null) => {
    let token = start
    const source: TokenSource = {
      get: () => token,
      clear: () => {
        token = null
      },
    }
    return source
  }

  it('sends that token and not the patient token', async () => {
    setToken('patient')
    fetchMock.mockResolvedValue(respond(200, {}))
    await api('GET', '/api/x', undefined, { auth: staffSide('staff') })
    expect(fetchMock.mock.calls[0][1]?.headers).toMatchObject({ Authorization: 'Bearer staff' })
  })

  it('sends no token at all when that source has none, even with a patient signed in', async () => {
    setToken('patient')
    fetchMock.mockResolvedValue(respond(200, {}))
    await api('GET', '/api/x', undefined, { auth: staffSide(null) })
    expect(fetchMock.mock.calls[0][1]?.headers).not.toHaveProperty('Authorization')
  })

  it('a 401 clears only the source that was used', async () => {
    setToken('patient')
    const source = staffSide('staff')
    fetchMock.mockResolvedValue(respond(401, { error: 'unauthorized', message: 'No' }))
    await expect(api('GET', '/api/x', undefined, { auth: source })).rejects.toBeInstanceOf(ApiError)
    expect(source.get()).toBeNull()
    expect(getToken()).toBe('patient')
  })
})

describe('errorText', () => {
  it('prefers message_ar in Arabic', () => {
    expect(textIn('ar', new ApiError(503, 'asr_unavailable', 'English', 'عربي'))).toBe('عربي')
  })

  it('uses the backend English beside a message_ar', () => {
    expect(textIn('en', new ApiError(503, 'asr_unavailable', 'English', 'عربي'))).toBe('English')
  })

  it('uses the i18n key otherwise', () => {
    const err = new ApiError(404, 'unknown_qid', 'No demo patient has this QID.')
    expect(textIn('ar', err)).toBe('لا يوجد مريض تجريبي بهذا الرقم.')
  })

  it('never puts raw English on an Arabic screen', () => {
    const err = new ApiError(400, 'something_new', 'Raw backend English')
    expect(textIn('ar', err)).toBe(translate('ar', 'error.generic'))
  })

  it('has a line for anything that is not an ApiError', () => {
    expect(textIn('en', new Error('boom'))).toBe(translate('en', 'error.generic'))
  })
})
