"""Dawri — score, foley and voice → out/mix.wav. Everything is timed from events.json (exported from the page), so sound and picture share one clock.
Two resolutions: a hi-fi band (Salamander piano, Karoryfer upright bass, MuldjordKit, VCSL vibraphone and glockenspiel) is the world;
a square-wave chip voice is the ticket mascot. 96 BPM, D major (Dmaj9 – Bm9 – Gmaj7 – A6sus)."""
import sys, os, json, numpy as np, soundfile as sf, soxr
LIB = os.environ.get('LIB') or os.path.expanduser('~/lemo-opuscar')
sys.path.insert(0, LIB)
from core.audio.sfx import SR, bp, lp, hp, noise, add, compress, limit, click as sclick
from core.audio import sampler as S
HERE = os.path.dirname(os.path.abspath(__file__))
EVJ = json.load(open(os.path.join(HERE, 'events.json'), encoding='utf-8')); E = EVJ['ev']; DUR = EVJ['dur']
rng = np.random.default_rng(11); S.seed(11)
NS = int((DUR + 2) * SR); B = 60 / 96
def tt(d): return np.arange(int(round(d * SR))) / SR
def db(x): return 10 ** (x / 20)
def all_(tp): return [e for e in E if e['type'] == tp]
def first(tp): return all_(tp)[0]['t']
VO = {e['id']: e['t'] for e in all_('vo')}
VD = json.load(open(os.path.join(HERE, 'out', 'voice', 'dur.json')))
def VE(i): return VO[i] + VD[i]
WIPES = [e['t'] for e in all_('wipe')]
C2, C4, C5, C6 = [w + .62 for w in WIPES]
T_TITLE, T_SPLIT, T_RED, T_FINAL = first('title'), first('burst'), first('redalert'), first('final')
T_WHIP = all_('whoosh')[0]['t']; T_PUSH = VE('v33') + .25; T_END = VO['v34'] - .15
NOTES = sorted(all_('note'), key=lambda e: e['t'])

def pulse(f, d, duty=.25, vol=1., att=.003, rel=.05, slide=None):
    t = tt(d); fr = np.full(len(t), float(f)) if slide is None else f * (slide ** (t / d))
    ph = np.cumsum(fr) / SR; x = np.zeros(len(t))
    for k in range(1, 22):
        m = fr * k < 16000; x += m * (np.sin(np.pi * k * duty) / k) * np.cos(2 * np.pi * k * (ph - duty / 2))
    e = np.minimum(1, t / att) * np.clip(np.minimum(1, (d - t) / rel), 0, 1)
    return (x * e * vol * .5).astype(np.float32)
def crush(x, bits=5): q = 2 ** bits; return (np.round(x * q) / q).astype(np.float32)
def nz(d, lo, hi, vol=1., tau=None):
    x = bp(rng.standard_normal(int(d * SR)), lo, hi) * vol
    if tau: x *= np.exp(-tt(d)[:len(x)] / tau)
    return x.astype(np.float32)
hz = S.hz

# ═════════ score
EVN = []
def N(t, inst, p, d, v, pan=0., g=1.):
    if t < DUR - .05: EVN.append((t, inst, p, d, v, pan, g))
PROG = [('D2', ['F#3', 'A3', 'C#4', 'E4']), ('B1', ['F#3', 'A3', 'C#4', 'D4']), ('G1', ['F#3', 'B3', 'D4', 'E4']), ('A1', ['E3', 'F#3', 'B3', 'D4'])]
def chord(t, t0): return PROG[int(np.floor((t - t0) / (4 * B) + 1e-6)) % 4]

# 1 · cold open: solo piano, sparse eighth-note arpeggio, until the gap
ARP = ['D4', 'A4', 'E5', 'F#5', 'E5', 'A4', 'C#5', 'A4']
t = .5; i = 0; GAP_IN = VE('v05') + .2
while t < GAP_IN:
    root, ch = chord(t, .5); v = .26 + .06 * np.sin(i * .7)
    if i % 8 == 0: N(t, 'piano', ch[0], 2.4, .3, -.15); N(t, 'piano', ch[2], 2.4, .26, -.1)
    N(t, 'piano', S.name(S.midi(ch[i % 4]) + 12), .5, v, .15); t += B / 2; i += 1
for k in range(4): N(GAP_IN - .1 + k * .02, 'piano', ['D3', 'A3', 'E4', 'F#4'][k], 3.5, .2, 0)       # last chord rings into the silence

# 2 · the title: chip arpeggio + glockenspiel, then the band enters with chapter 2
for k, p in enumerate(['D5', 'F#5', 'A5', 'C#6', 'E6', 'A6']):
    N(T_TITLE + k * .07, 'glockenspiel', p, 1.2, .45, .25)
N(T_TITLE, 'vibraphone', 'D4', 3, .45, -.2); N(T_TITLE, 'vibraphone', 'A4', 3, .4, .2); N(T_TITLE, 'jazz_bass', 'D2', 2.5, .55, 0)

def groove(t0, t1, kit=True, piano=True, vib=False, light=False, anchor=None):
    a = C2 if anchor is None else anchor
    n0 = int(np.ceil((t0 - a) / B)); n1 = int(np.floor((t1 - a) / B))
    for n in range(n0, n1):
        t = a + n * B; bi = n % 4; root, ch = chord(t + 1e-3, a)
        if kit:
            if bi == 0 or (bi == 2 and not light): N(t, 'drum_kit', 'kick_drum_left', .3, .55 if light else .7, 0)
            if bi in (1, 3) and not light: N(t, 'drum_kit', 'snare_rest_1', .25, .45, .05)
            for h in (0, .5): N(t + h * B, 'drum_kit', 'hi_hat_closed', .1, (.26 if h == 0 else .17), .3)
        N(t, 'jazz_bass', root if bi != 3 else S.name(S.midi(root) + 7), .5, .62, 0)
        if bi == 2: N(t + B / 2, 'jazz_bass', S.name(S.midi(root) + 12), .25, .4, 0)
        if piano:
            if bi == 0: [N(t + j * .012, 'piano', p, 1.7, .34, -.2) for j, p in enumerate(ch)]
            elif bi == 2: [N(t + B / 2, 'piano', p, .3, .24, -.2) for p in ch[1:]]
        if vib and bi == 0: N(t + B, 'vibraphone', S.name(S.midi(ch[-1]) + 12), 1.2, .3, .35)

groove(C2 - .2, T_WHIP - B, vib=False)
for k, tm in enumerate(['tom_1', 'tom_2', 'tom_3', 'tom_4']): N(T_WHIP - B + k * B / 4, 'drum_kit', tm, .3, .45 + .08 * k, (k - 1.5) * .3)
N(T_WHIP + .45, 'drum_kit', 'crash_left', 2.2, .5, -.2)
groove(T_WHIP + .45, T_SPLIT - .1, vib=True)
# 3 · two paths: drums drop; piano (left, Ahmed) and chip (right, Ravi) trade; a low pad builds and cuts on the red screen
N(T_SPLIT, 'glockenspiel', 'A6', 1, .4, 0)
t = T_SPLIT + .4; k = 0
while t < T_RED - .8:
    root, ch = chord(t, T_SPLIT)
    N(t, 'piano', ch[k % 4], .6, .3, -.75); N(t, 'jazz_bass', root, 1.0, .4, -.3)
    t += B * 2; k += 1
# 4 · safety: no drums; long vibraphone + piano pads; amber row: a muted minor colour
t = C4 + .3
while t < WIPES[2] - .2:
    root, ch = chord(t, C4)
    [N(t + j * .03, 'piano', p, 4 * B, .22, -.1) for j, p in enumerate(ch)]
    N(t, 'vibraphone', S.name(S.midi(ch[-1]) + 12), 4 * B, .26, .3); N(t, 'jazz_bass', root, 3 * B, .4, 0)
    t += 4 * B
T_AMB = first('amber')
[N(T_AMB + j * .03, 'piano', p, 4, .26, 0) for j, p in enumerate(['B2', 'F#3', 'A3', 'D4', 'G4'])]
# 5 · stack: the band again, light
groove(C5 + .2, WIPES[3] - B, light=True, vib=True, anchor=C5)
# 6 · aim: piano alone, subtracting; then near-silence, then the end card
t = C6 + .2
while t < T_PUSH:
    root, ch = chord(t, C6); [N(t + j * .02, 'piano', p, 4 * B, .28, -.1) for j, p in enumerate(ch)]; N(t, 'jazz_bass', root, 3 * B, .45, 0); t += 4 * B
for k, e in enumerate(NOTES):
    p = ['A5', 'D6', 'F#6'][k]; N(e['t'] + .02, 'glockenspiel', p, 1.4, .45, .1)
FIN = NOTES[-1]['t'] + .1
N(FIN, 'jazz_bass', 'D2', 4, .6, 0)
for j, p in enumerate(['D3', 'A3', 'E4', 'F#4', 'C#5', 'A5']): N(FIN + j * .035, 'piano', p, 5, .42, -.15 + j * .06)
N(FIN, 'vibraphone', 'F#5', 4, .3, .3)
band = S.render(EVN, dur=DUR + 2, master=False)
band = np.asarray(band, np.float32)
if len(band) < NS: band = np.pad(band, ((0, NS - len(band)), (0, 0)))
band = band[:NS]

chip = np.zeros((NS, 2), np.float32)
THEME = [('D6', 0, .5), ('F#6', .5, .5), ('A6', 1, 1), ('E6', 2, .5), ('F#6', 2.5, 1.5)]
def theme(t0, vol=.3, pan=.2):
    for p, o, d in THEME: add(chip, pulse(hz(p), d * B / 2 * .9, .25, vol), t0 + o * B / 2, 1, pan)
theme(T_TITLE + .9)
for k, e in enumerate(NOTES): add(chip, pulse(hz(['A5', 'D6', 'F#6'][k]), .22, .25, .2), e['t'] + .02, 1, .1)
# split duet: the chip answers the piano on the right
t = T_SPLIT + .4 + B; k = 0
while t < T_RED - .8:
    add(chip, pulse(hz(['A5', 'F#5', 'B5', 'E6'][k % 4]), .24, .25, .16), t, 1, .75); t += B * 2; k += 1
# a low pad builds towards Ravi's red screen
d = T_RED - (VO['v21'] - .2); x = tt(d); pad = (np.sin(2 * np.pi * 73.4 * x) + .5 * np.sin(2 * np.pi * 110 * x) + .25 * np.sin(2 * np.pi * 146.8 * x)) * (x / d) ** 2 * .22
add(chip, pad.astype(np.float32), VO['v21'] - .2, 1, 0)
music = band + chip
music = S.room(music, size=.4, mix=.14)

# ═════════ foley
fx = np.zeros((NS, 2), np.float32)
def key(v=.8, soft=False):
    d = .08; t = tt(d); th = np.sin(2 * np.pi * (190 + rng.uniform(-25, 25)) * t) * np.exp(-t / .016) * .45
    ck = nz(d, 2500, 7000, .45, .005) + nz(d, 900, 2200, .25, .01)
    return ((th + ck[:len(th)]) * v * (.6 if soft else 1)).astype(np.float32)
def tick(v=.5, f=2600): t = tt(.05); return (np.sin(2 * np.pi * f * t) * np.exp(-t / .008) * v + nz(.05, 3000, 8000, .15 * v, .004)[:len(t)]).astype(np.float32)
def pop(v=.6, f0=520, f1=980): t = tt(.12); f = f0 * (f1 / f0) ** np.minimum(1, t / .05); return (np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / .035) * v).astype(np.float32)
def swish(d=.35, v=.5, lo=400, hi=4000):
    x = rng.standard_normal(int(d * SR)); t = tt(d)[:len(x)]; e = np.sin(np.pi * t / d) ** 2
    return (bp(x, lo, hi) * e * v).astype(np.float32)
def boom(v=1., f0=90, d=.9): v *= .45; t = tt(d); f = f0 * np.exp(-t * 2.2) + 32; return (np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / .3) * v).astype(np.float32)
def tone(f, d, v, tau=.4): t = tt(d); return (np.sin(2 * np.pi * f * t) * np.exp(-t / tau) * np.minimum(1, t / .01) * v).astype(np.float32)
for e in E:
    t0, tp = e['t'], e['type']
    if tp == 'key': add(fx, key(e.get('v', .7)), t0, .5, -.1 + rng.uniform(-.1, .1))
    elif tp == 'akey': add(fx, key(e.get('v', .7), True), t0, .5, -.2 + rng.uniform(-.1, .1))       # phone keyboard: softer
    elif tp == 'click': add(fx, sclick(1.1, .8), t0, .45, .1)
    elif tp == 'pop': add(fx, pop(.32 * e.get('v', 1)), t0, 1, 0)
    elif tp == 'pin': add(fx, pop(.28, 600 + 120 * e['n'], 1100 + 150 * e['n']), t0, 1, -.2 + .15 * e['n'])
    elif tp == 'msg': add(fx, tone(1318, .35, .1, .12) + np.pad(tone(1760, .3, .08, .1), (int(.07 * SR), 0))[:int(.35 * SR)], t0, 1, -.1)
    elif tp == 'send': add(fx, swish(.28, .22, 800, 6000), t0, 1, 0); add(fx, pop(.22, 600, 1100), t0 + .22, 1, 0)
    elif tp == 'pane': add(fx, swish(.38, .26, 300, 3500), t0 - .1, 1, .2)
    elif tp == 'whoosh': add(fx, swish(.6, .36 * e.get('v', 1), 250, 4000), t0 - .1, 1, .3)
    elif tp == 'jump': d = min(.16, e.get('d', .3) * .4); add(fx, pulse(330, d, .25, .16, slide=2.4), t0, 1, .1)
    elif tp == 'land': add(fx, pulse(110, .06, .5, .2 * e.get('v', .6)), t0, 1, 0); add(fx, crush(nz(.05, 200, 2000, .22 * e.get('v', .6), .015)), t0, 1, 0)
    elif tp == 'step': add(fx, crush(nz(.02, 1500, 6000, .06, .005), 4), t0, 1, .1)
    elif tp == 'gapglow': add(fx, tone(55, 3.5, .18, 1.6), t0, 1, 0)
    elif tp == 'title':
        for k in range(18): add(fx, pulse(rng.uniform(900, 2600), .03, .125, .06), t0 + rng.uniform(0, .4), 1, rng.uniform(-.6, .6))
    elif tp == 'scramble':
        n = int(e.get('d', 1.5) / .06)
        for k in range(n): add(fx, tick(.12, 2400 + 400 * (k % 3)), t0 + k * .06, 1, -.1)
    elif tp == 'lock': add(fx, pulse(hz('D6'), .1, .25, .22), t0, 1, 0); add(fx, pulse(hz('A6'), .18, .25, .2), t0 + .08, 1, 0); add(fx, sclick(1.3, .9), t0, .5, 0)
    elif tp == 'alert': add(fx, boom(.5, 110, .5), t0, 1, .2); add(fx, tone(330, .5, .12, .2) + tone(311, .5, .1, .2), t0, 1, .2)
    elif tp == 'redalert': add(fx, boom(.9, 80, 1.2), t0, 1, .3); add(fx, tone(220, 1.2, .14, .5) + tone(207.6, 1.2, .12, .5), t0, 1, .4)
    elif tp == 'bump': add(fx, pulse(180, .12, .5, .25, slide=.5), t0, 1, .4)
    elif tp == 'burst':
        for k in range(16): add(fx, pulse(rng.uniform(1000, 3000), .03, .125, .07), t0 + k * .02, 1, (k % 2 - .5) * 1.2)
        add(fx, pop(.3, 450, 900), t0, 1, -.5); add(fx, pop(.3, 550, 1050), t0 + .07, 1, .5)
    elif tp == 'tick': add(fx, pulse(hz(['D6', 'E6', 'F#6', 'A6', 'B6'][e['n']]), .07, .125, .17), t0, 1, .2)
    elif tp == 'amber': add(fx, tone(392, 1.2, .1, .5) + tone(466, 1.2, .07, .5), t0, 1, 0)
    elif tp == 'fall': add(fx, pulse(440, .5, .25, .14, slide=.25), t0, 1, .2); add(fx, swish(.6, .2, 300, 3000), t0, 1, .2); add(fx, boom(.35, 90, .5), t0 + .65, 1, .2)
    elif tp == 'wipe':
        add(fx, swish(1.0, .24, 600, 7000), t0, 1, 0)
        for k in range(10): add(fx, pulse(hz(['D5', 'F#5', 'A5', 'D6'][k % 4]), .05, .125, .07), t0 + .3 + k * .05, 1, -.5 + k * .1)
    elif tp == 'chime': add(fx, S.note('glockenspiel', 'A6', .8, .4 * e.get('v', 1)), t0, .7, 0); add(fx, S.note('glockenspiel', 'D7', .8, .35 * e.get('v', 1)), t0 + .1, .7, 0)
# room tone: a soft brown-noise bed everywhere, lower in the two silences
bed = lp(noise(NS / SR), 300)[:NS] * .012; fx[:len(bed), 0] += bed; fx[:len(bed), 1] += np.roll(bed, 977)

# ═════════ voice + ducking
vo = np.zeros((NS, 2), np.float32)
for e in all_('vo'):
    y, sr = sf.read(os.path.join(HERE, 'out', 'voice', e['id'] + '.wav'), dtype='float32')
    if y.ndim > 1: y = y.mean(1)
    y = soxr.resample(y, sr, SR).astype(np.float32); y = compress(y, .3, 3.0); add(vo, y, e['t'], 1.0, 0)
env = np.abs(vo[:, 0]); k = int(.15 * SR); env = np.convolve(env, np.ones(k) / k, 'same'); env = np.clip(env / (env.max() * .22), 0, 1)
music *= (1 - .6 * env)[:, None]
# the two silences: music down to nothing before "That is the gap." and before "Dawri."
tn = np.arange(NS) / SR
def win(a, b, f=.4): return np.clip(np.minimum((tn - a) / f, (b - tn) / f), 0, 1)
quiet = 1 - .97 * np.maximum(win(VE('v05') + 1.2, VO['v07'] - .55, .6), win(T_PUSH + .9, VO['v35'] - .3, .3))
music *= quiet[:, None]
music = music / (np.abs(music).max() + 1e-9) * .5
fx = fx / (np.abs(fx).max() + 1e-9) * .42
vo = vo / (np.abs(vo).max() + 1e-9) * .9
mix = music * db(-1.5) + fx * db(2) + vo
end = int(DUR * SR); fo = int(1.2 * SR); fade = np.ones(NS); fade[end - fo:end] = np.linspace(1, 0, fo); fade[end:] = 0
mix = limit(mix * fade[:, None], .95)
os.makedirs(os.path.join(HERE, 'out'), exist_ok=True)
sf.write(os.path.join(HERE, 'out', 'mix.wav'), mix[:int((DUR + .1) * SR)], SR)
if os.environ.get('STEMS'):
    for nm, y in (('music', music), ('fx', fx), ('vo', vo)): sf.write(os.path.join(HERE, 'out', nm + '.wav'), y[:int((DUR + .1) * SR)], SR)
print('mix.wav', round(DUR, 2), 's; notes', len(EVN))
print('\n'.join(S.credits(['piano', 'jazz_bass', 'drum_kit', 'vibraphone', 'glockenspiel'])))
