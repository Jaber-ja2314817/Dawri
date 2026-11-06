import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { errorText } from '../../../api/client'
import type { Centre } from '../../../api/types'
import { AiMode } from '../../../components/staff/AiMode'
import { Button, ErrorBlock, Skeleton } from '../../../components/ui'
import { translate, useI18n, type Lang } from '../../../i18n'
import { useDisplay } from '../../../state/staff/hooks'
import { roleHome } from '../../../state/staff/roles'
import { useStaff } from '../../../state/staff/session'
import { dohaTime } from '../../../state/staff/time'
import { Both } from './Both'
import { DisplayCell } from './DisplayCell'
import { displayOrder } from './order'
import { useChimes, type Chimes } from './useChimes'
import './display.css'

const THEME = '#f2f4f7'
const TICK_MS = 1_000
const LOADING_CELLS = [0, 1, 2, 3, 4, 5]

function Clock() {
  const [now, setNow] = useState(() => new Date())
  useEffect(() => {
    const timer = setInterval(() => setNow(new Date()), TICK_MS)
    return () => clearInterval(timer)
  }, [])
  return (
    <span data-testid="display-clock" className="text-base font-medium tabular-nums">
      {dohaTime(now.toISOString())}
    </span>
  )
}

function SoundToggle({ sound, soundFailed, toggleSound }: Chimes) {
  return (
    <>
      <Button
        variant="secondary"
        data-testid="sound-toggle"
        data-sound={sound ? 'on' : 'off'}
        aria-pressed={sound}
        className="px-3 text-sm"
        onClick={toggleSound}
      >
        <Both name={sound ? 'display.sound.on' : 'display.sound.off'} />
      </Button>
      {soundFailed && (
        <p role="status" data-testid="sound-failed" className="text-sm text-muted">
          <Both name="display.sound.failed" />
        </p>
      )}
    </>
  )
}

function failure(error: unknown): string {
  const inLanguage = (lang: Lang) =>
    errorText(error, (key, vars) => translate(lang, key, vars), lang)
  return `${inLanguage('en')} / ${inLanguage('ar')}`
}

/** The waiting-room TV. It holds both languages itself, so the viewer's language and dir stop here. */
export function DisplayScreen({ centre }: { centre: Centre }) {
  const { t } = useI18n()
  const { staff } = useStaff()
  const { data, state, error, refetch, live } = useDisplay(centre.id)
  const chimes = useChimes(data)

  useEffect(() => {
    const root = document.documentElement
    root.dataset.tone = 'default'
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', THEME)
    return () => {
      delete root.dataset.tone
    }
  }, [])

  useEffect(() => {
    document.title = `${t('display.title')} | ${t('common.product')}`
  }, [t])

  return (
    <div
      dir="ltr"
      data-tone="default"
      data-testid="display-root"
      data-chimes={chimes.chimes}
      data-live={live}
      className="flex min-h-dvh w-full flex-col gap-3 bg-ground px-4 pt-[env(safe-area-inset-top)] text-ink"
    >
      <header className="flex min-h-14 flex-wrap items-center gap-x-4 gap-y-1 border-b border-border py-1">
        <Link
          to={staff === null ? '/staff/login' : roleHome(staff.role)}
          data-testid="word-mark"
          className="flex min-h-11 items-center text-base font-semibold whitespace-nowrap no-underline"
        >
          دوري / Dawri
        </Link>
        <span data-testid="centre-name" className="min-w-0 text-sm font-medium">
          <span lang="en" dir="ltr">
            {centre.name_en}
          </span>
          {' / '}
          <span lang="ar" dir="rtl">
            {centre.name_ar}
          </span>
        </span>
        <span className="flex-1" />
        <Clock />
        <AiMode />
        <Link
          to="/staff/dashboard"
          data-testid="display-dashboard"
          className="flex min-h-11 items-center text-sm text-muted hover:text-ink"
        >
          <Both name="display.dashboard" />
        </Link>
        <SoundToggle {...chimes} />
      </header>

      <main className="flex min-w-0 flex-1 flex-col gap-3">
        <h1 className="text-xl font-semibold tracking-normal lg:text-2xl">
          <Both name="display.title" />
        </h1>
        {data === null && state === 'loading' && (
          <ul className="display-grid">
            {LOADING_CELLS.map((cell) => (
              <li key={cell}>
                <Skeleton height={160} className="h-full" />
              </li>
            ))}
          </ul>
        )}
        {data === null && state !== 'loading' && (
          <ErrorBlock
            message={failure(error)}
            onRetry={state === 'error' ? () => void refetch() : undefined}
          />
        )}
        {data !== null && (
          <ul className="display-grid">
            {displayOrder(data.counters).map((counter) => (
              <DisplayCell
                key={counter.id}
                counter={counter}
                marked={chimes.marked.has(counter.id)}
              />
            ))}
          </ul>
        )}
      </main>

      <footer
        data-testid="footer"
        className="pb-[max(12px,env(safe-area-inset-bottom))] text-center text-xs text-muted"
      >
        <p lang="en">{translate('en', 'footer.demo')}</p>
        <p lang="ar" dir="rtl">
          {translate('ar', 'footer.demo')}
        </p>
      </footer>
    </div>
  )
}
