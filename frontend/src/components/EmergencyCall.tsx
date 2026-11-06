import { useI18n } from '../i18n'
import { PhoneIcon } from './icons'
import { buttonClass } from './ui'

/** The part of S06 that needs nothing from the server, so it never waits for anything. */
export function EmergencyCall() {
  const { t } = useI18n()
  return (
    <a
      href="tel:999"
      data-testid="emergency-call"
      className={buttonClass('inverse', 'min-h-14 w-full text-xl font-semibold')}
    >
      <PhoneIcon size={20} />
      {t('emergency.call')}
    </a>
  )
}

export function EmergencyTitle() {
  const { t } = useI18n()
  return <h1 className="text-2xl font-semibold">{t('emergency.title')}</h1>
}
