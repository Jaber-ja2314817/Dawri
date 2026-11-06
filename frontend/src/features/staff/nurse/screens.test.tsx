import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import type { ReactNode } from 'react'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../../api/client'
import type {
  DoctorSuggestion,
  HandoffDraft,
  StaffIntake,
  StaffTicket,
  StaffVisit,
} from '../../../api/staffTypes'
import { I18nProvider } from '../../../i18n'
import { HandoffDraftForm } from './HandoffDraft'
import { HandoffSent } from './HandoffSent'
import { IntakeCard } from './IntakeCard'
import { PatientWords } from './PatientWords'
import { EmergencyResult, VitalsForm } from './VitalsForm'

const staffApi = vi.hoisted(() => ({
  confirmHandoff: vi.fn(),
  demoStaff: vi.fn(),
  draftHandoff: vi.fn(),
  editIntake: vi.fn(),
  fastForward: vi.fn(),
  recordVitals: vi.fn(),
}))
vi.mock('../../../api/staff', () => staffApi)
vi.mock('../../../state/staff/session', () => ({
  useStaff: () => ({
    centreCounters: [
      { id: 'D4', label: 'Room 4', label_ar: 'غرفة 4', stage: 'doctor' },
      { id: 'D3', label: 'Room 3', label_ar: 'غرفة 3', stage: 'doctor' },
    ],
  }),
}))

const ticket = (over: Partial<StaffTicket> = {}): StaffTicket => ({
  id: 't1',
  visit_id: 'V1',
  number: 'T-014',
  state: 'serving',
  centre_id: 'C-WAKRA',
  counter_id: 'T1',
  counter: 'Triage 1',
  counter_ar: 'الفرز 1',
  people_ahead: 0,
  est_wait_min: 0,
  expires_at: null,
  ...over,
})

const intake = {
  chief_complaint: 'fever and cough',
  chief_complaint_patient_words: 'عندي حرارة',
  duration: '3 days',
  severity_0_10: 5,
  associated: ['cough'],
  self_medication: [],
  service: 'gp',
  summary_for_nurse: '34F, fever.',
  patient_concerns: null,
  denied_red_flags: [],
} as unknown as StaffIntake

const visit = (over: Partial<StaffVisit> = {}): StaffVisit =>
  ({
    status: 'in_triage',
    turns: [],
    denied_text_en: '',
    denied_text_ar: '',
    intake,
    edited: false,
    red_flags_raised: [],
    patient: {
      id: 'P001',
      name: 'Fatima',
      name_en: 'Fatima',
      name_ar: 'فاطمة',
      age: 34,
      sex: 'F',
      allergies: ['penicillin'],
      chronic: [],
      active_meds: [],
    },
    vitals: null,
    handoff: null,
    medicines: { en: [], ar: [] },
    ticket: ticket(),
    service: 'gp',
    ...over,
  }) as StaffVisit

const noor: DoctorSuggestion = {
  doctor_id: 'NOOR',
  name: 'Dr. Noor',
  counter_id: 'D4',
  counter_label: 'Room 4',
  clinic: 'gp',
  waiting: 0,
  speaks_language: true,
  gender_ok: true,
  score: 0,
  clinic_fallback: false,
  reason_en: 'Dr. Noor, GP, 0 waiting',
  reason_ar: 'الدكتورة نور',
}
const khalid: DoctorSuggestion = {
  ...noor,
  doctor_id: 'KHALID',
  name: 'Dr. Khalid',
  counter_id: 'D3',
  counter_label: 'Room 3',
  waiting: 1,
  reason_en: 'Dr. Khalid, GP, 1 waiting',
}

const draft = (over: Partial<HandoffDraft> = {}): HandoffDraft => ({
  text: 'Line one.\nLine two.\nLine three.',
  text_ar: 'سطر واحد',
  source: 'simulated',
  suggestions: [noor, khalid],
  denied_text: '',
  ...over,
})

function Where() {
  return <span data-testid="path">{useLocation().pathname}</span>
}

const show = (ui: ReactNode) =>
  render(
    <MemoryRouter initialEntries={['/staff/nurse/V1']}>
      <I18nProvider>
        <Routes>
          <Route path="*" element={<>{ui}<Where /></>} />
        </Routes>
      </I18nProvider>
    </MemoryRouter>,
  )

beforeEach(() => {
  localStorage.setItem('dawri.lang', 'en')
})

afterEach(() => {
  cleanup()
  localStorage.clear()
  Object.values(staffApi).forEach((mock) => mock.mockReset())
})

describe('PatientWords', () => {
  const turns = [
    { role: 'receptionist', text: 'شو اللي يتعبك اليوم؟' },
    { role: 'patient', text: 'عِنْدِي  حَرَارَة\nمع دم' },
  ] as const

  it('keeps every turn exactly, spaces, line breaks and diacritics included', () => {
    show(<PatientWords turns={[...turns]} />)
    const shown = screen.getAllByTestId('turn')
    expect(shown).toHaveLength(2)
    expect(shown[1].querySelector('p')?.textContent).toBe(turns[1].text)
    for (const turn of shown) expect(turn.querySelector('p')?.getAttribute('dir')).toBe('auto')
  })

  it('sets the patient in ink and the receptionist muted', () => {
    show(<PatientWords turns={[...turns]} />)
    const [receptionist, patient] = screen.getAllByTestId('turn')
    expect(receptionist.querySelector('p')?.className).toContain('text-muted')
    expect(patient.querySelector('p')?.className).toContain('text-ink')
  })

  it('clips nothing, however long a turn is', () => {
    const long = 'كلمة '.repeat(400)
    show(<PatientWords turns={[{ role: 'patient', text: long }]} />)
    const block = screen.getByTestId('patient-words')
    expect(block.querySelector('p')?.textContent).toBe(long)
    expect(block.innerHTML).not.toMatch(/truncate|line-clamp|overflow-hidden|max-h/)
  })

  it('keeps its frame with no chat', () => {
    show(<PatientWords turns={[]} />)
    expect(screen.getByTestId('patient-words').textContent).toContain('This visit has no chat.')
  })
})

describe('IntakeCard', () => {
  const card = (over: Partial<StaffVisit> = {}, editable = true) =>
    show(
      <IntakeCard visitId="V1" visit={visit(over)} editable={editable} refetch={async () => {}} />,
    )

  it('reads the red flag row in the order Build Decisions sets', () => {
    card({ red_flags_raised: ['chest pain'], denied_text_en: 'Patient denied: chest pain' })
    expect(screen.getByTestId('flags-raised').textContent).toBe('chest pain')
    expect(screen.queryByTestId('denied')).toBeNull()
    expect(screen.queryByTestId('no-flags')).toBeNull()
  })

  it('shows what the patient denied, by language', () => {
    localStorage.setItem('dawri.lang', 'ar')
    card({ denied_text_en: 'Patient denied: chest pain', denied_text_ar: 'المريض نفى: ألم في الصدر' })
    expect(screen.getByTestId('denied').textContent).toBe('المريض نفى: ألم في الصدر')
  })

  it('says none detected only when nothing fired and nothing was denied', () => {
    card()
    expect(screen.getByTestId('no-flags').textContent).toBe('none detected')
  })

  it('flags each allergy from the record', () => {
    card()
    expect(screen.getByTestId('allergy-flag').textContent).toBe('penicillin')
  })

  it('prints dashes for a visit with no intake, offers no edit, and still reads the flags', () => {
    card({ intake: null, red_flags_raised: ['chest pain'] })
    expect(screen.getByTestId('intake-reason').textContent).toBe('—')
    expect(screen.getByTestId('intake-severity').textContent).toBe('—')
    expect(screen.queryByTestId('intake-edit')).toBeNull()
    expect(screen.getByTestId('flags-raised')).toBeTruthy()
  })

  it('prints a zero severity as a zero', () => {
    card({ intake: { ...intake, severity_0_10: 0 } })
    expect(screen.getByTestId('intake-severity').textContent).toBe('0/10')
  })

  it('marks an edited intake', () => {
    card({ edited: true })
    expect(screen.getByTestId('edited-pill').textContent).toBe('Edited by nurse')
  })

  it('offers no edit once locked', () => {
    card({}, false)
    expect(screen.queryByTestId('intake-edit')).toBeNull()
  })

  it('saves only the changed field and says the draft was cleared', async () => {
    const refetch = vi.fn(async () => {})
    staffApi.editIntake.mockResolvedValue({ intake, edited: true, draft_cleared: true })
    show(<IntakeCard visitId="V1" visit={visit()} editable refetch={refetch} />)
    fireEvent.click(screen.getByTestId('intake-edit'))
    fireEvent.change(screen.getByTestId('edit-duration'), { target: { value: '4 days' } })
    fireEvent.click(screen.getByTestId('intake-save'))
    await screen.findByTestId('draft-cleared')
    expect(staffApi.editIntake).toHaveBeenCalledWith('V1', { duration: '4 days' })
    expect(refetch).toHaveBeenCalled()
  })

  it('closes with no call when nothing changed', () => {
    card()
    fireEvent.click(screen.getByTestId('intake-edit'))
    fireEvent.click(screen.getByTestId('intake-save'))
    expect(staffApi.editIntake).not.toHaveBeenCalled()
    expect(screen.queryByTestId('intake-form')).toBeNull()
  })

  it('holds a bad severity in the form without calling', () => {
    card()
    fireEvent.click(screen.getByTestId('intake-edit'))
    fireEvent.change(screen.getByTestId('edit-severity_0_10'), { target: { value: '11' } })
    fireEvent.click(screen.getByTestId('intake-save'))
    expect(staffApi.editIntake).not.toHaveBeenCalled()
    expect(screen.getByTestId('intake-form').textContent).toContain('whole number from 0 to 10')
  })

  it('shows a 422 in the form and keeps what was typed', async () => {
    staffApi.editIntake.mockRejectedValue(new ApiError(422, 'invalid_intake', 'raw'))
    card()
    fireEvent.click(screen.getByTestId('intake-edit'))
    const box = screen.getByTestId('edit-chief_complaint') as HTMLInputElement
    fireEvent.change(box, { target: { value: 'x' } })
    fireEvent.click(screen.getByTestId('intake-save'))
    const alert = await screen.findByRole('alert')
    expect(alert.textContent).toBe('That intake is not valid. Check the fields.')
    expect(box.value).toBe('x')
  })
})

describe('VitalsForm', () => {
  const form = (over: Partial<StaffVisit> = {}, onEscalated = vi.fn()) => {
    show(<VitalsForm visitId="V1" visit={visit(over)} onEscalated={onEscalated} />)
    return onEscalated
  }
  const primary = () => screen.getByTestId('vitals-submit') as HTMLButtonElement
  const pick = (urgency: string) => fireEvent.click(screen.getByTestId(`urgency-${urgency}`))

  it('selects no urgency, and the primary stays disabled until one is chosen', () => {
    form()
    for (const option of ['routine', 'soon', 'urgent']) {
      expect((screen.getByTestId(`urgency-${option}`) as HTMLInputElement).checked).toBe(false)
    }
    expect(primary().disabled).toBe(true)
    pick('soon')
    expect(primary().disabled).toBe(false)
  })

  it('does not carry an earlier urgency over as a default', () => {
    form({ vitals: { urgency: 'routine', bp_sys: 118 } as StaffVisit['vitals'] })
    expect((screen.getByTestId('urgency-routine') as HTMLInputElement).checked).toBe(false)
    expect(primary().disabled).toBe(true)
    expect(screen.getByTestId('urgency-earlier').textContent).toContain('Routine')
    expect((screen.getByTestId('vital-bp_sys') as HTMLInputElement).value).toBe('118')
  })

  it('posts the readings as numbers, Arabic digits and empties included, then opens the handoff', async () => {
    staffApi.recordVitals.mockResolvedValue({ escalated: false })
    form()
    fireEvent.change(screen.getByTestId('vital-bp_sys'), { target: { value: '١٢٠' } })
    fireEvent.change(screen.getByTestId('vital-temp_c'), { target: { value: '٣٧٫٥' } })
    pick('routine')
    fireEvent.click(primary())
    await waitFor(() =>
      expect(screen.getByTestId('path').textContent).toBe('/staff/nurse/V1/handoff'),
    )
    expect(staffApi.recordVitals).toHaveBeenCalledWith('V1', {
      bp_sys: 120,
      bp_dia: null,
      hr: null,
      temp_c: 37.5,
      spo2: null,
      weight_kg: null,
      urgency: 'routine',
    })
  })

  it('stops on a bad reading and names the range', () => {
    form()
    fireEvent.change(screen.getByTestId('vital-spo2'), { target: { value: '120' } })
    pick('routine')
    fireEvent.click(primary())
    expect(staffApi.recordVitals).not.toHaveBeenCalled()
    expect(screen.getByTestId('vitals-form').textContent).toContain('Enter 40 to 100.')
  })

  it('needs a second tap for urgent, and changing the choice disarms it', () => {
    form()
    pick('urgent')
    expect(primary().textContent).toBe('Send to emergency')
    fireEvent.click(primary())
    expect(staffApi.recordVitals).not.toHaveBeenCalled()
    expect(primary().textContent).toBe('Tap again to send to emergency')
    pick('soon')
    expect(primary().textContent).toBe('Confirm & generate handoff')
    pick('urgent')
    expect(primary().textContent).toBe('Send to emergency')
  })

  it('posts on the second tap and hands over to the result', async () => {
    staffApi.recordVitals.mockResolvedValue({ escalated: true })
    const onEscalated = form()
    pick('urgent')
    fireEvent.click(primary())
    fireEvent.click(primary())
    await waitFor(() => expect(onEscalated).toHaveBeenCalledOnce())
    expect(staffApi.recordVitals.mock.calls[0][1].urgency).toBe('urgent')
    expect(screen.getByTestId('path').textContent).toBe('/staff/nurse/V1')
  })

  it('takes no vitals from a ticket not yet called', () => {
    form({ ticket: ticket({ state: 'active' }) })
    expect(screen.getByTestId('not-called').textContent).toContain('Call this patient first')
    expect(primary().disabled).toBe(true)
    expect(screen.getByTestId('vital-hr').matches(':disabled')).toBe(true)
  })

  it('locks with a sentence and a way back once the visit left triage', () => {
    form({ status: 'in_doctor' })
    const lock = screen.getByTestId('visit-locked')
    expect(within(lock).getByRole('link').getAttribute('href')).toBe('/staff/nurse')
    expect(primary().disabled).toBe(true)
  })

  it('shows a refusal and lets the nurse try again', async () => {
    staffApi.recordVitals.mockRejectedValue(new ApiError(409, 'not_called', 'raw'))
    form()
    pick('routine')
    fireEvent.click(primary())
    expect((await screen.findByRole('alert')).textContent).toContain(
      'Call this patient to the counter first.',
    )
    expect(primary().disabled).toBe(false)
  })

  it('says no ticket remains after emergency', () => {
    show(<EmergencyResult />)
    expect(screen.getByTestId('sent-to-ed').textContent).toContain('No ticket remains')
  })
})

describe('HandoffDraftForm', () => {
  const form = (onConfirmed = vi.fn()) => {
    show(<HandoffDraftForm visitId="V1" onConfirmed={onConfirmed} />)
    return onConfirmed
  }
  const box = () => screen.findByTestId('handoff-text') as Promise<HTMLTextAreaElement>

  it('shows a skeleton while the draft is written, and posts once', async () => {
    staffApi.draftHandoff.mockResolvedValue(draft())
    form()
    expect(screen.getByTestId('handoff-skeleton')).toBeTruthy()
    expect(screen.queryByTestId('handoff-text')).toBeNull()
    await box()
    expect(staffApi.draftHandoff).toHaveBeenCalledOnce()
  })

  it.each([
    ['simulated', 'Scripted draft, not from a model'],
    ['model', 'Draft from the model'],
  ] as const)('labels a %s draft for what it is', async (source, label) => {
    staffApi.draftHandoff.mockResolvedValue(draft({ source }))
    form()
    await box()
    expect(screen.getByTestId('handoff-source').textContent).toBe(label)
  })

  it('selects the first doctor, shows each reason, and lets the nurse pick another', async () => {
    staffApi.draftHandoff.mockResolvedValue(draft())
    staffApi.confirmHandoff.mockResolvedValue({ ticket: ticket(), doctor: {} })
    const onConfirmed = form()
    await box()
    expect((screen.getByTestId('doctor-NOOR') as HTMLInputElement).checked).toBe(true)
    const reasons = screen.getAllByTestId('doctor-reason').map((one) => one.textContent)
    expect(reasons).toEqual(['Dr. Noor, GP, 0 waiting', 'Dr. Khalid, GP, 1 waiting'])
    fireEvent.click(screen.getByTestId('doctor-KHALID'))
    fireEvent.click(screen.getByTestId('handoff-confirm'))
    await waitFor(() => expect(onConfirmed).toHaveBeenCalledOnce())
    expect(staffApi.confirmHandoff).toHaveBeenCalledWith('V1', draft().text, 'KHALID')
  })

  it('uses the Arabic reason and room on an Arabic console', async () => {
    localStorage.setItem('dawri.lang', 'ar')
    staffApi.draftHandoff.mockResolvedValue(draft())
    form()
    await box()
    const option = screen.getAllByTestId('doctor-option')[0]
    expect(option.textContent).toContain('الدكتورة نور')
    expect(option.textContent).toContain('غرفة 4')
  })

  it('sends what the nurse typed, not the draft', async () => {
    staffApi.draftHandoff.mockResolvedValue(draft())
    staffApi.confirmHandoff.mockResolvedValue({ ticket: ticket(), doctor: {} })
    form()
    fireEvent.change(await box(), { target: { value: 'Edited.' } })
    fireEvent.click(screen.getByTestId('handoff-confirm'))
    await waitFor(() =>
      expect(staffApi.confirmHandoff).toHaveBeenCalledWith('V1', 'Edited.', 'NOOR'),
    )
  })

  it('cannot send a blank summary or with no doctor', async () => {
    staffApi.draftHandoff.mockResolvedValue(draft({ suggestions: [] }))
    form()
    await box()
    expect(screen.getByTestId('no-doctors')).toBeTruthy()
    expect((screen.getByTestId('handoff-confirm') as HTMLButtonElement).disabled).toBe(true)
  })

  it('notes a clinic fallback', async () => {
    staffApi.draftHandoff.mockResolvedValue(
      draft({ suggestions: [{ ...noor, clinic_fallback: true }] }),
    )
    form()
    await box()
    expect(screen.getByTestId('clinic-fallback')).toBeTruthy()
  })

  it.each(['draft_required', 'draft_stale'])(
    'on %s re-drafts, says so, keeps the nurse text and sends nothing',
    async (code) => {
      staffApi.draftHandoff
        .mockResolvedValueOnce(draft())
        .mockResolvedValueOnce(draft({ text: 'New draft.' }))
      staffApi.confirmHandoff.mockRejectedValueOnce(new ApiError(409, code, 'raw'))
      const onConfirmed = form()
      fireEvent.change(await box(), { target: { value: 'My text.' } })
      fireEvent.click(screen.getByTestId('handoff-confirm'))

      await screen.findByTestId('handoff-redrafted')
      const redrafted = await box()
      await waitFor(() => expect(redrafted.value).toBe('New draft.'))
      expect(screen.getByTestId('handoff-kept').textContent).toContain('My text.')
      expect(onConfirmed).not.toHaveBeenCalled()
      expect(staffApi.draftHandoff).toHaveBeenCalledTimes(2)

      fireEvent.click(screen.getByTestId('use-kept'))
      expect(((await box()) as HTMLTextAreaElement).value).toBe('My text.')
    },
  )

  it('drafts again when an edit lands during the first draft', async () => {
    staffApi.draftHandoff
      .mockRejectedValueOnce(new ApiError(409, 'draft_stale', 'raw'))
      .mockResolvedValueOnce(draft())
    form()
    await box()
    expect(staffApi.draftHandoff).toHaveBeenCalledTimes(2)
    expect(screen.getByTestId('handoff-redrafted')).toBeTruthy()
  })

  it('offers a retry when the draft fails', async () => {
    staffApi.draftHandoff
      .mockRejectedValueOnce(new ApiError(500, 'internal_error', 'raw'))
      .mockResolvedValueOnce(draft())
    form()
    fireEvent.click(await screen.findByRole('button', { name: 'Retry' }))
    await box()
    expect(screen.queryByRole('alert')).toBeNull()
  })
})

describe('HandoffSent', () => {
  const sent = visit({
    status: 'in_doctor',
    handoff: {
      visit_id: 'V1',
      ai_draft: 'draft',
      final_text: 'Final text.',
      suggested_doctor_id: 'NOOR',
      chosen_doctor_id: 'NOOR',
      reason: null,
      confirmed_by: 'S-NURSE',
      at: '2026-11-06T08:00:00+00:00',
    },
    ticket: ticket({ number: 'D-GP-023', counter: 'Room 4', counter_ar: 'غرفة 4' }),
  })
  const page = (over: Partial<StaffVisit> = {}, refetch = vi.fn(async () => {})) => {
    show(
      <HandoffSent
        visitId="V1"
        visit={{ ...sent, ...over }}
        confirmed={null}
        refetch={refetch}
      />,
    )
    return refetch
  }

  it('rebuilds the confirmed state from the visit alone, as after a reload', async () => {
    staffApi.demoStaff.mockResolvedValue([{ id: 'NOOR', name: 'Dr. Noor Al-Demo' }])
    page()
    expect(screen.getByTestId('sent-number').textContent).toBe('D-GP-023')
    expect(screen.getByTestId('sent-room').textContent).toBe('Room 4')
    expect(screen.getByTestId('handoff-final-text').textContent).toBe('Final text.')
    await waitFor(() =>
      expect(screen.getByTestId('sent-doctor').textContent).toBe('Dr. Noor Al-Demo'),
    )
    expect(staffApi.draftHandoff).not.toHaveBeenCalled()
  })

  it('prints a dash when the doctor name cannot be read', async () => {
    staffApi.demoStaff.mockRejectedValue(new ApiError(0, 'network', 'raw'))
    page()
    await act(async () => {})
    expect(screen.getByTestId('sent-doctor').textContent).toBe('—')
  })

  it('labels the skip as a demo, and completes the visit', async () => {
    staffApi.demoStaff.mockResolvedValue([])
    staffApi.fastForward.mockResolvedValue({ status: 'completed' })
    const refetch = page()
    const button = screen.getByTestId('fast-forward')
    expect(button.textContent).toBe('Demo: skip to visit complete')
    fireEvent.click(button)
    await screen.findByTestId('visit-complete')
    expect(staffApi.fastForward).toHaveBeenCalledWith('V1')
    expect(refetch).toHaveBeenCalled()
    expect(screen.queryByTestId('fast-forward')).toBeNull()
  })

  it('shows the refusal as a sentence and stays', async () => {
    staffApi.demoStaff.mockResolvedValue([])
    staffApi.fastForward.mockRejectedValue(new ApiError(409, 'not_next_in_queue', 'raw'))
    page()
    fireEvent.click(screen.getByTestId('fast-forward'))
    expect((await screen.findByRole('alert')).textContent).toContain(
      'Another patient is next at this counter.',
    )
    expect(screen.queryByTestId('visit-complete')).toBeNull()
    expect(screen.getByTestId('fast-forward')).toBeTruthy()
  })

  it('shows a completed visit on a reload, with no skip', async () => {
    staffApi.demoStaff.mockResolvedValue([])
    page({ status: 'completed', ticket: null })
    expect(screen.getByTestId('visit-complete')).toBeTruthy()
    expect(screen.queryByTestId('fast-forward')).toBeNull()
    await act(async () => {})
  })
})
