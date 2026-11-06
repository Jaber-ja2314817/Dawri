import { Link } from 'react-router-dom'
import { PatientShell } from '../../components/PatientShell'
import { buttonClass, Title } from '../../components/ui'
import { useI18n } from '../../i18n'

export default function Welcome() {
  const { t } = useI18n()
  return (
    <PatientShell fill>
      <div className="flex flex-1 flex-col justify-center gap-3 pb-12">
        <Title>{t('common.product')}</Title>
        <p className="text-base text-muted">{t('welcome.purpose')}</p>
        <Link to="/login" className={buttonClass('primary', 'mt-3 w-full')}>
          {t('welcome.login')}
        </Link>
      </div>
    </PatientShell>
  )
}
