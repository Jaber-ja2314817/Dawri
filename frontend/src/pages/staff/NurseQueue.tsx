import { Link, useNavigate } from 'react-router-dom'
import type { CounterRef, QueueTicket } from '../../api/staffTypes'
import { CounterBar } from '../../components/staff/CounterBar'
import { QueueTable } from '../../components/staff/QueueTable'
import { StaffShell } from '../../components/staff/StaffShell'
import { buttonClass, Card, ErrorBlock, Ltr, Skeleton } from '../../components/ui'
import { errorText } from '../../api/client'
import { useI18n } from '../../i18n'
import { useCounterQueue } from '../../state/staff/hooks'
import { useStaff } from '../../state/staff/session'
import { useCounterActions, type CounterActions } from '../../state/staff/useCounterActions'
import { DASH, visitPath } from '../../features/staff/nurse/parts'

const NONE: QueueTicket[] = []
const LOADING_ROWS = 4

/* The call button stands in the title row, so the bar's own card comes off there. */
const IN_TITLE_ROW =
  '[&>[data-testid=counter-bar]]:border-0 [&>[data-testid=counter-bar]]:bg-transparent ' +
  '[&>[data-testid=counter-bar]]:p-0 [&>[data-testid=counter-bar]]:items-end max-w-sm'

function Loading() {
  const { t } = useI18n()
  return (
    <Card data-testid="queue-loading" aria-busy="true" aria-label={t('queue.loading')} className="flex flex-col gap-3">
      {Array.from({ length: LOADING_ROWS }, (_, row) => (
        <Skeleton key={row} height={32} />
      ))}
    </Card>
  )
}

function Queue({ counter }: { counter: CounterRef }) {
  const { t, lang } = useI18n()
  const navigate = useNavigate()
  const queue = useCounterQueue(counter.id)
  const actions = useCounterActions(counter.id, queue.refetch)
  const tickets = queue.data?.tickets ?? NONE
  const current = tickets.find((ticket) => ticket.state !== 'active') ?? null
  const waiting = tickets.filter((ticket) => ticket.state === 'active').length

  const bar: CounterActions = {
    ...actions,
    callNext: async () => {
      const result = await actions.callNext()
      const visitId = result?.called?.visit_id
      if (visitId) {
        navigate(visitPath(visitId), { state: { autoCompleted: result?.auto_completed ?? [] } })
      }
      return result // No patient called: the bar shows what a colleague handled, and nothing else.
    },
  }

  const counterBar = <CounterBar tickets={tickets} actions={bar} />

  return (
    <StaffShell
      title={lang === 'ar' ? counter.label_ar : counter.label}
      live={queue.live}
      subtitle={
        queue.data !== null && (
          <span data-testid="queue-subline">
            <Ltr>{waiting}</Ltr> {t('nurse.queue.waiting')} · {t('nurse.queue.about')}{' '}
            <Ltr>{queue.data.wait.wait_min}</Ltr> {t('queue.minutes')}
          </span>
        )
      }
      actions={current === null ? <div className={IN_TITLE_ROW}>{counterBar}</div> : undefined}
    >
      {current?.visit_id && (
        <div data-testid="current-ticket" data-number={current.number} className="flex flex-col gap-3">
          {counterBar}
          <Card className="flex flex-wrap items-center justify-between gap-3">
            <p dir="auto" data-testid="current-complaint" className="min-w-0 text-sm">
              {current.complaint || DASH}
            </p>
            <Link
              to={visitPath(current.visit_id)}
              data-testid="open-intake"
              className={buttonClass(current.state === 'serving' ? 'primary' : 'secondary')}
            >
              {t('nurse.queue.openIntake')}
            </Link>
          </Card>
        </div>
      )}
      {queue.state === 'error' && queue.data === null ? (
        <ErrorBlock message={errorText(queue.error, t, lang)} onRetry={() => void queue.refetch()} />
      ) : queue.data === null ? (
        <Loading />
      ) : (
        <QueueTable
          tickets={tickets}
          aria-label={t('staff.nav.nurse')}
          rowAction={(ticket) =>
            ticket.simulated || ticket.visit_id === null || ticket.state !== 'active' ? null : (
              <Link
                to={visitPath(ticket.visit_id)}
                data-testid="open-visit"
                className="inline-flex min-h-11 items-center text-sm underline underline-offset-4"
              >
                {t('nurse.queue.open')}
              </Link>
            )
          }
        />
      )}
    </StaffShell>
  )
}

export default function NurseQueue() {
  const { t } = useI18n()
  const { counters } = useStaff()
  const counter = counters[0]
  if (counter === undefined) {
    return (
      <StaffShell title={t('staff.nav.nurse')}>
        <ErrorBlock message={t('nurse.queue.noCounter')} />
      </StaffShell>
    )
  }
  return <Queue key={counter.id} counter={counter} />
}
