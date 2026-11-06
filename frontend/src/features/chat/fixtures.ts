import type { ChatMessage, ChatResponse, Intake, Visit } from '../../api/types'

export const ID = 'V1'

export const intake: Intake = {
  emergency: false,
  language: 'ar-gulf',
  chief_complaint_patient_words: 'عندي حرارة وكحة من ثلاث أيام',
  severity_0_10: 6,
  self_medication: ['paracetamol'],
  service: 'gp',
  service_confidence: 0.8,
  refill_request: null,
  questions_asked: 5,
  denied_red_flags: [],
}

export const opening: ChatMessage = {
  role: 'assistant',
  content: 'شو اللي يتعبك اليوم؟',
  slot: 'complaint',
}

export const summaryText = 'شكرا. هذا اللي بقوله للممرضة: حرارة وكحة، 3 أيام، الشدة 6 من 10. هل هذا صحيح؟'

export const summaryMessage: ChatMessage = {
  role: 'assistant',
  content: summaryText,
  slot: 'summary',
}

export function visitWith(partial: Partial<Visit> = {}): Visit {
  return {
    visit_id: ID,
    patient_id: 'P1',
    booked_by: 'P1',
    status: 'intake',
    stage: 'intake',
    service: null,
    created_at: '2026-11-06T10:00:00Z',
    arrived_at: null,
    completed_at: null,
    centre: null,
    ticket: null,
    intake: null,
    confirmed_by_patient: false,
    chat: { messages: [opening], language: 'ar' },
    medicines: { en: [], ar: [] },
    emergency: null,
    go_to: null,
    refill: null,
    rating: null,
    ...partial,
  }
}

export function turn(partial: Partial<ChatResponse> = {}): ChatResponse {
  return {
    reply: 'كم شدته من 0 إلى 10؟',
    done: false,
    emergency: false,
    intake: null,
    refill: null,
    denied: [],
    ai_source: 'simulated',
    self_harm: false,
    status: 'intake',
    transcript: null,
    nearest_ed: null,
    ...partial,
  }
}
