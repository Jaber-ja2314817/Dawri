import type { AiMode, Centre, Intake, Service } from './types'

/* The staff API, as the backend returns it. Probed against a running server. */

export type StaffRole = 'nurse' | 'doctor' | 'pharmacist' | 'desk'
export type Stage = 'triage' | 'doctor' | 'pharmacy'
export type Urgency = 'routine' | 'soon' | 'urgent'

export interface StaffMember {
  id: string
  name: string
  role: StaffRole
  clinic: string | null
  centre_id: string
}

export interface CounterRef {
  id: string
  label: string
  label_ar: string
  stage: Stage
}

export interface OwnCounter extends CounterRef {
  prefix: string
}

export interface LoginCounter extends OwnCounter {
  centre_id: string
  staff_id: string
  avg_service_sec: number
}

export interface DemoStaff extends StaffMember {
  centre_name_en: string
  centre_name_ar: string
  counters: CounterRef[]
}

export interface StaffLogin {
  token: string
  staff: StaffMember
  counters: LoginCounter[]
}

export interface StaffMe {
  staff: StaffMember
  centre: Centre
  counters: OwnCounter[]
  centre_counters: CounterRef[]
}

export type QueueTicketState = 'active' | 'called' | 'serving'

export interface QueuePatient {
  name_en: string
  name_ar: string
  age: number
  sex: string
}

export interface QueueTicket {
  ticket_id: string
  number: string
  state: QueueTicketState
  priority: number
  simulated: boolean
  visit_id: string | null
  activated_at: string
  called_at: string | null
  call_count: number
  label: 'Simulated' | null
  /** Null at the counter: called or serving tickets have left the line. */
  position: number | null
  waiting_min: number
  /** Real tickets only. */
  patient?: QueuePatient
  complaint?: string | null
}

export interface CounterQueue {
  counter: OwnCounter
  wait: { people_ahead: number; wait_min: number }
  tickets: QueueTicket[]
}

export interface StaffTicket {
  id: string
  visit_id: string | null
  number: string | null
  state: string
  centre_id: string
  counter_id: string
  counter: string
  counter_ar: string
  people_ahead: number | null
  est_wait_min: number | null
  expires_at: string | null
}

export interface CallNext {
  called: StaffTicket | null
  auto_completed: string[]
  note: string | null
}

export interface StaffIntake extends Intake {
  summary_for_nurse: string
  chief_complaint: string
  chief_complaint_patient_words: string
  duration: string | null
  severity_0_10: number | null
  associated: string[]
  self_medication: string[]
  denied_red_flags: string[]
  patient_concerns: string | null
  [field: string]: unknown
}

export interface Turn {
  role: 'patient' | 'receptionist'
  text: string
}

export interface StaffVisitPatient {
  id: string
  name: string
  name_en: string
  name_ar: string
  age: number
  sex: string
  allergies: string[]
  chronic: string[]
  active_meds: string[]
}

export interface VitalsRow {
  visit_id: string
  bp_sys: number | null
  bp_dia: number | null
  hr: number | null
  temp_c: number | null
  spo2: number | null
  weight_kg: number | null
  urgency: Urgency
  nurse_id: string
  at: string
}

export interface HandoffRow {
  visit_id: string
  ai_draft: string | null
  final_text: string | null
  suggested_doctor_id: string | null
  chosen_doctor_id: string | null
  reason: string | null
  confirmed_by: string | null
  at: string | null
}

export interface PrescriptionItem {
  id: number
  visit_id: string
  drug: string
  dose: string | null
  frequency: string | null
  days: number | null
  notes: string | null
}

export interface MedicineLine {
  drug: string
  name: string
  line: string
}

export interface Medicines {
  en: MedicineLine[]
  ar: MedicineLine[]
}

export interface StaffVisit {
  status: string
  language: string
  turns: Turn[]
  /** Byte for byte, for the nurse backstop. */
  patient_words: string[]
  denied: string[]
  denied_text: string
  denied_text_en: string
  denied_text_ar: string
  intake: StaffIntake | null
  confirmed_by_patient: boolean
  edited: boolean
  /** An English sentence for the record. Screens read red_flags_raised instead. */
  red_flags_checked: string
  red_flags_raised: string[]
  red_flags_raised_ar: string[]
  arrived_at: string | null
  patient: StaffVisitPatient
  vitals: VitalsRow | null
  handoff: HandoffRow | null
  prescription: PrescriptionItem[]
  medicines: Medicines
  ticket: StaffTicket | null
  service: Service | null
  ai_mode: AiMode
  /** What wrote this intake. A real ai_mode alone does not say: a turn can fall back. */
  intake_source: 'model' | 'simulated'
}

export interface IntakeEditResponse {
  intake: StaffIntake
  edited: true
  draft_cleared: boolean
}

export interface VitalsBody {
  bp_sys?: number | null
  bp_dia?: number | null
  hr?: number | null
  temp_c?: number | null
  spo2?: number | null
  weight_kg?: number | null
  urgency: Urgency
}

export interface VitalsResponse {
  status: string
  stage: 'triage' | 'emergency'
  escalated: boolean
  ticket: StaffTicket
}

export interface DoctorSuggestion {
  doctor_id: string
  name: string
  counter_id: string
  counter_label: string
  clinic: string
  waiting: number
  speaks_language: boolean
  gender_ok: boolean
  score: number
  clinic_fallback: boolean
  reason_en: string
  reason_ar: string
}

export interface HandoffDraft {
  text: string
  /** The fixed Arabic template, for reading. The doctor gets final_text. */
  text_ar: string
  source: 'simulated' | 'model'
  suggestions: DoctorSuggestion[]
  denied_text: string
  /** Names this draft, so a confirm cannot land on a newer one from another tab. */
  draft_id: string
}

export interface HandoffConfirmResponse {
  ticket: StaffTicket
  doctor: { id: string; name: string }
}

export interface AllergyWarning {
  allergen: string
  text_en: string
  text_ar: string
}

export interface VisitDrug {
  id: string
  name_en: string
  name_ar: string
  form: string
  default_dose: string | null
  default_frequency: string | null
  default_days: number | null
  demo_default: number
  allergy_warning: AllergyWarning | null
}

export interface PrescriptionLine {
  drug_id: string
  dose?: string | null
  frequency?: string | null
  days?: number | null
  notes?: string | null
}

export interface ConsultDoneBody {
  prescription: PrescriptionLine[]
  acknowledge_allergy?: boolean
}

export interface ConsultDoneResponse {
  status: string
  ticket: StaffTicket
}

export interface DispensedResponse {
  status: 'completed'
  medicines: Medicines
}

export type WalkInResponse =
  | { emergency: false; visit_id: string; ticket: StaffTicket }
  | { emergency: true; visit_id: string; reply: string; ticket: null }

export interface Stats {
  waiting: Record<Stage, number>
  avg_wait_min: number | null
  completed_today: number
  refills_deflected: number
  emergencies_redirected: number
  walk_ins: number
  ai_mode: AiMode
}

export interface DisplayCounter extends CounterRef {
  now_serving: string | null
  waiting: number
}

export interface DisplaySnapshot {
  centre: Centre
  /** In id order, so Room 3 comes before Triage 1. A screen sorts them itself. */
  counters: DisplayCounter[]
}

export interface FastForwardStep {
  step: 'called' | 'consult_done' | 'dispensed'
  number: string
  counter_id?: string
  auto_completed?: string[]
  items?: number
}

export interface FastForwardResponse {
  status: 'completed'
  steps: FastForwardStep[]
  medicines: Medicines
}

export interface ResetResponse {
  ok: true
  simulate_load: boolean
  reset_at: string
}
