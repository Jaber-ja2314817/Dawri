import { act, cleanup, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../api/client'
import type { Visit } from '../api/types'
import { clearToken, setToken } from './token'
import { useVisit } from './useVisit'

class FakeEventSource {
  static instances: FakeEventSource[] = []
  onopen: (() => void) | null = null
  onmessage: (() => void) | null = null
  onerror: (() => void) | null = null
  closed = false
  url: string

  constructor(url: string) {
    this.url = url
    FakeEventSource.instances.push(this)
  }

  close() {
    this.closed = true
  }

  static get last() {
    return FakeEventSource.instances[FakeEventSource.instances.length - 1]
  }
}

const getVisit = vi.hoisted(() => vi.fn())
vi.mock('../api/endpoints', () => ({ getVisit }))

const visit = (status: Visit['status'] = 'reserved') => ({ visit_id: 'V1', status }) as Visit

const flush = () => act(() => vi.advanceTimersByTimeAsync(0))
const pass = (ms: number) => act(() => vi.advanceTimersByTimeAsync(ms))

beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal('EventSource', FakeEventSource)
  FakeEventSource.instances = []
  getVisit.mockReset()
  getVisit.mockResolvedValue(visit())
  setToken('tok en')
})

afterEach(() => {
  cleanup()
  clearToken()
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('useVisit', () => {
  it('loads the visit and passes the token to the stream', async () => {
    const { result } = renderHook(() => useVisit('V1'))
    expect(result.current.state).toBe('loading')
    await flush()
    expect(result.current.state).toBe('ready')
    expect(result.current.visit?.status).toBe('reserved')
    expect(result.current.updatedAt).not.toBeNull()
    expect(FakeEventSource.last.url).toBe('/api/visits/V1/stream?token=tok%20en')
  })

  it('refetches on any stream event', async () => {
    const { result } = renderHook(() => useVisit('V1'))
    await flush()
    act(() => FakeEventSource.last.onopen?.())
    await flush()
    expect(result.current.live).toBe('live')
    const before = getVisit.mock.calls.length
    getVisit.mockResolvedValue(visit('in_triage'))
    act(() => FakeEventSource.last.onmessage?.())
    await flush()
    expect(getVisit.mock.calls.length).toBe(before + 1)
    expect(result.current.visit?.status).toBe('in_triage')
  })

  it('polls every 4 s after a stream error', async () => {
    const { result } = renderHook(() => useVisit('V1'))
    await flush()
    act(() => FakeEventSource.last.onopen?.())
    await flush()
    act(() => FakeEventSource.last.onerror?.())
    expect(result.current.live).toBe('polling')
    expect(FakeEventSource.last.closed).toBe(true)
    const before = getVisit.mock.calls.length
    await pass(4_000)
    expect(getVisit.mock.calls.length).toBe(before + 1)
    await pass(4_000)
    expect(getVisit.mock.calls.length).toBe(before + 2)
  })

  it('retries the stream every 15 s until one opens, and that stops the polling', async () => {
    const { result } = renderHook(() => useVisit('V1'))
    await flush()
    act(() => FakeEventSource.last.onerror?.())
    expect(FakeEventSource.instances).toHaveLength(1)
    await pass(15_000)
    expect(FakeEventSource.instances).toHaveLength(2)
    act(() => FakeEventSource.last.onerror?.())
    await pass(15_000)
    expect(FakeEventSource.instances).toHaveLength(3)

    act(() => FakeEventSource.last.onopen?.())
    await flush()
    expect(result.current.live).toBe('live')
    const before = getVisit.mock.calls.length
    await pass(8_000)
    expect(getVisit.mock.calls.length).toBe(before)
    expect(FakeEventSource.instances).toHaveLength(3)
  })

  it('still runs the 20 s backstop while the stream is healthy', async () => {
    renderHook(() => useVisit('V1'))
    await flush()
    act(() => FakeEventSource.last.onopen?.())
    await flush()
    const before = getVisit.mock.calls.length
    await pass(19_999)
    expect(getVisit.mock.calls.length).toBe(before)
    await pass(1)
    expect(getVisit.mock.calls.length).toBe(before + 1)
  })

  it('refetches when the page becomes visible', async () => {
    renderHook(() => useVisit('V1'))
    await flush()
    const before = getVisit.mock.calls.length
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
    act(() => void document.dispatchEvent(new Event('visibilitychange')))
    await flush()
    expect(getVisit.mock.calls.length).toBe(before + 1)
  })

  it('ignores an answer older than the one on screen', async () => {
    let answerFirst: (value: Visit) => void = () => {}
    getVisit.mockImplementationOnce(() => new Promise((resolve) => (answerFirst = resolve)))
    const { result } = renderHook(() => useVisit('V1'))
    await flush()
    getVisit.mockResolvedValue(visit('in_doctor'))
    await act(() => result.current.refetch())
    expect(result.current.visit?.status).toBe('in_doctor')
    answerFirst(visit('reserved'))
    await flush()
    expect(result.current.visit?.status).toBe('in_doctor')
  })

  it('goes to gone on a 404 and stops everything', async () => {
    const { result } = renderHook(() => useVisit('V1'))
    await flush()
    act(() => FakeEventSource.last.onopen?.())
    await flush()
    const stream = FakeEventSource.last
    getVisit.mockRejectedValue(new ApiError(404, 'visit_not_found', 'Gone'))
    act(() => stream.onmessage?.())
    await flush()
    expect(result.current.state).toBe('gone')
    expect(result.current.visit).toBeNull()
    expect(stream.closed).toBe(true)
    const before = getVisit.mock.calls.length
    await pass(60_000)
    expect(getVisit.mock.calls.length).toBe(before)
    expect(FakeEventSource.instances).toHaveLength(1)
  })

  it('shows an error when nothing has loaded, and keeps old data when a refresh fails', async () => {
    getVisit.mockRejectedValueOnce(new ApiError(0, 'network', 'Down'))
    const { result } = renderHook(() => useVisit('V1'))
    await flush()
    expect(result.current.state).toBe('error')

    await act(() => result.current.refetch())
    expect(result.current.state).toBe('ready')

    getVisit.mockRejectedValueOnce(new ApiError(0, 'network', 'Down'))
    await act(() => result.current.refetch())
    expect(result.current.state).toBe('ready')
    expect(result.current.visit?.status).toBe('reserved')
  })

  it('cleans up on unmount', async () => {
    const remove = vi.spyOn(document, 'removeEventListener')
    const { unmount } = renderHook(() => useVisit('V1'))
    await flush()
    act(() => FakeEventSource.last.onerror?.())
    await pass(15_000)
    const stream = FakeEventSource.last
    unmount()
    expect(stream.closed).toBe(true)
    expect(remove).toHaveBeenCalledWith('visibilitychange', expect.any(Function))
    const before = getVisit.mock.calls.length
    await pass(60_000)
    expect(getVisit.mock.calls.length).toBe(before)
    expect(FakeEventSource.instances).toHaveLength(2)
  })

  it('polls when the browser has no EventSource', async () => {
    vi.stubGlobal('EventSource', undefined)
    renderHook(() => useVisit('V1'))
    await flush()
    const before = getVisit.mock.calls.length
    await pass(4_000)
    expect(getVisit.mock.calls.length).toBe(before + 1)
  })
})
