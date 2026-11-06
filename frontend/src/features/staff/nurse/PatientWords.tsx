import type { Turn } from '../../../api/staffTypes'
import { Card } from '../../../components/ui'
import { useI18n } from '../../../i18n'
import { cx } from '../../../lib/cx'

/**
 * The nurse backstop (Build Decisions): a summary can drop a detail such as "with blood", so
 * every turn stays here, byte for byte, whatever the summary says and during editing too.
 * It is never cut, folded or scrolled away. Nothing on this page may hide this block.
 */
export function PatientWords({ turns }: { turns: Turn[] }) {
  const { t } = useI18n()
  return (
    <Card as="section" data-testid="patient-words" className="flex min-w-0 flex-col gap-3">
      <h2 className="text-base font-semibold">{t('nurse.words.title')}</h2>
      {turns.length === 0 ? (
        <p className="text-sm text-muted">{t('nurse.words.empty')}</p>
      ) : (
        <ol className="flex flex-col gap-3">
          {turns.map((turn, index) => (
            <li key={index} data-testid="turn" data-role={turn.role}>
              <span className="sr-only">{t(`nurse.words.${turn.role}`)}</span>
              <p
                dir="auto"
                className={cx(
                  'break-words whitespace-pre-wrap',
                  turn.role === 'patient' ? 'text-base text-ink' : 'text-sm text-muted',
                )}
              >
                {turn.text}
              </p>
            </li>
          ))}
        </ol>
      )}
    </Card>
  )
}
