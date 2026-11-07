// Single source of truth — 72 BPM, 3:00 = 180 s
export const BPM   = 72;
export const BEAT  = 60 / BPM;   // 0.8333… s

// Section boundaries [start, end] seconds
export const SEC = {
  title:    [0,    3   ],
  problem:  [3,    25  ],
  fatima:   [25,   84  ],
  split:    [84,   102 ],
  safety:   [102,  134 ],
  stack:    [134,  161 ],
  aim:      [161,  180 ],
};

// Key hit times in seconds
export const HIT = {
  titleReveal:  0.83,   // B1  — "Dawri دوري" materialises
  flowStart:    8.0,    // B10 — front desk node spawns
  triaNode:     10.0,   // B12 — triage node
  doctorNode:   11.5,   // B14 — doctor node
  pharmNode:    13.0,   // B16 — pharmacy node
  narLbaih:     14.0,   // B17 — Nar'aakom / Lbaih labels
  gapGlow:      19.0,   // B23 — gap glows accent
  thatIsGap:    22.0,   // B26 — "That is the gap."
  dawriSubtitle:24.0,   // B29 — brief Dawri title

  phonePops:    25.0,   // B30 — phone frame expands
  arabicTypes:  34.0,   // B41 — Arabic chat starts
  q1:           40.0,   // B48 — first follow-up bubble
  q2:           43.0,   // B52 — second follow-up
  mapSlides:    45.0,   // B54 — map panel enters
  iAmHere:      50.0,   // B60 — taps "I'm here"
  ticketLocks:  53.3,   // B64 — T-014 locks in
  orderCode:    62.0,   // B74 — "Plain code, no AI"
  nursePops:    62.5,   // B75 — nurse console
  amberPulse:   68.0,   // B82 — penicillin tag pulse
  vitals:       72.0,   // B86 — vitals / handoff
  doctorRx:     75.0,   // B90 — doctor + allergy warning
  pharmacy:     80.0,   // B96 — pharmacy + "Visit complete"

  splitStart:   84.0,   // B101 — Ahmed / Ravi split
  raviRed:      90.0,   // B108 — Ravi panel turns red
  crtOff:       97.0,   // B116 — CRT-off, silence

  safetyIntro:  102.0,  // B122 — dark stage
  card1:        104.0,  // B125 — "Rules first"
  card2:        109.0,  // B131 — "Model reply check"
  card3:        113.0,  // B136 — "No diagnosis, no prescribing"
  card4:        118.0,  // B142 — "Nurse confirms"
  card5:        122.0,  // B146 — "Queue engine: no AI"
  snapBurst:    126.0,  // B151 — snap into 1×5 grid
  disclaimer:   128.0,  // B154 — amber disclaimer card

  archBegins:   134.0,  // B161 — architecture lane starts
  modelCards:   140.0,  // B168 — Gemma + Whisper cards
  ourTest:      148.0,  // B178 — "our test" label
  fanarDims:    156.0,  // B187 — Fanar tuned dims

  stageClear:   161.0,  // B193 — aim section starts
  line1:        163.0,  // B196 — "Reception step removed"
  line2:        167.0,  // B200 — "Structured intake for nurses"
  line3:        170.0,  // B204 — "People decide everything clinical"
  textClear:    174.0,  // B209 — all aim text clears
  dawriWord:    175.0,  // B210 — "Dawri." white
  catchphrase:  177.0,  // B212 — light reveal "Arrive, don't register."
};

// EV events — read by mix.py for audio placement
export const EV = [
  { t: HIT.titleReveal,  type: 'light_sweep'      },
  { t: HIT.flowStart,    type: 'glass_tap'         },
  { t: HIT.triaNode,     type: 'glass_tap'         },
  { t: HIT.doctorNode,   type: 'glass_tap'         },
  { t: HIT.pharmNode,    type: 'glass_tap'         },
  { t: HIT.narLbaih,     type: 'vibraphone'        },
  { t: HIT.gapGlow,      type: 'sine_pulse'        },
  { t: HIT.phonePops,    type: 'whoosh'            },
  { t: HIT.arabicTypes,  type: 'keystrokes'        },
  { t: HIT.mapSlides,    type: 'snap_grid'         },
  { t: HIT.ticketLocks,  type: 'lock_tick'         },
  { t: HIT.nursePops,    type: 'whoosh'            },
  { t: HIT.amberPulse,   type: 'amber_shimmer'     },
  { t: HIT.pharmacy,     type: 'rising_arp'        },
  { t: HIT.raviRed,      type: 'low_sine'          },
  { t: HIT.crtOff,       type: 'crt_off'           },
  { t: HIT.card1,        type: 'glass_tap'         },
  { t: HIT.card2,        type: 'glass_tap'         },
  { t: HIT.card3,        type: 'glass_tap'         },
  { t: HIT.card4,        type: 'glass_tap'         },
  { t: HIT.card5,        type: 'glass_tap'         },
  { t: HIT.snapBurst,    type: 'snap_burst'        },
  { t: HIT.disclaimer,   type: 'amber_tone'        },
  { t: HIT.archBegins,   type: 'marimba_start'     },
  { t: HIT.modelCards,   type: 'vibraphone_chord'  },
  { t: HIT.dawriWord,    type: 'breath'            },
  { t: HIT.catchphrase,  type: 'light_sweep'       },
];
