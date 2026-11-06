import { Link } from 'react-router-dom'
import { StaffShell } from '../../components/staff/StaffShell'
import { buttonClass } from '../../components/ui'
import { useI18n } from '../../i18n'
import { roleHome } from '../../state/staff/roles'
import { useStaff } from '../../state/staff/session'

export default function StaffNotFound() {
  const { t } = useI18n()
  const { staff } = useStaff()
  return (
    <StaffShell title={t('staff.notFound.title')}>
      <p data-testid="staff-not-found" className="text-base text-muted">
        {t('staff.notFound.body')}
      </p>
      <Link
        to={staff === null ? '/staff/login' : roleHome(staff.role)}
        className={buttonClass('secondary', 'self-start')}
      >
        {t(staff === null ? 'staff.notFound.login' : 'staff.notFound.home')}
      </Link>
    </StaffShell>
  )
}
