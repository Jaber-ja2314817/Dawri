import { useEffect, type ReactNode } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useI18n } from '../i18n'
import { cx } from '../lib/cx'
import { useHealth } from '../state/session'
import { ChevronIcon } from './icons'
import { Title } from './ui'

export type ShellTone = 'default' | 'emergency'

const THEME = { default: '#f2f4f7', emergency: '#c4242a' }

export function LanguageToggle({ tone = 'default' }: { tone?: ShellTone }) {
  const { lang, setLang } = useI18n()
  const other = lang === 'ar' ? 'en' : 'ar'
  return (
    <button
      type="button"
      lang={other}
      data-testid="language-toggle"
      onClick={() => setLang(other)}
      className={cx(
        'min-h-11 min-w-11 cursor-pointer rounded-control border px-3 text-sm font-medium transition-colors',
        tone === 'emergency'
          ? 'border-white text-white hover:bg-emergency-hover'
          : 'border-control bg-surface text-ink hover:bg-ground',
      )}
    >
      {other === 'ar' ? 'العربية' : 'English'}
    </button>
  )
}

export function Footer({ tone = 'default' }: { tone?: ShellTone }) {
  const { t } = useI18n()
  const { aiMode } = useHealth()
  return (
    <footer
      data-testid="footer"
      className={cx(
        'px-4 pt-3 pb-[max(12px,env(safe-area-inset-bottom))] text-center text-xs',
        tone === 'emergency' ? 'text-white' : 'text-muted',
      )}
    >
      <p>{t('footer.demo')}</p>
      {aiMode === 'simulated' && <p data-testid="footer-ai">{t('footer.ai')}</p>}
    </footer>
  )
}

function BackControl({ back, tone }: { back: string | (() => void); tone: ShellTone }) {
  const { t } = useI18n()
  const navigate = useNavigate()
  return (
    <button
      type="button"
      aria-label={t('common.back')}
      data-testid="back"
      onClick={() => (typeof back === 'string' ? navigate(back) : back())}
      className={cx(
        '-ms-3 flex size-11 shrink-0 cursor-pointer items-center justify-center rounded-control',
        tone === 'emergency' ? 'text-white' : 'text-ink',
      )}
    >
      <ChevronIcon back size={20} />
    </button>
  )
}

interface PatientShellProps {
  /** Renders the h1 first in the column. A page that sets its own <Title> leaves this out. */
  title?: string
  /** A path to go to, or a handler. */
  back?: string | (() => void)
  /** A wider column on desktop, for the map. */
  wide?: boolean
  /**
   * The column takes the height of the screen, with the footer at the very bottom, so a child
   * with flex-1 can fill it: chat with its composer, for example. Otherwise the footer simply
   * follows the content, which keeps a short screen from reading as a page with a hole in it.
   */
  fill?: boolean
  tone?: ShellTone
  children: ReactNode
}

export function PatientShell({
  title,
  back,
  wide = false,
  fill = false,
  tone = 'default',
  children,
}: PatientShellProps) {
  const { t } = useI18n()
  const column = cx('mx-auto w-full px-4', wide ? 'max-w-[800px]' : 'max-w-[480px]')
  const emergency = tone === 'emergency'

  useEffect(() => {
    // Overscroll and the phone's status bar belong to the screen as well.
    const root = document.documentElement
    root.dataset.tone = tone
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', THEME[tone])
    return () => {
      delete root.dataset.tone
      document.querySelector('meta[name="theme-color"]')?.setAttribute('content', THEME.default)
    }
  }, [tone])

  useEffect(() => {
    document.title = title ? `${title} | ${t('common.product')}` : t('common.product')
  }, [title, t])

  return (
    <div
      data-tone={tone}
      className={cx(
        'flex min-h-dvh w-full flex-col',
        emergency ? 'bg-emergency text-white' : 'bg-ground text-ink',
      )}
    >
      <header className="pt-[env(safe-area-inset-top)]">
        <div className={cx(column, 'flex min-h-14 items-center gap-2')}>
          {back !== undefined && <BackControl back={back} tone={tone} />}
          <Link to="/" className="flex min-h-11 min-w-11 items-center text-base font-semibold">
            {t('common.product')}
          </Link>
          <span className="flex-1" />
          <LanguageToggle tone={tone} />
        </div>
      </header>
      <main className={cx(column, 'flex min-w-0 flex-col gap-3 pt-2 pb-6', fill && 'flex-1')}>
        {title && <Title>{title}</Title>}
        {children}
      </main>
      <Footer tone={tone} />
    </div>
  )
}

export default PatientShell
