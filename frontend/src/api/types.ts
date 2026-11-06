/* The patient API, as the backend returns it. */

export interface Centre {
  id: string
  name_en: string
  name_ar: string
}

export interface DemoPatient {
  id: string
  qid_demo: string
  full_name_en: string
  full_name_ar: string
}

export interface Patient extends DemoPatient {
  dob: string
  age: number
  sex: string
  preferred_lang: string
  allergies: string[]
  chronic: string[]
  active_meds: string[]
  registered_centre: Centre
  demo: true
}

export interface AuthStartResponse {
  otp_sent: true
}

export interface AuthVerifyResponse {
  token: string
  patient: Patient
}

export interface Me {
  patient: Patient
  dependents: Patient[]
  record: unknown
}

export type AiMode = 'real' | 'simulated'

export interface Health {
  status: string
  ai_mode: AiMode
  simulate_load: boolean
}

export type VisitStatus =
  | 'intake'
  | 'redirected_emergency'
  | 'deflected_refill'
  | 'reserved'
  | 'expired'
  | 'in_triage'
  | 'in_doctor'
  | 'in_pharmacy'
  | 'completed'
  | 'cancelled'

export type VisitStage =
  | 'intake'
  | 'emergency'
  | 'refill'
  | 'reserved'
  | 'expired'
  | 'triage'
  | 'doctor'
  | 'pharmacy'
  | 'completed'
  | 'cancelled'

export type Service =
  | 'gp'
  | 'dental'
  | 'refill'
  | 'vaccination'
  | 'lab_only'
  | 'womens_health'
  | 'mental_health'
  | 'other'

export type TicketState =
  | 'reserved'
  | 'active'
  | 'called'
  | 'serving'
  | 'done'
  | 'released'
  | 'expired'

/** A reserved ticket has no number and no place: all three are null until arrival. */
export interface Ticket {
  id: string
  visit_id: string
  number: string | null
  state: TicketState
  centre_id: string
  counter_id: string
  counter: string
  counter_ar: string
  people_ahead: number | null
  est_wait_min: number | null
  expires_at: string | null
}

export interface Intake {
  emergency: boolean
  language: string
  chief_complaint_patient_words: string
  severity_0_10: number | null
  self_medication: string[]
  service: Service
  service_confidence: number
  refill_request: boolean | string | null
  questions_asked: number
  denied_red_flags: string[]
}

export interface ChatMessage {
  role: 'assistant' | 'user'
  content: string
  slot: string | null
}

export interface MedicineLine {
  drug: string
  name: string
  line: string
}

export interface NearestEd extends Centre {
  lat: number
  lng: number
  distance_km: number
}

export interface EmergencyCard {
  reply: string
  self_harm: boolean
  nearest_ed: NearestEd
}

export interface Visit {
  visit_id: string
  patient_id: string
  booked_by: string | null
  status: VisitStatus
  stage: VisitStage
  service: Service | null
  created_at: string
  arrived_at: string | null
  completed_at: string | null
  centre: Centre | null
  ticket: Ticket | null
  intake: Intake | null
  confirmed_by_patient: boolean
  chat: { messages: ChatMessage[]; language: string }
  medicines: { en: MedicineLine[]; ar: MedicineLine[] }
  emergency: EmergencyCard | null
  go_to: { counter: string; counter_ar: string } | null
  refill: { medicine: string } | null
  rating: number | null
}

export interface VisitRow {
  visit_id: string
  patient_id: string
  status: VisitStatus
  stage: VisitStage
  service: Service | null
  centre_id: string | null
  centre: Centre | null
  created_at: string
  completed_at: string | null
  active: boolean
}

export interface CreateVisitResponse {
  visit_id: string
  status: VisitStatus
  language: string
  opening: string
}

export interface ChatResponse {
  reply: string
  done: boolean
  emergency: boolean
  intake: Intake | null
  refill: { medicine: string } | null
  denied: string[]
  ai_source: string
  self_harm: boolean
  status: VisitStatus
  transcript: string | null
  nearest_ed: NearestEd | null
}

export interface TranscribeResponse {
  text: string
}

export interface ConfirmResponse {
  status: VisitStatus
  service: Service
  intake: Intake | null
}

export interface OverrideResponse {
  status: 'redirected_emergency'
  ticket: null
  message: string
  message_ar: string
}

export interface CentreOption extends Centre {
  operator: string
  lat: number
  lng: number
  wait_min: number | null
  people_ahead: number | null
  distance_km: number | null
  registered: boolean
}

export interface CentreList {
  service: string
  effective_service: string
  service_fallback: boolean
  default_centre_id: string | null
  centres: CentreOption[]
  suggestion: { centre_id: string; reason_en: string; reason_ar: string } | null
}

export interface ReserveResponse {
  ticket: Ticket
  expires_at: string
  check_in_valid_min: number
  message: string
  message_ar: string
}

export type ArriveBody =
  | { button: true }
  | { lat: number; lng: number }
  | { qr_code: string }

export interface ArriveResponse {
  ticket: Ticket
  go_to: { counter: string; counter_ar: string } | null
}

export interface RatingResponse {
  rating: number
}
