import type { TileLayer } from 'leaflet'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { TILE_GRACE_MS, TILE_TIMEOUT_MS, watchTiles } from './tiles'

function fakeLayer() {
  const handlers = new Map<string, () => void>()
  const layer = {
    on: (name: string, handler: () => void) => handlers.set(name, handler),
    off: (name: string) => handlers.delete(name),
  }
  return {
    layer: layer as unknown as TileLayer,
    fire: (name: string) => handlers.get(name)?.(),
    handlers,
  }
}

function setOnline(value: boolean) {
  Object.defineProperty(navigator, 'onLine', { configurable: true, value })
}

beforeEach(() => {
  vi.useFakeTimers()
  setOnline(true)
})
afterEach(() => {
  vi.useRealTimers()
  setOnline(true)
})

describe('watchTiles', () => {
  it('fails after three errors with no tile loaded', () => {
    const { layer, fire } = fakeLayer()
    const onFail = vi.fn()
    watchTiles(layer, onFail)
    fire('tileerror')
    fire('tileerror')
    expect(onFail).not.toHaveBeenCalled()
    fire('tileerror')
    expect(onFail).not.toHaveBeenCalled()
    vi.advanceTimersByTime(TILE_GRACE_MS)
    expect(onFail).toHaveBeenCalledTimes(1)
    expect(onFail).toHaveBeenCalledWith('tiles')
  })

  it('keeps the map when a good tile lands inside the grace', () => {
    const { layer, fire } = fakeLayer()
    const onFail = vi.fn()
    watchTiles(layer, onFail)
    fire('tileerror')
    fire('tileerror')
    fire('tileerror')
    vi.advanceTimersByTime(TILE_GRACE_MS - 1)
    fire('tileload')
    vi.advanceTimersByTime(TILE_TIMEOUT_MS * 2)
    expect(onFail).not.toHaveBeenCalled()
  })

  it('fails once when no tile arrives in time', () => {
    const { layer } = fakeLayer()
    const onFail = vi.fn()
    watchTiles(layer, onFail)
    vi.advanceTimersByTime(TILE_TIMEOUT_MS - 1)
    expect(onFail).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(onFail).toHaveBeenCalledTimes(1)
    expect(onFail).toHaveBeenCalledWith('timeout')
  })

  it('stops watching for good once a tile has loaded', () => {
    const { layer, fire, handlers } = fakeLayer()
    const onFail = vi.fn()
    watchTiles(layer, onFail)
    fire('tileerror')
    fire('tileload')
    expect(handlers.size).toBe(0)
    vi.advanceTimersByTime(TILE_TIMEOUT_MS * 2)
    expect(onFail).not.toHaveBeenCalled()
  })

  it('fails soon when the browser is offline', () => {
    setOnline(false)
    const { layer, handlers } = fakeLayer()
    const onFail = vi.fn()
    watchTiles(layer, onFail)
    expect(onFail).not.toHaveBeenCalled()
    vi.advanceTimersByTime(TILE_GRACE_MS)
    expect(onFail).toHaveBeenCalledTimes(1)
    expect(onFail).toHaveBeenCalledWith('offline')
    expect(handlers.size).toBe(0)
    vi.advanceTimersByTime(TILE_TIMEOUT_MS)
    expect(onFail).toHaveBeenCalledTimes(1)
  })

  it('takes one offline reading back when a tile loads anyway', () => {
    setOnline(false)
    const { layer, fire } = fakeLayer()
    const onFail = vi.fn()
    watchTiles(layer, onFail)
    fire('tileload')
    vi.advanceTimersByTime(TILE_TIMEOUT_MS * 2)
    expect(onFail).not.toHaveBeenCalled()
  })

  it('does nothing after being stopped', () => {
    const { layer } = fakeLayer()
    const onFail = vi.fn()
    watchTiles(layer, onFail)()
    vi.advanceTimersByTime(TILE_TIMEOUT_MS)
    expect(onFail).not.toHaveBeenCalled()
  })
})
