/*
 * Talks to a running Dawri server the way a second browser would. The e2e specs drive staff
 * through it, and the inspector uses it to put each screen into its real state. Nothing
 * here touches the database or invents a response.
 */

export const NURSE = 'S-WAK-NURSE1'
export const DOCTOR = 'S-WAK-DOC2'
export const PHARMACIST = 'S-WAK-PHARM1'
export const DESK = 'S-WAK-DESK1'
export const TRIAGE_COUNTER = 'C-WAKRA-T1'
export const DOCTOR_COUNTER = 'C-WAKRA-D4'
export const PHARMACY_COUNTER = 'C-WAKRA-P1'

export const QID = {
  fatima: 'DEMO-10001',
  ahmed: 'DEMO-10002',
  ravi: 'DEMO-10003',
}

export const FATIMA_WORDS = 'عندي حرارة وكحة من ثلاث أيام'
export const FATIMA_ANSWERS = ['خمسة', 'لا', 'لا']
export const AHMED_WORDS = 'I need my usual blood pressure tablets'
export const RAVI_WORDS = 'Chest pain going to my left arm'

export class DemoApi {
  constructor(base) {
    this.base = base.replace(/\/$/, '')
    this.staffTokens = new Map()
  }

  async request(method, path, { token, body } = {}) {
    const headers = {}
    if (token) headers.Authorization = `Bearer ${token}`
    if (body !== undefined) headers['Content-Type'] = 'application/json'
    const response = await fetch(`${this.base}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    const text = await response.text()
    let payload = null
    try {
      payload = text === '' ? null : JSON.parse(text)
    } catch {
      payload = text
    }
    if (!response.ok) {
      const error = new Error(`${method} ${path} gave ${response.status}: ${text.slice(0, 300)}`)
      error.status = response.status
      error.payload = payload
      throw error
    }
    return payload
  }

  /* Staff */

  async staffToken(staffId) {
    if (!this.staffTokens.has(staffId)) {
      const login = await this.request('POST', '/api/staff/login', { body: { staff_id: staffId } })
      this.staffTokens.set(staffId, login.token)
    }
    return this.staffTokens.get(staffId)
  }

  async asStaff(staffId, method, path, body) {
    return this.request(method, path, { token: await this.staffToken(staffId), body })
  }

  reset() {
    return this.asStaff(NURSE, 'POST', '/api/demo/reset')
  }

  callNext(counter = TRIAGE_COUNTER, staffId = NURSE) {
    return this.asStaff(staffId, 'POST', `/api/counters/${counter}/call-next`)
  }

  vitals(visitId, urgency = 'routine') {
    return this.asStaff(NURSE, 'POST', `/api/visits/${visitId}/vitals`, {
      bp_sys: 118,
      bp_dia: 76,
      hr: 88,
      temp_c: 38.2,
      spo2: 98,
      weight_kg: 62,
      urgency,
    })
  }

  async handoff(visitId, doctorId = DOCTOR) {
    const draft = await this.asStaff(NURSE, 'POST', `/api/visits/${visitId}/handoff/draft`)
    return this.asStaff(NURSE, 'POST', `/api/visits/${visitId}/handoff/confirm`, {
      final_text: draft.text,
      doctor_id: doctorId,
    })
  }

  async prescription(visitId) {
    const drugs = await this.asStaff(DOCTOR, 'GET', `/api/staff/visits/${visitId}/drugs`)
    const safe = drugs.filter((drug) => !drug.allergy_warning)
    const chosen = safe.find((drug) => drug.demo_default) ?? safe[0]
    return [{ drug_id: chosen.id }]
  }

  async consultDone(visitId) {
    await this.callNext(DOCTOR_COUNTER, DOCTOR)
    const prescription = await this.prescription(visitId)
    return this.asStaff(DOCTOR, 'POST', `/api/visits/${visitId}/consult/done`, { prescription })
  }

  async dispensed(visitId) {
    await this.callNext(PHARMACY_COUNTER, PHARMACIST)
    return this.asStaff(PHARMACIST, 'POST', `/api/visits/${visitId}/dispensed`)
  }

  walkIn(qid, complaint) {
    return this.asStaff(DESK, 'POST', '/api/desk/walk-in', { qid, complaint })
  }

  fastForward(visitId) {
    return this.asStaff(NURSE, 'POST', `/api/demo/fast-forward/${visitId}`)
  }

  stats(centreId = 'C-WAKRA') {
    return this.asStaff(NURSE, 'GET', `/api/stats/${centreId}`)
  }

  /* A patient, for setting up state only. Patient journeys under test go through the UI. */

  async patient(qid) {
    await this.request('POST', '/api/auth/start', { body: { qid } })
    return this.request('POST', '/api/auth/verify', { body: { qid, otp: '0000' } })
  }

  async newVisit(token, patientId) {
    const body = { consent: true, ...(patientId ? { patient_id: patientId } : {}) }
    return (await this.request('POST', '/api/visits', { token, body })).visit_id
  }

  say(token, visitId, text) {
    return this.request('POST', `/api/visits/${visitId}/chat`, { token, body: { text } })
  }

  async toSummary(token, visitId, words = FATIMA_WORDS, answers = FATIMA_ANSWERS) {
    let turn = await this.say(token, visitId, words)
    for (const answer of answers) {
      if (turn.done) break
      turn = await this.say(token, visitId, answer)
    }
    if (!turn.done) throw new Error(`no summary after: ${JSON.stringify(turn)}`)
    return turn
  }

  confirm(token, visitId) {
    return this.request('POST', `/api/visits/${visitId}/intake/confirm`, { token, body: {} })
  }

  reserve(token, visitId, centreId = 'C-WAKRA') {
    return this.request('POST', `/api/visits/${visitId}/reserve`, {
      token,
      body: { centre_id: centreId },
    })
  }

  arrive(token, visitId) {
    return this.request('POST', `/api/visits/${visitId}/arrive`, {
      token,
      body: { button: true },
    })
  }

  /** A patient taken by API as far as an active ticket. */
  async arrivedVisit(qid, words = FATIMA_WORDS, answers = FATIMA_ANSWERS) {
    const { token } = await this.patient(qid)
    const visitId = await this.newVisit(token)
    await this.toSummary(token, visitId, words, answers)
    await this.confirm(token, visitId)
    await this.reserve(token, visitId)
    const { ticket } = await this.arrive(token, visitId)
    return { token, visitId, number: ticket.number }
  }

  getVisit(token, visitId) {
    return this.request('GET', `/api/visits/${visitId}`, { token })
  }
}
