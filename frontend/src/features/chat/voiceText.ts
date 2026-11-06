import { ApiError, errorText } from '../../api/client'
import type { Lang, Translate } from '../../i18n'
import { RecorderError } from '../../voice/recorder'
import { VoiceError } from './useVoice'

const SERVER_CODES = ['asr_unavailable', 'asr_failed', 'bad_audio', 'audio_too_large']

/** Every one of these ends by telling the patient to type. */
export function voiceErrorText(cause: unknown, t: Translate, lang: Lang): string {
  if (cause instanceof ApiError && SERVER_CODES.includes(cause.code)) {
    return errorText(cause, t, lang)
  }
  if (cause instanceof RecorderError) {
    if (cause.failure === 'denied') return t('voice.error.denied')
    if (cause.failure === 'unsupported') return t('voice.error.unsupported')
  }
  if (cause instanceof VoiceError && cause.failure === 'decode') return t('voice.error.decode')
  return t('voice.error.failed')
}

export function clock(seconds: number): string {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`
}
