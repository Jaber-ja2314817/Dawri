import { errorText } from '../../../api/client'
import type { CounterRef } from '../../../api/staffTypes'
import { QueueTable } from '../../../components/staff/QueueTable'
import { ErrorBlock, Skeleton } from '../../../components/ui'
import { useI18n } from '../../../i18n'
import type { useCounterQueue } from '../../../state/staff/hooks'

/** Read only. The engine decides the order, and this screen does not describe it. */
export function DeskQueue({
  counter,
  queue,
}: {
  counter: CounterRef
  queue: ReturnType<typeof useCounterQueue>
}) {
  const { t, lang } = useI18n()
  const label = lang === 'ar' ? counter.label_ar : counter.label
  const { data, state, error, refetch } = queue
  return (
    <section data-testid="desk-queue" aria-labelledby="desk-queue-title" className="flex min-w-0 flex-col gap-2">
      <div className="flex flex-wrap items-baseline justify-between gap-x-3">
        <h2 id="desk-queue-title" className="text-base font-medium">
          {t('desk.queue.title', { counter: label })}
        </h2>
        <p className="text-xs text-muted">{t('desk.queue.note')}</p>
      </div>
      {error !== null && (
        <ErrorBlock message={errorText(error, t, lang)} onRetry={() => void refetch()} />
      )}
      {state === 'gone' && <ErrorBlock message={t('error.generic')} />}
      {data === null && state === 'loading' && <Skeleton height={176} />}
      {data !== null && <QueueTable tickets={data.tickets} aria-label={label} />}
    </section>
  )
}
