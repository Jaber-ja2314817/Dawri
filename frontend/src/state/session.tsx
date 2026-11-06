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
import { authStart, authVerify, getMe, health } from '../api/endpoints'
import type { AiMode, Me, Patient } from '../api/types'
import { useI18n } from '../i18n'
import { clearToken, getToken, onTokenChange, setToken } from './token'

const HEALTH_RETRY_MS = 10_000

// Inspector builds only. This expression is replaced at build time and the branch is gone
// from a normal build, so the URL can never set a session in the demo.
if (import.meta.env.VITE_INSPECT) {
  const inspectToken = new URLSearchParams(window.location.search).get('inspect_token')
  if (inspectToken) setToken(inspectToken)
}

export type MeState = 'idle' | 'loading' | 'ready' | 'error'

interface SessionValue {
  token: string | null
  patient: Patient | null
  me: Me | null
  meState: MeState
  meError: unknown
  signIn: (qid: string, otp: string) => Promise<void>
  signOut: () => void
  reloadMe: () => Promise<void>
}

const SessionContext = createContext<SessionValue | null>(null)
const HealthContext = createContext<{ aiMode: AiMode | null }>({ aiMode: null })

export function SessionProvider({ children }: { children: ReactNode }) {
  const { applyPreferred, resetLang } = useI18n()
  const [token, setTokenState] = useState(getToken)
  const [loggedIn, setLoggedIn] = useState<Patient | null>(null)
  const [me, setMe] = useState<Me | null>(null)
  const [meState, setMeState] = useState<MeState>(token === null ? 'idle' : 'loading')
  const [meError, setMeError] = useState<unknown>(null)
  const [aiMode, setAiMode] = useState<AiMode | null>(null)
  const meRequest = useRef(0)

  const reloadMe = useCallback(async () => {
    const request = ++meRequest.current
    setMeState((current) => (current === 'ready' ? current : 'loading'))
    setMeError(null)
    try {
      const next = await getMe()
      if (request !== meRequest.current) return
      setMe(next)
      setMeState('ready')
      applyPreferred(next.patient.preferred_lang)
    } catch (cause) {
      if (request !== meRequest.current) return
      setMeError(cause)
      setMeState((current) => (current === 'ready' ? current : 'error'))
    }
  }, [applyPreferred])

  useEffect(
    () =>
      onTokenChange((next) => {
        setTokenState(next)
        if (next === null) {
          // Logout, or a 401 from anywhere: the guards then go to /login.
          meRequest.current += 1
          setLoggedIn(null)
          setMe(null)
          setMeState('idle')
          setMeError(null)
          resetLang()
        }
      }),
    [resetLang],
  )

  useEffect(() => {
    if (token !== null) void reloadMe()
  }, [token, reloadMe])

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>
    const controller = new AbortController()
    const check = async () => {
      try {
        setAiMode((await health({ signal: controller.signal })).ai_mode)
      } catch {
        if (!controller.signal.aborted) timer = setTimeout(() => void check(), HEALTH_RETRY_MS)
      }
    }
    void check()
    return () => {
      clearTimeout(timer)
      controller.abort()
    }
  }, [])

  const signIn = useCallback(
    async (qid: string, otp: string) => {
      await authStart(qid)
      const verified = await authVerify(qid, otp)
      setLoggedIn(verified.patient)
      applyPreferred(verified.patient.preferred_lang)
      setToken(verified.token)
    },
    [applyPreferred],
  )

  const signOut = useCallback(() => clearToken(), [])

  const value = useMemo<SessionValue>(
    () => ({
      token,
      patient: me?.patient ?? loggedIn,
      me,
      meState,
      meError,
      signIn,
      signOut,
      reloadMe,
    }),
    [token, me, loggedIn, meState, meError, signIn, signOut, reloadMe],
  )
  const healthValue = useMemo(() => ({ aiMode }), [aiMode])

  return (
    <SessionContext.Provider value={value}>
      <HealthContext.Provider value={healthValue}>{children}</HealthContext.Provider>
    </SessionContext.Provider>
  )
}

export function useSession(): SessionValue {
  const value = useContext(SessionContext)
  if (value === null) throw new Error('useSession needs a SessionProvider above it')
  return value
}

export function useHealth(): { aiMode: AiMode | null } {
  return useContext(HealthContext)
}
