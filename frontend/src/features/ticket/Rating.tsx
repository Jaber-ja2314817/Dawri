import { useState } from 'react'
import { ApiError, errorText } from '../../api/client'
import { rateVisit } from '../../api/endpoints'
import { Ltr } from '../../components/ui'
import { useI18n } from '../../i18n'
import { cx } from '../../lib/cx'

const STARS = [1, 2, 3, 4, 5]

function Star({ filled }: { filled: boolean }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={24}
      height={24}
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinejoin="round"
      aria-hidden="true"
      className={cx('shrink-0', filled ? 'fill-current' : 'fill-none')}
    >
      <path d="m12 3.5 2.6 5.3 5.9.9-4.3 4.1 1 5.8-5.2-2.7-5.2 2.7 1-5.8-4.3-4.1 5.9-.9L12 3.5Z" />
    </svg>
  )
}

interface RatingProps {
  visitId: string
  rating: number | null
  refetch: () => Promise<void>
}

export function Rating({ visitId, rating, refetch }: RatingProps) {
  const { t, lang } = useI18n()
  const [sent, setSent] = useState<number | null>(null)
  const [busy, setBusy] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  const shown = rating ?? sent

  const rate = async (stars: number) => {
    setBusy(true)
    setFailure(null)
    try {
      setSent((await rateVisit(visitId, stars)).rating)
      await refetch()
    } catch (cause) {
      if (cause instanceof ApiError && cause.code === 'already_rated') await refetch()
      else setFailure(errorText(cause, t, lang))
    } finally {
      setBusy(false)
    }
  }

  if (shown !== null) {
    return (
      <div data-testid="rating-read-only" className="flex flex-col gap-1">
        <p
          role="img"
          aria-label={t('complete.stars', { stars: shown })}
          className="flex gap-1 text-ink"
        >
          {STARS.map((star) => (
            <Star key={star} filled={star <= shown} />
          ))}
        </p>
        <p className="text-sm text-muted">
          {t('complete.thanks')} (<Ltr>{shown}/5</Ltr>)
        </p>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-1">
      <div role="group" aria-label={t('complete.rate')} className="flex gap-1">
        {STARS.map((star) => (
          <button
            key={star}
            type="button"
            disabled={busy}
            aria-label={t('complete.stars', { stars: star })}
            data-testid="rate-star"
            onClick={() => void rate(star)}
            className="flex size-11 cursor-pointer items-center justify-center rounded-control text-ink hover:bg-ground disabled:cursor-not-allowed disabled:text-muted"
          >
            <Star filled={false} />
          </button>
        ))}
      </div>
      {failure !== null && (
        <p role="alert" className="text-sm text-negative">
          {failure}
        </p>
      )}
    </div>
  )
}
