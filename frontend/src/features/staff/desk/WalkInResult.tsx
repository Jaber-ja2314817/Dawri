import { useEffect, useRef, type ReactNode } from 'react'
import type { StaffTicket } from '../../../api/staffTypes'
import { Button, buttonClass, Card, Ltr } from '../../../components/ui'
import { useI18n } from '../../../i18n'

function Fact({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <dt className="text-xs text-muted">{label}</dt>
      <dd className="text-sm font-medium tabular-nums">{children}</dd>
    </div>
  )
}

export function WalkInTicket({ ticket }: { ticket: StaffTicket }) {
  const { t, lang } = useI18n()
  return (
    <Card
      data-testid="walkin-ticket"
      data-number={ticket.number ?? ''}
      role="status"
      className="flex flex-col gap-3"
    >
      <div className="flex flex-col gap-1">
        <p className="text-sm text-muted">{t('desk.ticket.title')}</p>
        <p data-testid="walkin-number" className="text-2xl font-semibold text-data">
          <Ltr>{ticket.number}</Ltr>
        </p>
      </div>
      <dl className="grid grid-cols-3 gap-3">
        <Fact label={t('desk.ticket.ahead')}>
          <Ltr>{ticket.people_ahead ?? '—'}</Ltr>
        </Fact>
        <Fact label={t('desk.ticket.wait')}>
          {ticket.est_wait_min === null
            ? '—'
            : t('desk.ticket.minutes', { count: ticket.est_wait_min })}
        </Fact>
        <Fact label={t('desk.ticket.counter')}>
          <span data-testid="walkin-counter">
            {lang === 'ar' ? ticket.counter_ar : ticket.counter}
          </span>
        </Fact>
      </dl>
    </Card>
  )
}

/** The patient is told what to do next, and nothing here may read as a ticket. */
export function WalkInEmergency({ reply, onNext }: { reply: string; onNext: () => void }) {
  const { t } = useI18n()
  const panel = useRef<HTMLElement>(null)

  useEffect(() => {
    panel.current?.focus()
  }, [])

  return (
    <section
      ref={panel}
      data-testid="walkin-emergency"
      role="alert"
      tabIndex={-1}
      className="flex flex-col gap-3 rounded-panel border border-negative bg-pill-negative-bg p-4 text-pill-negative-ink outline-none max-lg:order-first"
    >
      <h2 className="text-xl font-semibold">{t('desk.emergency.title')}</h2>
      <p dir="auto" data-testid="walkin-reply" className="text-base">
        {reply}
      </p>
      <div className="flex flex-wrap items-center gap-2">
        <a href="tel:999" data-testid="walkin-call" className={buttonClass('primary')}>
          {t('desk.emergency.call')}
        </a>
        <Button variant="secondary" data-testid="walkin-next" onClick={onNext}>
          {t('desk.emergency.next')}
        </Button>
      </div>
    </section>
  )
}
