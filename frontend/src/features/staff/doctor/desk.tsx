import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { errorText } from '../../../api/client'
import type { QueueTicket } from '../../../api/staffTypes'
import { CounterBar } from '../../../components/staff/CounterBar'
import { QueueTable } from '../../../components/staff/QueueTable'
import { Card, ErrorBlock, Skeleton } from '../../../components/ui'
import { useI18n } from '../../../i18n'
import { cx } from '../../../lib/cx'
import { useCounterQueue } from '../../../state/staff/hooks'
import { useCounterActions } from '../../../state/staff/useCounterActions'

/* A counter that holds one patient: the doctor's room and the pharmacy window share all of this. */

export type DeskName = 'doctor' | 'pharmacy'

export function useCounterDesk(counterId: string) {
  const queue = useCounterQueue(counterId)
  const actions = useCounterActions(counterId, queue.refetch)
  const tickets = queue.data?.tickets
  const current = tickets?.find((ticket) => ticket.state !== 'active') ?? null
  const currentId = current?.ticket_id ?? null
  const [gone, setGone] = useState(false)
  const seen = useRef<string | null>(null)
  const leaving = useRef<string | null>(null)

  /* Told before the request goes: the stream can beat the answer back to this page. */
  const expectLeaving = useCallback((ticketId: string | null) => {
    leaving.current = ticketId
  }, [])

  useEffect(() => {
    const before = seen.current
    seen.current = currentId
    if (before === currentId) return
    if (currentId !== null) {
      setGone(false)
      return
    }
    if (leaving.current === before) leaving.current = null
    else setGone(true)
  }, [currentId])

  const { refetch } = queue
  /** The visit answered 404, which is what a demo reset leaves behind. */
  const visitGone = useCallback(() => {
    setGone(true)
    void refetch()
  }, [refetch])

  const notHere = useCallback(
    async (ticketId: string) => {
      expectLeaving(ticketId)
      const result = await actions.notHere(ticketId)
      if (result === null) expectLeaving(null)
      return result
    },
    [actions, expectLeaving],
  )

  return {
    queue,
    actions: { ...actions, notHere },
    tickets: tickets ?? [],
    current,
    gone,
    expectLeaving,
    visitGone,
  }
}

export type CounterDesk = ReturnType<typeof useCounterDesk>

/** A value that shows for a while and then clears itself. */
export function useBrief<T>(ms: number): [T | null, (value: T) => void] {
  const [value, setValue] = useState<T | null>(null)
  useEffect(() => {
    if (value === null) return
    const timer = setTimeout(() => setValue(null), ms)
    return () => clearTimeout(timer)
  }, [value, ms])
  return [value, setValue]
}

/** Keeps the page's one stream: the visit under it polls, and reads again when the queue moves. */
export function useRefetchWith(signal: number | null, refetch: () => Promise<void>) {
  useEffect(() => {
    if (signal !== null) void refetch()
  }, [signal, refetch])
}

function RegionTab({
  active,
  testId,
  onClick,
  children,
}: {
  active: boolean
  testId: string
  onClick: () => void
  children: ReactNode
}) {
  return (
    <button
      type="button"
      data-testid={testId}
      aria-pressed={active}
      onClick={onClick}
      className={cx(
        'flex min-h-11 flex-1 cursor-pointer items-center justify-center rounded-control px-3 text-sm',
        active ? 'bg-raised font-medium text-ink' : 'text-muted hover:text-ink',
      )}
    >
      {children}
    </button>
  )
}

function QueueRegion({ desk, label }: { desk: CounterDesk; label: string }) {
  const { t, lang } = useI18n()
  const { queue } = desk
  if (queue.state === 'loading') {
    return (
      <Card
        data-testid="queue-loading"
        role="status"
        aria-label={t('queue.loading')}
        className="flex flex-col gap-3"
      >
        <Skeleton height={20} />
        <Skeleton height={20} />
        <Skeleton height={20} />
      </Card>
    )
  }
  if (queue.state === 'error') {
    return (
      <ErrorBlock
        message={errorText(queue.error, t, lang)}
        onRetry={() => void queue.refetch()}
      />
    )
  }
  return <QueueTable tickets={desk.tickets} aria-label={label} />
}

interface DeskRegionsProps {
  name: DeskName
  desk: CounterDesk
  children: ReactNode
}

/*
 * 1168 px of canvas at 1440 (1200 less two 16 px gutters): 580 queue + 12 gap + 576 patient.
 * 580 is what QueueTable's six columns need with a serving row. Below that it clips Waiting.
 * Below 1024 px one region shows at a time, and the patient at the counter comes first.
 */
export function DeskRegions({ name, desk, children }: DeskRegionsProps) {
  const { t } = useI18n()
  const [region, setRegion] = useState<'patient' | 'queue'>('patient')
  const waiting = desk.tickets.filter((ticket: QueueTicket) => ticket.state === 'active').length
  const currentId = desk.current?.ticket_id ?? null

  useEffect(() => {
    if (currentId !== null) setRegion('patient')
  }, [currentId])

  return (
    <div
      data-testid={`${name}-desk`}
      className="grid min-w-0 grid-cols-1 items-start gap-3 lg:grid-cols-[580px_minmax(0,1fr)]"
    >
      <div
        role="group"
        aria-label={t(`${name}.regions`)}
        className="flex gap-1 rounded-panel border border-border bg-surface p-1 lg:hidden"
      >
        <RegionTab
          active={region === 'patient'}
          testId="region-patient"
          onClick={() => setRegion('patient')}
        >
          {t(`${name}.regionPatient`)}
        </RegionTab>
        <RegionTab
          active={region === 'queue'}
          testId="region-queue"
          onClick={() => setRegion('queue')}
        >
          {t(`${name}.regionQueue`, { count: waiting })}
        </RegionTab>
      </div>

      <div className="flex min-w-0 flex-col gap-3 lg:sticky lg:top-3 lg:col-start-1 lg:row-start-1">
        <CounterBar tickets={desk.tickets} actions={desk.actions} />
        <section
          data-testid="queue-region"
          aria-label={t(`${name}.queue`)}
          className={cx('min-w-0', region !== 'queue' && 'max-lg:hidden')}
        >
          <QueueRegion desk={desk} label={t(`${name}.queue`)} />
        </section>
      </div>

      <section
        data-testid="patient-region"
        aria-label={t(`${name}.patient`)}
        className={cx(
          'flex min-w-0 flex-col gap-3 lg:col-start-2 lg:row-start-1',
          region !== 'patient' && 'max-lg:hidden',
        )}
      >
        {children}
      </section>
    </div>
  )
}

/** The block a region keeps when nobody stands at the counter. */
export function EmptyPanel({
  testId,
  title,
  body,
  children,
}: {
  testId: string
  title: string
  body: string
  children?: ReactNode
}) {
  return (
    <Card data-testid={testId} className="flex flex-col gap-3">
      <h2 className="text-base font-semibold">{title}</h2>
      <div className="flex flex-col gap-1 rounded-panel border border-dashed border-control px-4 py-3">
        <p className="text-base font-medium">{body}</p>
        {children}
      </div>
    </Card>
  )
}
