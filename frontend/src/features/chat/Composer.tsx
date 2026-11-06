import { useId, type RefObject } from 'react'
import { MicIcon, SendIcon, StopIcon } from '../../components/icons'
import { Button, Ltr } from '../../components/ui'
import { useI18n } from '../../i18n'
import { MAX_TEXT } from './send'
import type { ChatState } from './useChat'
import type { VoiceState } from './useVoice'
import { clock, voiceErrorText } from './voiceText'

function TranscriptConfirm({ chat, voice }: { chat: ChatState; voice: VoiceState }) {
  const { t } = useI18n()
  const fieldId = useId()
  const text = voice.transcript
  return (
    <div data-testid="voice-confirm" className="flex flex-col gap-2">
      <label htmlFor={fieldId} className="text-base font-semibold">
        {t('voice.confirm.check')}
      </label>
      <textarea
        id={fieldId}
        data-testid="voice-transcript"
        dir="auto"
        rows={3}
        maxLength={MAX_TEXT}
        value={text}
        onChange={(event) => voice.setTranscript(event.target.value)}
        className="min-h-11 w-full resize-none rounded-control border border-control bg-surface px-3 py-2 text-start text-base text-ink"
      />
      <Button
        data-testid="voice-send"
        className="w-full"
        disabled={text.trim() === '' || chat.thinking || chat.confirming}
        onClick={() => {
          chat.sendText(text)
          voice.reset()
        }}
      >
        {t('voice.confirm.send')}
      </Button>
      <Button data-testid="voice-retry" variant="quiet" className="w-full" onClick={voice.start}>
        {t('voice.confirm.retry')}
      </Button>
    </div>
  )
}

function VoiceControl({ chat, voice }: { chat: ChatState; voice: VoiceState }) {
  const { t } = useI18n()
  const hasText = chat.draft.trim() !== ''

  if (voice.step === 'listening') {
    return (
      <div className="flex min-h-14 items-center gap-3 rounded-control border border-control bg-surface ps-3 pe-1.5">
        <span aria-hidden="true" className="size-2 shrink-0 rounded-full bg-ink" />
        <span role="status" className="min-w-0 flex-1 text-base font-medium">
          {t('voice.listening')}
        </span>
        <Ltr className="text-base">
          <span data-testid="voice-timer">{clock(voice.seconds)}</span>
        </Ltr>
        <Button data-testid="voice-stop" onClick={voice.stop}>
          <StopIcon />
          {t('voice.stop')}
        </Button>
      </div>
    )
  }

  if (voice.step === 'starting' || voice.step === 'transcribing') {
    return (
      <p
        role="status"
        data-testid="voice-working"
        className="flex min-h-14 items-center justify-center gap-2 rounded-control border border-control bg-surface px-3 text-base text-muted"
      >
        <span
          aria-hidden="true"
          className="size-4 shrink-0 animate-spin rounded-full border-2 border-current border-b-transparent"
        />
        {t(voice.step === 'starting' ? 'voice.starting' : 'voice.transcribing')}
      </p>
    )
  }

  return (
    <Button
      data-testid="chat-mic"
      variant={hasText || chat.summary ? 'secondary' : 'primary'}
      className="min-h-14 w-full"
      disabled={chat.thinking || chat.confirming}
      onClick={voice.start}
    >
      <MicIcon size={20} />
      {t('voice.start')}
    </Button>
  )
}

interface ComposerProps {
  chat: ChatState
  voice: VoiceState
  inputRef: RefObject<HTMLInputElement | null>
}

export function Composer({ chat, voice, inputRef }: ComposerProps) {
  const { t, lang } = useI18n()
  const hasText = chat.draft.trim() !== ''
  const busy = chat.thinking || chat.confirming || voice.step !== 'idle'

  return (
    <div
      data-testid="chat-composer"
      className="sticky bottom-0 -mx-4 flex flex-col gap-2 border-t border-border bg-ground px-4 pt-3 pb-[max(12px,env(safe-area-inset-bottom))]"
    >
      {voice.step === 'confirm' ? (
        <TranscriptConfirm chat={chat} voice={voice} />
      ) : (
        <>
          {voice.error !== null && (
            <p role="alert" data-testid="voice-error" className="text-sm text-negative">
              {voiceErrorText(voice.error, t, lang)}
            </p>
          )}
          <form
            className="flex items-stretch gap-2"
            onSubmit={(event) => {
              event.preventDefault()
              if (!busy) chat.submit()
            }}
          >
            <input
              ref={inputRef}
              data-testid="chat-input"
              type="text"
              dir={chat.draft === '' ? undefined : 'auto'}
              aria-label={t('chat.input.label')}
              placeholder={t('chat.input.placeholder')}
              maxLength={MAX_TEXT}
              autoComplete="off"
              readOnly={chat.thinking || chat.confirming}
              value={chat.draft}
              onChange={(event) => {
                chat.setDraft(event.target.value)
                voice.clearError()
              }}
              className="min-h-11 min-w-0 flex-1 rounded-control border border-control bg-surface px-3 text-start text-base text-ink placeholder:text-muted"
            />
            <Button
              data-testid="chat-send"
              type="submit"
              variant={hasText ? 'primary' : 'secondary'}
              disabled={!hasText || busy}
            >
              <SendIcon />
              {t('chat.send')}
            </Button>
          </form>
          <VoiceControl chat={chat} voice={voice} />
        </>
      )}
    </div>
  )
}
