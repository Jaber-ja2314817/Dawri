import { Link, useParams } from 'react-router-dom'
import type { MedicineLine, Visit } from '../../api/types'
import { CheckIcon } from '../../components/icons'
import { PatientShell } from '../../components/PatientShell'
import { buttonClass, Card, Ltr, Title } from '../../components/ui'
import { VisitGate } from '../../components/VisitGate'
import { Rating } from '../../features/ticket/Rating'
import { Filled } from '../../features/ticket/Values'
import { useI18n } from '../../i18n'
import { centreName } from '../../lib/format'

/** The server writes "name: how to take it". The name then heads the line instead of repeating. */
function splitLine(medicine: MedicineLine): { heading: string; directions: string } {
  const colon = medicine.line.indexOf(':')
  if (colon === -1) return { heading: medicine.name, directions: medicine.line }
  return {
    heading: medicine.line.slice(0, colon),
    directions: medicine.line.slice(colon + 1).trim(),
  }
}

function Medicines({ visit }: { visit: Visit }) {
  const { t, lang } = useI18n()
  const medicines = visit.medicines[lang]
  return (
    <Card as="section" aria-labelledby="medicines" className="flex flex-col gap-2">
      <h2 id="medicines" className="text-base font-semibold">
        {t('complete.medicines')}
      </h2>
      {medicines.length === 0 ? (
        <p data-testid="no-medicines" className="text-sm text-muted">
          {t('complete.noMedicines')}
        </p>
      ) : (
        <ul className="flex flex-col gap-3">
          {medicines.map((medicine, index) => {
            const { heading, directions } = splitLine(medicine)
            return (
              <li key={`${medicine.drug}-${index}`} data-testid="medicine" dir="auto">
                <p className="text-base font-medium" dir="auto">
                  {heading}
                </p>
                <p className="text-sm" dir="auto">
                  {directions}
                </p>
              </li>
            )
          })}
        </ul>
      )}
    </Card>
  )
}

function CompleteScreen({ visit, refetch }: { visit: Visit; refetch: () => Promise<void> }) {
  const { t, lang } = useI18n()
  return (
    <PatientShell>
      <div className="flex flex-col gap-1">
        <div className="flex items-center gap-2">
          <CheckIcon size={30} className="text-positive" data-testid="complete-check" />
          <Title>{t('complete.title')}</Title>
        </div>
        {visit.centre && <p className="text-sm text-muted">{centreName(visit.centre, lang)}</p>}
      </div>

      <Medicines visit={visit} />

      <Card as="section" aria-labelledby="follow-up" className="flex flex-col gap-2">
        <h2 id="follow-up" className="text-base font-semibold">
          {t('complete.followUp')}
        </h2>
        <p className="text-sm">
          <Filled text={t('complete.followUpLine')} vars={{ phone: 999 }} />
        </p>
      </Card>

      <Card as="section" aria-labelledby="rate" className="flex flex-col gap-2">
        <h2 id="rate" className="text-base font-semibold">
          {t('complete.rate')}
        </h2>
        <Rating visitId={visit.visit_id} rating={visit.rating} refetch={refetch} />
      </Card>

      <div className="flex items-center justify-between gap-3">
        <div className="flex gap-1">
          <Link to="/home" className={buttonClass('quiet', '-ms-4')}>
            {t('complete.home')}
          </Link>
          <Link to="/history" className={buttonClass('quiet')}>
            {t('complete.history')}
          </Link>
        </div>
        {visit.ticket?.number && (
          <p data-testid="final-ticket" className="text-xs text-muted">
            {t('complete.finalTicket')} <Ltr>{visit.ticket.number}</Ltr>
          </p>
        )}
      </div>
    </PatientShell>
  )
}

export default function Complete() {
  const { id = '' } = useParams()
  return (
    <VisitGate id={id} screen="complete">
      {(visit, refetch) => <CompleteScreen visit={visit} refetch={refetch} />}
    </VisitGate>
  )
}
