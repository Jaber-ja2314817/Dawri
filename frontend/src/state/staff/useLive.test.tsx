import { act, cleanup, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../api/client'
import { useLive } from './useLive'

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

  static get open() {
    return FakeEventSource.instances.filter((source) => !source.closed)
  }

  static get last() {
    return FakeEventSource.instances[FakeEventSource.instances.length - 1]
  }
}

const load = vi.fn<(signal: AbortSignal) => Promise<string>>()
const STREAM = '/api/counters/C1/stream?token=t'

const flush = () => act(() => vi.advanceTimersByTimeAsync(0))
const pass = (ms: number) => act(() => vi.advanceTimersByTimeAsync(ms))

let visibility: DocumentVisibilityState

async function setVisibility(next: DocumentVisibilityState) {
  visibility = next
  await act(async () => {
    document.dispatchEvent(new Event('visibilitychange'))
    await vi.advanceTimersByTimeAsync(0)
  })
}

const mount = (stream: string | null = STREAM) =>
  renderHook(() => useLive({ key: 'k', load, stream }))

beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal('EventSource', FakeEventSource)
  FakeEventSource.instances = []
  visibility = 'visible'
  vi.spyOn(document, 'visibilityState', 'get').mockImplementation(() => visibility)
  load.mockReset()
  load.mockResolvedValue('one')
})

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('useLive', () => {
  it('loads and opens the stream it was given', async () => {
    const { result } = mount()
    expect(result.current.state).toBe('loading')
    await flush()
    expect(result.current).toMatchObject({ state: 'ready', data: 'one', live: 'polling' })
    expect(result.current.updatedAt).not.toBeNull()
    expect(FakeEventSource.last.url).toBe(STREAM)
  })

  it('reads live once the stream opens, and any event refetches', async () => {
    const { result } = mount()
    await flush()
    act(() => FakeEventSource.last.onopen?.())
    await flush()
    expect(result.current.live).toBe('live')
    const before = load.mock.calls.length
    load.mockResolvedValue('two')
    act(() => FakeEventSource.last.onmessage?.())
    await flush()
    expect(load.mock.calls.length).toBe(before + 1)
    expect(result.current.data).toBe('two')
  })

  it('lets the newest answer win', async () => {
    const answers: ((value: string) => void)[] = []
    load.mockImplementation(() => new Promise((resolve) => answers.push(resolve)))
    const { result } = mount()
    await flush()
    act(() => FakeEventSource.last.onmessage?.())
    await flush()
    await act(async () => {
      answers[1]('new')
      await vi.advanceTimersByTimeAsync(0)
    })
    await act(async () => {
      answers[0]('old')
      await vi.advanceTimersByTimeAsync(0)
    })
    expect(result.current.data).toBe('new')
  })

  it('keeps the last good data when a refresh fails', async () => {
    const { result } = mount()
    await flush()
    load.mockRejectedValue(new ApiError(0, 'network', 'down'))
    act(() => FakeEventSource.last.onmessage?.())
    await flush()
    expect(result.current).toMatchObject({ state: 'ready', data: 'one' })
    expect(result.current.error).toBeInstanceOf(ApiError)
  })

  it('reports error when nothing has loaded yet', async () => {
    load.mockRejectedValue(new ApiError(0, 'network', 'down'))
    const { result } = mount()
    await flush()
    expect(result.current).toMatchObject({ state: 'error', data: null })
  })

  it('polls after a dropped stream and reopens after 15 s', async () => {
    const { result } = mount()
    await flush()
    act(() => FakeEventSource.last.onopen?.())
    await flush()
    const before = load.mock.calls.length
    act(() => {
      FakeEventSource.last.closed = true
      FakeEventSource.last.onerror?.()
    })
    expect(result.current.live).toBe('polling')
    await pass(4_000)
    expect(load.mock.calls.length).toBe(before + 1)
    expect(FakeEventSource.instances).toHaveLength(1)
    await pass(11_000)
    expect(FakeEventSource.instances).toHaveLength(2)
    act(() => FakeEventSource.last.onopen?.())
    await flush()
    expect(result.current.live).toBe('live')
    const settled = load.mock.calls.length
    await pass(4_000)
    expect(load.mock.calls.length).toBe(settled) // Live again, so polling stopped.
  })

  it('gives gone on a 404 and stops everything', async () => {
    const { result } = mount()
    await flush()
    load.mockRejectedValue(new ApiError(404, 'visit_not_found', 'gone'))
    act(() => FakeEventSource.last.onmessage?.())
    await flush()
    expect(result.current).toMatchObject({ state: 'gone', data: null })
    expect(FakeEventSource.open).toHaveLength(0)
    const after = load.mock.calls.length
    await pass(60_000)
    expect(load.mock.calls.length).toBe(after)
  })

  it('never opens a stream with stream null, and polls at pollMs alone', async () => {
    const { result } = renderHook(() =>
      useLive({ key: 'k', load, stream: null, pollMs: 5_000 }),
    )
    await flush()
    expect(FakeEventSource.instances).toHaveLength(0)
    expect(result.current.live).toBe('polling')
    expect(load).toHaveBeenCalledTimes(1)
    await pass(20_000)
    expect(load).toHaveBeenCalledTimes(5) // No backstop on top of the poll.
    expect(FakeEventSource.instances).toHaveLength(0)
  })

  it('closes the stream and polls while hidden, then reopens and refetches', async () => {
    const { result } = mount()
    await flush()
    act(() => FakeEventSource.last.onopen?.())
    await flush()
    expect(FakeEventSource.open).toHaveLength(1)

    await setVisibility('hidden')
    expect(FakeEventSource.open).toHaveLength(0)
    expect(result.current.live).toBe('polling')
    const hidden = load.mock.calls.length
    await pass(4_000)
    expect(load.mock.calls.length).toBe(hidden + 1)

    const before = load.mock.calls.length
    await setVisibility('visible')
    expect(FakeEventSource.open).toHaveLength(1)
    expect(FakeEventSource.instances).toHaveLength(2)
    expect(load.mock.calls.length).toBe(before + 1)
    act(() => FakeEventSource.last.onopen?.())
    await flush()
    expect(result.current.live).toBe('live')
  })

  it('opens nothing when it mounts in a hidden tab', async () => {
    visibility = 'hidden'
    const { result } = mount()
    await flush()
    expect(FakeEventSource.instances).toHaveLength(0)
    expect(result.current).toMatchObject({ state: 'ready', live: 'polling' })
    await setVisibility('visible')
    expect(FakeEventSource.open).toHaveLength(1)
  })

  it('a reopen timer cannot open a stream in a hidden tab', async () => {
    mount()
    await flush()
    act(() => {
      FakeEventSource.last.closed = true
      FakeEventSource.last.onerror?.()
    })
    await setVisibility('hidden')
    await pass(30_000)
    expect(FakeEventSource.instances).toHaveLength(1)
    expect(FakeEventSource.open).toHaveLength(0)
  })

  it('holds one EventSource at most through any run of tab switches', async () => {
    mount()
    await flush()
    for (let turn = 0; turn < 5; turn += 1) {
      await setVisibility('hidden')
      expect(FakeEventSource.open).toHaveLength(0)
      await setVisibility('visible')
      await setVisibility('visible') // A browser may repeat itself.
      expect(FakeEventSource.open).toHaveLength(1)
    }
  })

  it('ignores a closed stream that still fires', async () => {
    const { result } = mount()
    await flush()
    const first = FakeEventSource.last
    await setVisibility('hidden')
    await setVisibility('visible')
    act(() => first.onopen?.())
    await flush()
    expect(result.current.live).toBe('polling')
  })

  it('closes the stream on unmount and on a new key', async () => {
    const { rerender, unmount } = renderHook(({ key }) => useLive({ key, load, stream: STREAM }), {
      initialProps: { key: 'a' },
    })
    await flush()
    rerender({ key: 'b' })
    await flush()
    expect(FakeEventSource.open).toHaveLength(1)
    unmount()
    expect(FakeEventSource.open).toHaveLength(0)
  })

  it('stays with a poll where EventSource does not exist', async () => {
    vi.stubGlobal('EventSource', undefined)
    const { result } = mount()
    await flush()
    expect(result.current.live).toBe('polling')
    const before = load.mock.calls.length
    await pass(4_000)
    expect(load.mock.calls.length).toBe(before + 1)
  })
})
