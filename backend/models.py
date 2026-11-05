"""SQLite schema: the vault's Data Model note plus the Build Decisions changes."""

from __future__ import annotations

SCHEMA = """
CREATE TABLE IF NOT EXISTS patient (
  id            TEXT PRIMARY KEY,          -- 'P001'
  qid_demo      TEXT UNIQUE NOT NULL,      -- fake, e.g. 'DEMO-28934' (never real)
  full_name_en  TEXT, full_name_ar TEXT,
  dob           TEXT, sex TEXT CHECK (sex IN ('F','M')),
  preferred_lang TEXT DEFAULT 'ar',
  registered_centre_id TEXT REFERENCES centre(id),
  allergies     TEXT,                      -- JSON array
  chronic       TEXT,                      -- JSON array
  active_meds   TEXT                       -- JSON array
);

CREATE TABLE IF NOT EXISTS dependent_link (guardian_id TEXT, dependent_id TEXT,
  PRIMARY KEY (guardian_id, dependent_id));

CREATE TABLE IF NOT EXISTS centre (
  id TEXT PRIMARY KEY, name_en TEXT, name_ar TEXT,
  operator TEXT CHECK (operator IN ('PHCC','HMC')),
  lat REAL, lng REAL, services TEXT,       -- JSON array of service codes
  has_emergency INTEGER DEFAULT 0,
  priority_age_min INTEGER DEFAULT 65
);

CREATE TABLE IF NOT EXISTS staff (
  id TEXT PRIMARY KEY, centre_id TEXT REFERENCES centre(id),
  name TEXT, role TEXT CHECK (role IN ('nurse','doctor','pharmacist','desk')),
  clinic TEXT, languages TEXT, gender TEXT
);

CREATE TABLE IF NOT EXISTS counter (       -- a queue point
  id TEXT PRIMARY KEY, centre_id TEXT, stage TEXT
    CHECK (stage IN ('triage','doctor','pharmacy')),
  label TEXT,                              -- 'Triage 1', 'Room 4'
  label_ar TEXT,
  staff_id TEXT REFERENCES staff(id),
  prefix TEXT,                             -- 'T', 'D-GP', 'P'
  avg_service_sec INTEGER DEFAULT 420
);

CREATE TABLE IF NOT EXISTS visit (
  id TEXT PRIMARY KEY, patient_id TEXT REFERENCES patient(id),
  centre_id TEXT REFERENCES centre(id),    -- nullable, set at reserve
  status TEXT CHECK (status IN ('intake','redirected_emergency','deflected_refill',
     'reserved','expired','in_triage','in_doctor','in_pharmacy','completed','cancelled')),
  service TEXT, created_at TEXT, arrived_at TEXT, completed_at TEXT,
  booked_by TEXT REFERENCES patient(id)
);

CREATE TABLE IF NOT EXISTS intake (visit_id TEXT PRIMARY KEY REFERENCES visit(id),
  json TEXT NOT NULL, transcript TEXT, confirmed_by_patient INTEGER DEFAULT 0,
  edited_by_staff_id TEXT, edited_json TEXT);

CREATE TABLE IF NOT EXISTS ticket (
  id TEXT PRIMARY KEY, visit_id TEXT REFERENCES visit(id),
  centre_id TEXT NOT NULL REFERENCES centre(id),
  counter_id TEXT REFERENCES counter(id), number TEXT,   -- 'T-014'
  day TEXT,
  seq INTEGER,                              -- order within counter/day
  priority INTEGER DEFAULT 0,               -- set ONLY by centre rules
  state TEXT CHECK (state IN ('reserved','active','called','serving','done','released')),
  simulated INTEGER NOT NULL DEFAULT 0,
  call_count INTEGER NOT NULL DEFAULT 0,
  reserved_at TEXT, activated_at TEXT, called_at TEXT, done_at TEXT,
  released_at TEXT,
  CHECK (state <> 'reserved' OR (number IS NULL AND seq IS NULL AND activated_at IS NULL)),
  CHECK (simulated = 0 OR visit_id IS NULL),
  CHECK (simulated = 1 OR visit_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS ix_ticket_queue
  ON ticket(counter_id, state, priority DESC, activated_at, seq);
CREATE UNIQUE INDEX IF NOT EXISTS ux_ticket_number
  ON ticket(centre_id, day, number) WHERE number IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_ticket_live
  ON ticket(visit_id)
  WHERE visit_id IS NOT NULL AND state IN ('reserved','active','called','serving');

CREATE TABLE IF NOT EXISTS number_sequence (
  centre_id TEXT, prefix TEXT, day TEXT, last_value INTEGER NOT NULL,
  PRIMARY KEY (centre_id, prefix, day)
);

CREATE TABLE IF NOT EXISTS vitals (visit_id TEXT PRIMARY KEY, bp_sys INT, bp_dia INT, hr INT,
  temp_c REAL, spo2 INT, weight_kg REAL, urgency TEXT, nurse_id TEXT, at TEXT);

CREATE TABLE IF NOT EXISTS handoff (visit_id TEXT PRIMARY KEY, ai_draft TEXT, final_text TEXT,
  suggested_doctor_id TEXT, chosen_doctor_id TEXT, reason TEXT,
  confirmed_by TEXT, at TEXT);

CREATE TABLE IF NOT EXISTS prescription_item (id INTEGER PRIMARY KEY AUTOINCREMENT,
  visit_id TEXT, drug TEXT, dose TEXT, frequency TEXT, days INT, notes TEXT);

CREATE TABLE IF NOT EXISTS event (id INTEGER PRIMARY KEY AUTOINCREMENT, visit_id TEXT,
  type TEXT, payload TEXT, at TEXT);       -- audit trail for every AI + staff action

CREATE TABLE IF NOT EXISTS session (
  token TEXT PRIMARY KEY,
  kind TEXT CHECK (kind IN ('patient','staff')),
  subject_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS drug (
  id TEXT PRIMARY KEY, name_en TEXT, name_ar TEXT, form TEXT,
  default_dose TEXT, default_frequency TEXT, default_days INT,
  allergy_tags TEXT,                       -- JSON array
  demo_default INTEGER DEFAULT 0
);
"""
