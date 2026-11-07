import { staffSource } from '../state/staff/staffToken'
import { api } from './client'
import type {
  CallNext,
  ConsultDoneBody,
  ConsultDoneResponse,
  CounterQueue,
  DemoStaff,
  DisplaySnapshot,
  DispensedResponse,
  FastForwardResponse,
  HandoffConfirmResponse,
  HandoffDraft,
  IntakeEditResponse,
  ResetResponse,
  StaffLogin,
  StaffMe,
  StaffTicket,
  StaffVisit,
  Stats,
  VisitDrug,
  VitalsBody,
  VitalsResponse,
  WalkInResponse,
} from './staffTypes'

/* Every staff route. Each one names the staff token, so a patient session is never touched. */

interface Options {
  signal?: AbortSignal
}

const auth = staffSource
const part = encodeURIComponent
const counterPath = (id: string) => `/api/counters/${part(id)}`
const ticketPath = (id: string) => `/api/tickets/${part(id)}`
const visitPath = (id: string) => `/api/visits/${part(id)}`
const staffVisitPath = (id: string) => `/api/staff/visits/${part(id)}`

export const demoStaff = (options?: Options) =>
  api<DemoStaff[]>('GET', '/api/staff/demo-staff', undefined, { ...options, auth })

export const login = (staffId: string) =>
  api<StaffLogin>('POST', '/api/staff/login', { staff_id: staffId }, { auth })

export const me = (options?: Options) =>
  api<StaffMe>('GET', '/api/staff/me', undefined, { ...options, auth })

export const counterQueue = (counterId: string, options?: Options) =>
  api<CounterQueue>('GET', `${counterPath(counterId)}/queue`, undefined, { ...options, auth })

export const callNext = (counterId: string) =>
  api<CallNext>('POST', `${counterPath(counterId)}/call-next`, undefined, { auth })

export const serveTicket = (ticketId: string) =>
  api<StaffTicket>('POST', `${ticketPath(ticketId)}/serve`, undefined, { auth })

/** The patient did not come when called. The screen says "Not here". */
export const notHere = (ticketId: string) =>
  api<StaffTicket>('POST', `${ticketPath(ticketId)}/no-show`, undefined, { auth })

export const staffVisit = (visitId: string, options?: Options) =>
  api<StaffVisit>('GET', staffVisitPath(visitId), undefined, { ...options, auth })

export const editIntake = (visitId: string, fields: Record<string, unknown>) =>
  api<IntakeEditResponse>('PUT', `${visitPath(visitId)}/intake`, { json: fields }, { auth })

export const recordVitals = (visitId: string, body: VitalsBody) =>
  api<VitalsResponse>('POST', `${visitPath(visitId)}/vitals`, body, { auth })

export const draftHandoff = (visitId: string) =>
  api<HandoffDraft>('POST', `${visitPath(visitId)}/handoff/draft`, undefined, { auth })

export const confirmHandoff = (
  visitId: string,
  finalText: string,
  doctorId: string,
  draftId: string,
) =>
  api<HandoffConfirmResponse>(
    'POST',
    `${visitPath(visitId)}/handoff/confirm`,
    { final_text: finalText, doctor_id: doctorId, draft_id: draftId },
    { auth },
  )

export const visitDrugs = (visitId: string, options?: Options) =>
  api<VisitDrug[]>('GET', `${staffVisitPath(visitId)}/drugs`, undefined, { ...options, auth })

export const consultDone = (visitId: string, body: ConsultDoneBody) =>
  api<ConsultDoneResponse>('POST', `${visitPath(visitId)}/consult/done`, body, { auth })

export const dispensed = (visitId: string) =>
  api<DispensedResponse>('POST', `${visitPath(visitId)}/dispensed`, undefined, { auth })

export const walkIn = (qid: string, complaint: string) =>
  api<WalkInResponse>('POST', '/api/desk/walk-in', { qid, complaint }, { auth })

export const stats = (centreId: string, options?: Options) =>
  api<Stats>('GET', `/api/stats/${part(centreId)}`, undefined, { ...options, auth })

export const display = (centreId: string, options?: Options) =>
  api<DisplaySnapshot>('GET', `/api/display/${part(centreId)}`, undefined, { ...options, auth })

export const fastForward = (visitId: string) =>
  api<FastForwardResponse>('POST', `/api/demo/fast-forward/${part(visitId)}`, undefined, { auth })

export const resetDemo = (passcode?: string) =>
  api<ResetResponse>('POST', '/api/demo/reset', passcode ? { passcode } : undefined, { auth })
