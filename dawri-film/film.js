// "Dawri — One Visit": the timeline. Voice lines set the clock; every beat hangs on a spoken word.
import { clamp, lerp, seg, ss, eio, eo, ei, back, hash } from '/core/lib.js';
import * as U from './ui.js';
import * as SP from './sprite.js';

export const BPM = 96, B = 60 / BPM;
// silence before each line (s). Two real silences: before "That is the gap." and before "Dawri."
const GAP = { v01: 1.0, v02: .45, v03: .3, v04: .5, v05: .5, v06: 1.5, v07: 1.6, v08: 2.2, v09: .35, v10: .55, v11: .5, v12: .15, v13: .6, v14: .35,
  v15: .6, v16: 1.15, v17: .4, v18: .5, v19: .4, v20: 1.5, v21: .6, v22: .3, v23: 1.9, v24: .3, v25: .3, v26: .3, v27: .45, v28: 1.8, v29: .4, v30: .4,
  v31: .3, v32: 1.9, v33: .4, v34: 1.4, v35: .6 };
export const VO = {}, D = {}; export let DUR = 0;
let WORDS = {};
const nrm = s => s.toLowerCase().replace(/[^a-z0-9]/g, '');
const S = id => VO[id], E = id => VO[id] + D[id];
export const W = (id, word, n = 0) => { let k = 0; for (const [w, a] of WORDS[id]) if (nrm(w) === nrm(word) && k++ === n) return VO[id] + Math.max(0, a); throw new Error(`word ${word} not in ${id}`); };
export const EV = []; const ev = (t, type, o = {}) => EV.push({ t: +t.toFixed(3), type, ...o });
export const SUBS = []; export const T = {};

// ───── camera (single take inside each chapter; cuts only under wipes)
const EASE = { eio, ss, eo, ei, whip: x => { x = clamp(x); return x < .5 ? 16 * x ** 5 : 1 - (-2 * x + 2) ** 5 / 2; }, cut: x => x > 0 ? 1 : 0 };
const MOVES = []; const cam = (t0, d, to, e = 'eio') => MOVES.push({ t0, d, to, e });
export function camAt(t) {
  let v = [960, 540, Math.log(1)];
  for (const m of MOVES) { if (t <= m.t0) break; const p = EASE[m.e]((t - m.t0) / m.d);
    v = [lerp(v[0], m.to[0], p), lerp(v[1], m.to[1], p), lerp(v[2], Math.log(m.to[2]), p)]; }
  const z = Math.exp(v[2]);
  return [v[0] + Math.sin(t * .7) * 1.4 / z, v[1] + Math.sin(t * .53 + 1) * 1.0 / z, z];
}

// ───── actor (the ticket mascot)
class Actor {
  constructor(px = 6) { this.px = px; this.segs = []; this.jumps = []; }
  add(s) { this.segs.push(s); return this; }
  stand(t0, t1, at, o = {}) { return this.add({ k: 'stand', t0, t1, at, ...o }); }
  walk(t0, t1, from, to, o = {}) { for (let t = t0 + .06; t < t1; t += .12) ev(t, 'step'); return this.add({ k: 'walk', t0, t1, from, to, ...o }); }
  jump(t0, t1, from, to, h = 90, o = {}) { this.jumps.push({ t0, t1, o }); ev(t0 - .02, 'jump', { d: t1 - t0 }); ev(t1, 'land', { v: o.big ? 1 : .6 }); return this.add({ k: 'jump', t0, t1, from, to, h, ...o }); }
  hide(t0, t1) { return this.add({ k: 'hide', t0, t1 }); }
  seg(t) { let s = null; for (const x of this.segs) { if (x.t0 <= t && t < x.t1) return x; if (x.t0 <= t) s = x; } return s; }
  eval(t, A) {
    const s = this.seg(t); if (!s || s.k === 'hide') return null;
    const px = s.px || this.px; let pos, legs = 'stand', flip = s.flip || false, sq = 0, rot = 0, arms = 'down', eyes = 'n';
    const P = f => typeof f === 'function' ? f(A, t) : f;
    if (s.k === 'stand') pos = P(s.at);
    if (s.k === 'walk') { const a = P(s.from), b = P(s.to); if (!a || !b) return null; const p = ss(seg(t, s.t0, s.t1));
      pos = { x: lerp(a.x, b.x, p), y: lerp(a.y, b.y, p) }; legs = Math.floor(t * 9) % 2 ? 'walkA' : 'walkB'; flip = b.x < a.x; }
    if (s.k === 'jump') { const a = P(s.from), b = P(s.to); if (!a || !b) return null; const p = seg(t, s.t0, s.t1);
      const ap = Math.min(a.y, b.y) - s.h, cy = 2 * ap - (a.y + b.y) / 2;
      pos = { x: lerp(a.x, b.x, p), y: (1 - p) ** 2 * a.y + 2 * (1 - p) * p * cy + p * p * b.y }; legs = 'tuck';
      flip = b.x < a.x - 2; sq = p < .5 ? -.22 * (1 - p * 2) : -.12 * (p * 2 - 1); if (s.spin) rot = p * Math.PI * 2 * (b.x < a.x ? -1 : 1); arms = 'up'; }
    if (!pos) return null;
    for (const j of this.jumps) {
      if (t >= j.t0 - .14 && t < j.t0) sq = Math.max(sq, .28 * ss(seg(t, j.t0 - .14, j.t0)));
      if (t >= j.t1 && t < j.t1 + .24) { const k = seg(t, j.t1, j.t1 + .24); sq = .34 * (1 - k) * Math.cos(k * 7); }
    }
    if (s.k === 'stand' && !s.still) { const bp = ((t % B) + B) % B; if (bp < .12) sq += .07 * Math.sin(bp / .12 * Math.PI); }
    const bl = Math.floor(t / 2.7), bt = t - bl * 2.7 - hash(bl * 3.7 + px) * 1.9;
    if (bt > 0 && bt < .1) eyes = 'blink';
    if (s.eyes) { const e = typeof s.eyes === 'function' ? s.eyes(t) : s.eyes; if (e && !(eyes === 'blink' && 'nlrud'.includes(e))) eyes = e; }
    if (s.arms) arms = typeof s.arms === 'function' ? s.arms(t) : s.arms;
    if (s.legs) legs = s.legs;
    const x = Math.round(pos.x / (px / 2)) * (px / 2);
    return { x, y: pos.y + (s.dy || 0), px, flip, sq, rot, legs, arms, eyes, op: s.op ? s.op(t) : 1, ghost: s.ghost ? s.ghost(t) : false, shadow: s.k === 'jump' ? 0 : 1 };
  }
}
// ───── cursor
class Cursor {
  constructor() { this.moves = []; this.clicks = []; this.vis = []; }
  show(t0, t1) { this.vis.push([t0, t1]); return this; }
  move(t0, t1, to, arc = 40) { this.moves.push({ t0, t1, to, arc }); return this; }
  click(t) { this.clicks.push(t); ev(t, 'click'); return this; }
  tap(t0, to, t1) { this.move(t0, t1 - .1, to); this.click(t1); return this; }
  eval(t, A) {
    let op = 0; for (const [a, b] of this.vis) op = Math.max(op, Math.min(seg(t, a, a + .2), 1 - seg(t, b - .25, b)));
    if (op <= 0) return null;
    let p = null, prev = null;
    for (const m of this.moves) { const to = m.to(A, t); if (!to) continue; if (t < m.t0) break;
      if (!prev) { p = to; prev = to; continue; }
      const k = seg(t, m.t0, m.t1), e = eio(k), from = prev, dx = to.x - from.x, dy = to.y - from.y, L = Math.hypot(dx, dy) || 1;
      p = { x: lerp(from.x, to.x, e) - dy / L * m.arc * Math.sin(Math.PI * e), y: lerp(from.y, to.y, e) + dx / L * m.arc * Math.sin(Math.PI * e), sp: Math.abs(Math.sin(Math.PI * k)) * L / (m.t1 - m.t0) };
      prev = k >= 1 ? to : from; if (k < 1) break; }
    if (!p) return null;
    let sc = 1, ring = 0; for (const c of this.clicks) { if (t >= c && t < c + .1) sc = .82; if (t >= c && t < c + .45) ring = seg(t, c, c + .45); }
    return { ...p, op, sc, ring };
  }
}
const at = (key, fx = .5, fy = 0, dx = 0, dy = 0) => { let last = null; return A => { const p = A(key, fx, fy); if (p) last = { x: p.x + dx, y: p.y + dy }; return last; }; };
const pt = (x, y) => () => ({ x, y });

// typing with a human rhythm
function typing(t0, text, cps = 13, seed = 1, kind = 'key') {
  const TT = []; let t = t0; const ch = [...text];
  for (let i = 0; i < ch.length; i++) { const r = hash(seed * 31 + i * 7.3); t += (1 / cps) * (.55 + r * .9) + (ch[i] === ' ' ? .03 : 0); TT.push(t); ev(t, kind, { v: .5 + r * .4 }); }
  return TT;
}
const typed = (TT, text, t) => { let n = 0; while (n < TT.length && TT[n] <= t) n++; return [...text].slice(0, n).join(''); };

// ───── build
let M, M2, CUR, TY = {};
export function build(words, dur) {
  WORDS = words; let t = 0;
  for (const id of Object.keys(GAP)) { t += GAP[id]; VO[id] = +t.toFixed(3); D[id] = dur[id]; t += dur[id]; }
  DUR = +Math.min(179.9, t + 1.75).toFixed(2);
  EV.length = 0; MOVES.length = 0; SUBS.length = 0;
  M = new Actor(6); M2 = new Actor(6); CUR = new Cursor();
  const CAP = { v01: "Most visits to Qatar's primary health centres are walk-ins.", v02: 'Each one starts at the front desk, where staff record why you came.',
    v03: 'Then come triage, the doctor and the pharmacy.', v04: "Qatar's apps, Nar'aakom and Lbaih, handle appointments and records.",
    v05: 'But in our research, we found no digital path for walk-ins.', v06: 'That is the gap.', v07: "This is Dawri, دوري, which means “my turn”.",
    v08: 'Dawri is an AI front desk.', v09: 'Fatima, 34, checks in on her phone before she arrives. This is a demo, with synthetic patients.',
    v10: 'She tells the AI receptionist, in Arabic, by text or voice: fever and cough for three days.', v11: 'It asks a few short questions,', v12: 'one at a time.',
    v13: 'She picks a centre on a map with estimated waits.', v14: 'That is a reservation, not yet a place in line.',
    v15: ["When she arrives, she taps “I'm here”. Her ticket activates and gets a number, T-014.", "Order comes from arrival and the centre's own priority rule. Plain code, no AI."],
    v16: "At triage, the nurse sees her exact words, the AI's intake, and her penicillin allergy.", v17: 'The nurse enters vitals and confirms the handoff to the doctor.',
    v18: 'The doctor prescribes, and the system warns about amoxicillin, because of her penicillin allergy.', v19: 'Then the pharmacy, and the visit is done.',
    v20: 'Ahmed asks for his usual blood-pressure pills. He is offered the refill route, with no ticket.', v21: 'Ravi types that he has chest pain spreading to his arm.',
    v22: "A rule catches it first. He sees “call 999” and the nearest hospital, and gets no ticket.", v23: 'Safety does not depend on the model behaving.',
    v24: ['Rules check every message for emergency wording, in Arabic and English,', 'and a hit stops the chat. The model cannot overrule it.'],
    v25: ["A model's reply reaches the patient only if it is one short, plain question.", 'The AI never diagnoses and never prescribes.'],
    v26: 'A nurse confirms everything before the doctor sees it, and the queue is code the AI cannot touch.',
    v27: 'And we say plainly: no clinician has reviewed our red-flag list yet.',
    v28: ['Under the hood: a FastAPI service with SQLite and a React app,', 'in one Docker container on a Hugging Face Space.'],
    v29: ["Chat, intake and the nurse's handoff draft run on Gemma 4 26B, through Hugging Face Inference Providers.", 'Whisper large-v3-turbo handles speech.'],
    v30: "We wanted Qatar's Fanar, but its only provider had no capacity.",
    v31: ['So we fine-tuned Fanar 9B ourselves.', 'Valid intakes rose from 6 to 56 of 63, but it lost emergency recognition, so it stays out of live chat.'],
    v32: ["Our aim: take the reception step off the walk-in's path,", 'and give nurses a structured intake, with people deciding everything clinical.'],
    v33: 'This is a prototype. Going live would need partnership, a clinical review and data-protection approval.' };
  const SPLIT = { v15: ['T014', 0], v24: ['and', 1], v25: ['the', 1], v28: ['in', 0], v29: ['whisper', 0], v31: ['ourselves', 0], v32: ['and', 0] };
  for (const id of Object.keys(VO)) {
    ev(VO[id], 'vo', { id });
    const c = CAP[id]; if (!c) continue;
    if (Array.isArray(c)) { const cut = WE(id, ...SPLIT[id]) + .15; SUBS.push({ id, t0: S(id) - .05, t1: cut, text: c[0] }, { id, t0: cut, t1: E(id) + .3, text: c[1] }); }
    else SUBS.push({ id, t0: S(id) - .05, t1: E(id) + .3, text: c });
  }
  // extend each caption to the next one (≥1.8 s holds, no flicker between close lines)
  for (let i = 0; i < SUBS.length - 1; i++) { const gap = SUBS[i + 1].t0 - SUBS[i].t1; if (gap < .7) SUBS[i].t1 = SUBS[i + 1].t0 - .02; }
  SUBS.forEach(s => { if (s.t1 - s.t0 < 1.8) s.t1 = s.t0 + 1.8; });

  // ═════ CH1 — the gap
  T.rowFD = W('v02', 'front') - .1; T.rowTr = W('v03', 'triov') - .05; T.rowDr = W('v03', 'doctor') - .05; T.rowPh = W('v03', 'pharmacy') - .05;
  T.apps = W('v04', 'nar'); T.apps2 = W('v04', 'labe'); T.slot = W('v05', 'digital') - .1;
  T.land0 = S('v07') - .02; T.dawri = T.land0 + .12; T.wave = W('v07', 'my');
  T.walkin = S('v01') + .2;
  [T.rowFD, T.rowTr, T.rowDr, T.rowPh].forEach(x => ev(x, 'pop'));
  ev(T.apps, 'pop', { v: .5 }); ev(T.apps2, 'pop', { v: .5 }); ev(T.slot, 'gapglow'); ev(T.walkin, 'pop', { v: .4 });
  cam(0, .01, [560, 420, 2.1], 'cut'); cam(.2, 3.5, [560, 430, 2.2], 'ss'); cam(T.rowFD - .4, 1.8, [960, 530, 1.0]);
  cam(T.apps - .4, 2.2, [960, 540, 1.03], 'ss');
  cam(E('v05') + .1, 1.6, [539, 513, 1.9]);      // push to the empty slot (world centre of the slot card)
  cam(T.dawri + .4, 1.4, [760, 560, 1.2]);
  M.hide(0, T.land0 - .55).jump(T.land0 - .55, T.land0, pt(539, -60), at('slot', .5, 0), 30, { big: true })
    .stand(T.land0, E('v07') + 3, at('slot', .5, 0), { eyes: t => t < T.land0 + .5 ? 'wide' : 'happy', arms: t => t > T.wave && t < T.wave + 1.4 ? 'wave' : t < T.land0 + .9 ? 'up' : 'down' });
  ev(T.dawri, 'title');

  // wipe 1→2
  T.w2 = E('v07') + .7; T.c2 = T.w2 + .62; ev(T.w2, 'wipe'); T.WIPES = [[T.w2, '02', 'One visit']];
  // ═════ CH2 — Fatima
  const PH = U.PH, SW = U.SW;
  const PF = [685, 512, 1.22];                                       // phone focus
  const SF = [1250, 560, 1.18];                                      // staff focus
  cam(T.c2, .01, [960, 540, 1.0], 'cut');
  T.login = E('v08') - .25; T.fat = W('v09', 'fatima') + .35; T.home = T.fat + .5; T.demo = W('v09', 'demo');
  T.start = E('v09') + .05; T.consent = T.start + .25; T.agree = S('v10') + .45; T.chat = T.agree + .25;
  cam(S('v08') + .5, 1.3, PF);
  CUR.show(S('v08') - .2, T.agree + .6).move(S('v08') - .2, S('v08'), pt(900, 700)).tap(S('v08') + .2, at('blogin', .6, .5), T.login)
    .tap(T.login + .3, at('pr0', .45, .5), T.fat).tap(T.fat + .3, at('blog2', .5, .5), T.fat + .55 - .05);
  T.home = T.fat + .55; CUR.tap(T.home + .5, at('bstart', .5, .5), T.start).tap(T.start + .3, at('bagree', .5, .5), T.agree);
  // chat
  const P1 = 'عندي حرارة وكحة من ثلاث أيام';
  T.type1 = W('v10', 'arabic') + .1; TY.p1 = typing(T.type1, P1, 13, 2, 'akey'); T.mic = W('v10', 'voice');
  T.send1 = Math.max(TY.p1[TY.p1.length - 1] + .25, W('v10', 'fever')); ev(T.send1, 'send');
  T.a2 = S('v11') + .25; T.p2 = S('v11') + 1.15; T.a3 = S('v12') + .05; TY.p3 = typing(T.a3 + .4, 'باراسيتامول', 18, 5, 'akey');
  T.send3 = TY.p3[TY.p3.length - 1] + .18; T.sum = T.send3 + .3; T.yes = Math.max(S('v13') + .85, T.sum + 1.1); T.centre = T.yes + .2;
  [T.a2, T.a3].forEach(x => ev(x, 'msg')); ev(T.p2, 'send'); ev(T.send3, 'send'); ev(T.sum, 'msg');
  cam(T.type1 - .6, 1.2, [640, 600, 1.55]);
  cam(T.yes + .1, 1.0, PF);
  // map, reservation, arrival
  T.pins = W('v13', 'map'); T.selPin = W('v13', 'estimated'); T.checkin = E('v13') + .15; T.reserved = T.checkin + .2;
  for (let i = 0; i < 4; i++) ev(T.pins + i * .14, 'pin', { n: i }); ev(T.selPin, 'click');
  T.here = W('v15', "i'm") - .05; T.ticket = T.here + .3; T.lock = W('v15', 't014') + .2; T.order = W('v15', 'order');
  ev(T.lock, 'lock'); ev(T.ticket + .15, 'scramble', { d: T.lock - T.ticket - .15 });
  CUR.show(T.centre + .2, T.here + .7).tap(T.centre + .4, at('pw', .5, .9), T.selPin).tap(T.selPin + .3, at('bcheck', .5, .5), T.checkin)
    .move(T.reserved + .3, T.reserved + 1.0, at('activ', .9, .9)).tap(S('v15') + .4, at('bhere', .5, .5), T.here);
  cam(W('v14', 'reservation') - .3, 1.1, [690, 470, 1.55]);
  cam(S('v15') + .2, 1.2, [690, 760, 1.6]);
  cam(T.ticket + .2, 1.1, [700, 420, 1.55]);
  cam(T.order - .2, 1.2, [690, 560, 1.42]);
  // staff: whip
  T.whip = E('v15') + .35; ev(T.whip, 'whoosh', { v: 1 }); ev(T.whip + .45, 'crash');
  cam(T.whip, .55, SF, 'whip');
  T.exact = W('v16', 'exact'); T.intake = W('v16', 'intake'); T.pen = W('v16', 'penicillin');
  cam(T.exact - .3, 1.0, [960, 520, 1.5]); cam(T.intake - .2, 1.1, [1260, 540, 1.45]); cam(T.pen - .2, .9, [1450, 330, 1.6]);
  const VIT = [['bp_sys', '118'], ['bp_dia', '76'], ['hr', '92'], ['temp', '38.4'], ['spo2', '97'], ['wt', '64']];
  T.vit0 = S('v17') + .1; TY.vit = []; { let tt = T.vit0; for (const [k, v] of VIT) { const ty = typing(tt, v, 22, k.length, 'key'); TY.vit.push([k, v, ty, tt]); tt = ty[ty.length - 1] + .07; } T.vitEnd = tt; }
  T.urg = T.vitEnd + .05; T.conf = Math.max(W('v17', 'confirms') + .1, T.urg + .4); T.hand = T.conf + .3; T.send = E('v17') + .15; ev(T.urg, 'click'); ev(T.hand, 'pane');
  cam(S('v17') - .3, 1.0, [1560, 560, 1.45]);
  CUR.show(S('v17'), E('v18') + .3).tap(S('v17'), at('v-bp_sys', .5, .5), T.vit0).move(T.vit0 + .3, T.vitEnd - .1, at('v-wt', .5, .5)).tap(T.vitEnd - .1, at('urg', .17, .5), T.urg)
    .tap(T.urg + .2, at('bconf', .5, .5), T.conf).tap(T.hand + .3, at('bsend', .5, .5), T.send);
  T.doctor = S('v18') - .1; T.amox = W('v18', 'prescribes') + .25; T.warn = W('v18', 'warns'); ev(T.doctor, 'pane'); ev(T.warn, 'alert');
  CUR.tap(T.doctor + .2, at('d-amoxicillin', .5, .5), T.amox);
  cam(T.doctor - .1, .9, [1380, 520, 1.3]); cam(T.warn - .2, .9, [1470, 330, 1.75]);
  T.pharm = S('v19') - .1; T.disp = W('v19', 'visit') - .3; T.done = W('v19', 'done') + .1; T.complete = T.done + .3; ev(T.pharm, 'pane');
  CUR.show(T.pharm, T.disp + .5).move(T.pharm, T.disp - .1, at('bdisp', .5, .5)).click(T.disp);
  cam(T.pharm - .2, .8, [1150, 520, 1.25]);
  T.whip2 = T.done - .05; ev(T.whip2, 'whoosh', { v: .8 }); cam(T.whip2, .5, [560, 470, 1.45], 'whip'); ev(T.complete + .1, 'chime');
  // mascot, chapter 2
  M.hide(E('v07') + 3, T.c2 + .2)
    .jump(T.c2 + .4, T.c2 + .95, pt(390, 130), at('wm', .5, 0), 60)
    .stand(T.c2 + .95, T.login + .05, at('wm', .5, 0), { eyes: 'r' })
    .stand(T.login + .05, T.send1, at('phone', .72, 0, 0, 0), { eyes: t => t > T.type1 ? 'd' : 'n' })
    .stand(T.send1, T.a2 + .2, at('m1', .86, 0), { px: 5, eyes: 'happy', still: true })
    .jump(T.a2 + .2, T.a2 + .6, at('m1', .86, 0), at('m2', .14, 0), 50, { px: 5 })
    .stand(T.a2 + .6, T.a3 + .1, at('m2', .14, 0), { px: 5, eyes: 'u' })
    .jump(T.a3 + .1, T.a3 + .5, at('m2', .14, 0), at('m4', .14, 0), 50, { px: 5 })
    .stand(T.a3 + .5, T.sum + .1, at('m4', .14, 0), { px: 5, eyes: 'u' })
    .jump(T.sum + .1, T.sum + .5, at('m4', .14, 0), at('sum', .7, 0), 50)
    .stand(T.sum + .5, T.centre, at('sum', .7, 0), { eyes: 'l' })
    .stand(T.centre, T.reserved, at('map', .82, 0), { eyes: 'd' })
    .stand(T.reserved, T.here - .45, at('valid', .78, 0), { ghost: () => true, eyes: 'n', still: true })
    .jump(T.here - .45, T.here, at('valid', .78, 0), at('bhere', .7, 0), 70, { big: true })
    .stand(T.here, T.ticket + .1, at('bhere', .7, 0), { eyes: 'shut' })
    .jump(T.ticket + .1, T.lock, at('bhere', .7, 0), at('tnum', .72, 0, 0, -6), 160)
    .stand(T.lock, T.whip - .05, at('tnum', .72, 0, 0, -6), { eyes: t => t < T.lock + 1.2 ? 'happy' : 'r', arms: t => t < T.lock + .9 ? 'up' : 'down' })
    .jump(T.whip - .05, T.whip + .75, at('tnum', .72, 0, 0, -6), at('ban', .2, 0), 160)
    .stand(T.whip + .75, T.intake - .1, at('ban', .2, 0), { eyes: 'r' })
    .walk(T.intake - .1, T.intake + 1.2, at('intake', .15, 0), at('intake', .8, 0), { eyes: 'd' })
    .jump(T.intake + 1.2, T.pen + .05, at('intake', .8, 0), at('allergy', .5, 0), 80)
    .stand(T.pen + .05, S('v17') - .2, at('allergy', .5, 0), { eyes: 'wide' })
    .jump(S('v17') - .2, S('v17') + .3, at('allergy', .5, 0), at('vitals', .75, 0), 60)
    .stand(S('v17') + .3, T.hand, at('vitals', .75, 0), { eyes: 'd' })
    .stand(T.hand, T.doctor, at('handoff', .75, 0), { eyes: t => t > T.send ? 'happy' : 'd' })
    .stand(T.doctor, T.warn, at('rxpan', .8, 0), { eyes: 'd' })
    .jump(T.warn, T.warn + .4, at('rxpan', .8, 0), at('rxbad', .6, 0), 50)
    .stand(T.warn + .4, T.pharm, at('rxbad', .6, 0), { eyes: 'wide' })
    .stand(T.pharm, T.done, at('handover', .8, 0), { eyes: 'd' })
    .jump(T.done, T.complete + .25, at('handover', .8, 0), at('cdone', .75, 0), 140)
    .stand(T.complete + .25, E('v19') + .7, at('cdone', .75, 0), { eyes: 'happy', arms: 'up' });
  T.ch2 = [T.c2, '02', 'One visit'];

  // ═════ CH3 — two other paths (cell division, continuous)
  T.split = E('v19') + .55; T.c3 = T.split; ev(T.split, 'burst'); ev(T.split, 'chap');
  const PA = [570, 512, 1.0];
  cam(T.split - .35, .9, [960, 540, 1.0]);
  T.ahmed = S('v20') + .1; T.refill = W('v20', 'offered'); T.noTk = W('v20', 'ticket'); ev(T.refill, 'chime', { v: .5 });
  const P20 = 'أبي حبوب الضغط اللي آخذها دايم';
  TY.a = typing(T.ahmed, P20, 18, 9, 'akey'); T.sendA = TY.a[TY.a.length - 1] + .15; ev(T.sendA, 'send');
  const P21 = 'I have chest pain spreading to my left arm';
  T.ravi = S('v21') + .15; TY.r = typing(T.ravi, P21, 19, 4, 'key'); T.sendR = TY.r[TY.r.length - 1] + .12; ev(T.sendR, 'send');
  T.red = W('v22', 'catches'); T.n999 = W('v22', 'call'); T.near = W('v22', 'nearest'); T.noTk2 = W('v22', 'ticket');
  ev(T.red, 'redalert'); ev(T.noTk2, 'bump');
  cam(T.split + .2, 1.2, [960, 520, 1.08]);
  cam(S('v21') - .4, 1.1, [1300, 520, 1.25]);
  M.stand(T.split, T.noTk + .1, at('phoneA', .18, 0), { eyes: t => t > T.refill ? 'happy' : 'l', still: false })
    .stand(T.noTk + .1, T.noTk + 1.2, at('phoneA', .18, 0), { ghost: () => true, op: t => 1 - seg(t, T.noTk + .5, T.noTk + 1.1), eyes: 'happy' })
    .hide(T.noTk + 1.2, 9999);
  M2.hide(0, T.split + .12).stand(T.split + .12, T.red, at('phoneB', .16, 0), { eyes: t => t > T.sendR ? 'wide' : 'r' })
    .jump(T.red, T.red + .45, at('phoneB', .16, 0), at('phoneB', .16, 0), 60)
    .stand(T.red + .45, T.noTk2 - .55, at('phoneB', .16, 0), { eyes: 'wide', arms: 'up' })
    .jump(T.noTk2 - .55, T.noTk2 + .1, at('phoneB', .16, 0), at('phoneB', .86, 0), 70)
    .jump(T.noTk2 + .1, T.noTk2 + .9, at('phoneB', .86, 0), at('phoneB', 1.35, 1.2), 80, { spin: true })
    .hide(T.noTk2 + .9, 9999);
  CUR.show(T.sendR - .5, T.sendR + .4).move(T.sendR - .5, T.sendR - .1, at('sndB', .5, .5)).click(T.sendR);

  // wipe 3→4
  T.w4 = E('v22') + .35; T.c4 = T.w4 + .62; ev(T.w4, 'wipe'); T.WIPES.push([T.w4, '04', 'How it stays safe']);
  // ═════ CH4 — safety
  cam(T.c4, .01, [960, 520, 1.0], 'cut'); cam(T.c4 + .1, 3, [960, 530, 1.03], 'ss');
  T.r0 = S('v24') + .1; T.r1 = S('v25') + .05; T.r2 = W('v25', 'never'); T.r3 = S('v26') + .05; T.r4 = W('v26', 'cue'); T.r5 = S('v27') + .05;
  T.title4 = S('v23');
  T.ROWS = [T.r0, T.r1, T.r2, T.r3, T.r4, T.r5]; T.ROWS.forEach((x, i) => ev(x, i === 5 ? 'amber' : 'tick', { n: i }));
  T.hitStop = W('v24', 'hit');
  cam(T.r0 - .2, 1.2, [960, 470, 1.12]); cam(T.r3 - .2, 1.6, [960, 620, 1.12]); cam(T.r5 - .2, 1.2, [700, 820, 1.45]);
  M.hide(9999, 10000);
  const MS = new Actor(6); T.MS = MS;
  MS.hide(0, T.c4 + .5).jump(T.c4 + .5, T.c4 + 1.0, pt(960, 60), at('dh4', .97, 0), 40)
    .stand(T.c4 + 1.0, T.r0 - .4, at('dh4', .97, 0), { eyes: 'd' });
  let prevA = at('dh4', .97, 0);
  T.ROWS.forEach((tr, i) => { const a = at('sr' + i, .9, 0); MS.jump(tr - .4, tr, prevA, a, 50).stand(tr, (T.ROWS[i + 1] || T.r5 + 30) - .4, a, { eyes: i === 5 ? 'worry' : i === 0 ? 'r' : 'n' }); prevA = a; });

  // wipe 4→5
  T.w5 = E('v27') + .4; T.c5 = T.w5 + .62; ev(T.w5, 'wipe'); T.WIPES.push([T.w5, '05', 'Under the hood']);
  // ═════ CH5 — stack
  cam(T.c5, .01, [960, 530, 1.0], 'cut');
  T.n = { start: S('v28') + .15, fast: W('v28', 'fast'), sql: W('v28', 'sqlite'), react: W('v28', 'react'), docker: W('v28', 'docker'), hf: W('v28', 'hugging'),
    gemma: W('v29', 'gemma'), whisper: W('v29', 'whisper'), fanar: W('v30', 'finar'), cap: W('v30', 'capacity'),
    tuned: W('v31', 'tuned'), valid: W('v31', 'valid'), lost: W('v31', 'lost'), out: W('v31', 'out') };
  T.n.test = T.n.fanar - .2;
  Object.values(T.n).forEach(x => ev(x, 'pop', { v: .55 }));
  cam(T.c5 + .3, 2.5, [860, 520, 1.08], 'ss'); cam(T.n.gemma - .4, 1.2, [1500, 470, 1.22]); cam(T.n.test - .3, 1.1, [1500, 760, 1.22]); cam(T.n.tuned - .2, 1.0, [1520, 770, 1.32]);
  const MK = new Actor(6); T.MK = MK;
  MK.hide(0, T.c5 + .5).jump(T.c5 + .5, T.c5 + 1.0, pt(400, 60), at('nd0', .5, 0), 40)
    .stand(T.c5 + 1.0, T.n.start + 1.7, at('nd0', .5, 0), { eyes: 'r' })
    .walk(T.n.start + 1.7, T.n.docker + .4, at('nd0', .5, 0), at('nd2', .5, 0), { eyes: 'r' })
    .stand(T.n.docker + .4, T.n.gemma - .4, at('nd2', .5, 0), { eyes: 'r' })
    .jump(T.n.gemma - .4, T.n.gemma + .15, at('nd2', .5, 0), at('mc0', .8, 0), 90)
    .stand(T.n.gemma + .15, T.n.test - .4, at('mc0', .8, 0), { eyes: 'happy' })
    .jump(T.n.test - .4, T.n.test, at('mc0', .8, 0), at('tpan', .85, 0), 50)
    .stand(T.n.test, E('v31') + 2, at('tpan', .85, 0), { eyes: t => t > T.n.lost ? 'worry' : 'd' });

  // wipe 5→6
  T.w6 = E('v31') + .4; T.c6 = T.w6 + .62; ev(T.w6, 'wipe'); T.WIPES.push([T.w6, '06', 'The aim']);
  // ═════ CH6 — aim + end
  cam(T.c6, .01, [960, 530, 1.0], 'cut');
  T.fall = W('v32', 'reception') - .05; T.aim1 = W('v32', 'reception') + .2; T.aim2 = W('v32', 'structured'); T.aim3 = W('v32', 'people');
  ev(T.fall, 'fall'); [T.aim1, T.aim2, T.aim3].forEach(x => ev(x, 'pop', { v: .6 }));
  T.push = E('v33') + .25; T.endc = S('v34') - .15;
  cam(T.push, 1.1, [539, 513, 9], 'ei');
  cam(T.endc, .01, [960, 540, 1.0], 'cut');
  const ME = new Actor(10); T.ME = ME;
  ME.hide(0, T.c6 + .5).jump(T.c6 + .5, T.c6 + 1.0, pt(539, 60), at('slot', .5, 0), 40, { px: 6 })
    .stand(T.c6 + 1.0, T.push, at('slot', .5, 0), { px: 6, eyes: t => t > T.aim3 ? 'happy' : 'r' })
    .hide(T.push, T.endc + .3);
  const w0 = W('v35', 'arrive'), w1 = W('v35', 'dont'), w2 = W('v35', 'register'); T.hop = [w0, w1, w2];
  ME.jump(T.endc + .3, T.endc + .85, pt(980, 1180), at('wm2', .9, 0), 140, { big: true })
    .stand(T.endc + .85, w0 - .3, at('wm2', .9, 0), { eyes: 'd' })
    .jump(w0 - .3, w0, at('wm2', .9, 0), at('tg0', .5, 0), 30).stand(w0, w1 - .3, at('tg0', .5, 0), { eyes: 'r' })
    .jump(w1 - .28, w1, at('tg0', .5, 0), at('tg1', .5, 0), 40).stand(w1, w2 - .3, at('tg1', .5, 0), { eyes: 'r' })
    .jump(w2 - .28, w2, at('tg1', .5, 0), at('tg2', .55, 0), 40).stand(w2, w2 + 1.3, at('tg2', .55, 0), { eyes: 'happy', arms: 'up' })
    .stand(w2 + 1.3, DUR + 1, at('tg2', .55, 0), { eyes: t => t > w2 + 2.4 ? 'shut' : 'happy' });
  T.hop.forEach((x, i) => ev(x, 'note', { n: i }));
  ev(DUR - 2.0, 'final');
  T.CHAPS = [[0, '01', 'The gap'], [T.c2, '02', 'One visit'], [T.c3, '03', 'Two other paths'], [T.c4, '04', 'How it stays safe'], [T.c5, '05', 'Under the hood'], [T.c6, '06', 'The aim'], [T.endc, null]];
  T.WIPES.forEach(w => ev(w[0] + .5, 'chapnote'));
  MOVES.sort((a, b) => a.t0 - b.t0);
  EV.sort((a, b) => a.t - b.t);
}
export const WE = (id, word, n = 0) => { let k = 0; for (const [w, , b] of WORDS[id]) if (nrm(w) === nrm(word) && k++ === n) return VO[id] + b; throw new Error(`word ${word} not in ${id}`); };

// ───── per-frame state
const pop = (t, t0, d = .35) => { const k = seg(t, t0, t0 + d); return { op: eo(k), ty: (1 - back(k, 2.2)) * 18 }; };
const P = (k, fx) => k;
function docClamp(c, t) {
  const doc = t < T.c2 || (t >= T.c4 && t < T.endc); if (!doc) return c; let [x, y, z] = c;
  const hw = 960 / z, hh = 540 / z, X0 = U.DW.x - 30, X1 = U.DW.x + U.DW.w + 30, Y0 = U.DW.y - 20, Y1 = U.DW.y + U.DW.h + 20;
  x = X1 - X0 > 2 * hw ? clamp(x, X0 + hw, X1 - hw) : (X0 + X1) / 2; y = Y1 - Y0 > 2 * hh ? clamp(y, Y0 + hh, Y1 - hh) : (Y0 + Y1) / 2; return [x, y, z];
}
export const camFinal = t => docClamp(camAt(t), t);
export function frame(t) {
  const F = { cam: docClamp(camAt(t), t), html: '', actors: [], cursor: CUR, hud: {}, fx: '' };
  const H = F.hud;
  // chapter pill
  const ch = [...T.CHAPS].reverse().find(c => t >= c[0]); if (ch && ch[1]) H.chap = { no: ch[1], nm: ch[2], op: 1 };
  for (const w of T.WIPES) if (t >= w[0] && t < w[0] + 1.25) H.wipe = { p: (t - w[0]) / 1.25, no: w[1], nm: w[2] };
  // captions
  const sub = SUBS.find(s => t >= s.t0 && t < s.t1);
  if (sub) H.cap = { text: sub.text, op: Math.min(seg(t, sub.t0, sub.t0 + .15), 1 - seg(t, sub.t1 - .12, sub.t1)), x: capX(t) };
  if (t < T.c2) ch1(t, F); else if (t < T.c3) ch2(t, F); else if (t < T.c4) ch3(t, F); else if (t < T.c5) ch4(t, F); else if (t < T.c6) ch5(t, F); else ch6(t, F);
  return F;
}
function capX(t) {
  if (t > T.c2 + .6 && t < T.whip + .2) return 1390;            // phone focused: caption over the right side
  if (t > T.whip2 + .2 && t < T.c3) return 1390;
  if (t > S('v21') - .2 && t < T.w4) return 560;                 // Ravi's phone focused: caption left
  if (t > T.n.test - .3 && t < T.w6) return 560;                // Fanar panel on the right: caption left
  return 960;
}

// CH1 ───────────────────────────────
const RX = { walk: 72, slot: 274, fd: 536, tr: 798, dr: 1060, ph: 1322 }, RY = 290;
function rail(t, o) {
  const card = (x, y, cls, nm, sb, k, op = 1, ty = 0, extra = '') => `<div class="stp ${cls}"${k ? ` data-a="${k}"` : ''} style="left:${x}px;top:${y}px;opacity:${op};transform:translateY(${ty}px)${extra}">${nm}${sb}</div>`;
  let h = '';
  const arrow = (x0, x1, op) => `<div class="arrow" style="left:${x0}px;top:${RY + 94}px;width:${x1 - x0}px;opacity:${op}"></div>`;
  const w = o.walk; h += card(RX.walk, RY, '', '<div class="nm">Walk-in</div>', '<div class="sb">No appointment</div>', '', w.op, w.ty, ';width:170px');
  const sl = o.slot;
  if (sl.dawri) h += card(RX.slot, RY, 'dawri', '<div class="nm" style="font-size:34px">Dawri</div><div class="nm ar" style="font-size:30px;text-align:left;direction:rtl;align-self:flex-start">دوري</div>', '<div class="sb">AI front desk</div>', 'slot', 1, 0, `;transform:scale(${sl.sc || 1})`);
  else h += card(RX.slot, RY, 'gap', '', '', 'slot', sl.op, 0);
  h += arrow(RX.walk + 176, RX.slot - 8, sl.op);
  const fd = o.fd; h += card(RX.fd, RY + (fd.dy || 0), '', '<div class="nm">Front desk</div>', '<div class="sb">Staff record why you came</div>', 'fd', fd.op, fd.ty, `;transform:translateY(${(fd.dy || 0) + fd.ty}px) rotate(${fd.rot || 0}deg)`);
  h += arrow(RX.slot + 236, RX.fd - 8, Math.min(sl.op, fd.op));
  const xs = o.xs || [RX.tr, RX.dr, RX.ph];
  [['Triage', 'Nurse', o.tr], ['Doctor', 'Doctor', o.dr], ['Pharmacy', 'Pharmacy', o.ph]].forEach(([n, s, a], i) => {
    h += card(xs[i], RY, '', `<div class="nm">${n}</div>`, '', 'r' + i, a.op, a.ty);
    h += arrow((i ? xs[i - 1] : (o.xs ? RX.slot : RX.fd)) + 236, xs[i] - 8, a.op);
  });
  return h;
}
function ch1(t, F) {
  const H = F.hud;
  const body = `<div class="dh" style="${U.ani(eo(seg(t, .25, .9)), (1 - eo(seg(t, .25, .9))) * 14)}">The walk-in path</div>` + rail(t, {
    walk: pop(t, T.walkin), slot: { op: eo(seg(t, T.slot, T.slot + .5)), dawri: t >= T.dawri, sc: t >= T.dawri ? 1 + .06 * Math.sin(Math.PI * seg(t, T.dawri, T.dawri + .3)) : 1 },
    fd: pop(t, T.rowFD), tr: pop(t, T.rowTr), dr: pop(t, T.rowDr), ph: pop(t, T.rowPh) })
    + [['Nar\'aakom', T.apps, RX.tr], ['Lbaih', T.apps2, RX.tr + 380]].map(([n, t0, x]) => { const a = pop(t, t0); return `<div class="appc" style="left:${x}px;top:610px;opacity:${a.op};transform:translateY(${a.ty}px)"><b>${n}</b><span>Appointments, records</span></div>`; }).join('')
    + `<div style="position:absolute;left:${RX.tr}px;top:572px;font-size:17px;color:var(--muted);opacity:${eo(seg(t, T.apps, T.apps + .4))}">Qatar's health apps</div>`;
  F.html = U.doc(U.DW, 'github.com · Dawri · README', body);
  // spotlight on the gap, then the silence
  if (t > E('v05') + .1 && t < T.dawri + .6) H.spot = { key: 'slot', op: Math.min(seg(t, E('v05') + .1, E('v05') + .9), 1 - seg(t, T.dawri + .1, T.dawri + .6)) };
  if (t > T.dawri && t < T.dawri + .25) H.flash = .35 * (1 - seg(t, T.dawri, T.dawri + .25));
  F.actors = [M];
}
// CH2 ───────────────────────────────
function chatMsgs(t) {
  const P1 = 'عندي حرارة وكحة من ثلاث أيام';
  const L = [{ who: 'as', text: 'شو اللي يتعبك اليوم؟', ar: 1 }];
  const fly = (t0) => { const k = seg(t, t0, t0 + .4); return { op: eo(k * 2), ty: (1 - eo(k)) * 90 }; };
  const appear = (t0) => { const k = seg(t, t0, t0 + .3); return { op: eo(k), ty: (1 - back(k, 2)) * 14 }; };
  if (t >= T.send1) L.push({ who: 'me', text: P1, ar: 1, ...fly(T.send1) });
  if (t >= T.a2) L.push({ who: 'as', text: 'كم شدته من 0 إلى 10؟', ar: 1, ...appear(T.a2) });
  if (t >= T.p2) L.push({ who: 'me', text: '6', ar: 1, ...fly(T.p2) });
  if (t >= T.a3) L.push({ who: 'as', text: 'أخذتي أي دواء لها؟', ar: 1, ...appear(T.a3) });
  if (t >= T.send3) L.push({ who: 'me', text: 'باراسيتامول', ar: 1, ...fly(T.send3) });
  return L;
}
function phoneState(t) {
  if (t < T.login) return { scr: 'welcome', k1: 'wm', press: t > T.login - .1 ? 'login' : '' };
  if (t < T.home) return { scr: 'login', sel: t >= T.fat ? 0 : -1, press: t > T.home - .1 };
  if (t < T.consent) return { scr: 'home', press: t > T.start - .02 };
  if (t < T.chat) return { scr: 'consent', press: t > T.agree - .02 };
  if (t < T.centre) {
    const s = { scr: 'chat', t, msgs: chatMsgs(t), mic: t > T.mic && t < T.mic + .8 ? 6 * Math.sin(Math.PI * seg(t, T.mic, T.mic + .8)) : 0 };
    if (t >= T.type1 && t < T.send1) { s.input = typed(TY.p1, 'عندي حرارة وكحة من ثلاث أيام', t); s.ar = 1; s.caret = 1; }
    if (t >= TY.p3[0] - .05 && t < T.send3) { s.input = typed(TY.p3, 'باراسيتامول', t); s.ar = 1; s.caret = 1; }
    if ((t > T.send1 + .3 && t < T.a2) || (t > T.p2 + .2 && t < T.a3)) s.dots = 1;
    if (t >= T.sum) s.sum = { op: eo(seg(t, T.sum, T.sum + .3)), ty: (1 - eo(seg(t, T.sum, T.sum + .3))) * 16, press: t > T.yes - .02 };
    return s;
  }
  if (t < T.reserved) return { scr: 'centre', pins: [0, 1, 2, 3].map(i => eo(seg(t, T.pins + i * .14, T.pins + i * .14 + .3))), selPin: t >= T.selPin, cardOp: eo(seg(t, T.selPin, T.selPin + .3)), press: t > T.checkin - .02 };
  if (t < T.ticket) { const s = Math.max(0, 2698 - Math.floor((t - T.reserved) * 1)); return { scr: 'reserved', left: `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`, press: t > T.here - .02 }; }
  if (t < T.complete) {
    let num = 'T-014'; if (t < T.lock) { const f = Math.floor(t * 24); num = 'T-' + [0, 1, 2].map(i => Math.floor(hash(f * 3.1 + i * 17.7) * 10)).join(''); }
    const stage = t > T.doctor ? 1 : 0;
    return { scr: 'ticket', num, gonow: t > T.whip + .9 && t < T.doctor ? eo(seg(t, T.whip + .9, T.whip + 1.2)) : 0, stage: t > T.pharm ? 2 : stage, ahead: t > T.whip + .9 ? 0 : 3, wait: t > T.whip + .9 ? 'Now' : '15 min' };
  }
  return { scr: 'complete' };
}
function staffState(t) {
  if (t < T.whip + .3) return { scr: 'nurseQ', hl: t > T.lock };
  if (t < T.doctor) {
    const s = { scr: 'nurse', vit: {}, irHot: t > T.pen - .1 && t < S('v17') ? 4 : -1 };
    for (const [k, v, ty, t0] of TY.vit) { if (t >= t0 - .1) s.vit[k] = typed(ty, v, t); if (t >= t0 - .1 && t < ty[ty.length - 1] + .12) { s.vf = k; s.caret = 1; } }
    s.urg = t >= T.urg; s.press = t > T.conf - .02 && t < T.hand;
    if (t >= T.hand) { s.handoff = eo(seg(t, T.hand, T.hand + .35)); s.press2 = t > T.send - .02; s.sent = t > T.send + .08; }
    return s;
  }
  if (t < T.pharm) return { scr: 'doctor', rx: t >= T.warn - .15 ? eo(seg(t, T.warn - .15, T.warn + .2)) : 0, hot: t > T.amox - .3 && t < T.warn ? 'amoxicillin' : '' };
  return { scr: 'pharmacy', press: t > T.disp - .02 && t < T.disp + .2, done: t > T.disp + .2 };
}
function ch2(t, F) {
  const H = F.hud, z = F.cam[2];
  const focusStaff = t > T.whip + .25 && t < T.whip2 + .2;
  const ps = phoneState(t), ss_ = staffState(t);
  ps.blur = focusStaff ? 5 : 0; ss_.blur = !focusStaff && t > T.c2 + 1.6 ? 4 : 0;
  F.html = U.phone(U.PH, ps) + U.staff(U.SW, ss_);
  // HUD: keys
  if (t >= T.type1 - .1 && t < T.send1 + .3) H.keys = keysHud(t, TY.p1, 'عندي حرارة وكحة من ثلاث أيام', 'Arabic keyboard');
  if (t >= TY.p3[0] - .2 && t < T.send3 + .3) H.keys = keysHud(t, TY.p3, 'باراسيتامول', 'Arabic keyboard');
  if (t >= T.vit0 - .1 && t < T.vitEnd + .3) { const all = TY.vit.flatMap(([k, v, ty]) => ty.map((x, i) => [x, v[i]])); let last = all.filter(a => a[0] <= t).pop(); H.keys = { keys: [last ? last[1] : '1'], dn: last && t - last[0] < .07, label: 'Vitals', op: Math.min(seg(t, T.vit0 - .1, T.vit0 + .1), 1 - seg(t, T.vitEnd + .1, T.vitEnd + .3)) }; }
  // spotlights
  if (t > T.demo - .1 && t < T.demo + 1.6) H.spot = { key: 'phone', fy: .97, op: env2(t, T.demo - .1, T.demo + 1.6), r: 260 };
  if (t > W('v14', 'reservation') && t < E('v14') + .2) H.spot = { key: 'activ', op: env2(t, W('v14', 'reservation'), E('v14') + .2) };
  if (t > T.order && t < E('v15') + .1) H.spot = { key: 'ahead', op: env2(t, T.order, E('v15') + .1) };
  if (t > T.warn && t < E('v18')) H.spot = { key: 'rxbad', op: env2(t, T.warn, E('v18')) };
  if (t > T.lock && t < T.lock + .2) H.flash = .25 * (1 - seg(t, T.lock, T.lock + .2));
  F.actors = [M];
  // effects: bang, sparks
  F.fxf = (A, c) => {
    let h = ''; if (!c) return h; const top = c.y - c.px * 11;
    if (t > T.a2 + .6 && t < T.sum + .1) h += SP.QMARK(c.x + 40, top - 40, 5);
    if (t > T.pen && t < T.pen + .9) h += SP.BANG(c.x + 34, top - 52, 5, 1 - seg(t, T.pen + .6, T.pen + .9));
    if (t > T.warn + .3 && t < T.pharm) h += SP.BANG(c.x + 34, top - 52, 5);
    if (t > T.lock && t < T.lock + .7) { const k = seg(t, T.lock, T.lock + .7); h += SP.SPARK(c.x - 70 - k * 30, top - k * 30, 6, '#FFC21A', 1 - k) + SP.SPARK(c.x + 70 + k * 30, top - 10 - k * 30, 5, '#1d5fbf', 1 - k); }
    if (t > T.complete + .25 && t < T.complete + 1.2) { const k = seg(t, T.complete + .25, T.complete + 1.2); for (let i = 0; i < 6; i++) { const a = i / 6 * Math.PI * 2 + .3; h += SP.SPARK(c.x + Math.cos(a) * (40 + k * 70), c.y - 30 + Math.sin(a) * (30 + k * 50), 5, i % 2 ? '#FFC21A' : '#1d5fbf', 1 - k); } }
    if (t > T.send + .1 && t < T.send + .8) h += SP.CHECK(c.x + 40, top - 30, 5, 1 - seg(t, T.send + .5, T.send + .8));
    return h;
  };
}
const env2 = (t, a, b) => Math.min(seg(t, a, a + .35), 1 - seg(t, b - .35, b));
function keysHud(t, TT, text, label) {
  const ch = [...text]; let n = 0; while (n < TT.length && TT[n] <= t) n++;
  const k = ch[Math.max(0, n - 1)] === ' ' ? 'space' : ch[Math.max(0, n - 1)];
  return { keys: [k], dn: n > 0 && t - TT[n - 1] < .07, label, op: Math.min(seg(t, TT[0] - .25, TT[0]), 1 - seg(t, TT[TT.length - 1] + .2, TT[TT.length - 1] + .45)), ar: 1 };
}
// CH3 ───────────────────────────────
function ch3(t, F) {
  const H = F.hud;
  const k = eo(seg(t, T.split, T.split + .6));
  const xA = lerp(U.PH.x, 400, k), xB = lerp(U.PH.x, 1080, k);
  const ahmed = t < T.refill ? { scr: 'chat', t, en: 0, msgs: [{ who: 'as', text: 'شو اللي يتعبك اليوم؟', ar: 1 }].concat(t >= T.sendA ? [{ who: 'me', text: 'أبي حبوب الضغط اللي آخذها دايم', ar: 1, op: eo(seg(t, T.sendA, T.sendA + .3)), ty: (1 - eo(seg(t, T.sendA, T.sendA + .4))) * 80 }] : []),
    input: t >= T.ahmed && t < T.sendA ? typed(TY.a, 'أبي حبوب الضغط اللي آخذها دايم', t) : '', ar: 1, caret: t < T.sendA, dots: t > T.sendA + .3 } : { scr: 'refill' };
  ahmed.key = 'phoneA';
  const ravi = t < T.red ? { scr: 'chat', t, en: 1, msgs: [{ who: 'as', text: "What's bothering you today?" }].concat(t >= T.sendR ? [{ who: 'me', text: 'I have chest pain spreading to my left arm', op: eo(seg(t, T.sendR, T.sendR + .3)), ty: (1 - eo(seg(t, T.sendR, T.sendR + .4))) * 80 }] : []),
    input: t >= T.ravi && t < T.sendR ? typed(TY.r, 'I have chest pain spreading to my left arm', t) : '', caret: t >= T.ravi && t < T.sendR } : { scr: 'emergency' };
  ravi.key = 'phoneB';
  // before the split: one phone (Fatima, complete) on its own; the staff window slides away
  const sOff = eo(seg(t, T.split - .3, T.split + .4));
  let h = '';
  if (t < T.split + .05) h += U.phone(U.PH, { scr: 'complete' }) + U.staff(U.SW, { scr: 'pharmacy', done: 1, tf: `translateX(${sOff * 1300}px)` });
  else {
    h += U.phone({ ...U.PH, x: xA }, ahmed) + U.phone({ ...U.PH, x: xB }, ravi);
    if (t < T.split + .6) { const bl = 1 - k; h = h.replace('class="phone" data-a="phoneA"', `class="phone" data-a="phoneA"`); }
  }
  // the right phone's send button anchor
  h = h.replace(/(data-a="phoneB"[\s\S]*?)data-a="snd"/, '$1data-a="sndB"');
  F.html = h;
  // labels under the phones
  if (t > T.split + .4) { const o = eo(seg(t, T.split + .4, T.split + .8));
    F.html += `<div style="position:absolute;left:${xA}px;top:44px;width:440px;text-align:center;color:#fff;font-size:22px;font-weight:600;opacity:${o}">Ahmed Al-Demo</div>`
      + `<div style="position:absolute;left:${xB}px;top:44px;width:440px;text-align:center;color:#fff;font-size:22px;font-weight:600;opacity:${o}">Ravi Demo</div>`; }
  if (t > T.red && t < T.red + .5) H.flash = .3 * (1 - seg(t, T.red, T.red + .5)), H.flashCol = '#c4242a';
  if (t > T.n999 - .1 && t < T.near + .1) H.spot = { key: 'e999', op: env2(t, T.n999 - .1, T.near + .1) };
  if (t > T.near && t < E('v22') + .3) H.spot = { key: 'enear', op: env2(t, T.near, E('v22') + .3) };
  if (t >= T.ravi - .1 && t < T.sendR + .3) H.keys = keysHud(t, TY.r, 'I have chest pain spreading to my left arm', 'Ravi types');
  F.actors = [M, M2];
  F.burst = t > T.split && t < T.split + .5 ? seg(t, T.split, T.split + .5) : 0;
  F.burst2 = t > T.noTk2 + .75 && t < T.noTk2 + 1.25 ? seg(t, T.noTk2 + .75, T.noTk2 + 1.25) : 0;
  F.fxf = (A, c, i) => { let h = ''; if (!c) return h; const top = c.y - c.px * 11;
    if (i === 1 && t > T.red && t < T.noTk2 + .6) h += SP.BANG(c.x + 34, top - 52, 5);
    return h; };
}
// CH4 ───────────────────────────────
const ROWS4 = [['Rules first', 'Emergency wording, in Arabic and English. A hit stops the chat.'], ['Reply check', 'A reply reaches the patient only as one short, plain question.'],
  ['No diagnosis, no prescribing', 'The AI never diagnoses and never prescribes.'], ['Nurse confirms', 'Nothing reaches the doctor until the nurse confirms.'],
  ['Queue engine: no AI', 'Arrival order and the centre\'s priority rule, in plain code.'], ['Red-flag list: not clinically reviewed yet', 'No clinician has reviewed it. We say so plainly.']];
function ch4(t, F) {
  const H = F.hud; const act = T.ROWS.filter(x => t >= x).length - 1;
  let b = `<div class="dh" data-a="dh4" style="display:inline-block;${U.ani(eo(seg(t, T.c4 + .2, T.c4 + .7)), 0)}">How it stays safe</div>`;
  ROWS4.forEach(([n, d], i) => { const a = pop(t, T.ROWS[i] - .05);
    const cls = i === 5 ? 'amb' : i === act ? 'on' : '';
    b += `<div class="srow ${cls}" data-a="sr${i}" style="top:${150 + i * 104}px;height:90px;opacity:${t < T.ROWS[i] - .05 ? .28 : a.op}"><b>${n}</b><span>${d}</span></div>`; });
  // live example for the active row
  const ex = [
    () => `<div class="exc">I have <span class="hit">chest pain</span> <span class="hit">spreading to my left arm</span></div><div class="exc ar" style="text-align:right"><span class="hit">ألم في الصدر</span> ينتشر لذراعي</div>
      <div class="exc" style="background:#ffedea;color:var(--pneg);font-weight:600;opacity:${eo(seg(t, T.hitStop, T.hitStop + .3))}">Go to Emergency now · chat closed · no ticket</div>`,
    () => `<div class="exc ar" style="text-align:right">كم شدته من 0 إلى 10؟</div><div class="ok">One short, plain question: sent to the patient</div>
      <div class="exc"><span class="strike">Here are a few things that could explain your symptoms, and some steps…</span></div><div class="no">Not one short question: not sent</div>`,
    () => `<div class="exc"><span class="strike">This sounds like the flu.</span></div><div class="no">A diagnosis: never</div><div class="exc"><span class="strike">You should take amoxicillin.</span></div><div class="no">A prescription: never</div>`,
    () => `<div class="exc" style="display:flex;flex-direction:column;gap:12px"><span style="font-size:17px;color:var(--muted)">Nothing reaches the doctor until you confirm.</span><span class="btn" style="font-size:20px">Confirm &amp; send</span></div>`,
    () => `<div class="exc" style="padding:12px 18px"><table class="q" style="font-size:20px"><tr><th>Place</th><th>Number</th><th>Arrived</th></tr><tr><td>1</td><td><b>T-012</b></td><td>10:21</td></tr><tr><td>2</td><td><b>T-013</b></td><td>10:30</td></tr><tr class="hl"><td>3</td><td><b>T-014</b></td><td>10:41</td></tr></table></div><div class="ok" style="color:var(--pneu)">queue_engine.py · no model calls</div>`,
    () => `<div class="exc" style="background:var(--pwarn-bg);color:var(--pwarn)">Emergency wording list: written by the team, tested in code, waiting for a clinician's review.</div>`];
  if (act >= 0) { const k = seg(t, T.ROWS[act], T.ROWS[act] + .35); b += `<div class="ex" style="top:150px;opacity:${eo(k)};transform:translateX(${(1 - eo(k)) * 30}px)">${ex[act]()}</div>`; }
  else b += `<div class="ex" style="top:150px;opacity:${eo(seg(t, T.title4, T.title4 + .4))}"><div class="exc" style="font-size:26px;line-height:36px">Safety does not depend on the model behaving.</div></div>`;
  F.html = U.doc(U.DW, 'github.com · Dawri · README · Limits to know', b);
  if (t > T.r5 && t < E('v27') + .3) H.spot = { key: 'sr5', op: env2(t, T.r5, E('v27') + .3) };
  F.actors = [T.MS];
  F.fxf = (A, c) => { if (!c) return ''; const top = c.y - c.px * 11; let h = '';
    if (t > T.r5 + .2) h += SP.SWEAT(c.x + 52, top + 4, 5);
    T.ROWS.slice(0, 5).forEach((x, i) => { if (t > x + .1 && t < x + .7) h += SP.CHECK(c.x + 40, top - 30, 5, 1 - seg(t, x + .4, x + .7)); }); return h; };
}
// CH5 ───────────────────────────────
function ch5(t, F) {
  const N = T.n;
  const nd = (i, x, y, w, nm, sb, cls, t0) => { const a = pop(t, t0); return `<div class="node ${cls}" data-a="nd${i}" style="left:${x}px;top:${y}px;width:${w}px;opacity:${a.op};transform:translateY(${a.ty}px)"><b>${nm}</b><span>${sb}</span></div>`; };
  const ar = (x, y, w, t0, flip) => `<div class="arrow" style="left:${x}px;top:${y}px;width:${w}px;opacity:${eo(seg(t, t0, t0 + .3))};${flip ? 'transform:scaleX(-1)' : ''}"></div>`;
  const vr = (x, y, h, t0) => `<div style="position:absolute;left:${x}px;top:${y}px;width:3px;height:${h}px;background:#b8c0cc;opacity:${eo(seg(t, t0, t0 + .3))}"></div>`;
  let b = `<div class="dh" style="${U.ani(eo(seg(t, T.c5 + .2, T.c5 + .7)), 0)}">Under the hood</div>`;
  const bo = eo(seg(t, T.c5 + .3, T.c5 + .8));
  b += `<div class="box" style="left:72px;top:176px;width:880px;height:560px;opacity:${bo}"><span class="bl">One Docker container · Hugging Face Space</span></div>`;
  b += nd(0, 110, 216, 250, 'Patient app', 'React', '', N.start + 0.0) + ar(366, 258, 34, N.start + 0.25) + nd(1, 406, 216, 240, 'Red-flag rules', 'plain code', 'code', N.start + 0.41)
    + ar(652, 258, 34, N.start + 0.58) + nd(2, 692, 216, 230, 'Receptionist', 'AI, via the model', 'ai', N.start + 0.74)
    + vr(806, 302, 46, N.start + 0.91) + nd(3, 692, 352, 230, 'Reply check', 'plain code', 'code', N.start + 0.99)
    + ar(652, 394, 34, N.start + 1.15, 1) + nd(4, 406, 352, 240, 'Staff consoles', 'React', '', N.start + 1.24)
    + ar(366, 394, 34, N.start + 1.4, 1) + nd(5, 110, 352, 250, 'Queue engine', 'plain code, no AI', 'code', N.start + 1.48)
    + nd(6, 110, 520, 380, 'FastAPI service', 'Python', '', N.fast) + nd(7, 520, 520, 402, 'SQLite', 'one database file', '', N.sql);
  // right: inference providers + model cards
  const ho = eo(seg(t, N.gemma - .5, N.gemma));
  b += `<div class="box" style="left:1010px;top:176px;width:480px;height:330px;opacity:${ho}"><span class="bl">Hugging Face Inference Providers</span></div>`;
  [['Gemma 4 26B', 'Chat, intake and the nurse’s handoff draft', N.gemma], ['Whisper large-v3-turbo', 'Speech to text', N.whisper]].forEach(([n, s, t0], i) => {
    const a = pop(t, t0, .45); b += `<div class="mcard" data-a="mc${i}" style="left:1040px;top:${214 + i * 142}px;width:420px;opacity:${a.op};transform:translateY(${a.ty - (1 - a.op) * 30}px)"><b>${n}</b><span>${s}</span></div>`; });
  // receptionist ↔ providers link
  b += `<div style="position:absolute;left:922px;top:258px;width:88px;height:3px;background:var(--data);opacity:${ho}"></div>`;
  // Fanar panel: the hosted model had no capacity; our own fine-tune, with its results ("our test", from the training report)
  const tp = eo(seg(t, N.test - .3, N.test + .2));
  b += `<div data-a="tpan" style="position:absolute;left:1010px;top:522px;width:480px;height:276px;border-radius:12px;background:var(--ground);opacity:${tp}"></div>`;
  const txt = (x, y, s, o, css = '') => `<div style="position:absolute;left:${x}px;top:${y}px;opacity:${o};${css}">${s}</div>`;
  if (t < N.tuned - .2) {
    const o2 = tp * (1 - seg(t, N.tuned - .5, N.tuned - .2));
    b += txt(1034, 540, "Qatar's Fanar", o2, 'font-size:24px;font-weight:600');
    b += txt(1034, 580, 'Hosted Fanar: its only provider had no capacity, 0 of 8 calls worked.', o2 * eo(seg(t, N.cap - .3, N.cap + .1)), 'width:430px;font-size:18px;line-height:26px;color:var(--pneu)');
    b += txt(1034, 650, '<span class="pill data" style="font-size:15px;height:30px">Live chat: Gemma 4 26B</span>', o2 * eo(seg(t, N.cap + .2, N.cap + .5)));
  } else {
    const o3 = eo(seg(t, N.tuned - .2, N.tuned + .2)), BW = 260;
    b += txt(1034, 536, '<span style="font-size:22px;font-weight:600">Our Fanar 9B fine-tune</span><span class="pill neu" style="margin-left:10px">our test</span>', o3);
    b += txt(1034, 568, 'LoRA on QCRI/Fanar-1-9B-Instruct · Hugging Face Jobs', o3, 'font-size:14.5px;color:var(--muted)');
    const row = (y, lab, frac, val, col, t0) => `<div class="bar" style="left:1034px;top:${y}px;height:16px;width:${Math.max(5, BW * frac * eo(seg(t, t0, t0 + .5)))}px;background:${col};opacity:${o3}"></div>` + txt(1034 + BW + 14, y - 3, lab + ' <b>' + val + '</b>', o3 * eo(seg(t, t0, t0 + .3)), `font-size:15.5px;color:${col === 'var(--negative)' ? 'var(--negative)' : 'var(--ink)'}`);
    b += txt(1034, 602, 'Valid intake', o3, 'font-size:16px;font-weight:600');
    b += row(628, 'base', 6 / 63, '6 of 63', '#9aa6b8', N.valid) + row(652, 'tuned', 56 / 63, '56 of 63', 'var(--data)', N.valid + .4);
    b += txt(1034, 684, 'Emergency recognition', o3 * eo(seg(t, N.lost - .3, N.lost)), 'font-size:16px;font-weight:600');
    b += row(710, 'base', 9 / 13, '9 of 13', '#9aa6b8', N.lost - .1) + row(734, 'tuned', 0, '0 of 13', 'var(--negative)', N.lost + .3);
    b += txt(1034, 764, 'Kept out of live chat until it recognises emergencies.', o3 * eo(seg(t, N.out - .2, N.out + .2)), 'font-size:15.5px;font-weight:600;color:var(--negative)');
  }
  F.html = U.doc(U.DW, 'github.com · Dawri · README · Design', b);
  F.actors = [T.MK];
  F.fxf = (A, c) => { if (!c) return ''; const top = c.y - c.px * 11; return t > N.lost ? SP.SWEAT(c.x + 52, top + 4, 5) : ''; };
}
// CH6 ───────────────────────────────
function ch6(t, F) {
  const H = F.hud;
  if (t < T.endc) {
    const fk = seg(t, T.fall, T.fall + .9), sl = back(seg(t, T.fall + .35, T.fall + 1.0), 1.4);
    const xs = [lerp(RX.tr, RX.fd, sl), lerp(RX.dr, RX.tr, sl), lerp(RX.ph, RX.dr, sl)];
    let b = `<div class="dh" style="${U.ani(eo(seg(t, T.c6 + .2, T.c6 + .7)), 0)}">The walk-in path, with Dawri</div>` + rail(t, {
      walk: { op: 1, ty: 0 }, slot: { op: 1, dawri: true }, fd: { op: 1 - fk * .8, ty: 0, dy: ei(fk) * 700, rot: fk * 14 },
      tr: { op: 1, ty: 0 }, dr: { op: 1, ty: 0 }, ph: { op: 1, ty: 0 }, xs: t > T.fall + .35 ? xs : null });
    [['Reception step removed', T.aim1], ['Structured intake for nurses', T.aim2], ['People decide everything clinical', T.aim3]].forEach(([s, t0], i) => {
      const a = pop(t, t0, .4); b += `<div class="aim" style="top:${500 + i * 84}px;opacity:${a.op};transform:translateY(${a.ty}px)">${s}</div>`; });
        F.html = U.doc(U.DW, 'github.com · Dawri · README · What Dawri is', b);
  } else {
    const k = t - T.endc;
    const a = eo(seg(k, .1, .6)), tg = i => eo(seg(t, T.hop[i] - .15, T.hop[i] + .15));
    F.html = `<div class="endc">
      <div data-a="wm2" style="position:absolute;left:250px;top:250px;font-size:230px;line-height:230px;font-weight:700;letter-spacing:-.04em;opacity:${a};transform:translateY(${(1 - a) * 30}px)">Dawri</div>
      <div class="ar" style="position:absolute;left:1180px;top:268px;font-size:170px;line-height:200px;font-weight:600;color:#bcd2f2;opacity:${eo(seg(k, .3, .8))}">دوري</div>
      <div style="position:absolute;left:256px;top:610px;display:flex;gap:26px;font-size:84px;line-height:96px;font-weight:600;letter-spacing:-.02em">
        ${['Arrive,', 'don’t', 'register.'].map((w, i) => `<span data-a="tg${i}" style="opacity:${.25 + .75 * tg(i)};color:${i === 2 ? '#FFC21A' : '#fff'}">${w}</span>`).join('')}</div>
      <div style="position:absolute;left:256px;top:800px;font-size:24px;color:#cfdcf1;opacity:${eo(seg(k, 1.4, 2))}">A prototype · demo with synthetic data · not connected to PHCC/HMC systems</div></div>`;
  }
  F.actors = [T.ME];
  F.fxf = (A, c) => { if (!c) return ''; let h = ''; const top = c.y - c.px * 11;
    if (t > T.hop[2] + 2.6) { const k = ((t - T.hop[2] - 2.6) % 1.4) / 1.4; h += SP.ZZZ(c.x + 60 + k * 20, top - 10 - k * 40, 6, 1 - k); }
    if (t > T.hop[2] && t < T.hop[2] + .8) { const k = seg(t, T.hop[2], T.hop[2] + .8); for (let i = 0; i < 6; i++) { const a = i / 6 * Math.PI * 2; h += SP.SPARK(c.x + Math.cos(a) * (60 + k * 90), c.y - 50 + Math.sin(a) * (40 + k * 60), 8, i % 2 ? '#FFC21A' : '#ffffff', 1 - k); } }
    return h; };
}
