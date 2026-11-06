import type { ReactNode } from 'react'
import type { StaffVisit, Urgency, VitalsRow } from '../../../api/staffTypes'
import { Card, Ltr, Pill } from '../../../components/ui'
import { useI18n } from '../../../i18n'
import { cx } from '../../../lib/cx'

const DASH = '—'

/** A missing value is a grey dash, never a blank and never a zero. */
function Vital({
  id,
  label,
  value,
  className,
}: {
  id: string
  label: string
  value: string | null
  className?: string
}) {
  return (
    <div className={cx('flex flex-col gap-1', className)}>
      <dt className="text-xs text-muted">{label}</dt>
      <dd data-testid={`vital-${id}`} className="text-base font-medium tabular-nums">
        {value === null ? <span className="text-muted">{DASH}</span> : <Ltr>{value}</Ltr>}
      </dd>
    </div>
  )
}

const figure = (value: number | null | undefined) =>
  value === null || value === undefined ? null : String(value)

function bloodPressure(vitals: VitalsRow | null): string | null {
  if (vitals === null || vitals.bp_sys === null || vitals.bp_dia === null) return null
  return `${vitals.bp_sys}/${vitals.bp_dia}`
}

function Vitals({ vitals }: { vitals: VitalsRow | null }) {
  const { t } = useI18n()
  const temperature = vitals?.temp_c
  return (
    <dl data-testid="vitals" className="grid grid-cols-2 gap-x-3 gap-y-2 sm:grid-cols-5">
      <Vital
        id="bp"
        label={t('doctor.vitals.bp')}
        value={bloodPressure(vitals)}
        className="max-sm:col-span-2"
      />
      <Vital id="hr" label={t('doctor.vitals.hr')} value={figure(vitals?.hr)} />
      <Vital
        id="temp"
        label={t('doctor.vitals.temp')}
        value={
          temperature === null || temperature === undefined ? null : temperature.toFixed(1)
        }
      />
      <Vital id="spo2" label={t('doctor.vitals.spo2')} value={figure(vitals?.spo2)} />
      <Vital id="weight" label={t('doctor.vitals.weight')} value={figure(vitals?.weight_kg)} />
    </dl>
  )
}

function Label({ children }: { children: ReactNode }) {
  return <p className="text-xs text-muted">{children}</p>
}

function UrgencyPill({ urgency }: { urgency: Urgency | null }) {
  const { t } = useI18n()
  if (urgency === null) return <Pill>{DASH}</Pill>
  return (
    <span data-testid="urgency" data-urgency={urgency} className="inline-flex">
      <Pill tone={urgency === 'routine' ? 'neutral' : 'warning'}>
        {t(`doctor.urgency.${urgency}`)}
      </Pill>
    </span>
  )
}

/** What the nurse confirmed. The AI's draft is not on this screen. */
export function HandoffCard({ visit }: { visit: StaffVisit }) {
  const { t } = useI18n()
  const complaint = visit.intake?.chief_complaint
  return (
    <Card className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
        <h2 className="text-base font-semibold">{t('doctor.handoff.title')}</h2>
        <UrgencyPill urgency={visit.vitals?.urgency ?? null} />
      </div>
      <div className="flex flex-col gap-1">
        <Label>{t('doctor.handoff.complaint')}</Label>
        <p data-testid="handoff-complaint" className="text-base">
          {complaint ? <bdi>{complaint}</bdi> : <span className="text-muted">{DASH}</span>}
        </p>
      </div>
      <div className="flex flex-col gap-1">
        <Label>{t('doctor.handoff.confirmed')}</Label>
        <p
          data-testid="handoff-card"
          dir="ltr"
          className="text-start text-base whitespace-pre-wrap [overflow-wrap:anywhere]"
        >
          {visit.handoff?.final_text || <span className="text-muted">{DASH}</span>}
        </p>
      </div>
      <Vitals vitals={visit.vitals} />
      <details data-testid="doctor-patient-words" className="border-t border-rule">
        <summary className="min-h-11 cursor-pointer py-3 text-sm font-medium">
          {t('doctor.handoff.words', { count: visit.patient_words.length })}
        </summary>
        {visit.patient_words.length === 0 ? (
          <p className="pb-2 text-sm text-muted">{t('doctor.handoff.noWords')}</p>
        ) : (
          <ol className="flex flex-col gap-2 pb-2">
            {visit.patient_words.map((words, index) => (
              <li key={index} dir="auto" className="text-sm whitespace-pre-wrap">
                {words}
              </li>
            ))}
          </ol>
        )}
      </details>
    </Card>
  )
}

export default HandoffCard
