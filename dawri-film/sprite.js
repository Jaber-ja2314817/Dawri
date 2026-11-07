// "Tik", an original pixel ticket stub: Dawri's queue ticket made visible. 16×12 square pixels.
// Body = a ticket with a notch on each side and a perforation column; eyes do the acting.
export const BODY = '#FFC21A', SHADE = '#DB9C00', EYE = '#0A0A0A';

// returns [[c, r, kind]]; kind 1 body, 2 eye, 3 shade
export function grid({ eyes = 'n', arms = 'down', legs = 'stand', ghost = false } = {}) {
  const P = new Map(), put = (c, r, v = 1) => P.set(c + ',' + r, v), del = (c, r) => P.delete(c + ',' + r);
  for (let r = 0; r < 9; r++) for (let c = 2; c <= 13; c++) put(c, r);
  del(2, 0); del(13, 0);                                 // rounded corners
  for (const r of [3, 4, 5]) { del(2, r); }               // notches
  for (const r of [3, 4, 5]) { del(13, r); }
  del(3, 4); del(12, 4);
  for (const r of [1, 3, 5, 7]) put(10, r, 3);           // perforation
  for (let c = 3; c <= 12; c++) put(c, 8, 3);            // bottom shade row
  if (arms === 'up') for (const r of [0, 1, 2]) { put(0, r); put(1, r); put(14, r); put(15, r); }
  else if (arms === 'wave') { put(0, 6); put(1, 6); for (const r of [0, 1, 2]) { put(14, r); put(15, r); } }
  else if (arms === 'down') for (const c of [0, 1, 14, 15]) put(c, 6);
  const L = { stand: [[5, 2], [9, 2]], walkA: [[5, 2], [9, 1]], walkB: [[5, 1], [9, 2]], tuck: [[5, 1], [9, 1]], none: [] }[legs];
  for (const [c, h] of L) for (let r = 9; r < 9 + h; r++) put(c, r, 1);
  const E = { n: [[5, 2], [5, 3], [8, 2], [8, 3]], r: [[6, 2], [6, 3], [9, 2], [9, 3]], l: [[4, 2], [4, 3], [7, 2], [7, 3]],
    u: [[5, 1], [5, 2], [8, 1], [8, 2]], d: [[5, 4], [5, 5], [8, 4], [8, 5]], blink: [[5, 3], [8, 3]],
    happy: [[4, 3], [5, 2], [6, 3], [7, 3], [8, 2], [9, 3]], wide: [[5, 1], [5, 2], [5, 3], [8, 1], [8, 2], [8, 3]],
    shut: [[4, 3], [5, 3], [6, 3], [7, 3], [8, 3], [9, 3]], worry: [[4, 2], [5, 3], [8, 3], [9, 2], [5, 4], [8, 4]] }[eyes] || [];
  for (const [c, r] of E) put(c, r, 2);
  return [...P].map(([k, v]) => { const [c, r] = k.split(',').map(Number); return [c, r, v]; });
}
// x,y = midpoint under the feet (world coords); px = pixel side
export function sprite({ x, y, px = 6, flip = false, sq = 0, rot = 0, op = 1, shadow = 0, ghost = false, ...pose }) {
  const G = grid(pose); let s = '';
  for (let [c, r, v] of G) {
    if (flip) c = 15 - c;
    const fill = ghost ? (v === 2 ? '#ffffff' : 'none') : (v === 2 ? EYE : v === 3 ? SHADE : BODY);
    const stroke = ghost && v !== 2 ? ' stroke="#ffffff" stroke-width=".18" stroke-dasharray=".35 .25"' : '';
    s += `<rect x="${c}" y="${r}" width="1.04" height="1.04" fill="${fill}"${stroke}/>`;
  }
  const sy = 1 - sq, sx = 1 + sq * .7, w = 16 * px * sx, h = 11 * px * sy;
  const sh = shadow > 0 ? `<div style="position:absolute;left:${x - 6 * px}px;top:${y - px * .35}px;width:${12 * px}px;height:${px * .7}px;border-radius:50%;background:rgba(0,0,0,${.18 * shadow * op})"></div>` : '';
  return sh + `<svg class="px" viewBox="0 0 16 11" width="${w}" height="${h}" style="left:${x - w / 2}px;top:${y - h}px;opacity:${op};transform:rotate(${rot}rad);transform-origin:50% 60%" shape-rendering="crispEdges">${s}</svg>`;
}
export function pixart(rows, { x, y, px = 6, pal, op = 1 }) {
  let s = ''; rows.forEach((row, r) => [...row].forEach((ch, c) => { if (pal[ch]) s += `<rect x="${c}" y="${r}" width="1.04" height="1.04" fill="${pal[ch]}"/>`; }));
  const W = rows[0].length, H = rows.length;
  return `<svg class="px" viewBox="0 0 ${W} ${H}" width="${W * px}" height="${H * px}" style="left:${x}px;top:${y}px;opacity:${op}" shape-rendering="crispEdges">${s}</svg>`;
}
export const BANG = (x, y, px = 6, op = 1) => pixart(['.kkk.', 'krrrk', 'krrrk', 'krrrk', '.krk.', '.krk.', '..k..', '.krk.', '.kkk.'], { x, y, px, op, pal: { r: '#ef4444', k: EYE } });
export const QMARK = (x, y, px = 6, op = 1) => pixart(['.kkkk.', 'kwwwwk', 'kwkkwk', '.k.kwk', '..kwk.', '..kwk.', '..kk..', '..kwk.', '..kkk.'], { x, y, px, op, pal: { w: '#fff', k: EYE } });
export const SPARK = (x, y, px = 6, col = '#FFC21A', op = 1) => pixart(['..y..', '..y..', 'yy.yy', '..y..', '..y..'], { x: x - 2.5 * px, y: y - 2.5 * px, px, op, pal: { y: col } });
export const CHECK = (x, y, px = 6, op = 1) => pixart(['.....g', '....gg', 'g..gg.', 'gggg..', '.gg...'], { x, y, px, op, pal: { g: '#2e7d32' } });
export const SWEAT = (x, y, px = 5, op = 1) => pixart(['.b.', 'bbb', 'bbb', '.b.'], { x, y, px, op, pal: { b: '#7FB6E8' } });
export const ZZZ = (x, y, px = 5, op = 1) => pixart(['kkkk', '..k.', '.k..', 'kkkk'], { x, y, px, op, pal: { k: '#ffffff' } });
export function dust(x, y, t, px = 5, n = 6, seed = 1, col = '#cfd6e0') {
  if (t <= 0 || t >= 1) return ''; let s = '';
  for (let i = 0; i < n; i++) {
    const side = i % 2 ? 1 : -1, k = (i >> 1) + 1, e = 1 - Math.pow(1 - t, 2);
    const dx = side * (16 + k * 15 + ((seed * 7 + i * 13) % 9)) * e, dy = -(8 + k * 5) * Math.sin(Math.PI * t * .9);
    const sz = px * (1 - t * .7);
    s += `<div style="position:absolute;left:${x + dx - sz / 2}px;top:${y + dy - sz}px;width:${sz}px;height:${sz}px;background:${col};opacity:${1 - t}"></div>`;
  }
  return s;
}
