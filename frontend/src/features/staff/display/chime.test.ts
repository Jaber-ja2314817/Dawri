import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

class FakeAudio {
  static blocked = false
  state = 'suspended'
  currentTime = 0
  destination = {}
  oscillators = 0

  async resume() {
    if (FakeAudio.blocked) throw new Error('blocked')
    this.state = 'running'
  }

  createOscillator() {
    this.oscillators += 1
    fake = this
    return { frequency: {}, connect: vi.fn(), start: vi.fn(), stop: vi.fn() }
  }

  createGain() {
    return {
      gain: { setValueAtTime: vi.fn(), exponentialRampToValueAtTime: vi.fn() },
      connect: vi.fn(),
    }
  }
}

let fake: FakeAudio | null = null

/* The module keeps its context, so each test takes a fresh copy. */
async function chime() {
  vi.resetModules()
  return import('./chime')
}

beforeEach(() => {
  FakeAudio.blocked = false
  fake = null
  vi.stubGlobal('AudioContext', FakeAudio)
})

afterEach(() => vi.unstubAllGlobals())

describe('the chime', () => {
  it('plays nothing before a gesture', async () => {
    const { playChime } = await chime()
    expect(playChime()).toBe(false)
  })

  it('plays two tones once unlocked', async () => {
    const { playChime, unlockSound } = await chime()
    await expect(unlockSound()).resolves.toBe(true)
    expect(playChime()).toBe(true)
    expect(fake?.oscillators).toBe(2)
  })

  it('stays silent, and throws nothing, when the browser refuses', async () => {
    FakeAudio.blocked = true
    const { playChime, unlockSound } = await chime()
    await expect(unlockSound()).resolves.toBe(false)
    expect(playChime()).toBe(false)
  })

  it('stays silent, and throws nothing, with no Web Audio at all', async () => {
    vi.stubGlobal('AudioContext', undefined)
    const { playChime, unlockSound } = await chime()
    await expect(unlockSound()).resolves.toBe(false)
    expect(playChime()).toBe(false)
  })
})
