import { errorText } from '../../api/client'
import { StaffShell } from '../../components/staff/StaffShell'
import { ErrorBlock } from '../../components/ui'
import { StatsCard } from '../../features/staff/dashboard/StatsCard'
import { useI18n } from '../../i18n'
import { useStats } from '../../state/staff/hooks'
import { useStaff } from '../../state/staff/session'
import { dohaTime } from '../../state/staff/time'

function Figures({ centreId }: { centreId: string }) {
  const { t, lang } = useI18n()
  const { data, error, refetch, updatedAt } = useStats(centreId)
  return (
    <>
      {error !== null && (
        <ErrorBlock message={errorText(error, t, lang)} onRetry={() => void refetch()} />
      )}
      <StatsCard stats={data} />
      {updatedAt !== null && (
        <p data-testid="updated-at" className="text-xs text-muted">
          {t('dashboard.updated', { time: dohaTime(new Date(updatedAt).toISOString()) })}
        </p>
      )}
    </>
  )
}

/* Poll only: a refill or an emergency publishes nothing a stream could hear. */
export default function Dashboard() {
  const { t } = useI18n()
  const { centre } = useStaff()
  return (
    <StaffShell title={t('dashboard.title')}>
      {centre !== null && <Figures centreId={centre.id} />}
    </StaffShell>
  )
}
