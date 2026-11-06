import { expect, it } from 'vitest'
import type { DisplayCounter, Stage } from '../../../api/staffTypes'
import { displayOrder } from './order'

const counter = (id: string, stage: Stage): DisplayCounter => ({
  id,
  label: id,
  label_ar: id,
  stage,
  now_serving: null,
  waiting: 0,
})

it('puts triage, then the rooms in API order, then the pharmacy', () => {
  const inIdOrder = [
    counter('D3', 'doctor'),
    counter('D4', 'doctor'),
    counter('DEN1', 'doctor'),
    counter('P1', 'pharmacy'),
    counter('T1', 'triage'),
    counter('WH1', 'doctor'),
  ]
  expect(displayOrder(inIdOrder).map(({ id }) => id)).toEqual([
    'T1',
    'D3',
    'D4',
    'DEN1',
    'WH1',
    'P1',
  ])
  expect(inIdOrder[0].id).toBe('D3') // Left alone: this is the hook's data.
})
