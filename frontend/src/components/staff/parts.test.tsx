import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import type { ReactNode } from 'react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../api/client'
import type { QueueTicket } from '../../api/staffTypes'
import { I18nProvider } from '../../i18n'
import type { CounterActions } from '../../state/staff/useCounterActions'
import { AiMode } from './AiMode'
import { CounterBar } from './CounterBar'
import { PatientBanner } from './PatientBanner'
import { QueueTable } from './QueueTable'

const health = vi.hoisted(() => ({ aiMode: null as 'real' | 'simulated' | null }))
vi.mock('../../state/session', () => ({ useHealth: () => health }))

const real: QueueTicket = {
  ticket_id: 't14',
  number: 'T-014',
  state: 'active',
  priority: 0,
  simulated: false,
  visit_id: 'V1',
  activated_at: '2026-11-06T07:42:00.000000+00:00',
  called_at: null,
  call_count: 0,
  label: null,
  position: 4,
  waiting_min: 6,
  patient: { name_en: 'Fatima Al-Demo', name_ar: 'فاطمة التجريبية', age: 34, sex: 'F' },
  complaint: 'fever and cough',
}
const simulated: QueueTicket = {
  ...real,
  ticket_id: 't11',
  number: 'T-011',
  simulated: true,
  visit_id: null,
  label: 'Simulated',
  position: 1,
  waiting_min: 12,
  patient: undefined,
  complaint: undefined,
}

const actions = (over: Partial<CounterActions> = {}): CounterActions => ({
  callNext: vi.fn(async () => null),
  serve: vi.fn(async () => null),
  notHere: vi.fn(async () => null),
  busy: false,
  error: null,
  lastCall: null,
  ...over,
})

const show = (ui: ReactNode) =>
  render(
    <MemoryRouter>
      <I18nProvider>{ui}</I18nProvider>
    </MemoryRouter>,
  )

beforeEach(() => {
  localStorage.setItem('dawri.lang', 'en')
  health.aiMode = null
})

afterEach(() => {
  cleanup()
  localStorage.clear()
})

describe('QueueTable', () => {
  it('shows a real row with every column, by language', () => {
    show(<QueueTable tickets={[real]} />)
    const row = screen.getByTestId('queue-row')
    expect(row.dataset).toMatchObject({ number: 'T-014', simulated: 'false', state: 'active' })
    for (const text of ['T-014', 'Fatima Al-Demo', 'fever and cough']) {
      expect(row.textContent).toContain(text)
    }
    expect(row.textContent).toContain('34')
    expect(row.textContent).not.toContain('Simulated')
  })

  it('uses the Arabic name on an Arabic console', () => {
    localStorage.setItem('dawri.lang', 'ar')
    show(<QueueTable tickets={[real]} />)
    expect(screen.getByTestId('queue-row').textContent).toContain('فاطمة التجريبية')
  })

  it('labels a simulated row and gives it no name', () => {
    show(<QueueTable tickets={[simulated]} />)
    const row = screen.getByTestId('queue-row')
    expect(row.dataset.simulated).toBe('true')
    expect(within(row).getByText('Simulated')).toBeTruthy()
    expect(row.textContent).not.toContain('Fatima')
  })

  it('names the state of a ticket at the counter, not a place', () => {
    show(<QueueTable tickets={[{ ...real, state: 'called', position: null }]} />)
    const row = screen.getByTestId('queue-row')
    expect(row.dataset.state).toBe('called')
    expect(row.textContent).toContain('Called')
  })

  it('keeps its frame and says so when empty', () => {
    show(<QueueTable tickets={[]} />)
    expect(screen.getByTestId('queue-table').querySelector('thead')).not.toBeNull()
    expect(screen.getByTestId('queue-empty').textContent).toBe('Nobody is waiting at this counter.')
  })

  it('renders a row action only when asked', () => {
    show(<QueueTable tickets={[real]} rowAction={() => <button type="button">Open</button>} />)
    expect(screen.getByRole('button', { name: 'Open' })).toBeTruthy()
  })
})

describe('CounterBar', () => {
  it('offers call next while someone waits', () => {
    const bar = actions()
    show(<CounterBar tickets={[simulated, real]} actions={bar} />)
    fireEvent.click(screen.getByTestId('call-next'))
    expect(bar.callNext).toHaveBeenCalledOnce()
    expect(screen.queryByTestId('not-here')).toBeNull()
  })

  it('cannot call an empty queue', () => {
    show(<CounterBar tickets={[]} actions={actions()} />)
    expect((screen.getByTestId('call-next') as HTMLButtonElement).disabled).toBe(true)
  })

  it('shows the called patient with Not here and Patient here', () => {
    const bar = actions()
    show(
      <CounterBar
        tickets={[{ ...real, state: 'called', position: null }, simulated]}
        actions={bar}
      />,
    )
    expect(screen.queryByTestId('call-next')).toBeNull()
    expect(screen.getByTestId('at-counter').textContent).toContain('Fatima Al-Demo')
    fireEvent.click(screen.getByTestId('not-here'))
    expect(bar.notHere).toHaveBeenCalledWith('t14')
    fireEvent.click(screen.getByTestId('patient-here'))
    expect(bar.serve).toHaveBeenCalledWith('t14')
  })

  it('offers neither once the patient is being served', () => {
    show(
      <CounterBar tickets={[{ ...real, state: 'serving', position: null }]} actions={actions()} />,
    )
    expect(screen.getByTestId('at-counter').dataset.state).toBe('serving')
    expect(screen.queryByTestId('not-here')).toBeNull()
    expect(screen.queryByTestId('patient-here')).toBeNull()
  })

  it('names what a colleague handled, never as a called patient', () => {
    const lastCall = { called: null, auto_completed: ['T-011', 'T-012'], note: 'x' }
    show(<CounterBar tickets={[real]} actions={actions({ lastCall })} />)
    expect(screen.getByTestId('auto-completed').textContent).toContain('T-011, T-012')
    expect(screen.queryByTestId('at-counter')).toBeNull()
  })

  it('shows a refusal as a sentence', () => {
    const error = new ApiError(409, 'counter_busy', 'raw')
    show(<CounterBar tickets={[real]} actions={actions({ error })} />)
    expect(screen.getByRole('alert').textContent).toContain('This counter already has a patient.')
  })
})

describe('PatientBanner', () => {
  const patient = { ...real.patient!, allergies: ['penicillin', 'latex'] }

  it('flags every allergy and shows the arrival in Doha', () => {
    show(
      <PatientBanner
        number="T-014"
        patient={patient}
        arrivedAt="2026-11-06T07:42:00.000000+00:00"
        waitingMin={6}
      />,
    )
    const banner = screen.getByTestId('patient-banner')
    expect(screen.getAllByTestId('allergy-flag').map((flag) => flag.textContent)).toEqual([
      'penicillin',
      'latex',
    ])
    expect(banner.textContent).toContain('T-014')
    expect(banner.textContent).toContain('10:42')
    expect(banner.textContent).toContain('6')
  })

  it('says no allergies are on record, in a neutral pill', () => {
    show(
      <PatientBanner
        number="T-014"
        patient={{ ...patient, allergies: [] }}
        arrivedAt={null}
        waitingMin={null}
      />,
    )
    expect(screen.queryByTestId('allergy-flag')).toBeNull()
    expect(screen.getByTestId('patient-banner').textContent).toContain('No allergies on record')
  })

  it('works out the wait from the arrival when not told', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-11-06T07:50:30.000Z'))
    act(() => {
      show(
        <PatientBanner
          number="T-014"
          patient={patient}
          arrivedAt="2026-11-06T07:42:00.000000+00:00"
        />,
      )
    })
    expect(screen.getByTestId('patient-banner').textContent).toContain('Waiting 8 min')
    vi.useRealTimers()
  })
})

describe('AiMode', () => {
  it.each([
    ['simulated', 'simulated', 'AI: simulated'],
    ['real', 'real', 'AI: model'],
    [null, 'unknown', 'AI: checking'],
  ] as const)('reads %s', (mode, data, text) => {
    health.aiMode = mode
    show(<AiMode />)
    const pill = screen.getByTestId('ai-mode')
    expect(pill.dataset.mode).toBe(data)
    expect(pill.textContent).toBe(text)
  })
})
