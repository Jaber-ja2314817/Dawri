import type { ReactNode } from 'react'
import type { ChatMessage } from '../../api/types'
import { useI18n } from '../../i18n'
import { cx } from '../../lib/cx'

function Bubble({ message, scripted }: { message: ChatMessage; scripted: boolean }) {
  const user = message.role === 'user'
  return (
    <div
      data-testid="bubble"
      data-role={message.role}
      className={cx('flex max-w-[85%] flex-col gap-1', user ? 'items-end self-end' : 'items-start self-start')}
    >
      <p
        dir="auto"
        className={cx(
          'max-w-full rounded-panel px-3 py-2 text-start text-base wrap-anywhere whitespace-pre-wrap',
          user ? 'bg-ink text-white' : 'border border-border bg-surface text-ink',
        )}
      >
        {message.content}
      </p>
      {scripted && <ScriptedNote />}
    </div>
  )
}

export function ScriptedNote() {
  const { t } = useI18n()
  return (
    <p data-testid="chat-scripted" className="text-xs text-muted">
      {t('chat.scripted')}
    </p>
  )
}

interface MessagesProps {
  messages: ChatMessage[]
  scripted: ReadonlySet<number>
  /** The closing summary, which its card shows instead. */
  hidden: number | null
  thinking: boolean
  children?: ReactNode
}

export function Messages({ messages, scripted, hidden, thinking, children }: MessagesProps) {
  const { t } = useI18n()
  return (
    <div className="flex flex-1 flex-col gap-2">
      <div role="log" aria-label={t('chat.log')} className="flex flex-col gap-2">
        {messages.map((message, index) =>
          index === hidden ? null : (
            <Bubble key={index} message={message} scripted={scripted.has(index)} />
          ),
        )}
        {children}
      </div>
      <div role="status" aria-live="polite">
        {thinking && (
          <p
            data-testid="chat-thinking"
            className="inline-block rounded-panel border border-border bg-surface px-3 py-2 text-base text-muted"
          >
            {t('chat.thinking')}
          </p>
        )}
      </div>
    </div>
  )
}
