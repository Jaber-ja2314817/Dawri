import { useLocation } from 'react-router-dom'
import { StaffShell } from '../../components/staff/StaffShell'
import { ErrorBlock } from '../../components/ui'
import { DeskConsole } from '../../features/staff/desk/DeskConsole'
import { useI18n } from '../../i18n'
import { useStaff } from '../../state/staff/session'

export default function Desk() {
  const { t } = useI18n()
  const { centreCounters } = useStaff()
  const { key } = useLocation()
  const triage = centreCounters.find((counter) => counter.stage === 'triage') ?? null
  return (
    <StaffShell title={t('desk.title')} subtitle={t('desk.subtitle')}>
      {/* A reset lands back here on a new key, which drops a slip for a ticket now gone. */}
      {triage === null ? (
        <ErrorBlock message={t('desk.noTriage')} />
      ) : (
        <DeskConsole key={key} counter={triage} />
      )}
    </StaffShell>
  )
}
