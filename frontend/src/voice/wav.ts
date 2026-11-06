/* What the backend's Whisper path expects: 16 kHz mono, 16-bit PCM, in a RIFF/WAVE file. */

export const TARGET_RATE = 16_000

const HEADER_BYTES = 44
const BYTES_PER_SAMPLE = 2
const PCM_FORMAT = 1
const MONO = 1

function writeAscii(view: DataView, offset: number, text: string): void {
  for (let i = 0; i < text.length; i += 1) view.setUint8(offset + i, text.charCodeAt(i))
}

export function encodeWav(samples: Float32Array, sampleRate: number): Blob {
  const dataBytes = samples.length * BYTES_PER_SAMPLE
  const view = new DataView(new ArrayBuffer(HEADER_BYTES + dataBytes))

  writeAscii(view, 0, 'RIFF')
  view.setUint32(4, HEADER_BYTES - 8 + dataBytes, true)
  writeAscii(view, 8, 'WAVE')
  writeAscii(view, 12, 'fmt ')
  view.setUint32(16, 16, true)
  view.setUint16(20, PCM_FORMAT, true)
  view.setUint16(22, MONO, true)
  view.setUint32(24, sampleRate, true)
  view.setUint32(28, sampleRate * MONO * BYTES_PER_SAMPLE, true)
  view.setUint16(32, MONO * BYTES_PER_SAMPLE, true)
  view.setUint16(34, BYTES_PER_SAMPLE * 8, true)
  writeAscii(view, 36, 'data')
  view.setUint32(40, dataBytes, true)

  samples.forEach((sample, index) => {
    // Resampling overshoots: a probe here peaked at 1.0099, which would wrap round without this.
    const clamped = Math.max(-1, Math.min(1, sample))
    const scaled = clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff
    view.setInt16(HEADER_BYTES + index * BYTES_PER_SAMPLE, scaled, true)
  })

  return new Blob([view.buffer as ArrayBuffer], { type: 'audio/wav' })
}

interface WebkitWindow {
  webkitAudioContext?: typeof AudioContext
  webkitOfflineAudioContext?: typeof OfflineAudioContext
}

const prefixed = () => window as unknown as WebkitWindow

/** Old Safari takes callbacks here and returns nothing, so both forms settle the promise. */
function decode(context: BaseAudioContext, data: ArrayBuffer): Promise<AudioBuffer> {
  return new Promise((resolve, reject) => {
    const answer: Promise<AudioBuffer> | undefined = context.decodeAudioData(data, resolve, reject)
    answer?.then(resolve, reject)
  })
}

function render(context: OfflineAudioContext): Promise<AudioBuffer> {
  return new Promise((resolve, reject) => {
    context.oncomplete = (event) => resolve(event.renderedBuffer)
    const answer: Promise<AudioBuffer> | undefined = context.startRendering()
    answer?.then(resolve, reject)
  })
}

/** Any recording the browser can decode, down to one channel at 16 kHz. */
export async function toMono16k(blob: Blob): Promise<Float32Array> {
  const Audio = window.AudioContext ?? prefixed().webkitAudioContext
  const Offline = window.OfflineAudioContext ?? prefixed().webkitOfflineAudioContext
  if (!Audio || !Offline) throw new Error('Web Audio is not available.')

  const decoder = new Audio()
  let decoded: AudioBuffer
  try {
    decoded = await decode(decoder, await blob.arrayBuffer())
  } finally {
    void decoder.close?.()
  }

  const length = Math.ceil(decoded.duration * TARGET_RATE)
  const offline = new Offline(1, length, TARGET_RATE)
  const source = offline.createBufferSource()
  source.buffer = decoded
  source.connect(offline.destination)
  source.start()
  const rendered = await render(offline)
  return rendered.getChannelData(0)
}
