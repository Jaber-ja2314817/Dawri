import type { CentreOption } from '../../api/types'
import { CheckIcon } from '../../components/icons'
import { Card, Pill } from '../../components/ui'
import { useI18n } from '../../i18n'
import { cx } from '../../lib/cx'
import { centreName } from '../../lib/format'
import { Count, Kilometres, Minutes } from '../ticket/Values'

interface CentreListProps {
  centres: CentreOption[]
  selectedId: string | null
  onSelect: (id: string) => void
}

function CentreRow({
  centre,
  chosen,
  onSelect,
}: {
  centre: CentreOption
  chosen: boolean
  onSelect: () => void
}) {
  const { t, lang } = useI18n()
  return (
    <li className="border-t border-rule first:border-t-0">
      <button
        type="button"
        aria-pressed={chosen}
        data-testid="centre-row"
        data-centre-id={centre.id}
        onClick={onSelect}
        className={cx(
          'flex min-h-11 w-full cursor-pointer items-center gap-3 px-4 py-2 text-start transition-colors',
          chosen ? 'bg-ground' : 'hover:bg-ground',
        )}
      >
        <span className="min-w-0 flex-1">
          <span className="block text-sm font-medium">{centreName(centre, lang)}</span>
          <span className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-muted">
            {centre.registered && <Pill>{t('centre.yourCentre')}</Pill>}
            <span>
              {t('centre.peopleAhead')} <Count value={centre.people_ahead} />
            </span>
            {centre.distance_km !== null && <Kilometres value={centre.distance_km} />}
          </span>
        </span>
        <span className="text-base font-semibold">
          <Minutes value={centre.wait_min} />
        </span>
        <CheckIcon className={chosen ? 'text-ink' : 'invisible'} />
      </button>
    </li>
  )
}

export function CentreList({ centres, selectedId, onSelect }: CentreListProps) {
  const { t } = useI18n()
  return (
    <Card as="ul" flush aria-label={t('centre.listLabel')} className="overflow-hidden">
      {centres.map((centre) => (
        <CentreRow
          key={centre.id}
          centre={centre}
          chosen={centre.id === selectedId}
          onSelect={() => onSelect(centre.id)}
        />
      ))}
    </Card>
  )
}
