import { Link } from 'react-router-dom'
import { PatientShell } from '../../components/PatientShell'
import { buttonClass } from '../../components/ui'
import { useI18n } from '../../i18n'

export default function NotFound() {
  const { t } = useI18n()
  return (
    <PatientShell title={t('notFound.title')}>
      <p className="text-base text-muted">{t('notFound.body')}</p>
      <Link to="/home" className={buttonClass('secondary', 'w-full')}>
        {t('notFound.home')}
      </Link>
    </PatientShell>
  )
}
