/* Web Audio alone, with no file: the venue may be offline. Every failure here means silence. */

const TONES = [
  { hz: 880, at: 0 },
  { hz: 660, at: 0.24 },
]
const TONE_SEC = 0.22
const PEAK = 0.25
const SILENCE = 0.0001

type AudioClass = typeof AudioContext

let context: AudioContext | null = null

function audioClass(): AudioClass | null {
  const legacy = window as Window & { webkitAudioContext?: AudioClass }
  return window.AudioContext ?? legacy.webkitAudioContext ?? null
}

/** Call it from a tap: browsers keep audio suspended until a gesture. True when sound can play. */
export async function unlockSound(): Promise<boolean> {
  try {
    const Audio = audioClass()
    if (Audio === null) return false
    context ??= new Audio()
    if (context.state !== 'running') await context.resume()
    return context.state === 'running'
  } catch {
    return false
  }
}

function tone(audio: AudioContext, hz: number, start: number) {
  const oscillator = audio.createOscillator()
  const gain = audio.createGain()
  oscillator.frequency.value = hz
  gain.gain.setValueAtTime(SILENCE, start)
  gain.gain.exponentialRampToValueAtTime(PEAK, start + 0.02)
  gain.gain.exponentialRampToValueAtTime(SILENCE, start + TONE_SEC)
  oscillator.connect(gain)
  gain.connect(audio.destination)
  oscillator.start(start)
  oscillator.stop(start + TONE_SEC)
}

/** Two short tones. False when nothing played, which the screen does not depend on. */
export function playChime(): boolean {
  if (context === null || context.state !== 'running') return false
  try {
    for (const { hz, at } of TONES) tone(context, hz, context.currentTime + at)
    return true
  } catch {
    return false
  }
}
