import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../../api/client'
import type { VisitDrug } from '../../../api/staffTypes'
import { I18nProvider } from '../../../i18n'
import { Prescription } from './Prescription'

const api = vi.hoisted(() => ({ visitDrugs: vi.fn(), consultDone: vi.fn() }))
vi.mock('../../../api/staff', () => api)

const drug = (over: Partial<VisitDrug>): VisitDrug => ({
  id: 'DR-PARA',
  name_en: 'paracetamol',
  name_ar: 'باراسيتامول',
  form: 'tablet',
  default_dose: '500 mg',
  default_frequency: 'every 6 hours as needed',
  default_days: 3,
  demo_default: 1,
  allergy_warning: null,
  ...over,
})
const warning = (name: string) => ({
  allergen: 'penicillin',
  text_en: `Allergy on record: penicillin. Check before prescribing ${name}.`,
  text_ar: `حساسية مسجلة: penicillin. راجع قبل وصف ${name}.`,
})
const DRUGS = [
  drug({}),
  drug({
    id: 'DR-AMOX',
    name_en: 'amoxicillin',
    name_ar: 'أموكسيسيلين',
    form: 'capsule',
    default_frequency: 'three times daily',
    default_days: 5,
    demo_default: 0,
    allergy_warning: warning('amoxicillin'),
  }),
  drug({
    id: 'DR-AUGM',
    name_en: 'co-amoxiclav',
    default_dose: '625 mg',
    demo_default: 0,
    allergy_warning: warning('co-amoxiclav'),
  }),
]

const onDone = vi.fn()
const onSending = vi.fn()
const done = () => screen.getByTestId('consult-done') as HTMLButtonElement
const box = (id: string) => screen.getByTestId(id) as HTMLInputElement

async function show(list: VisitDrug[] = DRUGS) {
  api.visitDrugs.mockResolvedValue(list)
  render(
    <I18nProvider>
      <Prescription visitId="V1" onSending={onSending} onDone={onDone} />
    </I18nProvider>,
  )
  await screen.findByTestId(`drug-${list[0].id}`)
}

beforeEach(() => {
  localStorage.setItem('dawri.lang', 'en')
  localStorage.setItem('dawri.lang.chosen', '1')
  api.consultDone.mockReset()
  api.consultDone.mockResolvedValue({ status: 'in_pharmacy', ticket: { number: 'P-031' } })
  onDone.mockReset()
  onSending.mockReset()
})

afterEach(() => {
  cleanup()
  localStorage.clear()
})

describe('the picker', () => {
  it('starts with nothing selected, whatever demo_default says', async () => {
    await show()
    for (const { id } of DRUGS) expect(box(`drug-${id}`).checked).toBe(false)
  })

  it('shows the warning before anything is selected, and only on warned rows', async () => {
    await show()
    expect(screen.getByTestId('allergy-warning-DR-AMOX').textContent).toContain(
      'Check before prescribing amoxicillin',
    )
    expect(screen.queryByTestId('allergy-warning-DR-PARA')).toBeNull()
  })

  it('prefills a selected row, and refuses days outside 1 to 365', async () => {
    await show()
    fireEvent.click(box('drug-DR-AMOX'))
    expect(box('rx-dose-DR-AMOX').value).toBe('500 mg')
    expect(box('rx-frequency-DR-AMOX').value).toBe('three times daily')
    expect(box('rx-days-DR-AMOX').value).toBe('5')

    fireEvent.click(box('ack-allergy'))
    expect(done().disabled).toBe(false)
    fireEvent.change(box('rx-days-DR-AMOX'), { target: { value: '366' } })
    expect(done().disabled).toBe(true)
    fireEvent.change(box('rx-days-DR-AMOX'), { target: { value: '30' } })
    expect(done().disabled).toBe(false)
  })

  it('keeps Done disabled until the box is ticked, and unticking disables it again', async () => {
    await show()
    fireEvent.click(box('drug-DR-AMOX'))
    expect(done().disabled).toBe(true)
    fireEvent.click(done())
    expect(api.consultDone).not.toHaveBeenCalled()

    fireEvent.click(box('ack-allergy'))
    expect(done().disabled).toBe(false)
    fireEvent.click(box('ack-allergy'))
    expect(done().disabled).toBe(true)
  })

  it('sends the tick as it stands', async () => {
    await show()
    fireEvent.click(box('drug-DR-AMOX'))
    fireEvent.click(box('ack-allergy'))
    fireEvent.click(done())
    await waitFor(() => expect(onDone).toHaveBeenCalled())
    expect(api.consultDone).toHaveBeenCalledWith('V1', {
      prescription: [
        {
          drug_id: 'DR-AMOX',
          dose: '500 mg',
          frequency: 'three times daily',
          days: 5,
          notes: null,
        },
      ],
      acknowledge_allergy: true,
    })
  })

  it('sends false for a safe medicine', async () => {
    await show()
    fireEvent.click(box('drug-DR-PARA'))
    expect(screen.queryByTestId('ack-allergy')).toBeNull()
    fireEvent.click(done())
    await waitFor(() => expect(onDone).toHaveBeenCalled())
    expect(api.consultDone.mock.calls[0][1].acknowledge_allergy).toBe(false)
  })

  it('forgets the tick when the warned medicine goes, or another one joins it', async () => {
    await show()
    fireEvent.click(box('drug-DR-AMOX'))
    fireEvent.click(box('ack-allergy'))
    fireEvent.click(box('drug-DR-AUGM'))
    expect(box('ack-allergy').checked).toBe(false)
    expect(done().disabled).toBe(true)

    fireEvent.click(box('ack-allergy'))
    fireEvent.click(box('drug-DR-AUGM'))
    fireEvent.click(box('drug-DR-AMOX'))
    fireEvent.click(box('drug-DR-AMOX'))
    expect(box('ack-allergy').checked).toBe(false)
    expect(done().disabled).toBe(true)
  })

  it('takes a separate second tap to send no medicine, and says what that means', async () => {
    await show()
    fireEvent.click(done())
    expect(api.consultDone).not.toHaveBeenCalled()
    expect(screen.getByTestId('done-empty-note').textContent).toContain('no pharmacy step')

    fireEvent.click(screen.getByTestId('done-empty-cancel'))
    expect(screen.queryByTestId('done-empty-note')).toBeNull()
    expect(api.consultDone).not.toHaveBeenCalled()

    fireEvent.click(done())
    fireEvent.click(screen.getByTestId('done-empty-confirm'))
    await waitFor(() => expect(onDone).toHaveBeenCalled())
    expect(api.consultDone).toHaveBeenCalledWith('V1', {
      prescription: [],
      acknowledge_allergy: false,
    })
  })

  it('drops the second tap as soon as a medicine is chosen', async () => {
    await show()
    fireEvent.click(done())
    fireEvent.click(box('drug-DR-PARA'))
    expect(screen.queryByTestId('done-empty-confirm')).toBeNull()
    expect(done().textContent).toBe('Done')
  })

  it('shows the conflicts from a 409, then asks for the tick on that medicine', async () => {
    await show([drug({})])
    api.consultDone.mockRejectedValue(
      new ApiError(409, 'allergy_conflict', 'conflict', undefined, {
        conflicts: [
          {
            drug_id: 'DR-PARA',
            name_en: 'paracetamol',
            allergen: 'x',
            text_en: 'Conflict on paracetamol.',
            text_ar: 'تعارض.',
          },
        ],
      }),
    )
    fireEvent.click(box('drug-DR-PARA'))
    await act(async () => fireEvent.click(done()))

    expect(screen.getByTestId('allergy-conflicts').textContent).toContain('Conflict on paracetamol.')
    expect(onSending.mock.calls).toEqual([[true], [false]])
    expect(onDone).not.toHaveBeenCalled()
    expect(done().disabled).toBe(true)
    expect(box('ack-allergy').checked).toBe(false)
  })

  it('offers no way to finish while the list has not loaded', async () => {
    api.visitDrugs.mockRejectedValue(new ApiError(500, 'internal_error', 'failed'))
    render(
      <I18nProvider>
        <Prescription visitId="V1" onSending={onSending} onDone={onDone} />
      </I18nProvider>,
    )
    expect(await screen.findByRole('alert')).toBeTruthy()
    expect(screen.queryByTestId('consult-done')).toBeNull()
  })
})
