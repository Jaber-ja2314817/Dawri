import { errorText } from '../../api/client'
import { Button, Card, ErrorBlock, Pill } from '../../components/ui'
import { useI18n } from '../../i18n'
import { ScriptedNote } from './Messages'
import { withoutClosingQuestion } from './send'
import type { ChatState, Summary } from './useChat'

interface SummaryCardProps {
  summary: Summary
  scripted: boolean
  chat: Pick<ChatState, 'confirm' | 'confirming' | 'confirmError' | 'thinking'>
  /** Words in the box or the transcript step, which Yes would drop unread. */
  unsent: boolean
  onChange: () => void
}

export function SummaryCard({ summary, scripted, chat, unsent, onChange }: SummaryCardProps) {
  const { t, lang } = useI18n()
  return (
    <Card data-testid="chat-summary" className="flex flex-col gap-3">
      <div>
        <Pill>{t(`chat.service.${summary.service}`)}</Pill>
      </div>
      <p dir="auto" data-testid="chat-summary-text" className="text-start text-base wrap-anywhere whitespace-pre-wrap">
        {withoutClosingQuestion(summary.text)}
      </p>
      {scripted && <ScriptedNote />}
      <h2 className="text-base font-semibold">{t('chat.summary.check')}</h2>
      {chat.confirmError !== null && (
        <ErrorBlock
          message={errorText(chat.confirmError, t, lang)}
          onRetry={unsent ? undefined : chat.confirm}
        />
      )}
      {unsent && (
        <p data-testid="chat-summary-unsent" role="status" className="text-sm text-warning">
          {t('chat.summary.unsent')}
        </p>
      )}
      <div className="flex flex-col gap-2">
        <Button
          data-testid="chat-summary-yes"
          className="w-full"
          loading={chat.confirming}
          disabled={chat.thinking || unsent}
          onClick={chat.confirm}
        >
          {t('chat.summary.yes')}
        </Button>
        <Button
          data-testid="chat-summary-change"
          variant="secondary"
          className="w-full"
          disabled={chat.confirming}
          onClick={onChange}
        >
          {t('chat.summary.change')}
        </Button>
      </div>
    </Card>
  )
}
