import type {
  ButtonHTMLAttributes,
  ComponentProps,
  ElementType,
  InputHTMLAttributes,
  ReactNode,
} from 'react'
import { useId } from 'react'
import { useI18n } from '../i18n'
import { cx } from '../lib/cx'

export type ButtonVariant = 'primary' | 'secondary' | 'quiet' | 'inverse'

const BUTTON_BASE =
  'inline-flex min-h-11 items-center justify-center gap-2 rounded-control border px-4 py-2 ' +
  'text-base font-medium no-underline transition-colors cursor-pointer disabled:cursor-not-allowed'

const BUTTON_VARIANTS: Record<ButtonVariant, string> = {
  primary:
    'border-transparent bg-ink text-white hover:bg-ink-hover disabled:bg-control disabled:text-ink',
  secondary: 'border-control bg-surface text-ink hover:bg-ground disabled:text-muted',
  quiet:
    'border-transparent bg-transparent text-current underline-offset-4 hover:underline disabled:opacity-70',
  inverse: 'border-transparent bg-white text-ink hover:bg-raised disabled:text-muted',
}

/** The button's look for a link, such as tel:999 or a route. */
export function buttonClass(variant: ButtonVariant = 'primary', className?: string): string {
  return cx(BUTTON_BASE, BUTTON_VARIANTS[variant], className)
}

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant
  loading?: boolean
}

export function Button({
  variant = 'primary',
  loading = false,
  disabled,
  className,
  children,
  type = 'button',
  ...rest
}: ButtonProps) {
  return (
    <button
      type={type}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      className={buttonClass(variant, className)}
      {...rest}
    >
      {loading && (
        <span
          aria-hidden="true"
          className="size-4 shrink-0 animate-spin rounded-full border-2 border-current border-b-transparent"
        />
      )}
      {children}
    </button>
  )
}

/** `flush` drops the padding, for rows that carry their own. */
type CardProps<T extends ElementType> = { as?: T; flush?: boolean } & ComponentProps<T>

export function Card<T extends ElementType = 'div'>({
  as,
  flush = false,
  className,
  ...rest
}: CardProps<T>) {
  const Element: ElementType = as ?? 'div'
  return (
    <Element
      className={cx(
        'rounded-panel border border-border bg-surface text-ink',
        !flush && 'p-4',
        className,
      )}
      {...rest}
    />
  )
}

export type PillTone = 'positive' | 'negative' | 'warning' | 'neutral'

const PILL_TONES: Record<PillTone, string> = {
  positive: 'bg-pill-positive-bg text-pill-positive-ink',
  negative: 'bg-pill-negative-bg text-pill-negative-ink',
  warning: 'bg-pill-warning-bg text-pill-warning-ink',
  neutral: 'bg-pill-neutral-bg text-pill-neutral-ink',
}

export function Pill({
  tone = 'neutral',
  className,
  children,
}: {
  tone?: PillTone
  className?: string
  children: ReactNode
}) {
  return (
    <span
      className={cx(
        'inline-flex h-6 shrink-0 items-center rounded-full px-2 text-xs font-medium whitespace-nowrap',
        PILL_TONES[tone],
        className,
      )}
    >
      {children}
    </span>
  )
}

interface FieldProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string
  error?: string | null
  hint?: string
}

export function Field({ label, error, hint, id, className, ...rest }: FieldProps) {
  const generated = useId()
  const inputId = id ?? generated
  const noteId = `${inputId}-note`
  return (
    <div className={cx('flex flex-col gap-2', className)}>
      <label htmlFor={inputId} className="text-sm font-medium">
        {label}
      </label>
      <input
        id={inputId}
        aria-invalid={error ? true : undefined}
        aria-describedby={error || hint ? noteId : undefined}
        className={cx(
          'min-h-11 w-full rounded-control border bg-surface px-3 text-base text-ink placeholder:text-muted',
          error ? 'border-negative' : 'border-control',
        )}
        {...rest}
      />
      {error ? (
        <p id={noteId} className="text-sm text-negative">
          {error}
        </p>
      ) : (
        hint && (
          <p id={noteId} className="text-xs text-muted">
            {hint}
          </p>
        )
      )}
    </div>
  )
}

export function Title({ className, children }: { className?: string; children: ReactNode }) {
  return (
    <h1 className={cx('text-xl font-semibold tracking-normal sm:text-2xl', className)}>
      {children}
    </h1>
  )
}

/** Ticket numbers, codes and clocks stay left to right inside Arabic text. */
export function Ltr({ className, children }: { className?: string; children: ReactNode }) {
  return (
    <bdi dir="ltr" className={className}>
      {children}
    </bdi>
  )
}

/** A flat grey bar at the real size of what will land there. */
export function Skeleton({
  width,
  height = 16,
  className,
}: {
  width?: number | string
  height?: number | string
  className?: string
}) {
  return (
    <span
      aria-hidden="true"
      className={cx('block max-w-full rounded-control bg-raised', className)}
      style={{ width: width ?? '100%', height }}
    />
  )
}

/** Stays inside the block that failed, never full screen. */
export function ErrorBlock({ message, onRetry }: { message: string; onRetry?: () => void }) {
  const { t } = useI18n()
  return (
    <div
      role="alert"
      className="flex flex-wrap items-center justify-between gap-x-3 rounded-panel border border-border bg-surface px-4 py-2 text-sm text-ink"
    >
      <p className="min-w-0 py-1">{message}</p>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="min-h-11 cursor-pointer font-medium underline underline-offset-4"
        >
          {t('common.retry')}
        </button>
      )}
    </div>
  )
}

export function Notice({ className, ...rest }: ComponentProps<'p'>) {
  return (
    <p
      role="status"
      className={cx(
        'rounded-control border border-notice-border bg-pill-warning-bg px-3 py-2 text-sm text-warning',
        className,
      )}
      {...rest}
    />
  )
}
