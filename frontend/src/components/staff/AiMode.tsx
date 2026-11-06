import { useI18n } from '../../i18n'
import { useHealth } from '../../state/session'
import { Pill } from '../ui'

/** Staff always see this: simulated output is never passed off as a model. */
export function AiMode() {
  const { t } = useI18n()
  const { aiMode } = useHealth()
  const mode = aiMode ?? 'unknown'
  const text =
    aiMode === 'simulated'
      ? t('footer.ai')
      : aiMode === 'real'
        ? t('staff.ai.model')
        : t('staff.ai.checking')
  return (
    <span data-testid="ai-mode" data-mode={mode} className="inline-flex shrink-0">
      <Pill tone={aiMode === 'simulated' ? 'warning' : 'neutral'}>{text}</Pill>
    </span>
  )
}
