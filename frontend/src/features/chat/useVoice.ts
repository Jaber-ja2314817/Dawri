import { useCallback, useEffect, useRef, useState } from 'react'
import { transcribe } from '../../api/endpoints'
import { RecorderError, startRecording, type Recording } from '../../voice/recorder'
import { encodeWav, TARGET_RATE, toMono16k } from '../../voice/wav'
import { TURN_TIMEOUT_MS } from './send'

export type VoiceStep = 'idle' | 'starting' | 'listening' | 'transcribing' | 'confirm'

export type VoiceFailure = RecorderError['failure'] | 'decode' | 'blank'

/** One line for the patient. An ApiError or an abort from the upload stays as it came. */
export class VoiceError extends Error {
  failure: VoiceFailure

  constructor(failure: VoiceFailure) {
    super(failure)
    this.name = 'VoiceError'
    this.failure = failure
  }
}

export interface VoiceState {
  step: VoiceStep
  seconds: number
  /** Only what the server heard. Nothing else ever lands here. */
  transcript: string
  setTranscript: (text: string) => void
  error: unknown
  clearError: () => void
  start: () => void
  stop: () => void
  /** Closes the confirm step. */
  reset: () => void
}

export function useVoice(): VoiceState {
  const [step, setStep] = useState<VoiceStep>('idle')
  const [seconds, setSeconds] = useState(0)
  const [transcript, setTranscript] = useState('')
  const [error, setError] = useState<unknown>(null)

  const recording = useRef<Recording | null>(null)
  const ticking = useRef<ReturnType<typeof setInterval> | undefined>(undefined)
  const upload = useRef<AbortController | null>(null)
  const live = useRef(true)

  const stopTicking = useCallback(() => {
    clearInterval(ticking.current)
  }, [])

  const fail = useCallback(
    (cause: unknown) => {
      stopTicking()
      recording.current = null
      if (!live.current) return
      setError(cause)
      setStep('idle')
    },
    [stopTicking],
  )

  const finish = useCallback(async () => {
    const current = recording.current
    if (current === null) return
    recording.current = null
    stopTicking()
    setStep('transcribing')
    try {
      // These locals are the only references to the audio, and they end with this call.
      const recorded = await current.stop()
      const samples = await toMono16k(recorded).catch(() => {
        throw new VoiceError('decode')
      })
      if (samples.length === 0) throw new VoiceError('decode')
      const wav = encodeWav(samples, TARGET_RATE)

      const controller = new AbortController()
      upload.current = controller
      const timer = setTimeout(() => controller.abort(), TURN_TIMEOUT_MS)
      const answer = await transcribe(wav, { signal: controller.signal }).finally(() =>
        clearTimeout(timer),
      )
      if (!live.current) return
      const heard = answer.text.trim()
      if (heard === '') throw new VoiceError('blank')
      setTranscript(heard)
      setStep('confirm')
    } catch (cause) {
      fail(cause)
    }
  }, [fail, stopTicking])

  const start = useCallback(async () => {
    setError(null)
    setTranscript('')
    setStep('starting')
    try {
      const opened = await startRecording()
      if (!live.current) {
        void opened.stop().catch(() => {})
        return
      }
      recording.current = opened
      // The 60 s cap, or the browser ending the track, gets here with nobody tapping Stop.
      opened.finished.then(
        () => {
          if (recording.current === opened) void finish()
        },
        (cause: unknown) => {
          if (recording.current === opened) fail(cause)
        },
      )
      const startedAt = Date.now()
      setSeconds(0)
      stopTicking()
      ticking.current = setInterval(
        () => setSeconds(Math.floor((Date.now() - startedAt) / 1000)),
        250,
      )
      setStep('listening')
    } catch (cause) {
      fail(cause)
    }
  }, [fail, finish, stopTicking])

  useEffect(() => {
    live.current = true
    return () => {
      live.current = false
      stopTicking()
      upload.current?.abort()
      void recording.current?.stop().catch(() => {})
      recording.current = null
    }
  }, [stopTicking])

  return {
    step,
    seconds,
    transcript,
    setTranscript,
    error,
    clearError: useCallback(() => setError(null), []),
    start: () => void start(),
    stop: () => void finish(),
    reset: useCallback(() => {
      setTranscript('')
      setStep('idle')
    }, []),
  }
}
