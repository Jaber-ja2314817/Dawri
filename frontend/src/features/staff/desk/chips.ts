import type { DemoPatient } from '../../../api/types'

const NO_PHONE = 'P006'

/** Salem comes first: he is the demo's patient with no phone. */
export function deskChips(patients: DemoPatient[]): DemoPatient[] {
  return patients.toSorted((a, b) => Number(b.id === NO_PHONE) - Number(a.id === NO_PHONE))
}
