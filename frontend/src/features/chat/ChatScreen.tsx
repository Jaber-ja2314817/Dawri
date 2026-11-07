import { useEffect, useRef } from 'react'
import { errorText } from '../../api/client'
import type { Visit } from '../../api/types'
import { ErrorBlock } from '../../components/ui'
import { useI18n } from '../../i18n'
import { Composer } from './Composer'
import { Messages } from './Messages'
import { SummaryCard } from './SummaryCard'
import { useChat } from './useChat'
import { useVoice } from './useVoice'

interface ChatScreenProps {
  visit: Visit
  refetch: () => Promise<void>
}

export function ChatScreen({ visit, refetch }: ChatScreenProps) {
  const { t, lang } = useI18n()
  const chat = useChat(visit, refetch)
  const voice = useVoice()
  const input = useRef<HTMLInputElement>(null)
  const { failure, summary } = chat
  // Rules read only what is sent, so words still on their way hold back the Yes on the summary.
  const voiceHolds =
    voice.step === 'confirm' ? voice.transcript.trim() !== '' : voice.step !== 'idle'
  const unsent = chat.draft.trim() !== '' || voiceHolds

  // The composer sticks to the bottom of the page, so the end of the page is the newest message.
  useEffect(() => {
    window.scrollTo?.({ top: document.documentElement.scrollHeight })
  }, [chat.messages.length, chat.thinking, summary !== null, failure !== null, voice.step])

  useEffect(() => {
    if (voice.error !== null) input.current?.focus()
  }, [voice.error])

  return (
    <div className="flex flex-1 flex-col gap-3">
      <Messages
        messages={chat.messages}
        scripted={chat.scripted}
        hidden={summary?.index ?? null}
        thinking={chat.thinking}
      >
        {summary && (
          <SummaryCard
            summary={summary}
            scripted={chat.scripted.has(summary.index)}
            chat={chat}
            unsent={unsent}
            onChange={() => {
              voice.clearError()
              input.current?.focus()
            }}
          />
        )}
      </Messages>
      {failure && (
        <ErrorBlock
          message={failure.timedOut ? t('chat.timeout') : errorText(failure.error, t, lang)}
          onRetry={failure.retry ? chat.retry : undefined}
        />
      )}
      <Composer chat={chat} voice={voice} inputRef={input} />
    </div>
  )
}
