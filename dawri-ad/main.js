import { clamp, seg, eo, hash } from '/core/lib.js';
import * as SP from './sprite.js';
import * as FM from './film.js';

const Q = new URLSearchParams(location.search), NOSUBS = Q.has('nosubs');
const world = document.getElementById('world'), spr = document.getElementById('spr'), hudEl = document.getElementById('hud');
const mbg = document.getElementById('mbg'), mbw = document.getElementById('mbw');

const words = await (await fetch('out/voice/words.json')).json();
const dur = await (await fetch('out/voice/dur.json')).json();
FM.build(words, dur);
window.DUR = FM.DUR;
window.EV = FM.EV;
window.SUBS = FM.SUBS.map(s => ({ t0: s.t0, t1: s.t1, text: s.text }));
window.T = FM.T; window.VO = FM.VO;

const tf = ([cx, cy, z]) => `translate(960px,540px) scale(${z}) translate(${-cx}px,${-cy}px)`;
function render(t) {
  const F = FM.frame(t), [cx, cy, z] = F.cam;
  world.innerHTML = `<div id="wall"></div>` + F.html;
  world.style.transform = tf(F.cam); spr.style.transform = tf(F.cam);
  const cache = {};
  const A = (key, fx = .5, fy = 0) => { const el = cache[key] !== undefined ? cache[key] : (cache[key] = world.querySelector(`[data-a="${key}"]`));
    if (!el) return null; const r = el.getBoundingClientRect(); return { x: (r.left + r.width * fx - 960) / z + cx, y: (r.top + r.height * fy - 540) / z + cy, w: r.width / z, h: r.height / z }; };
  // motion blur from camera speed: whips only
  const [px, py] = FM.camFinal(t - 1 / 30), vx = (cx - px) * z, vy = (cy - py) * z;
  const bx = Math.min(40, Math.max(0, Math.abs(vx) - 26) * .32), by = Math.min(40, Math.max(0, Math.abs(vy) - 26) * .32);
  mbg.setAttribute('stdDeviation', `${bx.toFixed(2)} ${by.toFixed(2)}`); mbw.style.filter = bx > .6 || by > .6 ? 'url(#mb)' : '';
  spr.innerHTML = sprites(F, t, A, z);
  hud(F, t, A, z, cx, cy);
}
function sprites(F, t, A, z) {
  let h = '';
  F.actors.forEach((act, i) => {
    if (!act) return; const c = act.eval(t, A); if (!c) return;
    h += SP.sprite(c);
    for (const j of act.jumps) if (t >= j.t1 && t < j.t1 + .4) { const L = act.eval(j.t1 + .001, A); if (L) h += SP.dust(L.x, L.y, seg(t, j.t1, j.t1 + .4), Math.max(3, L.px * .7), 6, j.t1 * 10); }
    if (F.fxf) h += F.fxf(A, c, i);
  });
  const burst = (x, y, k, n = 16) => { let s = ''; for (let i = 0; i < n; i++) { const a = hash(i * 2.3) * Math.PI * 2, r = (20 + hash(i * 7.7) * 80) * eo(k), sz = 8 * (1 - k * .6);
    s += `<div style="position:absolute;left:${x + Math.cos(a) * r}px;top:${y + Math.sin(a) * r * .7}px;width:${sz}px;height:${sz}px;background:${i % 3 ? SP.BODY : '#ffffff'};opacity:${1 - k}"></div>`; } return s; };
  if (F.burst && false) { const p = A('phoneB', .28, 0); if (p) h += burst(p.x, p.y - 30, F.burst); }
  if (F.burst2) { const p = A('phoneB', 1.3, .9); if (p) h += burst(p.x, p.y, F.burst2, 20); }
  const cu = F.cursor.eval(t, A);
  if (cu && (F.cursorOn !== false)) {
    if (cu.sp > 900) for (let i = 1; i <= 4; i++) { const g = F.cursor.eval(t - i * .012, A); if (g) h += cursorSvg(g.x, g.y, 1, cu.op * .16 * (5 - i) / 4, z); }
    if (cu.ring > 0) h += `<div class="ring" style="left:${cu.x - 26 * cu.ring / z - 4}px;top:${cu.y - 26 * cu.ring / z - 4}px;width:${52 * cu.ring / z + 8}px;height:${52 * cu.ring / z + 8}px;opacity:${(1 - cu.ring) * .9};border-width:${3 / z}px"></div>`;
    h += cursorSvg(cu.x, cu.y, cu.sc, cu.op, z);
  }
  return h;
}
const cursorSvg = (x, y, sc, op, z) => { const s = 1.6 * sc / z;
  return `<svg style="position:absolute;left:${x - 2 * s}px;top:${y - 2 * s}px;opacity:${op};filter:drop-shadow(0 ${2 / z}px ${3 / z}px rgba(0,0,0,.3))" width="${22 * s}" height="${30 * s}" viewBox="0 0 22 30"><path d="M2 2 L2 24 L7.5 18.5 L11 27 L15 25.2 L11.6 17 L19 17 Z" fill="#000" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>`; };

function hud(F, t, A, z, cx, cy) {
  const H = F.hud; let h = '';
  const scr = p => ({ x: (p.x - cx) * z + 960, y: (p.y - cy) * z + 540 });
  if (H.spot && H.spot.op > 0) { const p = A(H.spot.key, .5, H.spot.fy ?? .5); if (p) { const s = scr(p), r = H.spot.r || Math.max(p.w, p.h) * z * .62 + 50;
    h += `<div class="spot" style="opacity:${H.spot.op};background:radial-gradient(ellipse ${r * 1.7}px ${r * 1.15}px at ${s.x}px ${s.y}px, transparent 62%, rgba(8,14,28,.62) 100%)"></div>`; } }
  if (H.flash) h += `<div class="fade" style="background:${H.flashCol || '#fff'};opacity:${H.flash}"></div>`;
  if (H.step && !H.wipe) { const S = H.step, k = eo(S.k);
    h += S.big ? `<div class="step big" style="opacity:${k};transform:translateX(${(1 - k) * 60}px)"><i>${S.n}</i><div><small>Step ${S.n} of 4</small><b>${S.nm}</b></div></div>`
      : `<div class="chap"><b>${S.n} / 4</b>${S.nm}</div>`; }
  if (H.chap && !H.wipe) h += `<div class="chap"><b>${H.chap.no}</b>${H.chap.nm}</div>`;
  if (H.keys && H.keys.op > 0) h += `<div class="keys" style="opacity:${H.keys.op}"><i class="${H.keys.dn ? 'dn' : ''}${H.keys.ar ? ' ar' : ''}">${H.keys.keys[0]}</i><span>${H.keys.label}</span></div>`;
  if (H.cap && !NOSUBS && H.cap.op > 0) { const ar = /[؀-ۿ]/.test(H.cap.text);
    h += `<div class="cap" style="left:${H.cap.x}px;opacity:${H.cap.op};transform:translateX(-50%);${H.cap.x !== 960 ? 'max-width:760px' : ''}">${H.cap.text.replace(/(دوري)/, '<span class="ar" style="font-family:PlexAr">$1</span>')}</div>`; }
  if (H.wipe) h += wipe(H.wipe, t);
  if (t < .45) h += `<div class="fade" style="opacity:${1 - eo(t / .45)}"></div>`;
  if (t > FM.DUR - .5) h += `<div class="fade" style="opacity:${eo(seg(t, FM.DUR - .5, FM.DUR))}"></div>`;
  hudEl.innerHTML = h;
}
// chapter transition: pixel blocks in Dawri blues sweep across, the chapter name, the ticket runs across
function wipe(W, t) {
  const S = 60, cols = 32, rows = 18, p = W.p; let s = '<div class="wipe">';
  const pal = ['#1d5fbf', '#1a55ab', '#2468cc'];
  for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
    const d = (c / cols) * .55 + ((rows - r) / rows) * .2 + hash(c * 13.1 + r * 7.7) * .12;
    const a = clamp((p / .42 - d) / .18), b = clamp(((p - .55) / .42 - d) / .18), k = a * (1 - b);
    if (k <= 0) continue; const sz = S * k;
    s += `<b style="left:${c * S + (S - sz) / 2}px;top:${r * S + (S - sz) / 2}px;width:${sz + .5}px;height:${sz + .5}px;background:${pal[Math.floor(hash(c * 3.7 + r * 11.3) * 3)]}"></b>`;
  }
  const lo = clamp(Math.min((p - .3) / .12, (.82 - p) / .1));
  if (lo > 0) {
    s += `<div class="wlabel" style="opacity:${lo};transform:translateY(calc(-50% + ${(1 - lo) * 16}px))"><div class="no">${W.no}</div><div class="nm">${W.nm}</div></div>`;
    const x = 300 + p * 1320; s += SP.sprite({ x, y: 800, px: 7, legs: Math.floor(t * 12) % 2 ? 'walkA' : 'walkB', op: lo });
  }
  return s + '</div>';
}
window.render = render;
await document.fonts.load('16px Plex'); await document.fonts.load('600 16px Plex'); await document.fonts.load('700 16px Plex'); await document.fonts.load('500 16px Plex');
await document.fonts.load('16px PlexAr', 'دوري'); await document.fonts.load('600 16px PlexAr', 'دوري');
render(+(Q.get('t') || 0));
window.READY = true;
