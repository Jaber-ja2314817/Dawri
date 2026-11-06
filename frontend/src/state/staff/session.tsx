import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import { login, me } from '../../api/staff'
import type { CounterRef, OwnCounter, StaffMe, StaffMember } from '../../api/staffTypes'
import type { Centre } from '../../api/types'
import { useI18n } from '../../i18n'
import { clearStaffToken, getStaffToken, onStaffTokenChange, setStaffToken } from './staffToken'

export type StaffState = 'idle' | 'loading' | 'ready' | 'error'

interface StaffValue {
  token: string | null
  staff: StaffMember | null
  centre: Centre | null
  counters: OwnCounter[]
  centreCounters: CounterRef[]
  state: StaffState
  error: unknown
  signIn: (staffId: string) => Promise<void>
  signOut: () => void
  reload: () => Promise<void>
}

const StaffContext = createContext<StaffValue | null>(null)
const NONE: never[] = []

export function StaffSessionProvider({ children }: { children: ReactNode }) {
  const { lang, applyPreferred } = useI18n()
  const [token, setTokenState] = useState(getStaffToken)
  const [profile, setProfile] = useState<StaffMe | null>(null)
  const [state, setState] = useState<StaffState>(token === null ? 'idle' : 'loading')
  const [error, setError] = useState<unknown>(null)
  const request = useRef(0)
  const signingIn = useRef(false)

  const reload = useCallback(async () => {
    const mine = ++request.current
    setState((current) => (current === 'ready' ? current : 'loading'))
    setError(null)
    try {
      const next = await me()
      if (mine !== request.current) return
      setProfile(next)
      setState('ready')
    } catch (cause) {
      if (mine !== request.current) return
      setError(cause)
      setState((current) => (current === 'ready' ? current : 'error'))
    }
  }, [])

  useEffect(
    () =>
      onStaffTokenChange((next) => {
        setTokenState(next)
        if (next === null) {
          // Logout, or a 401 from anywhere: the guards then go to /staff/login.
          request.current += 1
          setProfile(null)
          setState('idle')
          setError(null)
        }
      }),
    [],
  )

  useEffect(() => {
    if (token !== null && !signingIn.current) void reload()
  }, [token, reload])

  // After reload() too: a patient signed in beside this session sets its own language on load,
  // and this provider sits on the staff routes alone. The viewer's own choice still wins.
  useEffect(() => {
    if (state === 'ready') applyPreferred('en')
  }, [state, lang, applyPreferred])

  const signIn = useCallback(
    async (staffId: string) => {
      const session = await login(staffId)
      signingIn.current = true
      setStaffToken(session.token)
      await reload()
      signingIn.current = false
      applyPreferred('en')
    },
    [reload, applyPreferred],
  )

  const signOut = useCallback(() => clearStaffToken(), [])

  const value = useMemo<StaffValue>(
    () => ({
      token,
      staff: profile?.staff ?? null,
      centre: profile?.centre ?? null,
      counters: profile?.counters ?? NONE,
      centreCounters: profile?.centre_counters ?? NONE,
      state,
      error,
      signIn,
      signOut,
      reload,
    }),
    [token, profile, state, error, signIn, signOut, reload],
  )

  return <StaffContext.Provider value={value}>{children}</StaffContext.Provider>
}

export function useStaff(): StaffValue {
  const value = useContext(StaffContext)
  if (value === null) throw new Error('useStaff needs a StaffSessionProvider above it')
  return value
}
