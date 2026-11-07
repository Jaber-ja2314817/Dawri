import { useI18n } from '../../i18n'
import { recordTerm } from '../../i18n/record'
import { dohaTime, minutesSince } from '../../state/staff/time'
import { Card, Ltr, Pill } from '../ui'

const DASH = '—'

interface PatientBannerProps {
  number: string | null
  patient: {
    name_en: string
    name_ar: string
    age: number
    sex: string
    allergies: string[]
  }
  arrivedAt: string | null
  /** Worked out from arrivedAt when left out. */
  waitingMin?: number | null
}

export function PatientBanner({ number, patient, arrivedAt, waitingMin }: PatientBannerProps) {
  const { t, lang } = useI18n()
  const waited = waitingMin ?? (arrivedAt === null ? null : minutesSince(arrivedAt))
  return (
    <Card data-testid="patient-banner" className="flex flex-col gap-2">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <span
          data-testid="banner-number"
          className={number === null ? 'text-base text-muted' : 'text-xl font-semibold text-data'}
        >
          <Ltr>{number ?? DASH}</Ltr>
        </span>
        <span className="min-w-0 text-base font-semibold">
          {lang === 'ar' ? patient.name_ar : patient.name_en}
        </span>
        <span className="text-sm text-muted">
          {t(`queue.sex.${patient.sex}`)} · <Ltr>{patient.age}</Ltr>
        </span>
        <span className="text-sm text-muted">
          {t('queue.arrived')} <Ltr>{arrivedAt === null ? DASH : dohaTime(arrivedAt)}</Ltr>
        </span>
        <span className="text-sm text-muted">
          {t('queue.waitingFor')} <Ltr>{waited ?? DASH}</Ltr> {t('queue.minutes')}
        </span>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        {patient.allergies.length === 0 ? (
          <Pill>{t('queue.noAllergies')}</Pill>
        ) : (
          patient.allergies.map((allergy) => (
            <span key={allergy} data-testid="allergy-flag" className="inline-flex">
              <Pill tone="negative">{recordTerm(allergy, lang)}</Pill>
            </span>
          ))
        )}
      </div>
    </Card>
  )
}

export default PatientBanner
