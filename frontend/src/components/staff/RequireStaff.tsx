import { Navigate, Outlet } from 'react-router-dom'
import { errorText } from '../../api/client'
import type { StaffRole } from '../../api/staffTypes'
import { useI18n } from '../../i18n'
import { roleHome } from '../../state/staff/roles'
import { useStaff } from '../../state/staff/session'
import { ErrorBlock, Skeleton } from '../ui'
import { StaffShell } from './StaffShell'

function Waiting() {
  const { t, lang } = useI18n()
  const { state, error, reload } = useStaff()
  return (
    <StaffShell title={t('common.product')}>
      {state === 'error' ? (
        <ErrorBlock message={errorText(error, t, lang)} onRetry={() => void reload()} />
      ) : (
        <Skeleton height={44} />
      )}
    </StaffShell>
  )
}

/** Signed out goes to login. With `roles`, a wrong role goes to that person's own console. */
export function RequireStaff({ roles }: { roles?: StaffRole[] }) {
  const { token, staff } = useStaff()
  if (token === null) return <Navigate to="/staff/login" replace />
  if (staff === null) return <Waiting />
  if (roles !== undefined && !roles.includes(staff.role)) {
    return <Navigate to={roleHome(staff.role)} replace />
  }
  return <Outlet />
}

/** /staff itself. */
export function StaffIndex() {
  const { token, staff } = useStaff()
  if (token === null) return <Navigate to="/staff/login" replace />
  if (staff === null) return <Waiting />
  return <Navigate to={roleHome(staff.role)} replace />
}

export default RequireStaff
