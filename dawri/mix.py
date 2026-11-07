"""
mix.py  — score + voice + foley → out/mix.wav
Run from the project folder: python mix.py
Expects: LIB env var pointing to the lemo-opuscar library root.
"""
import os, sys, json, subprocess, math
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
LIB  = os.environ.get('LIB') or os.path.join(HERE, '..', '..', 'lemo-opuscar')
sys.path.insert(0, os.path.join(LIB, 'core', 'audio'))

import sfx                        # from $LIB/core/audio/sfx.py

SR   = 48000
DUR  = 180.0
OUT  = os.path.join(HERE, 'out')
VCDIR = os.path.join(OUT, 'voice')
os.makedirs(VCDIR, exist_ok=True)
os.makedirs(OUT,   exist_ok=True)

VENV_PY = os.path.join(LIB, '.venv', 'Scripts', 'python.exe')   # Windows
if not os.path.exists(VENV_PY):
    VENV_PY = os.path.join(LIB, '.venv', 'bin', 'python')       # Unix


# ── 1. Voice (edge-tts) ───────────────────────────────────────────────────────

def gen_voice():
    lines_path = os.path.join(HERE, 'lines.json')
    ret = subprocess.run(
        [VENV_PY, os.path.join(LIB, 'core', 'tts', 'tts_zh.py'),
         lines_path, VCDIR, '--voice', 'en-GB-RyanNeural'],
        check=False
    )
    if ret.returncode not in (0, 2):   # 2 = network error (voice lines optional)
        sys.exit(f'tts_zh.py failed with exit code {ret.returncode}')
    if ret.returncode == 2:
        print('mix.py: WARNING — TTS could not reach Microsoft; voice lines skipped', file=sys.stderr)

gen_voice()

# Load durations (may not exist if TTS failed)
dur_path = os.path.join(VCDIR, 'dur.json')
dur_map  = json.load(open(dur_path, encoding='utf-8')) if os.path.exists(dur_path) else {}


# ── 2. Voice placement times (seconds) ───────────────────────────────────────
# Matches the beat sheet in TREATMENT.md and the visual hit times in timeline.js

VOICE_CUES = [
    ('v01',   3.0),
    ('v02',   8.0),
    ('v03',  12.0),
    ('v04',  14.912),
    ('v05',  19.544),
    ('v06',  23.25),
    ('v07',  24.273),
    ('v08',  26.669),
    ('v09',  28.701),
    ('v10',  36.117),
    ('v11',  42.322),
    ('v12',  44.346),
    ('v13',  45.433),
    ('v14',  50.0),
    ('v15',  53.0),
    ('v16',  66.238),
    ('v17',  72.0),
    ('v18',  75.329),
    ('v19',  80.578),
    ('v20',  84.0),
    ('v21',  90.039),
    ('v22',  93.126),
    ('v23', 102.0),
    ('v24', 104.465),
    ('v25', 113.0),
    ('v26', 120.974),
    ('v27', 128.0),
    ('v28', 134.0),
    ('v29', 140.807),
    ('v30', 151.03),
    ('v31', 158.967),
    ('v32', 163.675),
    ('v33', 170.828),
    ('v34', 177.541),
    ('v35', 178.205),
]


# ── 3. Synthesis helpers ──────────────────────────────────────────────────────

def t_(d):  return np.arange(int(round(d * SR))) / SR
def sine(freq, d, amp=1.0): return np.sin(2 * np.pi * freq * t_(d)) * amp
def exp_env(d, tau): return np.exp(-t_(d) / max(tau, 1e-6))

def felt_piano(freq, d=2.0, v=1.0):
    """Warm piano hit: fundamental + 2nd harmonic, slow attack, long decay"""
    tt = t_(d)
    att = np.minimum(1.0, tt / 0.012)
    fundamental = np.sin(2 * np.pi * freq * tt) * exp_env(d, 0.9)
    second      = np.sin(2 * np.pi * freq * 2 * tt) * exp_env(d, 0.4) * 0.3
    third       = np.sin(2 * np.pi * freq * 3 * tt) * exp_env(d, 0.2) * 0.1
    x = (fundamental + second + third) * att
    return sfx.lp(x, 3000) * v

def glass_tap(freq=1800, v=1.0):
    """Short bright sine tap with quick decay"""
    d = 0.5; tt = t_(d)
    x = np.sin(2 * np.pi * freq * tt) * exp_env(d, 0.06)
    x += np.sin(2 * np.pi * freq * 1.6 * tt) * exp_env(d, 0.03) * 0.4
    return sfx.bp(x, 1200, 4000) * v

def vibraphone_chord(freqs=(523, 659, 784), d=1.5, v=1.0):
    """Warm vibraphone: sine + gentle vibrato"""
    tt = t_(d)
    out = np.zeros(int(d * SR))
    for f in freqs:
        vib = 1 + 0.005 * np.sin(2 * np.pi * 5.5 * tt)   # 5.5 Hz vibrato
        out += np.sin(2 * np.pi * f * np.cumsum(vib) / SR) * exp_env(d, 0.7)
    return sfx.lp(out / len(freqs), 5000) * v

def marimba_note(freq, d=0.4, v=1.0):
    """Bright marimba: fast attack, medium decay"""
    tt = t_(d)
    x = np.sin(2 * np.pi * freq * tt) * exp_env(d, 0.18)
    x += np.sin(2 * np.pi * freq * 2 * tt) * exp_env(d, 0.08) * 0.5
    return sfx.lp(x, 6000) * v

def snap_shimmer(v=1.0):
    """5 quick glass taps in rapid succession (the snap grid burst)"""
    d = 0.5; total = np.zeros(int(d * SR))
    for i in range(5):
        offset = int(i * 0.06 * SR)
        tap = glass_tap(1600 + i * 180, 0.7)
        end = min(len(total), offset + len(tap))
        total[offset:end] += tap[:end - offset]
    return total * v

def light_sweep(v=1.0):
    """High shimmer: filtered noise with fast rise and slow fall"""
    d = 1.5
    n = sfx.noise(d); tt = t_(d)
    env = tt / d * np.exp(-(tt - 0.1) / 0.6)
    env = np.maximum(0, env)
    return sfx.bp(n * env / (np.abs(n * env).max() + 1e-9), 3000, 8000) * 0.6 * v

def sine_pulse(freq=55, d=2.0, v=1.0):
    """Low sine swell — ominous"""
    tt = t_(d)
    env = np.sin(np.pi * tt / d) ** 2
    return np.sin(2 * np.pi * freq * tt) * env * v

def crt_off(v=1.0):
    """High-frequency squash: a short HF sine that falls fast"""
    d = 0.25; tt = t_(d)
    freq_sweep = 8000 * (1 - tt / d) + 200
    phase = 2 * np.pi * np.cumsum(freq_sweep) / SR
    env = exp_env(d, 0.04)
    return np.sin(phase) * env * v * 0.5

def amber_tone(v=1.0):
    """Muted bell: mid-frequency with slow decay"""
    return vibraphone_chord((440, 554, 660), d=1.2, v=v * 0.6)

def breath_sound(v=1.0):
    """Near-silence breath: low-pass noise, very quiet"""
    d = 0.3
    return sfx.lp(sfx.noise(d) * np.sin(np.pi * t_(d) / d) ** 2, 500) * 0.15 * v


# ── 4. Score ──────────────────────────────────────────────────────────────────
# C4 = 261.63 Hz, E4 = 329.63, G4 = 392, A4 = 440, B4 = 493.88

PIANO_NOTES = [
    # (time, freq, duration, velocity)
    # Intro
    (0.5,  261.63, 2.5, 0.6),   # C4 — title breath
    # Problem
    (3.5,  220.00, 1.8, 0.4),
    (8.0,  246.94, 1.5, 0.35),  # B3 — front desk
    (10.0, 261.63, 1.5, 0.35),  # C4 — triage
    (12.0, 293.66, 1.5, 0.35),  # D4 — doctor
    (13.0, 329.63, 1.5, 0.35),  # E4 — pharmacy
    (19.0, 174.61, 2.5, 0.5),   # F3 — gap (ominous)
    (22.0, 185.00, 1.0, 0.45),  # lowered — "that is the gap"
    # Fatima journey
    (25.0, 349.23, 1.8, 0.45),  # F4 — phone enters
    (34.0, 392.00, 1.5, 0.4),   # G4 — Arabic types
    (45.0, 440.00, 1.5, 0.45),  # A4 — map snaps
    (53.3, 523.25, 1.0, 0.5),   # C5 — ticket locks (higher, brighter)
    (62.5, 392.00, 2.0, 0.4),   # G4 — nurse console
    (75.0, 440.00, 1.5, 0.5),   # A4 — visit complete (rising arpeggio start)
    (75.5, 493.88, 1.0, 0.45),
    (76.0, 523.25, 1.5, 0.5),
    # Safety section
    (102.0,195.00, 3.5, 0.5),   # G3 — dark, brooding
    (104.0,207.65, 1.5, 0.35),
    (109.0,220.00, 1.5, 0.35),
    (113.0,233.08, 1.5, 0.35),
    (118.0,246.94, 1.5, 0.35),
    (122.0,261.63, 1.5, 0.35),
    # Architecture — marimba pulse (via marimba_note, not piano)
    # Aim
    (163.0,261.63, 2.0, 0.5),   # C4 — calm, single note
    (167.0,329.63, 2.0, 0.45),
    (170.0,392.00, 2.0, 0.45),
    (175.0,261.63, 4.0, 0.6),   # long decay
    (177.0,392.00, 5.0, 0.55),  # "Arrive, don't register."
]

MARIMBA_PULSE = [
    # (time, freq, velocity) — steady pulse during arch section 134-161s
    *[(134.0 + i * 0.4167, [261.63, 329.63, 392.00, 440.00, 349.23, 392.00][i % 6], 0.4)
      for i in range(66)],
]


# ── 5. EV events (foley placement) ───────────────────────────────────────────

FOLEY = [
    (0.83,  light_sweep,    0.7),
    (8.0,   glass_tap,      0.6),
    (10.0,  glass_tap,      0.6),
    (11.5,  glass_tap,      0.6),
    (13.0,  glass_tap,      0.6),
    (19.0,  lambda v: sine_pulse(55, 2.5, v), 0.35),
    (25.0,  sfx.whoosh,     0.5),
    (45.0,  snap_shimmer,   0.5),
    (53.3,  glass_tap,      0.5),
    (62.5,  sfx.whoosh,     0.4),
    (68.0,  amber_tone,     0.5),
    (90.0,  lambda v: sine_pulse(45, 2.0, v), 0.4),
    (97.0,  crt_off,        0.5),
    (104.0, glass_tap,      0.55),
    (109.0, glass_tap,      0.55),
    (113.0, glass_tap,      0.55),
    (118.0, glass_tap,      0.55),
    (122.0, glass_tap,      0.55),
    (126.0, snap_shimmer,   0.6),
    (128.0, amber_tone,     0.4),
    (175.0, breath_sound,   0.8),
    (177.0, light_sweep,    0.7),
]


# ── 6. Build the mix ──────────────────────────────────────────────────────────

def build():
    total = int(DUR * SR) + SR   # 1 s tail
    mix   = np.zeros((total, 2), dtype=np.float32)

    # -- Piano score --
    for (at, freq, d, vel) in PIANO_NOTES:
        note = felt_piano(freq, d, vel)
        sfx.add(mix, note, at, 0.4)

    # -- Vibraphone chord at 14s (Nar'aakom/Lbaih labels) --
    chord = vibraphone_chord((349.23, 440.00, 523.25), d=2.0, v=0.4)
    sfx.add(mix, chord, 14.0, 0.5)

    # -- Marimba pulse during architecture section --
    for (at, freq, vel) in MARIMBA_PULSE:
        note = marimba_note(freq, 0.35, vel)
        sfx.add(mix, note, at, 0.35)

    # -- Vibraphone chord at model cards --
    chord2 = vibraphone_chord((392.00, 493.88, 587.33), d=2.5, v=0.35)
    sfx.add(mix, chord2, 140.0, 0.5)

    # -- Foley effects --
    for (at, fn, gain) in FOLEY:
        try:
            sfx.add(mix, fn(1.0), at, gain)
        except Exception as e:
            print(f'mix.py: foley at {at}s skipped: {e}', file=sys.stderr)

    # -- Voice lines --
    for (vid, at) in VOICE_CUES:
        wav_path = os.path.join(VCDIR, f'{vid}.wav')
        if not os.path.exists(wav_path):
            continue
        y, sr = sf.read(wav_path, dtype='float32')
        if y.ndim > 1: y = y.mean(axis=1)
        # Resample to SR if needed
        if sr != SR:
            import soxr
            y = soxr.resample(y, sr, SR)
        # Compress voice
        yc = sfx.compress(y, thr=0.3, ratio=4.0)
        sfx.add(mix, yc, at, 0.9, pan=0.0)

    # Soft limit
    mix = sfx.limit(mix[:, 0], ceil=0.95).reshape(-1, 1) * np.array([[1, 1]])
    mix_l = sfx.limit(mix[:total, 0])
    mix_r = sfx.limit(mix[:total, 1]) if mix.shape[1] > 1 else mix_l
    out_mix = np.stack([mix_l, mix_r], axis=1)

    # Actually rewrite using proper limit per channel
    total_buf = np.zeros((total, 2), dtype=np.float32)
    for (at, freq, d, vel) in PIANO_NOTES:
        note = felt_piano(freq, d, vel)
        sfx.add(total_buf, note, at, 0.4)
    for (at, freq, vel) in MARIMBA_PULSE:
        note = marimba_note(freq, 0.35, vel)
        sfx.add(total_buf, note, at, 0.35)
    chord = vibraphone_chord((349.23, 440.00, 523.25), d=2.0, v=0.4)
    sfx.add(total_buf, chord, 14.0, 0.5)
    chord2 = vibraphone_chord((392.00, 493.88, 587.33), d=2.5, v=0.35)
    sfx.add(total_buf, chord2, 140.0, 0.5)
    for (at, fn, gain) in FOLEY:
        try:
            sfx.add(total_buf, fn(1.0), at, gain)
        except Exception as e:
            print(f'mix.py: foley at {at}s skipped: {e}', file=sys.stderr)
    for (vid, at) in VOICE_CUES:
        wav_path = os.path.join(VCDIR, f'{vid}.wav')
        if not os.path.exists(wav_path):
            continue
        y, sr_v = sf.read(wav_path, dtype='float32')
        if y.ndim > 1: y = y.mean(axis=1)
        if sr_v != SR:
            import soxr
            y = soxr.resample(y, sr_v, SR)
        yc = sfx.compress(y, thr=0.3, ratio=4.0)
        sfx.add(total_buf, yc, at, 0.9, pan=0.0)

    # Per-channel limit
    out_l = sfx.limit(total_buf[:, 0], ceil=0.9)
    out_r = sfx.limit(total_buf[:, 1], ceil=0.9)
    out   = np.stack([out_l, out_r], axis=1).astype(np.float32)

    out_path = os.path.join(OUT, 'mix.wav')
    sf.write(out_path, out, SR, subtype='FLOAT')
    print(f'mix.py: wrote {out_path}  ({len(out) / SR:.1f} s)')


if __name__ == '__main__':
    build()
