// Dark Tech Keynote engine for Dawri
// Implements the documented API from styles/dark-keynote/STYLE.md
import { clamp, lerp, seg, back, spring, mulberry, hash } from '/core/lib.js';

export const W = 1920, H = 1080;

let _accent = '#2563eb';
let _accentR = 37, _accentG = 99, _accentB = 235;

export function setAccent(hex) {
  _accent = hex;
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  _accentR = r; _accentG = g; _accentB = b;
}
export const accentHex = () => _accent;
export const accentRgba = (a) => `rgba(${_accentR},${_accentG},${_accentB},${a})`;

// ── Colour helpers ──────────────────────────────────────────────────────────
export const rgba = (r, g, b, a = 1) => `rgba(${r},${g},${b},${a})`;
export const font = (px, wt = 400, fam = 'IBM Plex Sans') => `${wt} ${px}px/${px * 1.2}px "${fam}", "IBM Plex Sans Arabic", "Noto Sans Arabic"`;
export const mono = (px, wt = 400) => `${wt} ${px}px "JetBrains Mono"`;

// ── bg: near-black stage with radial lift ───────────────────────────────────
export function bg(g, { lift = '#151822', cool = '#3b4cca', dark = '#0a0c0f' } = {}) {
  g.fillStyle = dark;
  g.fillRect(0, 0, W, H);
  // radial lift at upper centre
  const liftGrad = g.createRadialGradient(W / 2, H * 0.1, 0, W / 2, H * 0.1, W * 0.6);
  liftGrad.addColorStop(0, 'rgba(21,24,34,0.9)');
  liftGrad.addColorStop(1, 'rgba(21,24,34,0)');
  g.fillStyle = liftGrad;
  g.fillRect(0, 0, W, H);
  // cool glow off-centre upper right
  const coolGrad = g.createRadialGradient(W * 0.72, H * 0.18, 0, W * 0.72, H * 0.18, W * 0.4);
  coolGrad.addColorStop(0, `rgba(59,76,202,${0.08})`);
  coolGrad.addColorStop(1, 'rgba(59,76,202,0)');
  g.fillStyle = coolGrad;
  g.fillRect(0, 0, W, H);
}

// ── grid: hairline grid ─────────────────────────────────────────────────────
export function grid(g, { ox = 0, oy = 0, scale = 1, module = 48, alpha = 0.032, rect = null } = {}) {
  const m = module * scale;
  const [rx = 0, ry = 0, rw = W, rh = H] = rect ?? [0, 0, W, H];
  g.save();
  g.beginPath();
  g.rect(rx, ry, rw, rh);
  g.clip();
  const startX = ox % m;
  const startY = oy % m;
  let xi = 0;
  for (let x = startX; x <= W; x += m, xi++) {
    g.strokeStyle = `rgba(255,255,255,${xi % 4 === 0 ? alpha * 1.9 : alpha})`;
    g.lineWidth = 1;
    g.beginPath();
    g.moveTo(x, 0); g.lineTo(x, H);
    g.stroke();
  }
  let yi = 0;
  for (let y = startY; y <= H; y += m, yi++) {
    g.strokeStyle = `rgba(255,255,255,${yi % 4 === 0 ? alpha * 1.9 : alpha})`;
    g.lineWidth = 1;
    g.beginPath();
    g.moveTo(0, y); g.lineTo(W, y);
    g.stroke();
  }
  g.restore();
}

// ── glow: soft light pool ───────────────────────────────────────────────────
export function glow(g, x, y, r, color, a = 1) {
  // Convert any color format to rgba with the given alpha
  let c;
  if (color.startsWith('rgba(')) {
    c = color.replace(/,\s*[\d.]+\)$/, `,${a})`);
  } else if (color.startsWith('rgb(')) {
    c = color.replace('rgb(', 'rgba(').replace(')', `,${a})`);
  } else if (color.startsWith('#') && color.length === 7) {
    const rv = parseInt(color.slice(1,3), 16);
    const gv = parseInt(color.slice(3,5), 16);
    const bv = parseInt(color.slice(5,7), 16);
    c = `rgba(${rv},${gv},${bv},${a})`;
  } else {
    c = color;
  }
  const gr = g.createRadialGradient(x, y, 0, x, y, r);
  gr.addColorStop(0, c);
  gr.addColorStop(1, 'rgba(0,0,0,0)');
  g.fillStyle = gr;
  g.fillRect(x - r, y - r, r * 2, r * 2);
}

// ── vignette: corner falloff ────────────────────────────────────────────────
export function vignette(g, a = 0.52) {
  const gr = g.createRadialGradient(W / 2, H / 2, H * 0.35, W / 2, H / 2, H * 0.9);
  gr.addColorStop(0, 'rgba(0,0,0,0)');
  gr.addColorStop(1, `rgba(0,0,0,${a})`);
  g.fillStyle = gr;
  g.fillRect(0, 0, W, H);
}

// ── panel: rounded dark UI surface ─────────────────────────────────────────
export function panel(g, x, y, w, h, { r = 14, fill = '#12151c', shadow = true, cheap = false } = {}) {
  g.save();
  if (shadow && !cheap) {
    g.shadowColor = 'rgba(0,0,0,0.6)';
    g.shadowBlur = 32;
    g.shadowOffsetY = 8;
  }
  // main fill
  g.beginPath();
  g.roundRect(x, y, w, h, r);
  g.fillStyle = fill;
  g.fill();
  g.shadowColor = 'transparent';
  g.shadowBlur = 0;
  g.shadowOffsetY = 0;
  // 1px border
  g.strokeStyle = 'rgba(255,255,255,0.08)';
  g.lineWidth = 1;
  g.stroke();
  // 1px inner top highlight
  g.beginPath();
  g.roundRect(x + 1, y + 1, w - 2, 1, 0);
  g.fillStyle = 'rgba(255,255,255,0.07)';
  g.fill();
  g.restore();
}

// ── litShape: draw any shape in this style ──────────────────────────────────
export function litShape(g, path2d, { accent: useAccent = false, color = null, glowR = 0, sweep = -1, bbox = [0, 0, W, H] } = {}) {
  g.save();
  const [bx, by, bw, bh] = bbox;
  if (useAccent) {
    // Glowing accent fill
    g.fillStyle = _accent;
    g.fill(path2d);
    if (glowR > 0) {
      g.shadowColor = accentRgba(0.5);
      g.shadowBlur = glowR;
      g.fill(path2d);
      g.shadowBlur = 0;
    }
  } else if (sweep >= 0) {
    // Dark surface with moving light band
    g.fillStyle = color ?? '#1a1e28';
    g.fill(path2d);
    // light band
    const bandX = bx + sweep * (bw + 700) - 350;
    const bandGrad = g.createLinearGradient(bandX - 350, 0, bandX + 350, 0);
    bandGrad.addColorStop(0, 'rgba(255,255,255,0)');
    bandGrad.addColorStop(0.4, 'rgba(255,255,255,0.08)');
    bandGrad.addColorStop(0.5, 'rgba(255,255,255,0.14)');
    bandGrad.addColorStop(0.6, 'rgba(255,255,255,0.08)');
    bandGrad.addColorStop(1, 'rgba(255,255,255,0)');
    g.clip(path2d);
    g.fillStyle = bandGrad;
    g.fillRect(bx, by, bw, bh);
  } else {
    // Static dark lit surface
    g.fillStyle = color ?? '#1a1e28';
    g.fill(path2d);
    // rim light on top edge
    g.strokeStyle = 'rgba(255,255,255,0.09)';
    g.lineWidth = 1;
    g.stroke(path2d);
  }
  g.restore();
}

// ── scramble: glyph noise → number lock ─────────────────────────────────────
const GLYPHS = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#%&-+?';
export function scramble(g, text, x, y, t, locks, {
  px = 48, fam = 'Inter Tight', color = '#e8ecf2', tracking = -0.045, weight = 600
} = {}) {
  const rng = mulberry(42);
  const chars = text.split('');
  g.save();
  g.font = `${weight} ${px}px "${fam}"`;
  g.fillStyle = color;
  g.textBaseline = 'alphabetic';
  let cx = x;
  for (let i = 0; i < chars.length; i++) {
    const lockT = locks[i] ?? 0;
    let ch;
    if (t >= lockT) {
      ch = chars[i];
    } else {
      const fi = Math.floor(t * 24) + i * 7;
      ch = GLYPHS[Math.abs(Math.floor(hash(fi) * GLYPHS.length)) % GLYPHS.length];
    }
    const advance = px * (1 + tracking);
    if (t < lockT) {
      // Smear: draw 3 copies shifted vertically
      g.globalAlpha = 0.3;
      g.fillText(ch, cx, y - px * 0.3);
      g.fillText(ch, cx, y + px * 0.3);
      g.globalAlpha = 1;
    }
    // Landing bounce
    const bounce = t >= lockT ? Math.max(0, 1 - spring((t - lockT) * 8)) * px * 0.1 : 0;
    if (t >= lockT && chars[i] !== '-') {
      // accent glow on locked digits
      g.shadowColor = accentRgba(0.4);
      g.shadowBlur = 12;
    }
    g.fillText(ch, cx, y + bounce);
    g.shadowBlur = 0;
    cx += advance;
    rng();
  }
  g.restore();
  return cx - x; // total width
}

// ── lightReveal: soft band sweeps across a source canvas ────────────────────
export function lightReveal(g, src, x, y, w, h, p, {
  base = 0.07, soft = 700, band = 360, glint = 0.18, angle = 0
} = {}) {
  g.save();
  // dark base (what's not yet lit)
  g.globalAlpha = base;
  g.drawImage(src, x, y, w, h);
  g.globalAlpha = 1;
  // compute light front position
  const frontX = x + p * (w + soft * 2) - soft;
  // lit area (left of front)
  g.save();
  g.beginPath();
  g.rect(x, y, Math.max(0, frontX - x), h);
  g.clip();
  g.drawImage(src, x, y, w, h);
  g.restore();
  // soft front gradient (the glow riding the front)
  const bandGrad = g.createLinearGradient(frontX - band, y, frontX + band * 0.3, y);
  bandGrad.addColorStop(0, 'rgba(255,255,255,0)');
  bandGrad.addColorStop(0.6, `rgba(255,255,255,${glint * 0.5})`);
  bandGrad.addColorStop(0.85, `rgba(255,255,255,${glint})`);
  bandGrad.addColorStop(1, 'rgba(255,255,255,0)');
  g.save();
  g.beginPath();
  g.rect(x, y, w, h);
  g.clip();
  g.fillStyle = bandGrad;
  g.fillRect(frontX - band, y, band * 1.3, h);
  g.restore();
  g.restore();
}

// ── toast: caption pill ─────────────────────────────────────────────────────
export function toast(g, text, a = 1, { dense = false, y: ty = null } = {}) {
  if (a <= 0 || !text) return;
  const maxW = W - 160;  // 80px margin each side
  const padX = 24, padY = 14;
  // Auto-scale font to fit within maxW
  let px = 40;
  g.save();
  g.font = `500 ${px}px "Inter"`;
  let tw = g.measureText(text).width;
  if (tw + padX * 2 + 20 > maxW) {
    px = Math.max(18, Math.floor(px * maxW / (tw + padX * 2 + 20)));
    g.font = `500 ${px}px "Inter"`;
    tw = g.measureText(text).width;
  }
  const pw = Math.min(tw + padX * 2 + 20, maxW);
  const ph = px + padY * 2;
  const bx = (W - pw) / 2;
  const by = ty ?? (H - ph - 48);
  // rise + fade
  const ry = by + (1 - a) * 12;
  g.globalAlpha = a;
  // pill background
  g.beginPath();
  g.roundRect(bx, ry, pw, ph, ph / 2);
  g.fillStyle = 'rgba(10,12,15,0.82)';
  g.fill();
  g.strokeStyle = 'rgba(255,255,255,0.09)';
  g.lineWidth = 1;
  g.stroke();
  // accent dot
  g.beginPath();
  g.arc(bx + padX + 5, ry + ph / 2, 5, 0, Math.PI * 2);
  g.fillStyle = _accent;
  g.fill();
  // text
  g.fillStyle = '#e8ecf2';
  g.textBaseline = 'middle';
  g.textAlign = 'left';
  g.fillText(text, bx + padX + 18, ry + ph / 2);
  g.globalAlpha = 1;
  g.restore();
}

// ── camera: 2.5D camera ─────────────────────────────────────────────────────
export function camera({ x = W / 2, y = H / 2, zoom = 1, rot = 0, sx = W / 2, sy = H / 2 } = {}) {
  return {
    apply(g, z = 0) {
      const s = zoom * (z === 0 ? 1 : 1 / (1 / zoom - z));
      g.translate(sx, sy);
      g.rotate(rot);
      g.scale(s / zoom, s / zoom);
      g.translate(-x, -y);
    },
    proj(wx, wy, z = 0) {
      const s = zoom * (z === 0 ? 1 : 1 / (1 / zoom - z));
      const dx = (wx - x) * s, dy = (wy - y) * s;
      return [sx + dx, sy + dy, s / zoom];
    }
  };
}

// ── trail: fading light trail ───────────────────────────────────────────────
export function trail(g, pts, { color = null, width = 8 } = {}) {
  if (pts.length < 2) return;
  g.save();
  for (let i = 1; i < pts.length; i++) {
    const a = i / pts.length;
    g.beginPath();
    g.moveTo(pts[i - 1][0], pts[i - 1][1]);
    g.lineTo(pts[i][0], pts[i][1]);
    g.strokeStyle = color ?? accentRgba(a * 0.8);
    g.lineWidth = width * a;
    g.lineCap = 'round';
    g.stroke();
  }
  g.restore();
}

// ── caret: cursor ───────────────────────────────────────────────────────────
export function caret(g, x, y, h = 60, { sx = 1, sy = 1, on = true, glow: glowAmt = 0, color = null } = {}) {
  if (!on) return;
  const c = color ?? _accent;
  const w = h * 0.1 * sx;
  g.save();
  if (glowAmt > 0) {
    g.shadowColor = accentRgba(glowAmt);
    g.shadowBlur = 20;
  }
  g.fillStyle = c;
  g.fillRect(x - w / 2, y - h * sy / 2, w, h * sy);
  g.restore();
}

// ── flyPose: snap flight with overshoot ─────────────────────────────────────
export function flyPose(from, to, p) {
  const t = back(clamp(p), 1.3);
  return {
    x: lerp(from.x, to.x, t),
    y: lerp(from.y, to.y, t),
    w: lerp(from.w ?? to.w, to.w, t),
    h: lerp(from.h ?? to.h, to.h, t),
    a: lerp(from.a ?? 0, to.a ?? 1, clamp(p / 0.3))
  };
}

// ── sparklePath: four-point star ─────────────────────────────────────────────
export function sparklePath(cx, cy, r, k = 0.2, rot = 0) {
  const p = new Path2D();
  for (let i = 0; i < 8; i++) {
    const a = rot + i * Math.PI / 4;
    const len = i % 2 === 0 ? r : r * k;
    const px = cx + Math.cos(a) * len;
    const py = cy + Math.sin(a) * len;
    i === 0 ? p.moveTo(px, py) : p.lineTo(px, py);
  }
  p.closePath();
  return p;
}

// ── Helpers ──────────────────────────────────────────────────────────────────
export function buf(name, w = W, h = H) {
  const c = new OffscreenCanvas(w, h);
  return { canvas: c, g: c.getContext('2d') };
}

// draw rounded rect helper (for older canvas engines without roundRect)
export function rr(g, x, y, w, h, r) {
  if (g.roundRect) { g.roundRect(x, y, w, h, r); return; }
  g.moveTo(x + r, y);
  g.lineTo(x + w - r, y); g.quadraticCurveTo(x + w, y, x + w, y + r);
  g.lineTo(x + w, y + h - r); g.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  g.lineTo(x + r, y + h); g.quadraticCurveTo(x, y + h, x, y + h - r);
  g.lineTo(x, y + r); g.quadraticCurveTo(x, y, x + r, y);
}

// ── UI Kit ───────────────────────────────────────────────────────────────────
// Rounded window
export function windowBox(g, x, y, w, h, { title = '', r = 14, fill = '#12151c' } = {}) {
  panel(g, x, y, w, h, { r, fill });
  if (title) {
    g.save();
    g.font = font(13, 500, 'JetBrains Mono');
    g.fillStyle = '#5c6272';
    g.textBaseline = 'middle';
    g.textAlign = 'center';
    g.fillText(title, x + w / 2, y + 20);
    g.restore();
  }
}

// A single row in an intake/handoff table
export function tableRow(g, x, y, w, h, label, value, { labelColor = '#5c6272', valColor = '#e8ecf2', accent: isAccent = false, separatorColor = 'rgba(255,255,255,0.05)' } = {}) {
  g.save();
  g.strokeStyle = separatorColor;
  g.lineWidth = 1;
  g.beginPath(); g.moveTo(x, y + h); g.lineTo(x + w, y + h); g.stroke();
  g.font = font(15, 400, 'JetBrains Mono');
  g.textBaseline = 'middle';
  g.fillStyle = labelColor;
  g.textAlign = 'left';
  g.fillText(label, x + 16, y + h / 2);
  g.textAlign = 'right';
  g.fillStyle = isAccent ? _accent : valColor;
  if (isAccent) {
    g.shadowColor = accentRgba(0.4);
    g.shadowBlur = 8;
  }
  g.fillText(value, x + w - 16, y + h / 2);
  g.shadowBlur = 0;
  g.restore();
}

// Pill / tag (like penicillin allergy)
export function pill(g, x, y, text, { bg: bgColor = '#f59e0b', fg = '#0a0c0f', r = 20, px: padX = 12, py: padY = 5, fontPx = 14 } = {}) {
  g.save();
  g.font = font(fontPx, 600);
  const tw = g.measureText(text).width;
  const pw = tw + padX * 2, ph = fontPx + padY * 2;
  g.beginPath();
  g.roundRect(x, y, pw, ph, r);
  g.fillStyle = bgColor;
  g.fill();
  g.fillStyle = fg;
  g.textBaseline = 'middle';
  g.textAlign = 'left';
  g.fillText(text, x + padX, y + ph / 2);
  g.restore();
  return { w: pw, h: ph };
}

// Architecture node box
export function archNode(g, x, y, w, h, label, sublabel = '', { active = false } = {}) {
  panel(g, x, y, w, h, { r: 10, fill: active ? '#1a1e28' : '#111318' });
  if (active) {
    g.save();
    g.strokeStyle = accentRgba(0.5);
    g.lineWidth = 1;
    g.beginPath();
    g.roundRect(x, y, w, h, 10);
    g.stroke();
    g.restore();
  }
  g.save();
  g.font = font(15, active ? 600 : 400, 'JetBrains Mono');
  g.fillStyle = active ? _accent : '#8a94a8';
  g.textBaseline = 'middle';
  g.textAlign = 'center';
  g.fillText(label, x + w / 2, y + h / 2 - (sublabel ? 10 : 0));
  if (sublabel) {
    g.font = font(12, 400, 'JetBrains Mono');
    g.fillStyle = '#5c6272';
    g.fillText(sublabel, x + w / 2, y + h / 2 + 12);
  }
  g.restore();
}

// Arrow between two boxes
export function arrow(g, x1, y1, x2, y2, { color = 'rgba(255,255,255,0.15)', bend = 0 } = {}) {
  g.save();
  g.strokeStyle = color;
  g.lineWidth = 1;
  g.beginPath();
  if (bend === 0) {
    g.moveTo(x1, y1); g.lineTo(x2, y2);
  } else {
    const mx = (x1 + x2) / 2;
    g.moveTo(x1, y1);
    g.bezierCurveTo(mx + bend, y1, mx - bend, y2, x2, y2);
  }
  g.stroke();
  // arrowhead
  const a = Math.atan2(y2 - y1, x2 - x1);
  const as = 8;
  g.beginPath();
  g.moveTo(x2, y2);
  g.lineTo(x2 - as * Math.cos(a - 0.4), y2 - as * Math.sin(a - 0.4));
  g.lineTo(x2 - as * Math.cos(a + 0.4), y2 - as * Math.sin(a + 0.4));
  g.closePath();
  g.fillStyle = color;
  g.fill();
  g.restore();
}
