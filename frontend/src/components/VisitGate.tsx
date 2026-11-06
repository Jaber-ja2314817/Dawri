import { useEffect, type ReactNode } from 'react'
import { Navigate, useLocation, useNavigate } from 'react-router-dom'
import { errorText } from '../api/client'
import type { Visit } from '../api/types'
import { useI18n } from '../i18n'
import { pathFor, screensFor, type Screen } from '../lib/stages'
import { useVisit, type LiveMode } from '../state/useVisit'
import { EmergencyCall, EmergencyTitle } from './EmergencyCall'
import { PatientShell } from './PatientShell'
import { ErrorBlock, Skeleton } from './ui'

interface VisitGateProps {
  id: string
  /** Left out, the gate only sends the visit to its canonical screen. */
  screen?: Screen
  children?: (
    visit: Visit,
    refetch: () => Promise<void>,
    live: LiveMode,
    updatedAt: number | null,
  ) => ReactNode
}

/**
 * Every visit screen sits behind this, so a screen a visit has moved past can never render.
 * It is what keeps a chat box off a completed visit, and Back from returning to chat after
 * an emergency.
 */
export function VisitGate({ id, screen, children }: VisitGateProps) {
  const { t, lang } = useI18n()
  const navigate = useNavigate()
  const { visit, state, error, refetch, live, updatedAt } = useVisit(id)
  const tone = screen === 'emergency' ? 'emergency' : 'default'
  const title = t(screen ? `screen.${screen}` : 'screen.visit')
  const location = useLocation()
  const redFlag = (location.state as { redFlag?: boolean } | null)?.redFlag === true

  useEffect(() => {
    if (state === 'gone') navigate('/home', { replace: true, state: { demoReset: true } })
  }, [state, navigate])

  // The chat has just said emergency. 999 does not wait for this visit to load, or depend on it.
  if (visit === null && screen === 'emergency' && redFlag) {
    return (
      <PatientShell tone="emergency">
        <EmergencyTitle />
        <EmergencyCall />
        {state === 'error' && (
          <ErrorBlock message={errorText(error, t, lang)} onRetry={() => void refetch()} />
        )}
      </PatientShell>
    )
  }

  if (state === 'error' && visit === null) {
    return (
      <PatientShell title={title} back="/home" tone={tone}>
        <ErrorBlock message={errorText(error, t, lang)} onRetry={() => void refetch()} />
      </PatientShell>
    )
  }

  if (visit === null) {
    return (
      <PatientShell title={title} tone={tone}>
        <div data-testid="visit-loading" aria-busy="true" className="flex flex-col gap-3">
          <Skeleton height={20} width="60%" />
          <Skeleton height={96} />
        </div>
      </PatientShell>
    )
  }

  const screens = screensFor(visit)
  if (screen === undefined || !screens.includes(screen)) {
    return <Navigate to={pathFor(id, screens[0])} replace />
  }

  return <>{children?.(visit, refetch, live, updatedAt)}</>
}

export default VisitGate
