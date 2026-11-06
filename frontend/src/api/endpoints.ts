import { api } from './client'
import type {
  ArriveBody,
  ArriveResponse,
  AuthStartResponse,
  AuthVerifyResponse,
  CentreList,
  ChatResponse,
  ConfirmResponse,
  CreateVisitResponse,
  DemoPatient,
  Health,
  Me,
  OverrideResponse,
  RatingResponse,
  ReserveResponse,
  Service,
  TranscribeResponse,
  Visit,
  VisitRow,
} from './types'

interface Options {
  signal?: AbortSignal
}

const visitPath = (id: string) => `/api/visits/${encodeURIComponent(id)}`

export const authStart = (qid: string) =>
  api<AuthStartResponse>('POST', '/api/auth/start', { qid })

export const authVerify = (qid: string, otp: string) =>
  api<AuthVerifyResponse>('POST', '/api/auth/verify', { qid, otp })

export const demoPatients = (options?: Options) =>
  api<DemoPatient[]>('GET', '/api/auth/demo-patients', undefined, options)

export const health = (options?: Options) =>
  api<Health>('GET', '/api/health', undefined, options)

export const getMe = (options?: Options) => api<Me>('GET', '/api/me', undefined, options)

export const createVisit = (body: { patient_id?: string; consent: true }) =>
  api<CreateVisitResponse>('POST', '/api/visits', body)

export const listVisits = (options?: Options) =>
  api<VisitRow[]>('GET', '/api/visits', undefined, options)

export const getVisit = (id: string, options?: Options) =>
  api<Visit>('GET', visitPath(id), undefined, options)

export const sendChat = (id: string, text: string) =>
  api<ChatResponse>('POST', `${visitPath(id)}/chat`, { text })

/** The recording goes up as a multipart field `audio`, named audio.wav. */
export const transcribe = (blob: Blob, options?: Options) => {
  const form = new FormData()
  form.append('audio', blob, 'audio.wav')
  return api<TranscribeResponse>('POST', '/api/asr', form, options)
}

export const confirmIntake = (id: string, answers?: { service?: Service }) =>
  api<ConfirmResponse>(
    'POST',
    `${visitPath(id)}/intake/confirm`,
    answers ? { json: answers } : {},
  )

export const continueRefill = (id: string) =>
  api<ConfirmResponse>('POST', `${visitPath(id)}/refill/continue`)

export const emergencyOverride = (id: string) =>
  api<OverrideResponse>('POST', `${visitPath(id)}/emergency/override`)

export const listCentres = (
  query: { service: string; visit_id: string; lat?: number; lng?: number },
  options?: Options,
) => {
  const params = new URLSearchParams({ service: query.service, visit_id: query.visit_id })
  if (query.lat !== undefined) params.set('lat', String(query.lat))
  if (query.lng !== undefined) params.set('lng', String(query.lng))
  return api<CentreList>('GET', `/api/centres?${params}`, undefined, options)
}

export const reserve = (id: string, centreId: string) =>
  api<ReserveResponse>('POST', `${visitPath(id)}/reserve`, { centre_id: centreId })

export const arrive = (id: string, body: ArriveBody) =>
  api<ArriveResponse>('POST', `${visitPath(id)}/arrive`, body)

export const rateVisit = (id: string, stars: number) =>
  api<RatingResponse>('POST', `${visitPath(id)}/rating`, { stars })
