import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../api/client'
import type { ChatResponse, Visit } from '../../api/types'
import { I18nProvider } from '../../i18n'
import { RecorderError } from '../../voice/recorder'
import { ChatScreen } from './ChatScreen'
import { ID, intake, opening, summaryMessage, summaryText, turn, visitWith } from './fixtures'

const mocks = vi.hoisted(() => ({
  postTurn: vi.fn(),
  getVisit: vi.fn(),
  confirmIntake: vi.fn(),
  transcribe: vi.fn(),
  startRecording: vi.fn(),
  toMono16k: vi.fn(),
  aiMode: { value: 'simulated' as string | null },
}))

vi.mock('./send', async (original) => ({
  ...(await original<typeof import('./send')>()),
  postTurn: mocks.postTurn,
}))
vi.mock('../../api/endpoints', () => ({
  getVisit: mocks.getVisit,
  confirmIntake: mocks.confirmIntake,
  transcribe: mocks.transcribe,
}))
vi.mock('../../voice/recorder', async (original) => ({
  ...(await original<typeof import('../../voice/recorder')>()),
  startRecording: mocks.startRecording,
}))
vi.mock('../../voice/wav', async (original) => ({
  ...(await original<typeof import('../../voice/wav')>()),
  toMono16k: mocks.toMono16k,
}))
vi.mock('../../state/session', () => ({
  useHealth: () => ({ aiMode: mocks.aiMode.value }),
}))

const refetch = vi.fn(async () => {})

function Where() {
  return <p data-testid="at">{useLocation().pathname}</p>
}

function ui(visit: Visit) {
  return (
    <I18nProvider>
      <MemoryRouter initialEntries={[`/visit/${ID}/chat`]}>
        <Routes>
          <Route
            path="/visit/:id/chat"
            element={<ChatScreen visit={visit} refetch={refetch} />}
          />
          <Route path="*" element={<Where />} />
        </Routes>
      </MemoryRouter>
    </I18nProvider>
  )
}

const mount = (visit: Visit = visitWith()) => render(ui(visit))

function typeAndSend(text: string) {
  fireEvent.change(screen.getByTestId('chat-input'), { target: { value: text } })
  fireEvent.click(screen.getByTestId('chat-send'))
}

const box = () => screen.getByTestId('chat-input') as HTMLInputElement
const bubbles = () => screen.getAllByTestId('bubble').map((bubble) => bubble.textContent)

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (cause: unknown) => void
  const promise = new Promise<T>((yes, no) => {
    resolve = yes
    reject = no
  })
  return { promise, resolve, reject }
}

const heldRecording = () => {
  const stop = vi.fn(async () => new Blob(['audio'], { type: 'audio/webm' }))
  return { stop, finished: new Promise<Blob>(() => {}) }
}

async function record() {
  mocks.startRecording.mockResolvedValue(heldRecording())
  fireEvent.click(screen.getByTestId('chat-mic'))
  fireEvent.click(await screen.findByTestId('voice-stop'))
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.aiMode.value = 'simulated'
  mocks.toMono16k.mockResolvedValue(new Float32Array([0, 0.1]))
  window.scrollTo = vi.fn() as typeof window.scrollTo
})
afterEach(cleanup)

describe('the conversation', () => {
  it('shows role and content only, each bubble finding its own direction', () => {
    const { container } = mount(
      visitWith({
        chat: {
          language: 'ar',
          messages: [opening, { role: 'user', content: '٦', slot: null }],
        },
      }),
    )
    expect(bubbles()).toEqual(['شو اللي يتعبك اليوم؟', '٦'])
    expect(container.querySelectorAll('[data-testid="bubble"] p[dir="auto"]')).toHaveLength(2)
  })

  it('never reads a nurse summary, even if one arrived', () => {
    const leaked = {
      ...visitWith({ intake, chat: { language: 'ar', messages: [opening, summaryMessage] } }),
    }
    ;(leaked.intake as unknown as Record<string, string>).summary_for_nurse = 'NURSE ONLY'
    const { container } = mount(leaked)
    expect(container.textContent).not.toContain('NURSE ONLY')
    delete (leaked.intake as unknown as Record<string, string>).summary_for_nurse
  })

  it('shows the reply and keeps it after the visit catches up', async () => {
    mocks.postTurn.mockResolvedValue(turn())
    const view = mount()
    typeAndSend('عندي حرارة وكحة من ثلاث أيام')
    await screen.findByText('كم شدته من 0 إلى 10؟')
    expect(refetch).toHaveBeenCalled()
    view.rerender(
      ui(
        visitWith({
          chat: {
            language: 'ar',
            messages: [
              opening,
              { role: 'user', content: 'عندي حرارة وكحة من ثلاث أيام', slot: null },
              { role: 'assistant', content: 'كم شدته من 0 إلى 10؟', slot: 'severity' },
            ],
          },
        }),
      ),
    )
    expect(bubbles()).toHaveLength(3)
  })

  it('sends one message at a time and says it is thinking', async () => {
    const reply = deferred<ChatResponse>()
    mocks.postTurn.mockReturnValue(reply.promise)
    mount()
    typeAndSend('one')
    expect(screen.getByTestId('chat-thinking').textContent).toBe('لحظة من فضلك…')
    expect(screen.getByRole('status').getAttribute('aria-live')).toBe('polite')
    expect(screen.getByTestId('chat-send')).toHaveProperty('disabled', true)
    fireEvent.submit(box().form!)
    expect(mocks.postTurn).toHaveBeenCalledOnce()
    await act(async () => reply.resolve(turn()))
    expect(screen.queryByTestId('chat-thinking')).toBeNull()
  })

  it('scrolls to the newest message', async () => {
    mocks.postTurn.mockResolvedValue(turn())
    mount()
    const before = vi.mocked(window.scrollTo).mock.calls.length
    typeAndSend('hello')
    await screen.findByText('كم شدته من 0 إلى 10؟')
    expect(vi.mocked(window.scrollTo).mock.calls.length).toBeGreaterThan(before)
  })

  it('limits the box to 2000 characters', () => {
    mount()
    expect(box().maxLength).toBe(2000)
  })
})

describe('outcomes', () => {
  it('goes straight to the emergency screen and shows no question', async () => {
    mocks.postTurn.mockResolvedValue(
      turn({ emergency: true, reply: 'NOT TO BE SHOWN', status: 'redirected_emergency' }),
    )
    mount()
    typeAndSend('Chest pain going to my left arm.')
    await waitFor(() => expect(screen.getByTestId('at').textContent).toBe(`/visit/${ID}/emergency`))
    expect(screen.queryByText('NOT TO BE SHOWN')).toBeNull()
    expect(screen.queryByTestId('chat-input')).toBeNull()
  })

  it('puts an emergency ahead of everything else in the response', async () => {
    mocks.postTurn.mockResolvedValue(
      turn({ emergency: true, done: true, refill: { medicine: 'x' }, intake }),
    )
    mount()
    typeAndSend('text')
    await waitFor(() => expect(screen.getByTestId('at').textContent).toBe(`/visit/${ID}/emergency`))
  })

  it('goes to the refill screen', async () => {
    mocks.postTurn.mockResolvedValue(turn({ refill: { medicine: 'amlodipine 5 mg once daily' } }))
    mount()
    typeAndSend('I need my usual blood pressure tablets.')
    await waitFor(() => expect(screen.getByTestId('at').textContent).toBe(`/visit/${ID}/refill`))
  })
})

describe('the summary', () => {
  it('appears from done', async () => {
    mocks.postTurn.mockResolvedValue(turn({ done: true, reply: summaryText, intake }))
    mount()
    typeAndSend('لا شي')
    const card = await screen.findByTestId('chat-summary')
    expect(card.textContent).toContain('حرارة وكحة')
    expect(card.textContent).toContain('طب عام')
    expect(card.textContent).toContain('هل هذا صحيح؟')
    expect(card.textContent?.match(/هل هذا صحيح؟/g)).toHaveLength(1)
    expect(bubbles()).not.toContain(summaryText)
  })

  it('appears from reload data', () => {
    mount(
      visitWith({ intake, chat: { language: 'ar', messages: [opening, summaryMessage] } }),
    )
    expect(screen.getByTestId('chat-summary').textContent).toContain('الشدة 6 من 10')
  })

  it('stays away while the last message is a question', () => {
    const question = { role: 'assistant' as const, content: 'من متى؟', slot: null }
    mount(
      visitWith({
        intake,
        chat: {
          language: 'ar',
          messages: [opening, summaryMessage, { role: 'user', content: 'و', slot: null }, question],
        },
      }),
    )
    expect(screen.queryByTestId('chat-summary')).toBeNull()
  })

  it('names the service in the screen language', () => {
    mount(
      visitWith({
        intake: { ...intake, service: 'dental' },
        chat: { language: 'ar', messages: [opening, summaryMessage] },
      }),
    )
    expect(screen.getByTestId('chat-summary').textContent).toContain('الأسنان')
  })

  it('confirms and goes to the centre', async () => {
    mocks.confirmIntake.mockResolvedValue({ status: 'intake', service: 'gp', intake })
    mount(visitWith({ intake, chat: { language: 'ar', messages: [opening, summaryMessage] } }))
    fireEvent.click(screen.getByTestId('chat-summary-yes'))
    await waitFor(() => expect(screen.getByTestId('at').textContent).toBe(`/visit/${ID}/centre`))
    expect(mocks.confirmIntake).toHaveBeenCalledWith(ID, {})
  })

  it('shows a failed confirm in place', async () => {
    mocks.confirmIntake.mockRejectedValue(new ApiError(0, 'network', 'Down'))
    mount(visitWith({ intake, chat: { language: 'ar', messages: [opening, summaryMessage] } }))
    fireEvent.click(screen.getByTestId('chat-summary-yes'))
    expect((await screen.findByRole('alert')).textContent).toContain('تعذر الوصول')
    expect(screen.getByTestId('chat-summary')).toBeTruthy()
  })

  it('focuses the box to change something, and the correction is a normal message', async () => {
    mocks.postTurn.mockResolvedValue(
      turn({ done: true, reply: 'شكرا. ملخص جديد. هل هذا صحيح؟', intake }),
    )
    mount(visitWith({ intake, chat: { language: 'ar', messages: [opening, summaryMessage] } }))
    fireEvent.click(screen.getByTestId('chat-summary-change'))
    expect(document.activeElement).toBe(box())
    typeAndSend('وعندي صداع بعد')
    expect(mocks.postTurn).toHaveBeenCalledWith(ID, 'وعندي صداع بعد', expect.any(AbortSignal))
    await waitFor(() =>
      expect(screen.getByTestId('chat-summary').textContent).toContain('ملخص جديد'),
    )
  })
})

describe('error-retry', () => {
  const down = new ApiError(0, 'network', 'Down')

  it('keeps the words and offers Retry when the message did not land', async () => {
    mocks.postTurn.mockRejectedValue(down)
    mocks.getVisit.mockResolvedValue(visitWith())
    mount()
    typeAndSend('عندي حرارة')
    await screen.findByRole('alert')
    expect(box().value).toBe('عندي حرارة')
    expect(bubbles()).toEqual([opening.content])
    expect(mocks.postTurn).toHaveBeenCalledOnce()

    mocks.postTurn.mockResolvedValue(turn())
    fireEvent.click(within(screen.getByRole('alert')).getByRole('button'))
    await screen.findByText('كم شدته من 0 إلى 10؟')
    expect(mocks.postTurn).toHaveBeenCalledTimes(2)
    expect(box().value).toBe('')
  })

  it('does not resend what the server already stored', async () => {
    mocks.postTurn.mockRejectedValue(down)
    mocks.getVisit.mockResolvedValue(
      visitWith({
        chat: {
          language: 'ar',
          messages: [
            opening,
            { role: 'user', content: 'عندي حرارة', slot: null },
            { role: 'assistant', content: 'من متى؟', slot: 'duration' },
          ],
        },
      }),
    )
    mount()
    typeAndSend('عندي حرارة')
    await waitFor(() => expect(refetch).toHaveBeenCalled())
    expect(screen.queryByRole('alert')).toBeNull()
    expect(mocks.postTurn).toHaveBeenCalledOnce()
    expect(box().value).toBe('')
  })

  it('tells an old "no" from a new one', async () => {
    const said = { role: 'user' as const, content: 'لا', slot: null }
    const asked = { role: 'assistant' as const, content: 'من متى؟', slot: 'duration' }
    const earlier = { language: 'ar', messages: [opening, said, asked] }
    mocks.postTurn.mockRejectedValue(down)
    mocks.getVisit.mockResolvedValue(visitWith({ chat: earlier }))
    mount(visitWith({ chat: earlier }))
    typeAndSend('لا')
    await screen.findByRole('alert')
    expect(box().value).toBe('لا')
  })

  it('looks again before a retry, and never sends blind', async () => {
    mocks.postTurn.mockRejectedValue(down)
    mocks.getVisit.mockRejectedValue(down)
    mount()
    typeAndSend('عندي حرارة')
    await screen.findByRole('alert')

    fireEvent.click(within(screen.getByRole('alert')).getByRole('button'))
    await waitFor(() => expect(mocks.getVisit).toHaveBeenCalledTimes(3))
    await screen.findByRole('alert')
    expect(mocks.postTurn).toHaveBeenCalledOnce()
  })

  it('gives up after 45 s and keeps the words', async () => {
    vi.useFakeTimers()
    try {
      mocks.getVisit.mockResolvedValue(visitWith())
      mocks.postTurn.mockImplementation(
        (_id: string, _text: string, signal: AbortSignal) =>
          new Promise((_resolve, reject) => {
            signal.addEventListener('abort', () =>
              reject(new DOMException('Aborted', 'AbortError')),
            )
          }),
      )
      mount()
      typeAndSend('عندي حرارة')
      await act(async () => {
        await vi.advanceTimersByTimeAsync(44_999)
      })
      expect(screen.queryByRole('alert')).toBeNull()
      await act(async () => {
        await vi.advanceTimersByTimeAsync(1)
      })
      expect(screen.getByRole('alert').textContent).toContain('تأخر الرد')
      expect(box().value).toBe('عندي حرارة')
    } finally {
      vi.useRealTimers()
    }
  })

  it('refetches on 409 so the gate can move the patient', async () => {
    mocks.postTurn.mockRejectedValue(
      new ApiError(409, 'visit_not_in_intake', 'This visit is past the chat stage.'),
    )
    mount()
    typeAndSend('text')
    await waitFor(() => expect(refetch).toHaveBeenCalled())
    expect(mocks.getVisit).not.toHaveBeenCalled()
  })
})

describe('the scripted note', () => {
  it('marks a scripted turn when the model is on', async () => {
    mocks.aiMode.value = 'real'
    mocks.postTurn.mockResolvedValue(turn({ ai_source: 'simulated' }))
    mount()
    typeAndSend('text')
    await screen.findByText('هذا رد مُعدّ مسبقاً.')
  })

  it('stays away from a model turn', async () => {
    mocks.aiMode.value = 'real'
    mocks.postTurn.mockResolvedValue(turn({ ai_source: 'model' }))
    mount()
    typeAndSend('text')
    await screen.findByText('كم شدته من 0 إلى 10؟')
    expect(screen.queryByTestId('chat-scripted')).toBeNull()
  })

  it('leaves simulated mode to the footer', async () => {
    mocks.postTurn.mockResolvedValue(turn({ ai_source: 'simulated' }))
    mount()
    typeAndSend('text')
    await screen.findByText('كم شدته من 0 إلى 10؟')
    expect(screen.queryByTestId('chat-scripted')).toBeNull()
  })
})

describe('voice', () => {
  it('sends nothing until the patient confirms the transcript', async () => {
    mocks.transcribe.mockResolvedValue({ text: 'عندي حرارة وكحة من ثلاث أيام' })
    mocks.postTurn.mockResolvedValue(turn())
    mount()
    await record()
    const field = (await screen.findByTestId('voice-transcript')) as HTMLTextAreaElement
    expect(field.value).toBe('عندي حرارة وكحة من ثلاث أيام')
    expect(screen.getByTestId('voice-confirm').textContent).toContain('هل هذا صحيح؟')
    expect(mocks.postTurn).not.toHaveBeenCalled()

    fireEvent.change(field, { target: { value: 'عندي حرارة' } })
    expect(mocks.postTurn).not.toHaveBeenCalled()
    fireEvent.click(screen.getByTestId('voice-send'))
    expect(mocks.postTurn).toHaveBeenCalledWith(ID, 'عندي حرارة', expect.any(AbortSignal))
    await screen.findByText('كم شدته من 0 إلى 10؟')
  })

  it('uploads 16 kHz mono wav, whatever the browser recorded', async () => {
    mocks.transcribe.mockResolvedValue({ text: 'hello' })
    mount()
    await record()
    await screen.findByTestId('voice-transcript')
    const blob = mocks.transcribe.mock.calls[0][0] as Blob
    expect(blob.type).toBe('audio/wav')
    expect(new DataView(await blob.arrayBuffer()).getUint32(24, true)).toBe(16_000)
  })

  it('records again on Try again, with nothing sent', async () => {
    mocks.transcribe.mockResolvedValue({ text: 'wrong words' })
    mount()
    await record()
    fireEvent.click(await screen.findByTestId('voice-retry'))
    await screen.findByTestId('voice-stop')
    expect(mocks.startRecording).toHaveBeenCalledTimes(2)
    expect(mocks.postTurn).not.toHaveBeenCalled()
  })

  it('shows message_ar on a 503, with no transcript, and focuses the box', async () => {
    const message = 'Voice is not available right now. Please type your message.'
    const arabic = 'الصوت غير متاح الآن. الرجاء كتابة رسالتك.'
    mocks.transcribe.mockRejectedValue(new ApiError(503, 'asr_unavailable', message, arabic))
    mount()
    fireEvent.change(box(), { target: { value: 'كتبت شيئاً' } })
    await record()
    expect((await screen.findByTestId('voice-error')).textContent).toBe(arabic)
    expect(screen.queryByTestId('voice-transcript')).toBeNull()
    expect(mocks.postTurn).not.toHaveBeenCalled()
    expect(document.activeElement).toBe(box())
    expect(box().value).toBe('كتبت شيئاً')
  })

  it.each<[string, unknown, string]>([
    ['a 502', new ApiError(502, 'asr_failed', 'x'), 'تعذر تحويل الصوت'],
    ['a 400', new ApiError(400, 'bad_audio', 'x'), 'تعذرت قراءة التسجيل'],
    ['a 413', new ApiError(413, 'audio_too_large', 'x'), 'التسجيل طويل جداً'],
    ['no network', new ApiError(0, 'network', 'x'), 'يرجى كتابة رسالتك'],
    ['a blank answer', { text: '   ' }, 'يرجى كتابة رسالتك'],
  ])('tells the patient to type after %s', async (_name, outcome, line) => {
    if (outcome instanceof ApiError) mocks.transcribe.mockRejectedValue(outcome)
    else mocks.transcribe.mockResolvedValue(outcome)
    mount()
    await record()
    expect((await screen.findByTestId('voice-error')).textContent).toContain(line)
    expect(document.activeElement).toBe(box())
    expect(screen.queryByTestId('voice-transcript')).toBeNull()
  })

  it.each<[string, RecorderError, string]>([
    ['blocked', new RecorderError('denied', 'x'), 'لا يوجد إذن لاستخدام الميكروفون'],
    ['missing', new RecorderError('unsupported', 'x'), 'التسجيل الصوتي لا يعمل على هذا الجهاز'],
  ])('tells the patient to type when the microphone is %s', async (_name, cause, line) => {
    mocks.startRecording.mockRejectedValue(cause)
    mount()
    fireEvent.click(screen.getByTestId('chat-mic'))
    expect((await screen.findByTestId('voice-error')).textContent).toContain(line)
    expect(document.activeElement).toBe(box())
  })

  it('tells the patient to type when the recording cannot be decoded', async () => {
    mocks.toMono16k.mockRejectedValue(new Error('no'))
    mount()
    await record()
    expect((await screen.findByTestId('voice-error')).textContent).toContain('تعذرت قراءة')
    expect(mocks.transcribe).not.toHaveBeenCalled()
  })

  it('shows the timer while listening', async () => {
    mocks.startRecording.mockResolvedValue(heldRecording())
    mount()
    fireEvent.click(screen.getByTestId('chat-mic'))
    expect((await screen.findByTestId('voice-timer')).textContent).toBe('0:00')
  })

  it('moves on by itself when the recording ends at the cap', async () => {
    mocks.transcribe.mockResolvedValue({ text: 'heard' })
    const ended = deferred<Blob>()
    mocks.startRecording.mockResolvedValue({
      stop: () => ended.promise,
      finished: ended.promise,
    })
    mount()
    fireEvent.click(screen.getByTestId('chat-mic'))
    await screen.findByTestId('voice-stop')
    await act(async () => ended.resolve(new Blob(['a'])))
    expect(((await screen.findByTestId('voice-transcript')) as HTMLTextAreaElement).value).toBe(
      'heard',
    )
  })

  it('stops the recording when the patient leaves', async () => {
    const recording = heldRecording()
    mocks.startRecording.mockResolvedValue(recording)
    const view = mount()
    fireEvent.click(screen.getByTestId('chat-mic'))
    await screen.findByTestId('voice-stop')
    view.unmount()
    expect(recording.stop).toHaveBeenCalled()
  })
})
