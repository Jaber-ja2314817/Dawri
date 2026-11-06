import { errorText } from '../../api/client'
import type { QueueTicket } from '../../api/staffTypes'
import { useI18n } from '../../i18n'
import type { CounterActions } from '../../state/staff/useCounterActions'
import { Button, Card, ErrorBlock, Ltr } from '../ui'

interface CounterBarProps {
  tickets: QueueTicket[]
  actions: CounterActions
}

/** Call next, or the one patient already at this counter. Works for any counter. */
export function CounterBar({ tickets, actions }: CounterBarProps) {
  const { t, lang } = useI18n()
  const current = tickets.find((ticket) => ticket.state !== 'active') ?? null
  const anyoneWaiting = tickets.some((ticket) => ticket.state === 'active')
  const handled = actions.lastCall?.auto_completed ?? []
  const name = current?.patient
    ? lang === 'ar'
      ? current.patient.name_ar
      : current.patient.name_en
    : null

  return (
    <Card data-testid="counter-bar" className="flex flex-col gap-3">
      {current === null ? (
        <Button
          data-testid="call-next"
          loading={actions.busy}
          disabled={!anyoneWaiting}
          className="self-start"
          onClick={() => void actions.callNext()}
        >
          {t('queue.callNext')}
        </Button>
      ) : (
        <div
          data-testid="at-counter"
          data-number={current.number}
          data-state={current.state}
          className="flex flex-wrap items-center gap-3"
        >
          <span className="text-xl font-semibold text-data">
            <Ltr>{current.number}</Ltr>
          </span>
          {name && <span className="min-w-0 text-base font-medium">{name}</span>}
          <span className="text-sm text-muted">{t(`queue.state.${current.state}`)}</span>
          <span className="flex-1" />
          {current.state === 'called' && (
            <>
              <Button
                variant="secondary"
                data-testid="not-here"
                disabled={actions.busy}
                onClick={() => void actions.notHere(current.ticket_id)}
              >
                {t('queue.notHere')}
              </Button>
              <Button
                data-testid="patient-here"
                loading={actions.busy}
                onClick={() => void actions.serve(current.ticket_id)}
              >
                {t('queue.patientHere')}
              </Button>
            </>
          )}
        </div>
      )}
      {handled.length > 0 && (
        <p data-testid="auto-completed" role="status" className="text-sm text-muted">
          {t('queue.autoCompleted')} <Ltr>{handled.join(', ')}</Ltr>
        </p>
      )}
      {actions.error !== null && <ErrorBlock message={errorText(actions.error, t, lang)} />}
    </Card>
  )
}

export default CounterBar
