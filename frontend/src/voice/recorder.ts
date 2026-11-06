/* Audio stays in memory for this one recording: nothing here may reach any browser storage. */

export const MAX_RECORDING_MS = 60_000

const MIME_TYPES = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus']

export type RecorderFailure = 'unsupported' | 'denied' | 'failed'

export class RecorderError extends Error {
  failure: RecorderFailure

  constructor(failure: RecorderFailure, message: string) {
    super(message)
    this.name = 'RecorderError'
    this.failure = failure
  }
}

export interface Recording {
  /** Ends the recording and resolves it. A second call gets the same answer. */
  stop: () => Promise<Blob>
  /** Settles when the recording ends for any reason: stop, the cap or a recorder error. */
  finished: Promise<Blob>
}

function bestMimeType(): string | undefined {
  return MIME_TYPES.find((type) => MediaRecorder.isTypeSupported?.(type))
}

function stopTracks(stream: MediaStream): void {
  stream.getTracks().forEach((track) => track.stop())
}

async function askForMicrophone(): Promise<MediaStream> {
  // No mediaDevices at all: plain http on a phone.
  if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') {
    throw new RecorderError('unsupported', 'This browser cannot record here.')
  }
  try {
    return await navigator.mediaDevices.getUserMedia({ audio: true })
  } catch (cause) {
    const denied =
      cause instanceof DOMException &&
      (cause.name === 'NotAllowedError' || cause.name === 'SecurityError')
    throw new RecorderError(denied ? 'denied' : 'failed', 'The microphone did not open.')
  }
}

function record(stream: MediaStream): Recording {
  const mimeType = bestMimeType()
  const recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined)
  const chunks: Blob[] = []
  let limit: ReturnType<typeof setTimeout> | undefined

  const finished = new Promise<Blob>((resolve, reject) => {
    const close = () => {
      clearTimeout(limit)
      stopTracks(stream)
    }
    recorder.ondataavailable = (event) => {
      if (event.data.size > 0) chunks.push(event.data)
    }
    recorder.onstop = () => {
      close()
      resolve(new Blob(chunks, { type: recorder.mimeType || mimeType || 'audio/webm' }))
      chunks.length = 0
    }
    recorder.onerror = () => {
      close()
      chunks.length = 0
      reject(new RecorderError('failed', 'The recording failed.'))
    }
  })
  finished.catch(() => {}) // A caller that only uses stop() still sees the rejection there.

  const stop = () => {
    if (recorder.state !== 'inactive') recorder.stop()
    stopTracks(stream) // Now, not on the stop event: the microphone goes off the moment we say.
    return finished
  }

  recorder.start()
  limit = setTimeout(() => void stop().catch(() => {}), MAX_RECORDING_MS)

  return { stop, finished }
}

export async function startRecording(): Promise<Recording> {
  const stream = await askForMicrophone()
  try {
    return record(stream)
  } catch {
    stopTracks(stream)
    throw new RecorderError('failed', 'The recorder did not start.')
  }
}
