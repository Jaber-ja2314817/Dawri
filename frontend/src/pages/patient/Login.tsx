import { useState, type FormEvent } from 'react'
import { ApiError, errorText } from '../../api/client'
import { PatientShell } from '../../components/PatientShell'
import { Button, ErrorBlock, Field } from '../../components/ui'
import { useI18n } from '../../i18n'
import { nameOf } from '../../lib/format'
import { useSession } from '../../state/session'

const DEMO_OTP = '0000'

// The three vault demo patients. Anyone else in the seed logs in by typing their QID.
const DEMO_CHIPS = [
  { id: 'P001', qid: 'DEMO-10001', full_name_en: 'Fatima Al-Demo', full_name_ar: 'فاطمة التجريبية' },
  { id: 'P002', qid: 'DEMO-10002', full_name_en: 'Ahmed Al-Demo', full_name_ar: 'أحمد التجريبي' },
  { id: 'P003', qid: 'DEMO-10003', full_name_en: 'Ravi Demo', full_name_ar: 'رافي' },
]

type Attempt = { qid: string; otp: string; chip: string | null }

export default function Login() {
  const { t, lang } = useI18n()
  const { signIn } = useSession()
  const [qid, setQid] = useState('')
  const [otp, setOtp] = useState('')
  const [busy, setBusy] = useState<string | null>(null)
  const [failed, setFailed] = useState<{ error: unknown; attempt: Attempt } | null>(null)

  const attempt = async (next: Attempt) => {
    setBusy(next.chip ?? 'form')
    setFailed(null)
    try {
      await signIn(next.qid, next.otp)
      // The session guard moves on to /home.
    } catch (error) {
      setFailed({ error, attempt: next })
      setBusy(null)
    }
  }

  const submit = (event: FormEvent) => {
    event.preventDefault()
    void attempt({ qid: qid.trim(), otp: otp.trim(), chip: null })
  }

  const code = failed?.error instanceof ApiError ? failed.error.code : null
  const message = failed ? errorText(failed.error, t, lang) : null

  return (
    <PatientShell title={t('login.title')} back="/">
      <section aria-labelledby="demo-patients" className="flex flex-col gap-2">
        <h2 id="demo-patients" className="text-sm font-medium">
          {t('login.demoPatients')}
        </h2>
        <div className="flex flex-wrap gap-2">
          {DEMO_CHIPS.map((chip) => (
            <Button
              key={chip.id}
              variant="secondary"
              data-testid={`chip-${chip.id}`}
              loading={busy === chip.id}
              disabled={busy !== null}
              className="px-3 text-sm"
              onClick={() => void attempt({ qid: chip.qid, otp: DEMO_OTP, chip: chip.id })}
            >
              {nameOf(chip, lang)}
            </Button>
          ))}
        </div>
      </section>

      <form onSubmit={submit} noValidate className="mt-3 flex flex-col gap-3">
        <Field
          label={t('login.qid')}
          name="qid"
          dir="ltr"
          autoCapitalize="characters"
          autoComplete="off"
          spellCheck={false}
          required
          value={qid}
          onChange={(event) => setQid(event.target.value)}
          error={code === 'unknown_qid' ? message : null}
        />
        <Field
          label={t('login.otp')}
          name="otp"
          dir="ltr"
          inputMode="numeric"
          autoComplete="one-time-code"
          required
          hint={t('login.otpHint')}
          value={otp}
          onChange={(event) => setOtp(event.target.value)}
          error={code === 'invalid_otp' ? message : null}
        />
        <Button
          type="submit"
          className="mt-1 w-full"
          loading={busy === 'form'}
          disabled={busy !== null || qid.trim() === '' || otp.trim() === ''}
        >
          {t('login.submit')}
        </Button>
      </form>

      {failed && code !== 'unknown_qid' && code !== 'invalid_otp' && message && (
        <ErrorBlock message={message} onRetry={() => void attempt(failed.attempt)} />
      )}
    </PatientShell>
  )
}
