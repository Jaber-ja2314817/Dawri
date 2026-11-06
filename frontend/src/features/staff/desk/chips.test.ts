import { expect, it } from 'vitest'
import type { DemoPatient } from '../../../api/types'
import { deskChips } from './chips'

const patient = (id: string): DemoPatient => ({
  id,
  qid_demo: `DEMO-${id}`,
  full_name_en: id,
  full_name_ar: id,
})

it('puts Salem first and keeps the rest in order', () => {
  const ids = deskChips(['P001', 'P002', 'P003', 'P005', 'P006'].map(patient)).map(({ id }) => id)
  expect(ids).toEqual(['P006', 'P001', 'P002', 'P003', 'P005'])
})
