import { useCallback, useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from 'react'
import { Link, NavLink, useLocation, useNavigate } from 'react-router-dom'
import { useI18n } from '../../i18n'
import { centreName } from '../../lib/format'
import { cx } from '../../lib/cx'
import { roleHome } from '../../state/staff/roles'
import { useStaff } from '../../state/staff/session'
import type { LiveMode } from '../../state/staff/useLive'
import { LanguageToggle } from '../PatientShell'
import { Button, Notice } from '../ui'
import { AiMode } from './AiMode'
import { ResetDemo } from './ResetDemo'

const THEME = '#f2f4f7'
const NARROW = '(max-width: 1023px)'

function subscribeNarrow(listener: () => void) {
  if (typeof window.matchMedia !== 'function') return () => {}
  const query = window.matchMedia(NARROW)
  query.addEventListener('change', listener)
  return () => query.removeEventListener('change', listener)
}

/** Rendered, not hidden, so each test id and control exists once at any width. */
function useNarrow(): boolean {
  return useSyncExternalStore(subscribeNarrow, () =>
    typeof window.matchMedia === 'function' ? window.matchMedia(NARROW).matches : false,
  )
}

function WordMark({ to }: { to: string }) {
  return (
    <Link
      to={to}
      data-testid="word-mark"
      className="flex min-h-11 min-w-0 items-center overflow-hidden text-base font-semibold whitespace-nowrap"
    >
      دوري / Dawri
    </Link>
  )
}

function LiveState({ live }: { live: LiveMode }) {
  const { t } = useI18n()
  return (
    <span
      data-testid="live-state"
      data-live={live}
      role="status"
      className="inline-flex shrink-0 items-center gap-2 text-sm text-muted"
    >
      <span
        aria-hidden="true"
        className={cx('size-2 rounded-full', live === 'live' ? 'bg-positive' : 'bg-warning')}
      />
      {t(`staff.live.${live}`)}
    </span>
  )
}

function useNavItems(): { key: string; to: string }[] {
  const { staff } = useStaff()
  if (staff === null) return []
  const own = {
    nurse: 'nurse',
    doctor: 'doctor',
    pharmacist: 'pharmacy',
    desk: 'desk',
  }[staff.role]
  return [
    { key: own, to: roleHome(staff.role) },
    ...(staff.role === 'nurse' ? [{ key: 'desk', to: '/staff/desk' }] : []),
    { key: 'display', to: '/staff/display' },
    { key: 'dashboard', to: '/staff/dashboard' },
  ]
}

function Nav({ sheet = false }: { sheet?: boolean }) {
  const { t } = useI18n()
  const items = useNavItems()
  return (
    <nav aria-label={t('staff.menu.label')} className={cx('flex gap-1', sheet && 'flex-col')}>
      {items.map((item) => (
        <NavLink
          key={item.key}
          to={item.to}
          data-testid={`staff-nav-${item.key}`}
          className={({ isActive }) =>
            cx(
              'flex min-h-11 items-center rounded-control px-3 text-sm whitespace-nowrap no-underline',
              isActive ? 'bg-raised font-medium text-ink' : 'text-muted hover:text-ink',
            )
          }
        >
          {t(`staff.nav.${item.key}`)}
        </NavLink>
      ))}
    </nav>
  )
}

function Who({ stacked = false }: { stacked?: boolean }) {
  const { t, lang } = useI18n()
  const { staff, centre } = useStaff()
  if (staff === null || centre === null) return null
  return (
    <div className={cx('flex min-w-0 text-sm', stacked ? 'flex-col gap-1' : 'items-center gap-3')}>
      <span data-testid="centre-name" className="truncate font-medium">
        {centreName(centre, lang)}
      </span>
      <span data-testid="staff-name" className="truncate text-muted">
        {staff.name} · {t(`staff.role.${staff.role}`)}
      </span>
    </div>
  )
}

function Logout() {
  const { t } = useI18n()
  const { signOut } = useStaff()
  return (
    <Button
      variant="quiet"
      data-testid="staff-logout"
      className="px-3 text-sm"
      onClick={signOut}
    >
      {t('staff.logout')}
    </Button>
  )
}

function MenuIcon({ open }: { open: boolean }) {
  return (
    <svg
      aria-hidden="true"
      width="20"
      height="20"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
    >
      <path d={open ? 'M6 6l12 12M18 6 6 18' : 'M4 7h16M4 12h16M4 17h16'} />
    </svg>
  )
}

/** Sits under the bar, so the AI pill is still on screen with the menu open. */
function Sheet({ live, onClose }: { live?: LiveMode | null; onClose: () => void }) {
  const { t } = useI18n()
  const { staff } = useStaff()
  const panel = useRef<HTMLDivElement>(null)

  useEffect(() => {
    panel.current?.focus()
    const { overflow } = document.body.style
    document.body.style.overflow = 'hidden'
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', onKey)
    return () => {
      document.body.style.overflow = overflow
      document.removeEventListener('keydown', onKey)
    }
  }, [onClose])

  return (
    <div
      ref={panel}
      id="staff-sheet"
      data-testid="staff-sheet"
      role="dialog"
      aria-modal="true"
      aria-label={t('staff.menu.label')}
      tabIndex={-1}
      className="fixed inset-0 z-10 flex flex-col gap-3 overflow-y-auto bg-ground px-4 pt-[calc(68px+env(safe-area-inset-top))] pb-6"
    >
      <Who stacked />
      {live && <LiveState live={live} />}
      {staff !== null && <Nav sheet />}
      <div className="flex flex-wrap items-center gap-2 border-t border-border pt-3">
        <LanguageToggle />
        {staff !== null && <ResetDemo onDone={onClose} />}
        {staff !== null && <Logout />}
      </div>
    </div>
  )
}

/** Router state outlives a reload, so a line is read once and taken out of history. */
function useCarriedNotice(): string | null {
  const location = useLocation()
  const navigate = useNavigate()
  const carried = (location.state as { staffNotice?: string } | null)?.staffNotice ?? null
  const [notice, setNotice] = useState(carried)

  useEffect(() => {
    if (carried === null) return
    setNotice(carried)
    navigate(location, { replace: true, state: null })
  }, [carried, location, navigate])

  return notice
}

export interface StaffShellProps {
  title: string
  subtitle?: ReactNode
  /** The screen's own controls, level with the title. */
  actions?: ReactNode
  /** Leave out on a page with no stream, which has nothing to reconnect. */
  live?: LiveMode | null
  children: ReactNode
}

export function StaffShell({ title, subtitle, actions, live, children }: StaffShellProps) {
  const { t } = useI18n()
  const { staff } = useStaff()
  const notice = useCarriedNotice()
  const narrow = useNarrow()
  const [open, setOpen] = useState(false)
  const menuButton = useRef<HTMLButtonElement>(null)
  const home = staff === null ? '/staff/login' : roleHome(staff.role)

  useEffect(() => {
    const root = document.documentElement
    root.dataset.tone = 'default'
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', THEME)
    return () => {
      delete root.dataset.tone
    }
  }, [])

  useEffect(() => {
    document.title = `${title} | ${t('common.product')}`
  }, [title, t])

  useEffect(() => {
    if (!narrow) setOpen(false)
  }, [narrow])

  const closeSheet = useCallback(() => {
    setOpen(false)
    menuButton.current?.focus()
  }, [])

  return (
    <div data-tone="default" className="flex min-h-dvh w-full flex-col bg-ground text-ink">
      <header
        className={cx(
          'border-b border-border bg-ground pt-[env(safe-area-inset-top)]',
          narrow && 'sticky top-0 z-20',
        )}
      >
        <div className="mx-auto flex min-h-14 w-full max-w-[1200px] items-center gap-3 px-4">
          <WordMark to={home} />
          {narrow ? (
            <>
              <span className="flex-1" />
              <AiMode />
              {staff === null && <LanguageToggle />}
              {staff !== null && (
                <button
                  ref={menuButton}
                  type="button"
                  data-testid="staff-menu"
                  aria-expanded={open}
                  aria-controls="staff-sheet"
                  aria-label={t(open ? 'staff.menu.close' : 'staff.menu.open')}
                  onClick={() => setOpen((current) => !current)}
                  className="flex size-11 shrink-0 cursor-pointer items-center justify-center rounded-control border border-control bg-surface text-ink"
                >
                  <MenuIcon open={open} />
                </button>
              )}
            </>
          ) : (
            <>
              <Who />
              <span className="flex-1" />
              {live && <LiveState live={live} />}
              <AiMode />
              <LanguageToggle />
              {staff !== null && <ResetDemo />}
              {staff !== null && <Logout />}
            </>
          )}
        </div>
        {!narrow && staff !== null && (
          <div className="mx-auto w-full max-w-[1200px] px-4 pb-2">
            <Nav />
          </div>
        )}
      </header>
      {narrow && open && <Sheet live={live} onClose={closeSheet} />}

      <main className="mx-auto flex w-full max-w-[1200px] min-w-0 flex-1 flex-col gap-3 px-4 pt-6 pb-6">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex min-w-0 flex-col gap-1">
            <h1 className="text-xl font-semibold tracking-normal">{title}</h1>
            {subtitle && <p className="text-sm text-muted">{subtitle}</p>}
          </div>
          {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
        </div>
        {notice && <Notice data-testid="staff-notice">{t(notice)}</Notice>}
        {children}
      </main>

      <footer
        data-testid="footer"
        className="px-4 pt-3 pb-[max(12px,env(safe-area-inset-bottom))] text-center text-xs text-muted"
      >
        <p>{t('footer.demo')}</p>
      </footer>
    </div>
  )
}

export default StaffShell
