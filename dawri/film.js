import { clamp, lerp, seg, ss, eio, eo, ei, back, spring, env, mulberry, hash, vnoise, TAU } from '/core/lib.js';
import * as E from './engine.js';
import { HIT, SEC, EV } from './timeline.js';

const W = E.W, H = E.H;

// ── Dawri app palette (from frontend/src/index.css) ──────────────────────────
const GROUND   = '#f2f4f7';   // app background
const SURFACE  = '#ffffff';   // card / panel background
const BORDER   = '#e6e6e6';   // card border
const INK      = '#0a0a0a';   // primary text (dark)
const MUTED    = '#6b6b6b';   // secondary text
const DATA     = '#1d5fbf';   // accent blue
const POSITIVE = '#2e7d32';   // positive / complete green
const NEGATIVE = '#c4242a';   // emergency red
const WARN_BG  = '#fffbeb';   // warning pill background
const WARN_INK = '#92400e';   // warning pill text
const NEG_BG   = '#ffedea';   // negative pill background
const NEG_INK  = '#831c1e';   // negative pill text

// ── Presentation palette (dark keynote — title/flow/safety/arch/aim slides) ──
const ACCENT   = DATA;
const TXT1     = '#e8ecf2';   // primary text on dark
const TXT2     = '#8a94a8';   // secondary text on dark
const SURF2    = '#1a1e28';   // dark panel fill
const SURF3    = '#222834';   // darker panel fill

// ── Arabic chat message ───────────────────────────────────────────────────────
const ARABIC_MSG = 'عندي حرارة وكحة من ثلاث أيام';
// عندي حرارة وكحة من ثلاث أيام

// ── Caption table (t0 matches corrected voice cue times; no overlap) ──────────
const CAPS = [
  { t0:  3.0,   t1:  7.2,   text: "Most visits to Qatar's primary health centres are walk-ins." },
  { t0:  8.0,   t1: 11.5,   text: "Each one starts at the front desk, where staff record why you came." },
  { t0: 12.0,   t1: 14.6,   text: "Then come triage, the doctor and the pharmacy." },
  { t0: 14.912, t1: 19.2,   text: "Qatar's apps, Nar'aakom and Lbaih, handle appointments and records." },
  { t0: 19.544, t1: 23.0,   text: "But in our research, we found no digital path for walk-ins." },
  { t0: 23.25,  t1: 24.1,   text: "That is the gap." },
  { t0: 24.273, t1: 26.4,   text: "This is Dawri, دوري, which means ‘my turn’." },
  { t0: 26.669, t1: 28.4,   text: "Dawri is an AI front desk." },
  { t0: 28.701, t1: 35.7,   text: "Fatima, 34, checks in on her phone before she arrives. This is a demo, with synthetic patients." },
  { t0: 36.117, t1: 42.0,   text: "She tells the AI receptionist, in Arabic, by text or voice: fever and cough for three days." },
  { t0: 42.322, t1: 44.1,   text: "It asks a few short questions," },
  { t0: 44.346, t1: 45.2,   text: "one at a time." },
  { t0: 45.433, t1: 49.8,   text: "She picks a centre on a map with estimated waits." },
  { t0: 50.0,   t1: 52.4,   text: "That is a reservation, not yet a place in line." },
  { t0: 53.0,   t1: 65.9,   text: "When she arrives, she taps ‘I’m here’. Her ticket activates and gets a number, T-014. Order comes from arrival and the centre’s own priority rule. Plain code, no AI." },
  { t0: 66.238, t1: 71.3,   text: "At triage, the nurse sees her exact words, the AI’s intake, and her penicillin allergy." },
  { t0: 72.0,   t1: 75.0,   text: "The nurse enters vitals and confirms the handoff to the doctor." },
  { t0: 75.329, t1: 80.3,   text: "The doctor prescribes, and the system warns about amoxicillin, because of her penicillin allergy." },
  { t0: 80.578, t1: 82.7,   text: "Then the pharmacy, and the visit is done." },
  { t0: 84.0,   t1: 89.7,   text: "Ahmed asks for his usual blood-pressure pills. He is offered the refill route, with no ticket." },
  { t0: 90.039, t1: 92.8,   text: "Ravi types that he has chest pain spreading to his arm." },
  { t0: 93.126, t1: 99.4,   text: "A rule catches it first. He sees ‘call 999’ and the nearest hospital, and gets no ticket." },
  { t0:102.0,   t1:104.2,   text: "Safety does not depend on the model behaving." },
  { t0:104.465, t1:112.2,   text: "Rules check every message for emergency wording, in Arabic and English, and a hit stops the chat. The model cannot overrule it." },
  { t0:113.0,   t1:120.7,   text: "A model's reply reaches the patient only if it is one short, plain question. The AI never diagnoses and never prescribes." },
  { t0:120.974, t1:126.1,   text: "A nurse confirms everything before the doctor sees it, and the queue is code the AI cannot touch." },
  { t0:128.0,   t1:131.9,   text: "And we say plainly: no clinician has reviewed our red-flag list yet." },
  { t0:134.0,   t1:140.5,   text: "Under the hood: a FastAPI service with SQLite and a React app, in one Docker container on a Hugging Face Space." },
  { t0:140.807, t1:150.6,   text: "Chat, intake and the nurse’s handoff draft run on Gemma 4 26B, through Hugging Face Inference Providers. Whisper large-v3-turbo handles speech." },
  { t0:151.03,  t1:158.6,   text: "We chose Gemma after testing sixteen model and provider pairs. We wanted Qatar’s Fanar, but it had no provider capacity." },
  { t0:158.967, t1:163.3,   text: "Our fine-tuned Fanar 9B lost emergency recognition, so we kept it out." },
  { t0:163.675, t1:170.5,   text: "Our aim: take the reception step off the walk-in’s path, and give nurses a structured intake, with people deciding everything clinical. This is a prototype. Going live would need partnership, a clinical review and data-protection approval." },
  { t0:170.828, t1:177.2,   text: "This is a prototype. Going live would need partnership, a clinical review and data-protection approval." },
  { t0:177.541, t1:177.9,   text: "Dawri." },
  { t0:178.205, t1:179.6,   text: "Arrive, don’t register." },
];

// ── Helpers ───────────────────────────────────────────────────────────────────

function active(t) {
  return CAPS.filter(c => t >= c.t0 && t < c.t1);
}

function popIn(t, start, dur = 0.4) { return eo(seg(t, start, start + dur)); }

// Draw a card/panel with Dawri light border
function lightCard(g, x, y, w, h, r = 8) {
  g.save();
  g.fillStyle = SURFACE;
  g.beginPath();
  g.roundRect(x, y, w, h, r);
  g.fill();
  g.strokeStyle = BORDER;
  g.lineWidth = 1;
  g.stroke();
  g.restore();
}

// Draw a row for the light-theme consoles
function lightRow(g, x, y, w, h, label, value, { accent = false, valColor = INK } = {}) {
  g.save();
  g.strokeStyle = BORDER;
  g.lineWidth = 1;
  g.beginPath(); g.moveTo(x, y + h); g.lineTo(x + w, y + h); g.stroke();
  g.font = E.font(14, 400);
  g.textBaseline = 'middle';
  g.fillStyle = MUTED;
  g.textAlign = 'left';
  g.fillText(label, x + 16, y + h / 2);
  g.textAlign = 'right';
  g.fillStyle = accent ? DATA : valColor;
  g.font = E.font(14, accent ? 600 : 400);
  g.fillText(value, x + w - 16, y + h / 2);
  g.restore();
}

// ── Flow diagram (Scene 1 — dark keynote) ────────────────────────────────────

const NODES = [
  { x: 300,  label: 'Front Desk' },
  { x: 740,  label: 'Triage'     },
  { x: 1180, label: 'Doctor'     },
  { x: 1620, label: 'Pharmacy'   },
];
const NW = 260, NH = 80;

function drawFlow(g, t) {
  const spawnT = [HIT.flowStart, HIT.triaNode, HIT.doctorNode, HIT.pharmNode];

  NODES.forEach((n, i) => {
    if (t < spawnT[i]) return;
    const p = popIn(t, spawnT[i]);
    g.save();
    g.globalAlpha = p;
    g.translate(0, (1 - p) * 20);
    E.panel(g, n.x - NW / 2, H / 2 - NH / 2, NW, NH, { r: 12, fill: SURF2 });
    g.font = E.font(20, 500);
    g.fillStyle = TXT1;
    g.textBaseline = 'middle';
    g.textAlign = 'center';
    g.fillText(n.label, n.x, H / 2);
    g.restore();
    if (i < 3 && t >= spawnT[i + 1]) {
      const ap = popIn(t, spawnT[i + 1]);
      g.save();
      g.globalAlpha = ap * 0.5;
      E.arrow(g, NODES[i].x + NW / 2 + 4, H / 2, NODES[i + 1].x - NW / 2 - 4, H / 2);
      g.restore();
    }
  });

  if (t >= HIT.narLbaih) {
    const p = popIn(t, HIT.narLbaih, 0.8);
    g.save();
    g.globalAlpha = p * 0.55;
    g.font = E.font(13, 400, 'JetBrains Mono');
    g.fillStyle = TXT2;
    g.textAlign = 'center';
    g.textBaseline = 'top';
    g.fillText("Nar'aakom", NODES[0].x, H / 2 + NH / 2 + 12);
    g.fillText("appointments, records", NODES[0].x, H / 2 + NH / 2 + 28);
    g.fillText("Lbaih", NODES[3].x, H / 2 + NH / 2 + 12);
    g.fillText("appointments, records", NODES[3].x, H / 2 + NH / 2 + 28);
    g.restore();
  }

  if (t >= HIT.gapGlow) {
    const p = popIn(t, HIT.gapGlow, 1.0);
    const gapX = (NODES[0].x + NW / 2 + NODES[1].x - NW / 2) / 2;
    E.glow(g, gapX, H / 2, 200, E.accentRgba(1), p * 0.5);
    g.save();
    g.globalAlpha = p;
    g.strokeStyle = E.accentRgba(0.7);
    g.lineWidth = 1.5;
    g.setLineDash([6, 5]);
    g.beginPath();
    g.moveTo(NODES[0].x + NW / 2 + 6, H / 2);
    g.lineTo(NODES[1].x - NW / 2 - 6, H / 2);
    g.stroke();
    g.setLineDash([]);
    g.restore();
  }

  if (t >= HIT.thatIsGap && t < 24.1) {
    const p = env(t, HIT.thatIsGap, 24.0, 0.3, 0.3);
    g.save();
    g.globalAlpha = p;
    g.font = E.font(28, 500);
    g.fillStyle = E.accentRgba(1);
    g.textAlign = 'center';
    g.textBaseline = 'middle';
    g.fillText('That is the gap.', W / 2, H / 2 + 150);
    g.restore();
  }

  if (t >= HIT.dawriSubtitle && t < SEC.fatima[0]) {
    const p = env(t, HIT.dawriSubtitle, SEC.fatima[0], 0.25, 0.4);
    g.save();
    g.globalAlpha = p;
    g.font = `700 56px "IBM Plex Sans", "IBM Plex Sans Arabic"`;
    g.fillStyle = TXT1;
    g.textAlign = 'center';
    g.textBaseline = 'middle';
    g.fillText('Dawri  دوري', W / 2, H / 2 - 180);
    g.restore();
  }
}

// ── Phone frame helper ────────────────────────────────────────────────────────

function phoneFrame(g, cx, cy, sc, drawFn) {
  const PW = 400 * sc, PH = 760 * sc;
  const px = cx - PW / 2, py = cy - PH / 2;
  const pad = 10 * sc;
  // Phone body (dark casing)
  E.panel(g, px, py, PW, PH, { r: 36 * sc, fill: '#1a1e28' });
  // Screen area — Dawri app GROUND background
  const sx = px + pad, sy = py + pad + 32 * sc;
  const sw = PW - pad * 2, sh = PH - pad * 2 - 32 * sc - 10 * sc;
  g.save();
  g.beginPath();
  g.roundRect(sx, sy, sw, sh, 20 * sc);
  g.fillStyle = GROUND;
  g.fill();
  g.restore();
  // Status bar
  g.font = E.font(10 * sc, 500, 'JetBrains Mono');
  g.fillStyle = MUTED;
  g.textBaseline = 'middle';
  g.textAlign = 'center';
  g.fillText('9:41', cx, py + 18 * sc);
  // Notch
  g.beginPath();
  g.roundRect(cx - 48 * sc, py - 1, 96 * sc, 24 * sc, 12 * sc);
  g.fillStyle = '#1a1e28';
  g.fill();
  // Home indicator
  g.beginPath();
  g.roundRect(cx - 52 * sc, py + PH - 9 * sc, 104 * sc, 4 * sc, 2 * sc);
  g.fillStyle = 'rgba(0,0,0,0.2)';
  g.fill();
  if (drawFn) drawFn(g, sx, sy, sw, sh, sc);
}

// ── Phone screens — Dawri light theme ────────────────────────────────────────

function screenIntro(g, x, y, w, h, sc) {
  // Dawri logo bar at top (white strip)
  g.fillStyle = SURFACE;
  g.fillRect(x, y, w, 44 * sc);
  g.strokeStyle = BORDER;
  g.lineWidth = 1;
  g.beginPath(); g.moveTo(x, y + 44 * sc); g.lineTo(x + w, y + 44 * sc); g.stroke();
  g.font = `700 ${18 * sc}px "IBM Plex Sans"`;
  g.fillStyle = DATA;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.fillText('Dawri', x + w / 2, y + 22 * sc);

  // Subtitle
  g.font = E.font(12 * sc, 400);
  g.fillStyle = MUTED;
  g.textAlign = 'center';
  g.textBaseline = 'top';
  g.fillText('Select patient', x + w / 2, y + 50 * sc);

  // Patient list cards
  const pats = ['Fatima Al-Mohanna', 'Ahmed Al-Rashid', 'Ravi Kapoor'];
  pats.forEach((name, i) => {
    const ry = y + 76 * sc + i * (52 * sc);
    lightCard(g, x + 12 * sc, ry, w - 24 * sc, 44 * sc, 8 * sc);
    if (i === 0) {
      // Selected — DATA blue left accent
      g.fillStyle = DATA;
      g.beginPath();
      g.roundRect(x + 12 * sc, ry, 4 * sc, 44 * sc, [4 * sc, 0, 0, 4 * sc]);
      g.fill();
    }
    g.font = E.font(14 * sc, i === 0 ? 600 : 400);
    g.fillStyle = i === 0 ? INK : MUTED;
    g.textAlign = 'left';
    g.textBaseline = 'middle';
    g.fillText(name, x + 24 * sc, ry + 22 * sc);
  });

  // Footer disclaimer
  g.font = E.font(9 * sc, 400, 'JetBrains Mono');
  g.fillStyle = MUTED;
  g.textAlign = 'center';
  g.textBaseline = 'bottom';
  g.fillText('Demo · synthetic patients · not connected to PHCC/HMC', x + w / 2, y + h - 8 * sc);
}

function screenChat(g, x, y, w, h, sc, progress) {
  // Top bar
  g.fillStyle = SURFACE;
  g.fillRect(x, y, w, 44 * sc);
  g.strokeStyle = BORDER;
  g.lineWidth = 1;
  g.beginPath(); g.moveTo(x, y + 44 * sc); g.lineTo(x + w, y + 44 * sc); g.stroke();
  g.font = E.font(14 * sc, 600);
  g.fillStyle = INK;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.fillText('Dawri AI Receptionist', x + w / 2, y + 22 * sc);

  // User Arabic bubble (dark INK bg, white text, right-aligned — matches actual app)
  const bubW = w * 0.78;
  const bubY = y + 56 * sc;
  if (progress >= 0) {
    g.save();
    g.beginPath();
    g.roundRect(x + w - bubW - 10 * sc, bubY, bubW, 50 * sc, 12 * sc);
    g.fillStyle = INK;
    g.fill();
    g.direction = 'rtl';
    g.font = `400 ${14 * sc}px "IBM Plex Sans Arabic", "Noto Sans Arabic"`;
    g.fillStyle = SURFACE;
    g.textAlign = 'right';
    g.textBaseline = 'middle';
    g.fillText(ARABIC_MSG, x + w - 18 * sc, bubY + 25 * sc);
    g.restore();
  }

  // AI follow-up q1 (white card with border, left-aligned)
  if (progress >= 1) {
    const qy = bubY + 62 * sc;
    lightCard(g, x + 10 * sc, qy, bubW, 46 * sc, 12 * sc);
    g.font = `400 ${13 * sc}px "IBM Plex Sans Arabic", "Noto Sans Arabic"`;
    g.fillStyle = INK;
    g.direction = 'rtl';
    g.textAlign = 'right';
    g.textBaseline = 'middle';
    g.fillText('هل بدأت قبل ثلاثة أيام؟', x + w - 18 * sc, qy + 23 * sc);
    g.direction = 'ltr';
  }

  // AI follow-up q2
  if (progress >= 2) {
    const q2y = bubY + 120 * sc;
    lightCard(g, x + 10 * sc, q2y, bubW, 46 * sc, 12 * sc);
    g.font = `400 ${13 * sc}px "IBM Plex Sans Arabic", "Noto Sans Arabic"`;
    g.fillStyle = INK;
    g.direction = 'rtl';
    g.textAlign = 'right';
    g.textBaseline = 'middle';
    g.fillText('هل عندك أعراض أخرى؟', x + w - 18 * sc, q2y + 23 * sc);
    g.direction = 'ltr';
  }

  // Input bar
  const inputY = y + h - 52 * sc;
  g.fillStyle = SURFACE;
  g.fillRect(x, inputY, w, 52 * sc);
  g.strokeStyle = BORDER;
  g.lineWidth = 1;
  g.beginPath(); g.moveTo(x, inputY); g.lineTo(x + w, inputY); g.stroke();
  // Send button
  g.beginPath();
  g.arc(x + w - 24 * sc, inputY + 26 * sc, 14 * sc, 0, TAU);
  g.fillStyle = DATA;
  g.fill();
}

function screenMap(g, x, y, w, h, sc) {
  // Top bar
  g.fillStyle = SURFACE;
  g.fillRect(x, y, w, 44 * sc);
  g.strokeStyle = BORDER;
  g.lineWidth = 1;
  g.beginPath(); g.moveTo(x, y + 44 * sc); g.lineTo(x + w, y + 44 * sc); g.stroke();
  g.font = E.font(14 * sc, 600);
  g.fillStyle = INK;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.fillText('Select a Centre', x + w / 2, y + 22 * sc);

  // Map background (light blue-grey like a real map)
  const mx = x + 12 * sc, my = y + 54 * sc;
  const mw = w - 24 * sc, mh = h * 0.52;
  g.fillStyle = '#dde8f5';
  g.beginPath();
  g.roundRect(mx, my, mw, mh, 8 * sc);
  g.fill();

  // Qatar coast
  const coast = [
    [.5,.05],[.72,.15],[.85,.30],[.80,.55],
    [.65,.78],[.50,.90],[.38,.88],[.28,.70],
    [.22,.50],[.26,.28],[.40,.12],[.5,.05]
  ];
  g.save();
  g.beginPath();
  coast.forEach(([rx, ry], i) => {
    const px = mx + rx * mw, py = my + ry * mh;
    i === 0 ? g.moveTo(px, py) : g.lineTo(px, py);
  });
  g.closePath();
  g.strokeStyle = DATA;
  g.lineWidth = 1 * sc;
  g.stroke();
  g.fillStyle = 'rgba(29,95,191,0.08)';
  g.fill();
  g.restore();

  // Centre dots with wait labels
  const centres = [
    { rx: .54, ry: .60, name: 'Doha',     wait: '12 min' },
    { rx: .44, ry: .78, name: 'Al Wakra', wait: '8 min'  },
    { rx: .36, ry: .52, name: 'Al Rayyan',wait: '5 min'  },
    { rx: .50, ry: .28, name: 'Al Khor',  wait: '15 min' },
  ];
  centres.forEach(c => {
    const cx2 = mx + c.rx * mw, cy2 = my + c.ry * mh;
    // Dot
    g.beginPath();
    g.arc(cx2, cy2, 6 * sc, 0, TAU);
    g.fillStyle = DATA;
    g.fill();
    g.strokeStyle = SURFACE;
    g.lineWidth = 2 * sc;
    g.stroke();
    // Wait label
    g.font = E.font(10 * sc, 500);
    g.fillStyle = INK;
    g.textAlign = 'left';
    g.textBaseline = 'middle';
    g.fillText(c.wait, cx2 + 10 * sc, cy2);
  });

  // "I'm here" button — INK dark, white text (matches app primary button)
  const btnY = my + mh + 12 * sc;
  g.beginPath();
  g.roundRect(x + 20 * sc, btnY, w - 40 * sc, 42 * sc, 6 * sc);
  g.fillStyle = INK;
  g.fill();
  g.font = E.font(15 * sc, 600);
  g.fillStyle = SURFACE;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.fillText("I’m here", x + w / 2, btnY + 21 * sc);
}

function screenTicket(g, x, y, w, h, sc, t) {
  // Top bar
  g.fillStyle = SURFACE;
  g.fillRect(x, y, w, 44 * sc);
  g.strokeStyle = BORDER;
  g.lineWidth = 1;
  g.beginPath(); g.moveTo(x, y + 44 * sc); g.lineTo(x + w, y + 44 * sc); g.stroke();
  g.font = E.font(14 * sc, 600);
  g.fillStyle = DATA;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.fillText('Your Ticket', x + w / 2, y + 22 * sc);

  // Ticket card — white with border
  const ty = y + 60 * sc;
  const tCardH = h * 0.5;
  lightCard(g, x + 20 * sc, ty, w - 40 * sc, tCardH, 12 * sc);

  // Subtle DATA glow on "I'm here" activation
  const iAmHereProg = seg(t, HIT.iAmHere, HIT.ticketLocks);
  E.glow(g, x + w / 2, ty + 20 * sc, 100 * sc, `rgba(29,95,191,1)`, iAmHereProg * 0.25);

  // T-014 scramble — real time t, lockTimes in real seconds
  const lockTimes = [
    HIT.iAmHere + 0.5,
    HIT.iAmHere + 0.9,
    HIT.iAmHere + 1.3,
    HIT.iAmHere + 1.7,
    HIT.ticketLocks,
  ];
  const textCx = x + w / 2;
  E.scramble(g, 'T-014', textCx - 60 * sc, ty + 60 * sc, t, lockTimes, {
    px: 44 * sc, fam: 'IBM Plex Sans', weight: 700, color: INK,
  });

  // "IN QUEUE" label
  g.font = E.font(11 * sc, 500, 'JetBrains Mono');
  g.fillStyle = MUTED;
  g.textAlign = 'center';
  g.textBaseline = 'top';
  g.fillText('IN QUEUE', x + w / 2, ty + 110 * sc);

  // Name
  g.font = E.font(13 * sc, 400);
  g.fillStyle = INK;
  g.textBaseline = 'middle';
  g.textAlign = 'center';
  g.fillText('Fatima Al-Mohanna', x + w / 2, ty + tCardH * 0.75);
}

// ── Nurse console — Dawri light theme ────────────────────────────────────────

function drawNurseConsole(g, t) {
  const panW = 500, panH = 580;
  const panX = (W - panW * 3 - 32) / 2;
  const panY = (H - panH) / 2;

  // Panel 1: Patient words
  lightCard(g, panX, panY, panW, panH, 8);
  g.font = E.font(11, 600, 'JetBrains Mono');
  g.fillStyle = MUTED;
  g.textBaseline = 'top';
  g.textAlign = 'left';
  g.fillText('PATIENT INTAKE', panX + 16, panY + 16);
  // Arabic text (what patient typed)
  g.save();
  g.font = `400 15px "IBM Plex Sans Arabic", "Noto Sans Arabic"`;
  g.fillStyle = INK;
  g.direction = 'rtl';
  g.textAlign = 'right';
  g.textBaseline = 'top';
  g.fillText(ARABIC_MSG, panX + panW - 16, panY + 44);
  g.restore();
  // Translation
  g.font = E.font(13, 400);
  g.fillStyle = MUTED;
  g.textBaseline = 'top';
  g.textAlign = 'left';
  g.fillText('fever and cough for three days', panX + 16, panY + 72);

  // Panel 2: AI intake summary
  lightCard(g, panX + panW + 16, panY, panW, panH, 8);
  g.font = E.font(11, 600, 'JetBrains Mono');
  g.fillStyle = MUTED;
  g.textBaseline = 'top';
  g.textAlign = 'left';
  g.fillText('AI INTAKE', panX + panW + 32, panY + 16);
  const intakeRows = [
    ['Chief complaint', 'Fever + cough × 3 d'],
    ['Onset',          'Gradual'],
    ['Associated',     'Fatigue, mild rhinorrhoea'],
    ['Allergies',      'Penicillin'],
  ];
  intakeRows.forEach((row, i) => {
    const accent = row[0] === 'Allergies';
    lightRow(g, panX + panW + 16, panY + 44 + i * 52, panW, 52, row[0], row[1],
      { accent, valColor: accent ? WARN_INK : INK });
  });

  // Panel 3: Status / vitals
  lightCard(g, panX + (panW + 16) * 2, panY, panW, panH, 8);
  g.font = E.font(11, 600, 'JetBrains Mono');
  g.fillStyle = MUTED;
  g.textBaseline = 'top';
  g.textAlign = 'left';
  g.fillText('STATUS', panX + (panW + 16) * 2 + 16, panY + 16);

  // Penicillin allergy pill — warning tone, pulses
  const pulseProg = env(t, HIT.amberPulse, HIT.amberPulse + 1.5, 0.15, 0.6);
  g.save();
  if (pulseProg > 0) {
    g.shadowColor = WARN_INK;
    g.shadowBlur = 16 * pulseProg;
  }
  E.pill(g, panX + (panW + 16) * 2 + 16, panY + 44, '⚠  PENICILLIN ALLERGY', {
    bg: WARN_BG, fg: WARN_INK, fontPx: 13,
  });
  g.restore();

  // Vitals rows
  if (t >= HIT.vitals) {
    const p2 = popIn(t, HIT.vitals, 0.5);
    g.save();
    g.globalAlpha = p2;
    const vRows = [['HR', '88 bpm'], ['BP', '118/76'], ['Temp', '38.2 °C'], ['SpO2', '97 %']];
    vRows.forEach((row, i) => {
      lightRow(g, panX + (panW + 16) * 2, panY + 80 + i * 52, panW, 52, row[0], row[1]);
    });
    g.restore();
  }
}

// ── Doctor console — Dawri light theme ───────────────────────────────────────

function drawDoctorConsole(g, t) {
  const panW = 700, panH = 480;
  const px = (W - panW * 2 - 32) / 2, py = (H - panH) / 2;

  // Doctor panel
  lightCard(g, px, py, panW, panH, 8);
  g.font = E.font(11, 600, 'JetBrains Mono');
  g.fillStyle = MUTED;
  g.textBaseline = 'top';
  g.textAlign = 'left';
  g.fillText('PRESCRIBING', px + 16, py + 16);
  lightRow(g, px, py + 44, panW, 52, 'Patient', 'Fatima Al-Mohanna · F 34');
  lightRow(g, px, py + 96, panW, 52, 'Diagnosis', 'Viral URTI (ICD J06)');

  // Amoxicillin allergy warning badge
  const warnP = popIn(t, HIT.doctorRx + 0.4, 0.3);
  if (warnP > 0) {
    g.save();
    g.globalAlpha = warnP;
    g.shadowColor = NEG_INK;
    g.shadowBlur = 12;
    E.pill(g, px + 16, py + 164, '❌  Amoxicillin — allergy contraindication', {
      bg: NEG_BG, fg: NEG_INK, fontPx: 13,
    });
    g.restore();
  }
  lightRow(g, px, py + 210, panW, 52, 'Prescription', 'Paracetamol 500 mg PRN');

  // Pharmacy panel
  if (t >= HIT.pharmacy) {
    const pp = popIn(t, HIT.pharmacy, 0.5);
    lightCard(g, px + panW + 32, py, panW, panH, 8);
    g.save();
    g.globalAlpha = pp;
    g.font = E.font(11, 600, 'JetBrains Mono');
    g.fillStyle = MUTED;
    g.textBaseline = 'top';
    g.textAlign = 'left';
    g.fillText('PHARMACY', px + panW + 48, py + 16);
    lightRow(g, px + panW + 32, py + 44, panW, 52, 'Dispensed', 'Paracetamol 500 mg × 20');
    lightRow(g, px + panW + 32, py + 96, panW, 52, 'Status', 'Complete', { accent: false, valColor: POSITIVE });
    g.restore();
  }

  // "Visit complete" badge
  if (t >= HIT.pharmacy + 1.5) {
    const vc = popIn(t, HIT.pharmacy + 1.5, 0.5);
    g.save();
    g.globalAlpha = vc;
    g.font = E.font(26, 600);
    g.fillStyle = POSITIVE;
    g.textAlign = 'center';
    g.textBaseline = 'middle';
    g.fillText('✓ Visit complete', W / 2, py + panH + 56);
    g.restore();
  }
}

// ── Split screen — Ahmed (light) / Ravi (emergency red) ──────────────────────

function drawSplit(g, t) {
  const leftW = W / 2;
  const rightW = W / 2;

  // Ahmed (left) — Dawri light theme
  g.save();
  g.beginPath();
  g.rect(0, 0, leftW, H);
  g.clip();
  g.fillStyle = GROUND;
  g.fillRect(0, 0, leftW, H);

  lightCard(g, 80, 150, 740, 400, 8);
  g.font = E.font(11, 600, 'JetBrains Mono');
  g.fillStyle = MUTED;
  g.textBaseline = 'top';
  g.textAlign = 'left';
  g.fillText('REFILL REQUEST', 96, 170);
  lightRow(g, 80, 210, 740, 52, 'Patient', 'Ahmed Al-Rashid · M 58');
  lightRow(g, 80, 262, 740, 52, 'Request', 'Usual BP medication');
  lightRow(g, 80, 314, 740, 52, 'Route', 'Refill (no ticket)');
  lightRow(g, 80, 366, 740, 52, 'Queue', 'Not added', { valColor: MUTED });
  g.restore();

  // Divider
  g.save();
  g.strokeStyle = BORDER;
  g.lineWidth = 1;
  g.beginPath();
  g.moveTo(leftW, 0);
  g.lineTo(leftW, H);
  g.stroke();
  g.restore();

  // Ravi (right) — builds to NEGATIVE red emergency
  const raviP = seg(t, HIT.raviRed, HIT.raviRed + 2.0);
  g.save();
  g.beginPath();
  g.rect(leftW, 0, rightW, H);
  g.clip();

  if (raviP < 1) {
    g.fillStyle = GROUND;
    g.fillRect(leftW, 0, rightW, H);
    lightCard(g, leftW + 80, 150, 740, 400, 8);
    g.font = E.font(11, 600, 'JetBrains Mono');
    g.fillStyle = MUTED;
    g.textBaseline = 'top';
    g.textAlign = 'left';
    g.fillText('AI RECEPTIONIST', leftW + 96, 170);
    // Ravi's message bubble
    g.beginPath();
    g.roundRect(leftW + 100, 220, 580, 46, 12);
    g.fillStyle = INK;
    g.fill();
    g.font = E.font(14, 400);
    g.fillStyle = SURFACE;
    g.textBaseline = 'middle';
    g.textAlign = 'left';
    g.fillText('chest pain spreading to my arm', leftW + 120, 243);
  }

  if (raviP > 0) {
    const redAlpha = Math.min(1, raviP * 1.5);
    g.fillStyle = `rgba(196,36,42,${redAlpha})`;
    g.fillRect(leftW, 0, rightW, H);
    g.save();
    g.globalAlpha = Math.min(1, (raviP - 0.3) / 0.4);
    g.font = `700 56px "IBM Plex Sans"`;
    g.fillStyle = SURFACE;
    g.textAlign = 'center';
    g.textBaseline = 'middle';
    g.shadowColor = 'rgba(0,0,0,0.3)';
    g.shadowBlur = 20;
    g.fillText('☎ CALL 999', leftW + rightW / 2, H / 2 - 60);
    g.font = E.font(22, 500);
    g.fillStyle = 'rgba(255,255,255,0.9)';
    g.shadowBlur = 0;
    g.fillText('Nearest hospital: Hamad General Hospital', leftW + rightW / 2, H / 2 + 30);
    g.fillText('No ticket issued.', leftW + rightW / 2, H / 2 + 68);
    g.restore();
  }
  g.restore();

  // Red panel fades to dark for safety transition
  if (t >= HIT.crtOff - 0.5) {
    const fadeP = seg(t, HIT.crtOff - 0.5, HIT.crtOff + 0.3);
    g.save();
    g.globalAlpha = fadeP;
    g.fillStyle = '#080a0d';
    g.fillRect(0, 0, W, H);
    g.restore();
  }
}

// ── Safety cards (dark keynote) ───────────────────────────────────────────────

const SAFETY_CARDS = [
  { title: 'Rules first', body: 'Emergency wording checked before every reply, in Arabic and English. A hit stops the chat.' },
  { title: 'Model reply check', body: 'A reply reaches the patient only if it is one short, plain question.' },
  { title: 'No diagnosis, no prescribing', body: 'The AI never diagnoses and never prescribes.' },
  { title: 'Nurse confirms', body: 'A nurse confirms everything before the doctor sees it.' },
  { title: 'Queue engine: no AI', body: 'The queue is code the AI cannot touch.' },
];
const CARD_TIMES = [HIT.card1, HIT.card2, HIT.card3, HIT.card4, HIT.card5];

function drawSafety(g, t) {
  const CW = 860, CH = 72;
  const cx = (W - CW) / 2;
  const totalH = SAFETY_CARDS.length * (CH + 12) - 12;
  const startY = (H - totalH) / 2;
  const snapped = t >= HIT.snapBurst;

  SAFETY_CARDS.forEach((card, i) => {
    if (t < CARD_TIMES[i]) return;
    const dropP = eo(seg(t, CARD_TIMES[i], CARD_TIMES[i] + 0.5));
    const targetY = startY + i * (CH + 12);
    const entryY = snapped ? targetY : lerp(targetY - 120, targetY, dropP);
    const alpha = snapped ? 1 : dropP;

    g.save();
    g.globalAlpha = alpha;
    E.panel(g, cx, entryY, CW, CH, { r: 10, fill: SURF2 });
    g.fillStyle = E.accentRgba(0.7);
    g.beginPath();
    g.roundRect(cx, entryY, 4, CH, [0, 2, 2, 0]);
    g.fill();
    g.font = E.font(17, 600);
    g.fillStyle = TXT1;
    g.textBaseline = 'middle';
    g.textAlign = 'left';
    g.fillText(card.title, cx + 20, entryY + 24);
    g.font = E.font(13, 400);
    g.fillStyle = TXT2;
    g.fillText(card.body, cx + 20, entryY + 50);
    g.restore();
  });

  if (t >= HIT.snapBurst && t < HIT.snapBurst + 0.3) {
    const fp = 1 - seg(t, HIT.snapBurst, HIT.snapBurst + 0.3);
    g.save();
    g.globalAlpha = fp * 0.12;
    g.fillStyle = '#fff';
    g.fillRect(0, 0, W, H);
    g.restore();
  }

  if (t >= HIT.disclaimer) {
    const dp = popIn(t, HIT.disclaimer, 0.5);
    g.save();
    g.globalAlpha = dp;
    const dy = startY + totalH + 20;
    E.panel(g, cx, dy, CW, 50, { r: 10, fill: '#1a1200' });
    g.fillStyle = WARN_INK;
    g.beginPath();
    g.roundRect(cx, dy, 4, 50, [0, 2, 2, 0]);
    g.fill();
    g.font = E.font(14, 500);
    g.fillStyle = WARN_INK;
    g.textBaseline = 'middle';
    g.textAlign = 'left';
    g.fillText('⚠️  Red-flag list: not clinically reviewed yet', cx + 20, dy + 25);
    g.restore();
  }
}

// ── Architecture (dark keynote) ───────────────────────────────────────────────

const ARCH_NODES = [
  { label: 'Patient App',      sub: 'React',           active: false },
  { label: 'Red-flag Rules',   sub: 'code only',        active: true  },
  { label: 'AI Receptionist',  sub: 'FastAPI',          active: false },
  { label: 'HF Inference',     sub: 'Providers',        active: true  },
  { label: 'Reply Check',      sub: 'code only',        active: true  },
  { label: 'Staff Consoles',   sub: 'React',            active: false },
  { label: 'Queue Engine',     sub: 'code only',        active: true  },
  { label: 'SQLite',           sub: 'Docker',           active: false },
];
const AN_W = 180, AN_H = 70, AN_GAP = 48;
const ARCH_TOTAL_W = ARCH_NODES.length * (AN_W + AN_GAP) - AN_GAP;

function drawArch(g, t) {
  const p = seg(t, HIT.archBegins, SEC.aim[0]);
  const camX = lerp(0, ARCH_TOTAL_W - W + 220, p);
  const baseY = H / 2 - AN_H / 2;
  const startX = (W - ARCH_TOTAL_W) / 2;

  g.save();
  g.translate(-camX, 0);

  ARCH_NODES.forEach((node, i) => {
    const nx = startX + 100 + i * (AN_W + AN_GAP);
    const entryP = popIn(t, HIT.archBegins + i * 0.5, 0.5);
    g.save();
    g.globalAlpha = entryP;
    E.archNode(g, nx, baseY, AN_W, AN_H, node.label, node.sub, { active: node.active });
    if (i < ARCH_NODES.length - 1) {
      const ax1 = nx + AN_W + 4, ax2 = nx + AN_W + AN_GAP - 4;
      E.arrow(g, ax1, baseY + AN_H / 2, ax2, baseY + AN_H / 2,
              { color: 'rgba(255,255,255,0.18)' });
    }
    g.restore();
  });

  if (t >= HIT.modelCards) {
    const mp = popIn(t, HIT.modelCards, 0.5);
    const hfIdx = 3;
    const hfX = startX + 100 + hfIdx * (AN_W + AN_GAP);
    g.save();
    g.globalAlpha = mp;
    E.panel(g, hfX - 100, baseY - 110, 200, 54, { r: 10, fill: SURF3 });
    g.font = E.font(13, 600, 'JetBrains Mono');
    g.fillStyle = TXT1;
    g.textBaseline = 'middle';
    g.textAlign = 'center';
    g.fillText('Gemma 4 26B', hfX, baseY - 83);
    E.panel(g, hfX + 120, baseY - 110, 220, 54, { r: 10, fill: SURF3 });
    g.fillText('Whisper large-v3-turbo', hfX + 230, baseY - 83);
    g.restore();
  }

  if (t >= HIT.ourTest) {
    const op = popIn(t, HIT.ourTest, 0.5);
    const hfIdx = 3;
    const hfX = startX + 100 + hfIdx * (AN_W + AN_GAP);
    g.save();
    g.globalAlpha = op;
    E.pill(g, hfX - 90, baseY + AN_H + 10, 'our test: Fanar 9B → 0/13 emergency', {
      bg: 'rgba(29,95,191,0.2)', fg: E.accentRgba(1), fontPx: 12,
    });
    g.restore();
  }

  if (t >= HIT.fanarDims) {
    const dp = seg(t, HIT.fanarDims, HIT.fanarDims + 1.5);
    const hfIdx = 3;
    const hfX = startX + 100 + hfIdx * (AN_W + AN_GAP);
    g.save();
    g.globalAlpha = dp * 0.6;
    g.fillStyle = '#0a0c0f';
    g.beginPath();
    g.roundRect(hfX - 110, baseY - 120, 440, 65, 10);
    g.fill();
    g.restore();
  }

  g.restore();
}

// ── Aim section (dark keynote) ────────────────────────────────────────────────

function drawAim(g, t) {
  const lines = [
    { text: 'Reception step removed',          t: HIT.line1 },
    { text: 'Structured intake for nurses',     t: HIT.line2 },
    { text: 'People decide everything clinical', t: HIT.line3 },
  ];
  const lineH = 72;
  const totalH = lines.length * lineH;
  const ys = (H - totalH) / 2;

  lines.forEach((line, i) => {
    if (t < line.t) return;
    const p = t < HIT.textClear
      ? popIn(t, line.t, 0.5)
      : 1 - eo(seg(t, HIT.textClear, HIT.textClear + 0.5));
    g.save();
    g.globalAlpha = p;
    g.font = E.font(28, 500);
    g.fillStyle = TXT1;
    g.textBaseline = 'middle';
    g.textAlign = 'center';
    g.fillText(line.text, W / 2, ys + i * lineH + lineH / 2);
    g.restore();
  });

  if (t >= HIT.dawriWord) {
    const wp = popIn(t, HIT.dawriWord, 0.4);
    g.save();
    g.globalAlpha = wp;
    g.font = `700 96px "IBM Plex Sans"`;
    g.fillStyle = TXT1;
    g.textAlign = 'center';
    g.textBaseline = 'middle';
    g.fillText('Dawri.', W / 2, H / 2 - 40);
    g.restore();
  }

  if (t >= HIT.catchphrase) {
    const cp = eio(seg(t, HIT.catchphrase, HIT.catchphrase + 2.2));
    const { canvas: bc, g: bg2 } = E.buf('catchphrase');
    bg2.clearRect(0, 0, W, H);
    bg2.font = `600 72px "IBM Plex Sans"`;
    bg2.fillStyle = E.accentRgba(1);
    bg2.textAlign = 'center';
    bg2.textBaseline = 'middle';
    bg2.fillText('Arrive, don’t register.', W / 2, H / 2 + 48);
    E.lightReveal(g, bc, 0, 0, W, H, cp, { base: 0.04, soft: 500, band: 320, glint: 0.22 });
  }
}

// ── Main render entry point ───────────────────────────────────────────────────

export function createRender(ctx) {
  return function render(t) {
    E.setAccent(ACCENT);
    const g = ctx;

    if (t < SEC.problem[0]) {
      // S1: Title (dark keynote)
      E.bg(g);
      E.grid(g);
      const p = ss(seg(t, 0.3, 2.5));
      const { canvas: bc, g: bg2 } = E.buf('title');
      bg2.clearRect(0, 0, W, H);
      bg2.font = `700 120px "IBM Plex Sans", "IBM Plex Sans Arabic"`;
      bg2.fillStyle = TXT1;
      bg2.textBaseline = 'middle';
      bg2.textAlign = 'center';
      bg2.fillText('Dawri  دوري', W / 2, H / 2);
      E.lightReveal(g, bc, 0, 0, W, H, p, { base: 0.05, soft: 400, band: 300, glint: 0.2 });

    } else if (t < SEC.fatima[0]) {
      // S2: Problem (dark keynote)
      E.bg(g);
      E.grid(g);
      drawFlow(g, t);

    } else if (t < SEC.split[0]) {
      // S3: Fatima journey — dark stage + light phone/consoles
      E.bg(g);
      E.grid(g);

      const phoneX = t < HIT.mapSlides ? W * 0.38 : lerp(W * 0.38, W * 0.27, seg(t, HIT.mapSlides, HIT.mapSlides + 0.5));
      const sc = 0.95;
      const phoneIn = popIn(t, HIT.phonePops, 0.5);

      g.save();
      g.globalAlpha = phoneIn;

      if (t < HIT.arabicTypes) {
        phoneFrame(g, phoneX, H / 2, sc, screenIntro);
      } else if (t < HIT.mapSlides) {
        const chatProg = t < HIT.q1 ? 0 : t < HIT.q2 ? 1 : 2;
        phoneFrame(g, phoneX, H / 2, sc, (gg, x, y, w, h, s) => screenChat(gg, x, y, w, h, s, chatProg));
      } else if (t < HIT.orderCode) {
        const inMap = t < HIT.iAmHere + 2.0;
        if (inMap) {
          phoneFrame(g, phoneX, H / 2, sc, screenMap);
        } else {
          phoneFrame(g, phoneX, H / 2, sc, (gg, x, y, w, h, s) => screenTicket(gg, x, y, w, h, s, t));
        }
      } else {
        const fadeA = 1 - seg(t, HIT.orderCode, HIT.nursePops);
        g.globalAlpha = phoneIn * (1 - fadeA * 0.9);
        phoneFrame(g, phoneX, H / 2, sc, (gg, x, y, w, h, s) => screenTicket(gg, x, y, w, h, s, t));
      }
      g.restore();

      // Map panel slides in from right
      if (t >= HIT.mapSlides && t < HIT.iAmHere + 2.5) {
        const mapP = eo(seg(t, HIT.mapSlides, HIT.mapSlides + 0.6));
        const mapX = W - 540 - 48;
        const mapFade = t < HIT.iAmHere + 1.5 ? 1
          : 1 - seg(t, HIT.iAmHere + 1.5, HIT.iAmHere + 2.5);
        g.save();
        g.globalAlpha = mapP * mapFade;
        g.translate((1 - mapP) * 60, 0);
        // Light card for the map panel
        g.fillStyle = SURFACE;
        g.beginPath();
        g.roundRect(mapX, 80, 480, 760 * sc, 8);
        g.fill();
        g.strokeStyle = BORDER;
        g.lineWidth = 1;
        g.stroke();
        // Header
        g.font = E.font(13, 600);
        g.fillStyle = DATA;
        g.textBaseline = 'top';
        g.textAlign = 'center';
        g.fillText('PRIMARY HEALTH CENTRES', mapX + 240, 100);
        // Map inside
        const mx = mapX + 20, my = 130, mw = 440, mh = 500;
        g.fillStyle = '#dde8f5';
        g.beginPath();
        g.roundRect(mx, my, mw, mh, 8);
        g.fill();
        const coast = [[.5,.05],[.72,.15],[.85,.30],[.80,.55],[.65,.78],[.50,.90],[.38,.88],[.28,.70],[.22,.50],[.26,.28],[.40,.12],[.5,.05]];
        g.beginPath();
        coast.forEach(([rx, ry], i) => {
          i === 0 ? g.moveTo(mx + rx * mw, my + ry * mh) : g.lineTo(mx + rx * mw, my + ry * mh);
        });
        g.closePath();
        g.strokeStyle = DATA;
        g.lineWidth = 1;
        g.stroke();
        g.fillStyle = 'rgba(29,95,191,0.08)';
        g.fill();
        const centres = [[.54,.60,'12 min'],[.44,.78,'8 min'],[.36,.52,'5 min'],[.50,.28,'15 min']];
        centres.forEach(([rx, ry, wt]) => {
          const dx = mx + rx * mw, dy = my + ry * mh;
          g.beginPath();
          g.arc(dx, dy, 5, 0, TAU);
          g.fillStyle = DATA;
          g.fill();
          g.strokeStyle = SURFACE;
          g.lineWidth = 1.5;
          g.stroke();
          g.font = E.font(11, 500);
          g.fillStyle = INK;
          g.textAlign = 'left';
          g.textBaseline = 'middle';
          g.fillText(wt, dx + 8, dy);
        });
        g.restore();
      }

      // Nurse / doctor consoles enter
      if (t >= HIT.nursePops && t < HIT.doctorRx - 0.5) {
        const np = popIn(t, HIT.nursePops, 0.5);
        g.save();
        // Light GROUND background for console area
        g.globalAlpha = np;
        g.fillStyle = GROUND;
        g.fillRect(0, 0, W, H);
        drawNurseConsole(g, t);
        g.restore();
      } else if (t >= HIT.doctorRx - 0.5) {
        const dp = popIn(t, HIT.doctorRx - 0.5, 0.5);
        g.save();
        g.fillStyle = GROUND;
        g.fillRect(0, 0, W, H);
        g.globalAlpha = dp;
        drawDoctorConsole(g, t);
        g.restore();
      }

    } else if (t < SEC.safety[0]) {
      // S4: Split screen
      drawSplit(g, t);

    } else if (t < SEC.stack[0]) {
      // S5: Safety cards (dark keynote)
      E.bg(g);
      E.grid(g);
      drawSafety(g, t);

    } else if (t < SEC.aim[0]) {
      // S6: Architecture stack (dark keynote)
      E.bg(g);
      E.grid(g);
      drawArch(g, t);

    } else {
      // S7: Aim + ending (dark keynote)
      E.bg(g, { lift: '#0d1016', cool: '#1a2340', dark: '#070809' });
      drawAim(g, t);
    }

    // Vignette
    E.vignette(g, 0.4);

    // Captions
    const caps = active(t);
    if (caps.length > 0) {
      const c = caps[0];
      const a = env(t, c.t0, c.t1, 0.16, 0.16);
      E.toast(g, c.text, a);
    }
  };
}

export { EV } from './timeline.js';
