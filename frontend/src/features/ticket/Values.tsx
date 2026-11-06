import type { ReactNode } from 'react'
import { Ltr } from '../../components/ui'
import { useI18n, type Vars } from '../../i18n'

/** A value that is missing, as opposed to a real zero. */
export function Dash() {
  const { t } = useI18n()
  return (
    <span role="img" aria-label={t('ticket.notKnown')} data-testid="dash" className="text-muted">
      –
    </span>
  )
}

export function Count({ value }: { value: number | null }) {
  return value === null ? <Dash /> : <Ltr>{value}</Ltr>
}

/** The figure keeps its own direction and the unit follows the language. */
function Measure({ value, unit }: { value: number | null; unit: string }) {
  if (value === null) return <Dash />
  return (
    <span className="whitespace-nowrap">
      <Ltr>{value}</Ltr> {unit}
    </span>
  )
}

export function Minutes({ value }: { value: number | null }) {
  const { t } = useI18n()
  return <Measure value={value} unit={t('centre.unitMin')} />
}

export function Kilometres({ value }: { value: number | null }) {
  const { t } = useI18n()
  return <Measure value={value} unit={t('centre.unitKm')} />
}

export function Rows({ children }: { children: ReactNode }) {
  return <dl className="flex flex-col">{children}</dl>
}

export function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex min-h-11 items-center justify-between gap-3 border-t border-rule px-4 py-2 first:border-t-0">
      <dt className="text-sm text-muted">{label}</dt>
      <dd className="text-end text-base font-medium">{children}</dd>
    </div>
  )
}

/** A translated sentence with its figures kept left to right inside Arabic text. */
export function Filled({ text, vars }: { text: string; vars: Vars }) {
  return (
    <>
      {text.split(/(\{\w+\})/).map((part, index) => {
        const name = /^\{(\w+)\}$/.exec(part)?.[1]
        if (name === undefined || !(name in vars)) return part
        return <Ltr key={index}>{vars[name]}</Ltr>
      })}
    </>
  )
}
