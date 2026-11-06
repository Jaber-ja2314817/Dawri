import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { RecorderError, startRecording, type Recording } from './recorder'

class FakeRecorder {
  static instances: FakeRecorder[] = []
  static supported = ['audio/webm;codecs=opus', 'audio/webm']
  static startFails = false
  static isTypeSupported = (type: string) => FakeRecorder.supported.includes(type)

  state: RecordingState = 'inactive'
  mimeType: string
  options: MediaRecorderOptions | undefined
  ondataavailable: ((event: { data: Blob }) => void) | null = null
  onstop: (() => void) | null = null
  onerror: (() => void) | null = null

  constructor(_stream: MediaStream, options?: MediaRecorderOptions) {
    this.options = options
    this.mimeType = options?.mimeType ?? ''
    FakeRecorder.instances.push(this)
  }

  start() {
    if (FakeRecorder.startFails) throw new Error('no')
    this.state = 'recording'
  }

  stop() {
    this.state = 'inactive'
    this.ondataavailable?.({ data: new Blob(['abc']) })
    this.onstop?.()
  }

  static get last() {
    return FakeRecorder.instances[FakeRecorder.instances.length - 1]
  }
}

function fakeStream() {
  const tracks = [{ stop: vi.fn() }, { stop: vi.fn() }]
  return { tracks, stream: { getTracks: () => tracks } as unknown as MediaStream }
}

const expectStopped = (tracks: { stop: ReturnType<typeof vi.fn> }[]) => {
  for (const track of tracks) expect(track.stop).toHaveBeenCalled()
}

function setDevices(value: unknown) {
  Object.defineProperty(navigator, 'mediaDevices', { value, configurable: true })
}

const failure = (run: () => Promise<unknown>) =>
  run().then(
    () => null,
    (cause: RecorderError) => cause.failure,
  )

beforeEach(() => {
  FakeRecorder.instances = []
  FakeRecorder.startFails = false
  FakeRecorder.supported = ['audio/webm;codecs=opus', 'audio/webm']
  vi.stubGlobal('MediaRecorder', FakeRecorder)
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
  setDevices(undefined)
})

describe('startRecording', () => {
  it('stops every track on stop and resolves the audio', async () => {
    const { stream, tracks } = fakeStream()
    setDevices({ getUserMedia: vi.fn().mockResolvedValue(stream) })
    const recording = await startRecording()
    const blob = await recording.stop()
    expect(await blob.text()).toBe('abc')
    expect(blob.type).toBe('audio/webm;codecs=opus')
    expectStopped(tracks)
  })

  it('lets go of the microphone at once, before the recorder reports back', async () => {
    const { stream, tracks } = fakeStream()
    setDevices({ getUserMedia: vi.fn().mockResolvedValue(stream) })
    const recording = await startRecording()
    FakeRecorder.last.stop = () => {} // The stop event has not come yet.
    void recording.stop()
    expectStopped(tracks)
  })

  it('takes the best type the browser has', async () => {
    FakeRecorder.supported = ['audio/mp4']
    const { stream } = fakeStream()
    setDevices({ getUserMedia: vi.fn().mockResolvedValue(stream) })
    await startRecording()
    expect(FakeRecorder.last.options?.mimeType).toBe('audio/mp4')
  })

  it('asks for audio only', async () => {
    const { stream } = fakeStream()
    const getUserMedia = vi.fn().mockResolvedValue(stream)
    setDevices({ getUserMedia })
    await startRecording()
    expect(getUserMedia).toHaveBeenCalledWith({ audio: true })
  })

  it('answers a second stop with the same recording', async () => {
    const { stream } = fakeStream()
    setDevices({ getUserMedia: vi.fn().mockResolvedValue(stream) })
    const recording = await startRecording()
    expect(await recording.stop()).toBe(await recording.stop())
  })

  it('stops every track on a recorder error', async () => {
    const { stream, tracks } = fakeStream()
    setDevices({ getUserMedia: vi.fn().mockResolvedValue(stream) })
    const recording: Recording = await startRecording()
    FakeRecorder.last.onerror?.()
    await expect(recording.finished).rejects.toBeInstanceOf(RecorderError)
    expectStopped(tracks)
  })

  it('stops every track if the recorder never starts', async () => {
    FakeRecorder.startFails = true
    const { stream, tracks } = fakeStream()
    setDevices({ getUserMedia: vi.fn().mockResolvedValue(stream) })
    expect(await failure(() => startRecording())).toBe('failed')
    expectStopped(tracks)
  })

  it('ends by itself at the cap', async () => {
    vi.useFakeTimers()
    const { stream, tracks } = fakeStream()
    setDevices({ getUserMedia: vi.fn().mockResolvedValue(stream) })
    const recording = await startRecording()
    await vi.advanceTimersByTimeAsync(59_999)
    expect(FakeRecorder.last.state).toBe('recording')
    await vi.advanceTimersByTimeAsync(1)
    expect(FakeRecorder.last.state).toBe('inactive')
    await recording.finished
    expectStopped(tracks)
  })

  it('tells a blocked microphone apart', async () => {
    setDevices({
      getUserMedia: vi.fn().mockRejectedValue(new DOMException('no', 'NotAllowedError')),
    })
    expect(await failure(() => startRecording())).toBe('denied')
  })

  it('calls no mediaDevices unsupported, as on plain http', async () => {
    setDevices(undefined)
    expect(await failure(() => startRecording())).toBe('unsupported')
  })

  it('calls a browser with no MediaRecorder unsupported', async () => {
    vi.stubGlobal('MediaRecorder', undefined)
    setDevices({ getUserMedia: vi.fn() })
    expect(await failure(() => startRecording())).toBe('unsupported')
  })
})
