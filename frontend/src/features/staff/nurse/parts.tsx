import type { ReactNode, TextareaHTMLAttributes } from 'react'
import { useId } from 'react'
import { Link } from 'react-router-dom'
import { buttonClass } from '../../../components/ui'
import { cx } from '../../../lib/cx'

export const QUEUE_PATH = '/staff/nurse'

export const visitPath = (visitId: string) => `/staff/nurse/${encodeURIComponent(visitId)}`
export const handoffPath = (visitId: string) => `${visitPath(visitId)}/handoff`

/*
 * T04, at the shell's 1168 px of content (1200 less 16 + 16 gutters):
 * 744 text + 12 gap + 412 doctors = 1168. Stacked below 1100 px.
 */
export const TWO_COLUMNS =
  'grid min-w-0 grid-cols-1 items-start gap-3 min-[1100px]:grid-cols-[minmax(0,744fr)_minmax(0,412fr)]'

export const CONTROL =
  'min-h-11 w-full rounded-control border border-control bg-surface px-3 text-base text-ink'

export const DASH = '—'

/** A missing value, in grey. */
export function Dash() {
  return <span className="text-muted">{DASH}</span>
}

export function QuietLink({
  to,
  testId,
  children,
}: {
  to: string
  testId?: string
  children: ReactNode
}) {
  return (
    <Link to={to} data-testid={testId} className={buttonClass('quiet', 'self-start px-0 text-sm')}>
      {children}
    </Link>
  )
}

interface TextBoxProps extends TextareaHTMLAttributes<HTMLTextAreaElement> {
  label: string
}

export function TextBox({ label, className, ...rest }: TextBoxProps) {
  const id = useId()
  return (
    <div className="flex flex-col gap-2">
      <label htmlFor={id} className="text-sm font-medium">
        {label}
      </label>
      <textarea id={id} className={cx(CONTROL, 'py-2', className)} {...rest} />
    </div>
  )
}
