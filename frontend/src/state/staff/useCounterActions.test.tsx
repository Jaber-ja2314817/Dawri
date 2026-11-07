import { act, cleanup, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../api/client'
import { announceDemoReset } from './demoReset'
import { useCounterActions } from './useCounterActions'

const api = vi.hoisted(() => ({
  callNext: vi.fn(),
  serveTicket: vi.fn(),
  notHere: vi.fn(),
}))
vi.mock('../../api/staff', () => api)

const handled = { called: null, auto_completed: ['T-011'], note: 'x' }

async function afterACall() {
  api.callNext.mockResolvedValue(handled)
  const view = renderHook(() => useCounterActions('C1'))
  await act(async () => {
    await view.result.current.callNext()
  })
  expect(view.result.current.lastCall).toEqual(handled)
  return view
}

beforeEach(() => vi.clearAllMocks())
afterEach(cleanup)

describe('useCounterActions after a demo reset', () => {
  it('forgets what a colleague handled', async () => {
    const { result } = await afterACall()
    act(() => announceDemoReset())
    expect(result.current.lastCall).toBeNull()
  })

  it('keeps the rest: a refusal stays until the next action', async () => {
    const { result } = await afterACall()
    api.callNext.mockRejectedValue(new ApiError(409, 'counter_busy', 'raw'))
    await act(async () => {
      await result.current.callNext()
    })
    expect(result.current.error).toBeInstanceOf(ApiError)
    act(() => announceDemoReset())
    expect(result.current.error).toBeInstanceOf(ApiError)
    expect(result.current.busy).toBe(false)
  })

  it('keeps the last call when no reset happened', async () => {
    const { result } = await afterACall()
    api.serveTicket.mockResolvedValue({ id: 't1' })
    await act(async () => {
      await result.current.serve('t1')
    })
    expect(result.current.lastCall).toEqual(handled)
  })

  it('stops listening once unmounted', async () => {
    const view = await afterACall()
    view.unmount()
    expect(() => announceDemoReset()).not.toThrow()
  })
})
