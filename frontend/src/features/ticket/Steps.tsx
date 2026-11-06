import type { VisitStage } from '../../api/types'
import { CheckIcon } from '../../components/icons'
import { useI18n } from '../../i18n'
import { cx } from '../../lib/cx'

const STEPS = [
  { stage: 'triage', label: 'ticket.stepTriage' },
  { stage: 'doctor', label: 'ticket.stepDoctor' },
  { stage: 'pharmacy', label: 'ticket.stepPharmacy' },
] as const

export function Steps({ stage }: { stage: VisitStage }) {
  const { t } = useI18n()
  const current = STEPS.findIndex((step) => step.stage === stage)
  return (
    <ol aria-label={t('ticket.stepsLabel')} className="grid w-full grid-cols-3 gap-2">
      {STEPS.map((step, index) => {
        const isCurrent = index === current
        const isDone = current !== -1 && index < current
        return (
          <li
            key={step.stage}
            aria-current={isCurrent ? 'step' : undefined}
            data-testid={`step-${step.stage}`}
            className={cx(
              'flex flex-col items-center gap-1 text-sm transition-colors',
              isCurrent ? 'font-semibold text-data' : isDone ? 'text-ink' : 'text-muted',
            )}
          >
            <span className="flex size-4 items-center justify-center" aria-hidden="true">
              {isDone ? (
                <CheckIcon />
              ) : (
                <span
                  className={cx(
                    'size-3 rounded-full border-2',
                    isCurrent ? 'border-data bg-data' : 'border-control',
                  )}
                />
              )}
            </span>
            {t(step.label)}
          </li>
        )
      })}
    </ol>
  )
}
