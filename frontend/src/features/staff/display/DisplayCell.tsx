import type { DisplayCounter } from '../../../api/staffTypes'
import { Card, Ltr } from '../../../components/ui'
import { Both } from './Both'

/** Numbers only. Nothing on this screen may ever name a patient. */
export function DisplayCell({ counter, marked }: { counter: DisplayCounter; marked: boolean }) {
  const { id, label, label_ar: labelAr, now_serving: nowServing, waiting } = counter
  return (
    <Card
      as="li"
      data-testid="display-counter"
      data-counter={id}
      data-serving={nowServing ?? ''}
      data-marked={marked && nowServing !== null}
      className="display-cell"
    >
      <p className="flex items-baseline justify-between gap-3 text-base font-medium lg:text-xl">
        <span data-testid="display-label-en" lang="en" dir="ltr">
          {label}
        </span>
        <span data-testid="display-label-ar" lang="ar" dir="rtl">
          {labelAr}
        </span>
      </p>
      <p data-testid="display-number" className="display-serving">
        {nowServing === null ? (
          <span className="display-serving-dash text-muted">—</span>
        ) : (
          <Ltr className="text-data">{nowServing}</Ltr>
        )}
      </p>
      <p className="text-center text-sm text-muted lg:text-base">
        <Both name="display.waiting" vars={{ count: waiting }} />
      </p>
    </Card>
  )
}
