import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { ApiError } from '../../api/client'
import { confirmIntake, getVisit } from '../../api/endpoints'
import type { ChatMessage, ChatResponse, Intake, Service, Visit } from '../../api/types'
import { pathFor } from '../../lib/stages'
import { useHealth } from '../../state/session'
import { isAbort, isStored, isUnknownOutcome, postTurn, SUMMARY_SLOT, TURN_TIMEOUT_MS } from './send'

/** A turn the visit has not caught up with yet. It stops showing as soon as the visit has it. */
interface LocalTurn {
  baseline: number
  user: string
  reply?: string
  done?: boolean
  intake?: Intake | null
}

interface Failure {
  text: string
  baseline: number
  error: unknown
  /** Set when the turn may have landed, so a retry has to look before it sends. */
  retry: boolean
  fromBox: boolean
}

export interface Summary {
  text: string
  service: Service
  /** Where the message sits in the conversation. */
  index: number
}

export interface ChatState {
  messages: ChatMessage[]
  scripted: ReadonlySet<number>
  summary: Summary | null
  thinking: boolean
  failure: { error: unknown; timedOut: boolean; retry: boolean } | null
  confirming: boolean
  confirmError: unknown
  draft: string
  setDraft: (text: string) => void
  /** Sends the box. */
  submit: () => void
  /** Sends a confirmed transcript. The box keeps whatever is typed in it. */
  sendText: (text: string) => void
  retry: () => void
  confirm: () => void
}

export function useChat(visit: Visit, refetch: () => Promise<void>): ChatState {
  const id = visit.visit_id
  const navigate = useNavigate()
  const { aiMode } = useHealth()
  const [draft, setDraft] = useState('')
  const [thinking, setThinking] = useState(false)
  const [local, setLocal] = useState<LocalTurn | null>(null)
  const [failure, setFailure] = useState<Failure | null>(null)
  const [scripted, setScripted] = useState<ReadonlySet<number>>(new Set())
  const [confirming, setConfirming] = useState(false)
  const [confirmError, setConfirmError] = useState<unknown>(null)

  const inFlight = useRef(false)
  const live = useRef(true)
  const controller = useRef<AbortController | null>(null)
  const unresolved = useRef<Failure | null>(null)
  const stored = useRef(visit.chat.messages.length)
  useEffect(() => {
    stored.current = visit.chat.messages.length
  }, [visit.chat.messages.length])

  useEffect(() => {
    live.current = true
    return () => {
      live.current = false
      controller.current?.abort()
    }
  }, [])

  /** Runs one request under the 45 s limit. Unmounting ends it too. */
  const timed = useCallback(async <T,>(request: (signal: AbortSignal) => Promise<T>) => {
    const current = new AbortController()
    controller.current = current
    const timer = setTimeout(() => current.abort(), TURN_TIMEOUT_MS)
    try {
      return await request(current.signal)
    } finally {
      clearTimeout(timer)
    }
  }, [])

  const applyTurn = useCallback(
    async (response: ChatResponse, baseline: number, text: string) => {
      // The order matters: a red flag beats everything, and nothing may follow it.
      if (response.emergency) {
        // Before anything else, and with no second request: this answer alone is enough.
        navigate(pathFor(id, 'emergency'), { replace: true, state: { redFlag: true } })
        return
      }
      if (response.refill) {
        navigate(pathFor(id, 'refill'), { replace: true })
        return
      }
      if (aiMode === 'real' && response.ai_source === 'simulated') {
        setScripted((known) => new Set(known).add(baseline + 1))
      }
      setLocal({
        baseline,
        user: text,
        reply: response.reply,
        done: response.done,
        intake: response.intake,
      })
      await refetch()
    },
    [aiMode, id, navigate, refetch],
  )

  const fail = useCallback((next: Failure) => {
    unresolved.current = next.retry ? next : null
    setFailure(next)
    setLocal(null)
    // The box was cleared on send, or holds something typed before a transcript went.
    setDraft((current) => (next.fromBox || current === '' ? next.text : current))
  }, [])

  /** True when the visit shows the message landed, or that the chat is over anyway. */
  const landed = useCallback(
    async (baseline: number, text: string) => {
      const fresh = await timed((signal) => getVisit(id, { signal }))
      return fresh.stage !== 'intake' || isStored(fresh.chat.messages, baseline, text)
    },
    [id, timed],
  )

  const send = useCallback(
    async (raw: string, fromBox: boolean) => {
      const text = raw.trim()
      if (text === '' || inFlight.current) return
      inFlight.current = true

      const earlier = unresolved.current?.text === text ? unresolved.current : null
      const baseline = earlier?.baseline ?? stored.current
      unresolved.current = null
      setFailure(null)
      setThinking(true)
      setLocal({ baseline, user: text })
      if (fromBox) setDraft('')

      try {
        if (earlier !== null && (await landed(baseline, text))) {
          await refetch()
          return
        }
        const response = await timed((signal) => postTurn(id, text, signal))
        await applyTurn(response, baseline, text)
      } catch (cause) {
        if (!live.current) return
        if (cause instanceof ApiError && cause.code === 'visit_not_in_intake') {
          // The visit moved on. The gate takes the patient to where it is now.
          await refetch()
          fail({ text, baseline, error: cause, retry: false, fromBox })
          return
        }
        if (!isUnknownOutcome(cause)) {
          fail({ text, baseline, error: cause, retry: false, fromBox })
          return
        }
        let arrived = false
        try {
          arrived = await landed(baseline, text)
        } catch {
          // Still no answer. The retry looks again before it sends anything.
        }
        if (!live.current) return
        if (arrived) await refetch()
        else fail({ text, baseline, error: cause, retry: true, fromBox })
      } finally {
        inFlight.current = false
        if (live.current) setThinking(false)
      }
    },
    [applyTurn, fail, id, landed, refetch, timed],
  )

  const submit = useCallback(() => void send(draft, true), [draft, send])
  const sendText = useCallback((text: string) => void send(text, false), [send])

  const retry = useCallback(() => {
    if (failure === null) return
    // The patient may have fixed the words in the box before tapping Retry.
    const edited = failure.fromBox && draft.trim() !== ''
    void send(edited ? draft : failure.text, failure.fromBox)
  }, [draft, failure, send])

  const confirm = useCallback(async () => {
    setConfirming(true)
    setConfirmError(null)
    try {
      await confirmIntake(id, {})
      navigate(pathFor(id, 'centre'), { replace: true })
    } catch (cause) {
      if (cause instanceof ApiError && cause.code === 'visit_not_in_intake') await refetch()
      if (live.current) {
        setConfirmError(cause)
        setConfirming(false)
      }
    }
  }, [id, navigate, refetch])

  const messages = useMemo(() => {
    const kept = visit.chat.messages
    if (local === null || kept.length > local.baseline) return kept
    const extra: ChatMessage[] = [{ role: 'user', content: local.user, slot: null }]
    if (local.reply !== undefined) {
      extra.push({
        role: 'assistant',
        content: local.reply,
        slot: local.done ? SUMMARY_SLOT : null,
      })
    }
    return [...kept, ...extra]
  }, [local, visit.chat.messages])

  const summary = useMemo<Summary | null>(() => {
    const index = messages.length - 1
    const last = messages[index]
    const intake = local?.intake ?? visit.intake
    if (!intake || visit.confirmed_by_patient) return null
    // A correction can bring a question instead, and the old intake stays until it is answered.
    if (last?.role !== 'assistant' || last.slot !== SUMMARY_SLOT) return null
    return { text: last.content, service: intake.service, index }
  }, [local, messages, visit.confirmed_by_patient, visit.intake])

  return {
    messages,
    scripted,
    summary,
    thinking,
    failure:
      failure && {
        error: failure.error,
        timedOut: isAbort(failure.error),
        retry: failure.retry,
      },
    confirming,
    confirmError,
    draft,
    setDraft,
    submit,
    sendText,
    retry,
    confirm: () => void confirm(),
  }
}
