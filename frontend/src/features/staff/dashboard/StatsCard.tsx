import type { ReactNode } from 'react'
import type { Stage, Stats } from '../../../api/staffTypes'
import { Card, Ltr, Skeleton } from '../../../components/ui'
import { useI18n } from '../../../i18n'
import { cx } from '../../../lib/cx'
import { STAGES, waitingTotal } from './figures'

function Waiting({ id, label, value }: { id: string; label: string; value: number | null }) {
  return (
    <div className="flex flex-col gap-1 bg-surface px-4 py-3">
      <dt className="text-sm text-muted">{label}</dt>
      <dd
        data-testid={`figure-${id}`}
        data-value={value ?? undefined}
        className="text-2xl font-semibold tabular-nums"
      >
        {value === null ? <Skeleton width={48} height={36} /> : <Ltr>{value}</Ltr>}
      </dd>
    </div>
  )
}

function Count({
  id,
  label,
  value,
  shown,
}: {
  id: string
  label: string
  /** The raw figure, or undefined when it has none. */
  value?: number
  shown: ReactNode
}) {
  return (
    <div className="flex min-h-11 items-center justify-between gap-3 bg-surface px-4 py-2 lg:flex-col lg:items-start lg:justify-start lg:gap-1 lg:py-3">
      <dt className="text-sm text-muted">{label}</dt>
      <dd data-testid={`figure-${id}`} data-value={value} className="text-end lg:text-start">
        {shown}
      </dd>
    </div>
  )
}

const NUMBER = 'text-xl font-medium tabular-nums'

function plainCount(value: number | null): ReactNode {
  return value === null ? (
    <Skeleton width={32} height={32} />
  ) : (
    <Ltr className={NUMBER}>{value}</Ltr>
  )
}

function AverageWait({ stats }: { stats: Stats | null }) {
  const { t } = useI18n()
  if (stats === null) return <Skeleton width={72} height={32} />
  if (stats.avg_wait_min === null) {
    return (
      <span className="text-sm text-muted">
        <span data-testid="no-wait">—</span> {t('dashboard.noCalls')}
      </span>
    )
  }
  return (
    <>
      <Ltr className={NUMBER}>{stats.avg_wait_min}</Ltr>
      <span className="ms-1 text-sm text-muted">{t('dashboard.minutes')}</span>
    </>
  )
}

/** One divided card, with what is waiting first and largest. No tiles, no icons, no charts. */
export function StatsCard({ stats }: { stats: Stats | null }) {
  const { t } = useI18n()
  const stage = (name: Stage) => stats?.waiting[name] ?? null
  return (
    <Card flush data-testid="stats-card" className="overflow-hidden">
      <h2 className="px-4 pt-3 pb-2 text-sm font-medium">{t('dashboard.waitingNow')}</h2>
      <dl className="grid grid-cols-2 gap-px border-t border-border bg-border lg:grid-cols-4">
        {STAGES.map((name) => (
          <Waiting
            key={name}
            id={`waiting-${name}`}
            label={t(`dashboard.stage.${name}`)}
            value={stage(name)}
          />
        ))}
        <Waiting
          id="waiting-total"
          label={t('dashboard.total')}
          value={stats === null ? null : waitingTotal(stats.waiting)}
        />
      </dl>
      <dl className={cx('grid gap-px border-t border-border bg-border lg:grid-cols-5')}>
        <Count
          id="avg-wait"
          label={t('dashboard.avgWait')}
          value={stats?.avg_wait_min ?? undefined}
          shown={<AverageWait stats={stats} />}
        />
        <Count
          id="completed"
          label={t('dashboard.completed')}
          value={stats?.completed_today}
          shown={plainCount(stats?.completed_today ?? null)}
        />
        <Count
          id="deflections"
          label={t('dashboard.deflections')}
          value={stats?.refills_deflected}
          shown={plainCount(stats?.refills_deflected ?? null)}
        />
        <Count
          id="emergencies"
          label={t('dashboard.emergencies')}
          value={stats?.emergencies_redirected}
          shown={plainCount(stats?.emergencies_redirected ?? null)}
        />
        <Count
          id="walk-ins"
          label={t('dashboard.walkIns')}
          value={stats?.walk_ins}
          shown={plainCount(stats?.walk_ins ?? null)}
        />
      </dl>
      <p data-testid="real-only" className="border-t border-border px-4 py-3 text-sm text-muted">
        {t('dashboard.realOnly')}
      </p>
    </Card>
  )
}
