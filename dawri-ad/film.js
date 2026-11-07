// "Dawri — How it works" (short ad): four steps on the real screens. Voice lines set the clock; every beat hangs on a spoken word.
import { clamp, lerp, seg, ss, eio, eo, ei, back, hash } from '/core/lib.js';
import * as U from './ui.js';
import * as SP from './sprite.js';

export const BPM = 96, B = 60 / BPM;
const GAP = { a01: 1.0, a02: .55, a03: 1.75, a04: .45, a05: .9, a06: .5, a07: .7, a08: .35, a09: 1.5, a10: 1.4, a11: .35, a12: .7 };
export const VO = {}, D = {}; export let DUR = 0;
let WORDS = {};
const nrm = s => s.toLowerCase().replace(/[^a-z0-9]/g, '');
const S = id => VO[id], E = id => VO[id] + D[id];
export const W = (id, word, n = 0) => { let k = 0; for (const [w, a] of WORDS[id]) if (nrm(w) === nrm(word) && k++ === n) return VO[id] + Math.max(0, a); throw new Error(`word ${word} not in ${id}`); };
export const WE = (id, word, n = 0) => { let k = 0; for (const [w, , b] of WORDS[id]) if (nrm(w) === nrm(word) && k++ === n) return VO[id] + b; throw new Error(`word ${word} not in ${id}`); };
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
let M, CUR, TY = {};
const P1 = 'عندي حرارة وكحة من ثلاث أيام', P3 = 'باراسيتامول', PR = 'I have chest pain spreading to my left arm';
export function build(words, dur) {
  WORDS = words; let t = 0;
  for (const id of Object.keys(GAP)) { t += GAP[id]; VO[id] = +t.toFixed(3); D[id] = dur[id]; t += dur[id]; }
  DUR = +(t + 2.4).toFixed(2);
  EV.length = 0; MOVES.length = 0; SUBS.length = 0;
  M = new Actor(6); CUR = new Cursor();
  const CAP = { a01: 'Walking into a health centre? Skip the front desk.', a02: 'Meet Dawri, the AI front desk for walk-ins.',
    a03: "Step one: tell it what's wrong, in Arabic or English, by text or voice.", a04: 'It asks a few short questions, one at a time.',
    a05: 'Step two: pick a health centre, with estimated waits.', a06: "Step three: when you arrive, tap “I'm here”, and your ticket gets its number.",
    a07: 'Then follow your turn. The nurse already has your answers, and your allergies.', a08: 'Doctor. Pharmacy. Done.',
    a09: 'And if it sounds like an emergency, Dawri tells you to call 999. No queue.', a10: 'Dawri.', a11: "Arrive, don't register.", a12: 'Try the demo today.' };
  for (const id of Object.keys(VO)) { ev(VO[id], 'vo', { id }); SUBS.push({ id, t0: S(id) - .05, t1: E(id) + .3, text: CAP[id] }); }
  for (let i = 0; i < SUBS.length - 1; i++) { const gap = SUBS[i + 1].t0 - SUBS[i].t1; if (gap < .7) SUBS[i].t1 = SUBS[i + 1].t0 - .02; }
  SUBS.forEach(s => { if (s.t1 - s.t0 < 1.6) s.t1 = s.t0 + 1.6; });

  // ═════ INTRO — kinetic type on the desktop; the ticket kicks the front desk away
  T.iw = [W('a01', 'walking'), W('a01', 'health'), W('a01', 'skip'), W('a01', 'front')];
  T.kick = E('a01') + .1; T.meet = S('a02'); T.wm = W('a02', 'dowry') - .05; T.sub = W('a02', 'ai');
  T.iw.forEach((x, i) => ev(x, 'pop', { v: .5 + i * .1 })); ev(T.kick, 'fall'); ev(T.wm, 'title'); ev(T.sub, 'pop', { v: .6 });
  cam(0, .01, [960, 520, 1.12], 'cut'); cam(.1, E('a01'), [960, 540, 1.0], 'ss'); cam(T.meet - .1, 2.6, [960, 540, 1.06], 'ss');
  M.hide(0, T.iw[2] - .5).jump(T.iw[2] - .5, T.iw[2] + .05, pt(1820, 1200), at('fdk', .5, 0), 200, { big: true })
    .stand(T.iw[2] + .05, T.kick - .3, at('fdk', .5, 0), { eyes: 'd' })
    .jump(T.kick - .3, T.kick + .25, at('fdk', .5, 0), pt(1500, 420), 70)
    .stand(T.kick + .25, T.wm - .45, pt(1500, 420), { eyes: 'l' })
    .jump(T.wm - .45, T.wm + .1, pt(1500, 420), at('wmI', .9, 0), 120, { big: true })
    .stand(T.wm + .1, E('a02') + .9, at('wmI', .9, 0), { eyes: t => t < T.wm + .6 ? 'wide' : 'happy', arms: t => t > T.sub && t < T.sub + 1.2 ? 'wave' : 'down' });

  // wipe → the app
  T.w2 = E('a02') + .45; T.c2 = T.w2 + .62; ev(T.w2, 'wipe'); T.WIPES = [[T.w2, 'How it works', 'Four steps']];
  const PF = [740, 512, 1.15], SF = [1250, 560, 1.18];
  cam(T.c2, .01, PF, 'cut');
  // STEP 1 — sign in with a demo patient, then the Arabic message
  T.st1 = S('a03') - .25;
  const a = S('a03') + .1; T.login = a + .35; T.fat = a + .8; T.home = a + 1.25; T.start = a + 1.65; T.consent = T.start + .05; T.agree = a + 2.05; T.chat = T.agree + .2;
  CUR.show(T.c2 + .2, T.chat + .4).move(T.c2 + .2, T.c2 + .4, pt(900, 760)).tap(T.c2 + .5, at('blogin', .6, .5), T.login)
    .tap(T.login + .1, at('pr0', .45, .5), T.fat).tap(T.fat + .1, at('blog2', .5, .5), T.home - .05)
    .tap(T.home + .05, at('bstart', .5, .5), T.start).tap(T.start + .05, at('bagree', .5, .5), T.agree);
  T.type1 = T.chat + .15; TY.p1 = typing(T.type1, P1, 17, 2, 'akey'); T.mic = W('a03', 'voice');
  T.send1 = Math.max(TY.p1[TY.p1.length - 1] + .2, E('a03') - .1); ev(T.send1, 'send');
  T.a2 = S('a04') + .15; T.p2 = W('a04', 'questions'); T.a3 = W('a04', 'one') + .05; TY.p3 = typing(T.a3 + .35, P3, 22, 5, 'akey');
  T.send3 = TY.p3[TY.p3.length - 1] + .15; T.sum = T.send3 + .25; T.yes = T.sum + .75; T.centre = T.yes + .2;
  [T.a2, T.a3].forEach(x => ev(x, 'msg')); ev(T.p2, 'send'); ev(T.send3, 'send'); ev(T.sum, 'msg');
  cam(T.type1 - .5, .9, [660, 650, 1.5]); cam(T.yes - .2, .8, PF);
  // STEP 2 — the map
  T.st2 = S('a05') - .2; T.pins = W('a05', 'pick'); T.selPin = W('a05', 'estimated'); T.checkin = Math.max(E('a05') + .05, T.selPin + .6); T.reserved = T.checkin + .2;
  if (T.centre > T.pins - .15) throw new Error('step 1 overruns step 2 by ' + (T.centre - T.pins + .15).toFixed(2));
  for (let i = 0; i < 4; i++) ev(T.pins + i * .12, 'pin', { n: i }); ev(T.selPin, 'click');
  CUR.show(T.centre + .1, T.checkin + .3).tap(T.centre + .3, at('pw', .5, .9), T.selPin).tap(T.selPin + .2, at('bcheck', .5, .5), T.checkin);
  cam(T.pins - .3, .9, [700, 470, 1.32]);
  // STEP 3 — "I'm here", the ticket number
  T.st3 = S('a06') - .2; T.here = W('a06', "i'm") - .05; T.ticket = T.here + .3; T.lock = W('a06', 'number') + .1;
  ev(T.lock, 'lock'); ev(T.ticket + .15, 'scramble', { d: T.lock - T.ticket - .15 });
  CUR.show(T.reserved + .1, T.here + .6).move(T.reserved + .2, T.reserved + .8, at('activ', .9, .9)).tap(T.reserved + .9, at('bhere', .5, .5), T.here);
  cam(T.reserved - .1, .9, [690, 760, 1.55]); cam(T.ticket + .1, 1.0, [700, 430, 1.5]);
  // STEP 4 — follow your turn: people ahead count down, then the nurse, doctor and pharmacy
  T.st4 = S('a07') - .2; T.count = S('a07') + .1; T.gonow = W('a07', 'turn') + .3;
  for (let i = 1; i <= 3; i++) ev(T.count + (T.gonow - T.count) * i / 3.2, 'tick', { n: i });
  ev(T.gonow, 'chime', { v: .7 });
  cam(T.count - .2, .7, [700, 520, 1.45]);
  T.whip = W('a07', 'nurse') - .35; ev(T.whip, 'whoosh', { v: 1 }); ev(T.whip + .45, 'crash');
  cam(T.whip, .5, SF, 'whip');
  T.intake = W('a07', 'answers') - .1; T.pen = W('a07', 'allergies');
  cam(T.intake - .2, 1.0, [1270, 540, 1.4]); cam(T.pen - .25, .8, [1450, 340, 1.6]);
  T.doctor = W('a08', 'doctor') - .15; T.warn = T.doctor + .35; ev(T.doctor, 'pane'); ev(T.warn, 'alert', { v: .6 });
  cam(T.doctor - .1, .5, [1320, 430, 1.32]);
  T.pharm = W('a08', 'pharmacy') - .15; T.disp = T.pharm + .4; ev(T.pharm, 'pane');
  CUR.show(T.pharm, T.disp + .4).move(T.pharm, T.disp - .1, at('bdisp', .5, .5)).click(T.disp);
  T.done = W('a08', 'done') - .1; T.complete = T.done + .3; T.whip2 = T.done - .1; ev(T.whip2, 'whoosh', { v: .8 }); ev(T.complete + .1, 'chime');
  cam(T.whip2, .45, [700, 470, 1.4], 'whip');
  M.hide(E('a02') + .9, T.c2 + .2)
    .jump(T.c2 + .2, T.c2 + .7, pt(960, 1200), at('phone', .78, 0), 160)
    .stand(T.c2 + .7, T.send1, at('phone', .78, 0), { eyes: t => t > T.type1 ? 'd' : 'l' })
    .stand(T.send1, T.a2 + .15, at('m1', .86, 0), { px: 5, eyes: 'happy', still: true })
    .jump(T.a2 + .15, T.a2 + .5, at('m1', .86, 0), at('m2', .14, 0), 50, { px: 5 })
    .stand(T.a2 + .5, T.a3 + .1, at('m2', .14, 0), { px: 5, eyes: 'u' })
    .jump(T.a3 + .1, T.a3 + .45, at('m2', .14, 0), at('m4', .14, 0), 50, { px: 5 })
    .stand(T.a3 + .45, T.sum + .05, at('m4', .14, 0), { px: 5, eyes: 'u' })
    .jump(T.sum + .05, T.sum + .4, at('m4', .14, 0), at('sum', .7, 0), 50)
    .stand(T.sum + .4, T.centre, at('sum', .7, 0), { eyes: 'l' })
    .stand(T.centre, T.reserved, at('map', .82, 0), { eyes: 'd' })
    .stand(T.reserved, T.here - .45, at('valid', .78, 0), { ghost: () => true, still: true })
    .jump(T.here - .45, T.here, at('valid', .78, 0), at('bhere', .7, 0), 70, { big: true })
    .stand(T.here, T.ticket + .1, at('bhere', .7, 0), { eyes: 'shut' })
    .jump(T.ticket + .1, T.lock, at('bhere', .7, 0), at('tnum', .72, 0, 0, -6), 160)
    .stand(T.lock, T.whip - .05, at('tnum', .72, 0, 0, -6), { eyes: t => t < T.lock + 1 ? 'happy' : 'd', arms: t => t < T.lock + .8 || (t > T.gonow && t < T.gonow + .6) ? 'up' : 'down' })
    .jump(T.whip - .05, T.whip + .7, at('tnum', .72, 0, 0, -6), at('ban', .2, 0), 160)
    .stand(T.whip + .7, T.intake, at('ban', .2, 0), { eyes: 'r' })
    .walk(T.intake, T.pen - .3, at('intake', .15, 0), at('intake', .8, 0), { eyes: 'd' })
    .jump(T.pen - .3, T.pen + .1, at('intake', .8, 0), at('allergy', .5, 0), 80)
    .stand(T.pen + .1, T.doctor, at('allergy', .5, 0), { eyes: 'wide' })
    .stand(T.doctor, T.pharm, at('rxbad', .6, 0), { eyes: 'wide' })
    .stand(T.pharm, T.done, at('handover', .8, 0), { eyes: 'd' })
    .jump(T.done, T.complete + .25, at('handover', .8, 0), at('cdone', .75, 0), 140)
    .stand(T.complete + .25, 999, at('cdone', .75, 0), { eyes: 'happy', arms: 'up' });
  T.STEPS = [[T.st1, 1, "Tell it what's wrong"], [T.st2, 2, 'Pick a centre'], [T.st3, 3, 'Tap “I\'m here”'], [T.st4, 4, 'Follow your turn']];
  T.STEPS.forEach(s => ev(s[0], 'chapnote'));

  // ═════ EMERGENCY — Ravi, one phone in the middle
  T.w3 = E('a08') + .55; T.c3 = T.w3 + .62; ev(T.w3, 'wipe'); T.WIPES.push([T.w3, 'Safety first', "If it's an emergency"]);
  cam(T.c3, .01, [960, 512, 1.08], 'cut');
  T.ravi = T.c3 + .25; TY.r = typing(T.ravi, PR, 22, 4, 'key'); T.sendR = TY.r[TY.r.length - 1] + .12; ev(T.sendR, 'send');
  T.red = Math.max(W('a09', 'emergency') + .1, T.sendR + .4); T.n999 = W('a09', 'call'); T.noTk = W('a09', 'no'); ev(T.red, 'redalert'); ev(T.noTk, 'bump');
  cam(T.red - .1, 1.0, [960, 560, 1.2]);
  const MR = new Actor(6); T.MR = MR;
  MR.hide(0, T.c3 + .3).jump(T.c3 + .3, T.c3 + .8, pt(960, 1200), at('phoneB', .16, 0), 150)
    .stand(T.c3 + .8, T.red, at('phoneB', .16, 0), { eyes: t => t > T.sendR ? 'wide' : 'r' })
    .jump(T.red, T.red + .45, at('phoneB', .16, 0), at('phoneB', .16, 0), 60)
    .stand(T.red + .45, T.noTk - .5, at('phoneB', .16, 0), { eyes: 'wide', arms: 'up' })
    .jump(T.noTk - .5, T.noTk + .1, at('phoneB', .16, 0), at('phoneB', .86, 0), 70)
    .jump(T.noTk + .1, T.noTk + .9, at('phoneB', .86, 0), at('phoneB', 1.35, 1.2), 80, { spin: true })
    .hide(T.noTk + .9, 9999);
  CUR.show(T.sendR - .5, T.sendR + .4).move(T.sendR - .5, T.sendR - .1, at('sndB', .5, .5)).click(T.sendR);

  // ═════ END — wordmark, tagline, the demo link
  T.endc = E('a09') + .6; cam(T.endc, .01, [960, 540, 1.0], 'cut'); ev(T.endc, 'endtitle');
  const ME = new Actor(10); T.ME = ME;
  const w0 = W('a11', 'arrive'), w1 = W('a11', 'dont'), w2 = W('a11', 'register'); T.hop = [w0, w1, w2]; T.demo = S('a12') - .1;
  ME.hide(0, T.endc + .3).jump(T.endc + .3, T.endc + .85, pt(980, 1180), at('wm2', .9, 0), 140, { big: true })
    .stand(T.endc + .85, w0 - .3, at('wm2', .9, 0), { eyes: 'd' })
    .jump(w0 - .3, w0, at('wm2', .9, 0), at('tg0', .5, 0), 30).stand(w0, w1 - .3, at('tg0', .5, 0), { eyes: 'r' })
    .jump(w1 - .28, w1, at('tg0', .5, 0), at('tg1', .5, 0), 40).stand(w1, w2 - .3, at('tg1', .5, 0), { eyes: 'r' })
    .jump(w2 - .28, w2, at('tg1', .5, 0), at('tg2', .55, 0), 40).stand(w2, T.demo, at('tg2', .55, 0), { eyes: 'happy', arms: 'up' })
    .jump(T.demo, T.demo + .5, at('tg2', .55, 0), at('url', .97, 0), 60).stand(T.demo + .5, DUR + 1, at('url', .97, 0), { eyes: t => t > T.demo + 1.8 ? 'happy' : 'd', arms: t => t > T.demo + .5 && t < T.demo + 1.6 ? 'wave' : 'down' });
  T.hop.forEach((x, i) => ev(x, 'note', { n: i })); ev(T.demo + .5, 'pop', { v: .8 });
  ev(DUR - 1.6, 'final');
  T.WIPES.forEach(w => ev(w[0] + .5, 'chapnote'));
  MOVES.sort((a, b) => a.t0 - b.t0);
  EV.sort((a, b) => a.t - b.t);
}

// ───── per-frame state
const pop = (t, t0, d = .35) => { const k = seg(t, t0, t0 + d); return { op: eo(k), ty: (1 - back(k, 2.2)) * 18 }; };
const env2 = (t, a, b) => Math.min(seg(t, a, a + .35), 1 - seg(t, b - .35, b));
export const camFinal = t => camAt(t);
export function frame(t) {
  const F = { cam: camAt(t), html: '', actors: [], cursor: CUR, hud: {}, fx: '' };
  const H = F.hud;
  for (const w of T.WIPES) if (t >= w[0] && t < w[0] + 1.25) H.wipe = { p: (t - w[0]) / 1.25, no: w[1], nm: w[2] };
  const sub = SUBS.find(s => t >= s.t0 && t < s.t1);
  if (sub && t < T.endc - .1) H.cap = { text: sub.text, op: Math.min(seg(t, sub.t0, sub.t0 + .15), 1 - seg(t, sub.t1 - .12, sub.t1)), x: capX(t) };
  if (t < T.c2) intro(t, F); else if (t < T.c3) app(t, F); else if (t < T.endc) sos(t, F); else end(t, F);
  return F;
}
const phoneFocus = t => t > T.c2 && (t < T.whip + .15 || t > T.whip2 + .25);
function capX(t) { if (t >= T.c2 && t < T.c3 && phoneFocus(t)) return 1390; return 960; }

// INTRO ─────────────────────────────
function intro(t, F) {
  const w = i => { const a = pop(t, T.iw[i] - .05); return `opacity:${a.op};transform:translateY(${a.ty}px)`; };
  const up = eo(seg(t, T.meet - .1, T.meet + .5));
  const fk = seg(t, T.kick, T.kick + .9), fd = pop(t, T.iw[3] - .05);
  let h = `<div class="endc"><div style="position:absolute;left:180px;top:${330 - up * 120}px;opacity:${1 - up};font-size:104px;line-height:120px;font-weight:600;letter-spacing:-.03em">
    <div><span style="display:inline-block;${w(0)}">Walking into</span> <span style="display:inline-block;${w(1)}">a health centre?</span></div>
    <div style="margin-top:28px"><span style="display:inline-block;${w(2)}">Skip</span> <span data-a="fdk" style="display:inline-block;color:#FFC21A;opacity:${fd.op * (1 - fk * .7)};transform:translateY(${fd.ty + ei(fk) * 640}px) rotate(${fk * 16}deg)">the front desk.</span></div></div>`;
  if (t > T.meet - .2) { const m = eo(seg(t, T.wm - .1, T.wm + .4)), s2 = pop(t, T.sub, .45);
    h += `<div data-a="wmI" style="position:absolute;left:250px;top:260px;font-size:230px;line-height:230px;font-weight:700;letter-spacing:-.04em;opacity:${m};transform:translateY(${(1 - m) * 40}px)">Dawri</div>
      <div class="ar" style="position:absolute;left:1180px;top:278px;font-size:170px;line-height:200px;font-weight:600;color:#bcd2f2;opacity:${eo(seg(t, T.wm + .2, T.wm + .7))}">دوري</div>
      <div style="position:absolute;left:258px;top:560px;font-size:72px;line-height:84px;font-weight:600;letter-spacing:-.02em;opacity:${s2.op};transform:translateY(${s2.ty}px)">The AI front desk <span style="color:#FFC21A">for walk-ins.</span></div>`; }
  F.html = h + '</div>';
  if (t > T.wm && t < T.wm + .25) F.hud.flash = .3 * (1 - seg(t, T.wm, T.wm + .25));
  F.actors = [M];
}
// APP ───────────────────────────────
function chatMsgs(t) {
  const L = [{ who: 'as', text: 'شو اللي يتعبك اليوم؟', ar: 1 }];
  const fly = t0 => { const k = seg(t, t0, t0 + .4); return { op: eo(k * 2), ty: (1 - eo(k)) * 90 }; };
  const appear = t0 => { const k = seg(t, t0, t0 + .3); return { op: eo(k), ty: (1 - back(k, 2)) * 14 }; };
  if (t >= T.send1) L.push({ who: 'me', text: P1, ar: 1, ...fly(T.send1) });
  if (t >= T.a2) L.push({ who: 'as', text: 'كم شدته من 0 إلى 10؟', ar: 1, ...appear(T.a2) });
  if (t >= T.p2) L.push({ who: 'me', text: '6', ar: 1, ...fly(T.p2) });
  if (t >= T.a3) L.push({ who: 'as', text: 'أخذتي أي دواء لها؟', ar: 1, ...appear(T.a3) });
  if (t >= T.send3) L.push({ who: 'me', text: P3, ar: 1, ...fly(T.send3) });
  return L;
}
function phoneState(t) {
  if (t < T.login) return { scr: 'welcome', press: t > T.login - .1 ? 'login' : '' };
  if (t < T.home) return { scr: 'login', sel: t >= T.fat ? 0 : -1, press: t > T.home - .1 };
  if (t < T.consent) return { scr: 'home', press: t > T.start - .02 };
  if (t < T.chat) return { scr: 'consent', press: t > T.agree - .02 };
  if (t < T.centre) {
    const s = { scr: 'chat', t, msgs: chatMsgs(t), mic: t > T.mic && t < T.mic + .7 ? 6 * Math.sin(Math.PI * seg(t, T.mic, T.mic + .7)) : 0 };
    if (t >= T.type1 && t < T.send1) { s.input = typed(TY.p1, P1, t); s.ar = 1; s.caret = 1; }
    if (t >= TY.p3[0] - .05 && t < T.send3) { s.input = typed(TY.p3, P3, t); s.ar = 1; s.caret = 1; }
    if ((t > T.send1 + .25 && t < T.a2) || (t > T.p2 + .2 && t < T.a3)) s.dots = 1;
    if (t >= T.sum) s.sum = { op: eo(seg(t, T.sum, T.sum + .3)), ty: (1 - eo(seg(t, T.sum, T.sum + .3))) * 16, press: t > T.yes - .02 };
    return s;
  }
  if (t < T.reserved) return { scr: 'centre', pins: [0, 1, 2, 3].map(i => eo(seg(t, T.pins + i * .12, T.pins + i * .12 + .3))), selPin: t >= T.selPin, cardOp: eo(seg(t, T.selPin, T.selPin + .3)), press: t > T.checkin - .02 };
  if (t < T.ticket) { const s = Math.max(0, 2698 - Math.floor((t - T.reserved) * 1)); return { scr: 'reserved', left: `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`, press: t > T.here - .02 }; }
  if (t < T.complete) {
    let num = 'T-014'; if (t < T.lock) { const f = Math.floor(t * 24); num = 'T-' + [0, 1, 2].map(i => Math.floor(hash(f * 3.1 + i * 17.7) * 10)).join(''); }
    const n = t < T.count ? 3 : Math.max(0, 3 - Math.floor((t - T.count) / ((T.gonow - T.count) / 3.2)));
    const go = t > T.gonow;
    return { scr: 'ticket', num, gonow: go && t < T.doctor ? eo(seg(t, T.gonow, T.gonow + .3)) : 0, stage: t > T.pharm ? 2 : t > T.doctor ? 1 : 0, ahead: go ? 0 : n, wait: go ? 'Now' : ['Now', '5 min', '10 min', '15 min'][n] };
  }
  return { scr: 'complete' };
}
function staffState(t) {
  if (t < T.whip + .3) return { scr: 'nurseQ', hl: true };
  if (t < T.doctor) return { scr: 'nurse', vit: {}, irHot: t > T.pen - .1 ? 4 : -1 };
  if (t < T.pharm) return { scr: 'doctor', rx: eo(seg(t, T.warn - .15, T.warn + .2)), hot: t < T.warn ? 'amoxicillin' : '' };
  return { scr: 'pharmacy', press: t > T.disp - .02 && t < T.disp + .2, done: t > T.disp + .2 };
}
function app(t, F) {
  const H = F.hud;
  const focusStaff = t > T.whip + .25 && t < T.whip2 + .2;
  const ps = phoneState(t); ps.blur = focusStaff ? 5 : 0;
  F.html = U.phone(U.PH, ps);
  if (t > T.whip - .35) { const ss_ = staffState(t); ss_.blur = focusStaff ? 0 : 4; F.html += U.staff(U.SW, ss_); }
  if (t >= T.type1 - .1 && t < T.send1 + .3) H.keys = keysHud(t, TY.p1, P1, 'Arabic keyboard');
  if (t >= TY.p3[0] - .2 && t < T.send3 + .3) H.keys = keysHud(t, TY.p3, P3, 'Arabic keyboard');
  // step badge: big on the free right half while the phone is in focus; a pill while the staff screens are in view
  const st = [...T.STEPS].reverse().find(s => t >= s[0]);
  if (st) H.step = { n: st[1], nm: st[2], k: seg(t, st[0], st[0] + .5), big: phoneFocus(t) && t < T.complete, op: 1 };
  if (t > T.selPin && t < E('a05') + .3) H.spot = { key: 'pw', op: env2(t, T.selPin, E('a05') + .3), r: 200 };
  if (t > T.count && t < T.whip) H.spot = { key: 'ahead', op: env2(t, T.count, T.whip) };
  if (t > T.pen && t < T.doctor) H.spot = { key: 'allergy', op: env2(t, T.pen, T.doctor) };
  if (t > T.lock && t < T.lock + .2) H.flash = .25 * (1 - seg(t, T.lock, T.lock + .2));
  F.actors = [M];
  F.fxf = (A, c) => {
    let h = ''; if (!c) return h; const top = c.y - c.px * 11;
    if (t > T.a2 + .5 && t < T.sum + .05) h += SP.QMARK(c.x + 40, top - 40, 5);
    if (t > T.pen + .1 && t < T.doctor) h += SP.BANG(c.x + 34, top - 52, 5);
    if (t > T.lock && t < T.lock + .7) { const k = seg(t, T.lock, T.lock + .7); h += SP.SPARK(c.x - 70 - k * 30, top - k * 30, 6, '#FFC21A', 1 - k) + SP.SPARK(c.x + 70 + k * 30, top - 10 - k * 30, 5, '#1d5fbf', 1 - k); }
    if (t > T.complete + .25 && t < T.complete + 1.2) { const k = seg(t, T.complete + .25, T.complete + 1.2); for (let i = 0; i < 6; i++) { const a = i / 6 * Math.PI * 2 + .3; h += SP.SPARK(c.x + Math.cos(a) * (40 + k * 70), c.y - 30 + Math.sin(a) * (30 + k * 50), 5, i % 2 ? '#FFC21A' : '#1d5fbf', 1 - k); } }
    return h;
  };
}
function keysHud(t, TT, text, label) {
  const ch = [...text]; let n = 0; while (n < TT.length && TT[n] <= t) n++;
  const k = ch[Math.max(0, n - 1)] === ' ' ? 'space' : ch[Math.max(0, n - 1)];
  return { keys: [k], dn: n > 0 && t - TT[n - 1] < .07, label, op: Math.min(seg(t, TT[0] - .25, TT[0]), 1 - seg(t, TT[TT.length - 1] + .2, TT[TT.length - 1] + .45)), ar: /[؀-ۿ]/.test(text) ? 1 : 0 };
}
// EMERGENCY ─────────────────────────
function sos(t, F) {
  const H = F.hud;
  const ravi = t < T.red ? { scr: 'chat', t, en: 1, msgs: [{ who: 'as', text: "What's bothering you today?" }].concat(t >= T.sendR ? [{ who: 'me', text: PR, op: eo(seg(t, T.sendR, T.sendR + .3)), ty: (1 - eo(seg(t, T.sendR, T.sendR + .4))) * 80 }] : []),
    input: t >= T.ravi && t < T.sendR ? typed(TY.r, PR, t) : '', caret: t >= T.ravi && t < T.sendR, dots: t > T.sendR + .3 } : { scr: 'emergency' };
  ravi.key = 'phoneB';
  F.html = U.phone({ ...U.PH, x: 740 }, ravi).replace(/data-a="snd"/, 'data-a="sndB"');
  if (t > T.red && t < T.red + .5) H.flash = .3 * (1 - seg(t, T.red, T.red + .5)), H.flashCol = '#c4242a';
  if (t > T.n999 - .1 && t < T.endc) H.spot = { key: 'e999', op: env2(t, T.n999 - .1, T.endc) };
  if (t >= T.ravi - .1 && t < T.sendR + .3) H.keys = keysHud(t, TY.r, PR, 'Ravi types');
  F.actors = [T.MR];
  F.burst2 = t > T.noTk + .75 && t < T.noTk + 1.25 ? seg(t, T.noTk + .75, T.noTk + 1.25) : 0;
  F.fxf = (A, c) => { if (!c) return ''; const top = c.y - c.px * 11; return t > T.red && t < T.noTk + .6 ? SP.BANG(c.x + 34, top - 52, 5) : ''; };
}
// END ───────────────────────────────
function end(t, F) {
  const k = t - T.endc, a = eo(seg(k, .1, .6)), tg = i => eo(seg(t, T.hop[i] - .15, T.hop[i] + .15)), u = pop(t, T.demo, .45);
  F.html = `<div class="endc">
    <div data-a="wm2" style="position:absolute;left:250px;top:200px;font-size:230px;line-height:230px;font-weight:700;letter-spacing:-.04em;opacity:${a};transform:translateY(${(1 - a) * 30}px)">Dawri</div>
    <div class="ar" style="position:absolute;left:1180px;top:218px;font-size:170px;line-height:200px;font-weight:600;color:#bcd2f2;opacity:${eo(seg(k, .3, .8))}">دوري</div>
    <div style="position:absolute;left:256px;top:540px;display:flex;gap:26px;font-size:84px;line-height:96px;font-weight:600;letter-spacing:-.02em">
      ${['Arrive,', 'don’t', 'register.'].map((w, i) => `<span data-a="tg${i}" style="opacity:${.25 + .75 * tg(i)};color:${i === 2 ? '#FFC21A' : '#fff'}">${w}</span>`).join('')}</div>
    <div data-a="url" style="position:absolute;left:256px;top:720px;display:flex;align-items:center;gap:18px;height:84px;padding:0 34px;border-radius:42px;background:#fff;color:var(--ink);font-size:40px;font-weight:600;opacity:${u.op};transform:translateY(${u.ty}px)">
      <span style="color:var(--data)">Try the demo</span><span>xtamim-dawri.hf.space</span></div>
    <div style="position:absolute;left:256px;top:880px;font-size:24px;color:#cfdcf1;opacity:${eo(seg(t, T.demo + .4, T.demo + 1))}">A prototype · demo with synthetic data · not connected to PHCC/HMC systems</div></div>`;
  F.actors = [T.ME];
  F.fxf = (A, c) => { if (!c) return ''; let h = '';
    if (t > T.hop[2] && t < T.hop[2] + .8) { const kk = seg(t, T.hop[2], T.hop[2] + .8); for (let i = 0; i < 6; i++) { const q = i / 6 * Math.PI * 2; h += SP.SPARK(c.x + Math.cos(q) * (60 + kk * 90), c.y - 50 + Math.sin(q) * (40 + kk * 60), 8, i % 2 ? '#FFC21A' : '#ffffff', 1 - kk); } }
    return h; };
}
