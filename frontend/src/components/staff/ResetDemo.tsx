import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { ApiError, errorText } from '../../api/client'
import { resetDemo } from '../../api/staff'
import { useI18n } from '../../i18n'
import { announceDemoReset } from '../../state/staff/demoReset'
import { roleHome } from '../../state/staff/roles'
import { useStaff } from '../../state/staff/session'
import { Button } from '../ui'

const DISARM_MS = 6_000

/** Two taps, because this wipes every open console. `onDone` runs once the reset has worked. */
export function ResetDemo({ onDone }: { onDone?: () => void }) {
  const { t, lang } = useI18n()
  const { staff } = useStaff()
  const navigate = useNavigate()
  const [armed, setArmed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [failed, setFailed] = useState<unknown>(null)
  const [needsCode, setNeedsCode] = useState(false)
  const [code, setCode] = useState('')

  useEffect(() => {
    if (!armed || busy || needsCode) return
    const timer = setTimeout(() => setArmed(false), DISARM_MS)
    return () => clearTimeout(timer)
  }, [armed, busy, needsCode])

  const cancel = () => {
    setArmed(false)
    setNeedsCode(false)
    setCode('')
    setFailed(null)
  }

  const confirm = async () => {
    setBusy(true)
    setFailed(null)
    try {
      await resetDemo(code)
      announceDemoReset()
      cancel()
      onDone?.()
      if (staff !== null) {
        navigate(roleHome(staff.role), {
          replace: true,
          state: { staffNotice: 'staff.reset.done' },
        })
      }
    } catch (cause) {
      if (cause instanceof ApiError && cause.code === 'passcode_required') setNeedsCode(true)
      setFailed(cause)
    } finally {
      setBusy(false)
    }
  }

  return (
    <span className="inline-flex flex-wrap items-center gap-2">
      {armed ? (
        <>
          {needsCode && (
            <input
              type="password"
              data-testid="reset-passcode"
              aria-label={t('staff.reset.passcode')}
              placeholder={t('staff.reset.passcode')}
              value={code}
              autoComplete="off"
              className="h-11 w-36 rounded-md border border-control bg-white px-3 text-sm"
              onChange={(event) => setCode(event.target.value)}
            />
          )}
          <Button
            variant="secondary"
            data-testid="reset-confirm"
            loading={busy}
            className="px-3 text-sm"
            onClick={() => void confirm()}
          >
            {t('staff.reset.confirm')}
          </Button>
          <Button
            variant="quiet"
            data-testid="reset-cancel"
            disabled={busy}
            className="px-3 text-sm"
            onClick={cancel}
          >
            {t('staff.reset.cancel')}
          </Button>
        </>
      ) : (
        <Button
          variant="secondary"
          data-testid="reset-demo"
          className="px-3 text-sm"
          onClick={() => setArmed(true)}
        >
          {t('staff.reset.start')}
        </Button>
      )}
      {failed !== null && (
        <span role="alert" data-testid="reset-error" className="text-sm text-negative">
          {errorText(failed, t, lang)}
        </span>
      )}
    </span>
  )
}
