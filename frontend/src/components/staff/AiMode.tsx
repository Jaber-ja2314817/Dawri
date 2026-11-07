import { Both } from '../../features/staff/display/Both'
import { useI18n } from '../../i18n'
import { useHealth } from '../../state/session'
import { Pill } from '../ui'

/**
 * Staff always see this: simulated output is never passed off as a model.
 * `both` is for the waiting-room display, which never follows the viewer's language.
 */
export function AiMode({ both = false }: { both?: boolean }) {
  const { t } = useI18n()
  const { aiMode } = useHealth()
  const mode = aiMode ?? 'unknown'
  const name =
    aiMode === 'simulated'
      ? 'footer.ai'
      : aiMode === 'real'
        ? 'staff.ai.model'
        : 'staff.ai.checking'
  return (
    <span data-testid="ai-mode" data-mode={mode} className="inline-flex shrink-0">
      <Pill tone={aiMode === 'simulated' ? 'warning' : 'neutral'}>
        {both ? <Both name={name} /> : t(name)}
      </Pill>
    </span>
  )
}
