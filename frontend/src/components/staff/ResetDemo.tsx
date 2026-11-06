import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { errorText } from '../../api/client'
import { resetDemo } from '../../api/staff'
import { useI18n } from '../../i18n'
import { roleHome } from '../../state/staff/roles'
import { useStaff } from '../../state/staff/session'
import { Button } from '../ui'

const DISARM_MS = 6_000

/** Two taps, because this wipes every open console. */
export function ResetDemo() {
  const { t, lang } = useI18n()
  const { staff } = useStaff()
  const navigate = useNavigate()
  const [armed, setArmed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [failed, setFailed] = useState<unknown>(null)

  useEffect(() => {
    if (!armed || busy) return
    const timer = setTimeout(() => setArmed(false), DISARM_MS)
    return () => clearTimeout(timer)
  }, [armed, busy])

  const confirm = async () => {
    setBusy(true)
    setFailed(null)
    try {
      await resetDemo()
      setArmed(false)
      if (staff !== null) {
        navigate(roleHome(staff.role), {
          replace: true,
          state: { staffNotice: 'staff.reset.done' },
        })
      }
    } catch (cause) {
      setFailed(cause)
    } finally {
      setBusy(false)
    }
  }

  return (
    <span className="inline-flex flex-wrap items-center gap-2">
      {armed ? (
        <>
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
            onClick={() => setArmed(false)}
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
