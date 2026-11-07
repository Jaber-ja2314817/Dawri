// Dawri's real screens, redrawn as HTML. Every label comes from frontend/src/i18n/*.en.json; demo data from backend/seed.
export const PH = { x: 170, y: 84, w: 440, h: 856 };
export const SW = { x: 690, y: 84, w: 1120, h: 856 };
export const DW = { x: 150, y: 84, w: 1620, h: 856 };

const st = (o = {}) => Object.entries(o).map(([k, v]) => `${k}:${v}`).join(';');
const A = k => k ? ` data-a="${k}"` : '';
const ani = (op = 1, ty = 0, sc = 1) => `opacity:${op};transform:translateY(${ty}px) scale(${sc})`;
const FOOT = `<div class="afoot"><span>Demo — synthetic data, not connected to PHCC/HMC systems.</span><span style="white-space:nowrap">AI: model</span></div>`;
const MIC = `<svg width="20" height="20" viewBox="0 0 20 20"><rect x="7" y="2" width="6" height="11" rx="3" fill="none" stroke="#0a0a0a" stroke-width="1.8"/><path d="M4 10a6 6 0 0 0 12 0M10 16v2" fill="none" stroke="#0a0a0a" stroke-width="1.8"/></svg>`;
const SEND = `<svg width="20" height="20" viewBox="0 0 20 20"><path d="M3 10h12M10 4l6 6-6 6" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

export function phone(p, s, extra = '') {
  const tone = s.scr === 'emergency' ? ' em' : '';
  const titles = { welcome: '', login: 'Log in', home: 'Home', consent: 'Before we start', chat: 'Reception', centre: 'Choose a centre', reserved: 'Check-in',
    ticket: 'Your ticket', complete: 'Visit complete', refill: 'Medicine refill', emergency: 'Emergency' };
  const hd = s.scr === 'welcome' ? '' : `<div class="ahd${tone}"><span class="bk">‹</span><span class="tt">${titles[s.scr]}</span><span class="lg">عربي</span></div>`;
  return `<div class="phone"${A(s.key || 'phone')} style="${st({ left: p.x + 'px', top: p.y + 'px', width: p.w + 'px', height: p.h + 'px', filter: s.blur ? `blur(${s.blur}px)` : 'none', opacity: s.op ?? 1, transform: s.tf || 'none' })}">
  <div class="scr"><div class="sbar"><span>10:41</span><span class="isl"></span><span class="ic"><i></i></span></div>${hd}
  ${SCR[s.scr](s)}${s.scr === 'chat' ? '' : FOOT}${extra}</div></div>`;
}

const SCR = {
  welcome: s => `<div class="abody" style="justify-content:center;gap:22px;padding:34px">
      <div style="font-size:64px;font-weight:700;letter-spacing:-.03em;line-height:64px"${A(s.k1)}>Dawri</div>
      <div class="ar" style="font-size:40px;font-weight:600;color:var(--data);text-align:left;direction:rtl;align-self:flex-start">دوري</div>
      <div style="font-size:21px;line-height:30px">Check in for your health centre visit from your phone.</div>
      <div style="height:30px"></div>
      <div class="btn${s.press === 'login' ? ' press' : ''}"${A('blogin')}>Log in with Tawtheeq (demo)</div></div>`,
  login: s => `<div class="abody">
      <div class="lbl" style="font-weight:600;color:var(--ink);font-size:16px">Demo patients</div>
      ${[['F', 'Fatima Al-Demo', 'DEMO-10001'], ['A', 'Ahmed Al-Demo', 'DEMO-10002'], ['R', 'Ravi Demo', 'DEMO-10003']].map(([i, n, q], k) =>
        `<div class="prow${s.sel === k ? ' sel' : ''}"${A('pr' + k)}><div class="av">${i}</div><div style="display:flex;flex-direction:column"><b>${n}</b><span>QID ${q}</span></div></div>`).join('')}
      <div style="height:6px"></div>
      <div class="lbl">QID</div><div class="field${s.sel === 0 ? '' : ' ph'}">${s.sel === 0 ? 'DEMO-10001' : ''}</div>
      <div class="lbl">One-time code</div><div class="field${s.sel === 0 ? '' : ' ph'}">${s.sel === 0 ? '0000' : ''}</div>
      <div class="lbl" style="font-size:13px">The demo code is 0000.</div>
      <div class="btn${s.press ? ' press' : ''}"${A('blog2')}>Log in</div></div>`,
  home: s => `<div class="abody">
      <div class="h1">Fatima Al-Demo</div>
      <div class="card" style="display:flex;flex-direction:column;gap:12px">
        <div class="row"><span class="lbl">Registered centre</span><span class="pill neu">Demo data</span></div>
        <div style="font-size:18px;font-weight:600">Al Wakra Health Centre</div>
        <div class="lbl">Allergies</div><div><span class="pill warn" style="font-size:15px;height:28px">penicillin</span></div></div>
      <div class="btn${s.press ? ' press' : ''}"${A('bstart')}>Start check-in</div>
      <div class="btn q">Open visits</div><div class="btn q">History</div></div>`,
  consent: s => `<div class="abody" style="font-size:18px;line-height:27px;gap:16px">
      <div class="h1">Before we start</div>
      <div>The assistant asks why you are visiting, so the nurse has it ready.</div>
      <div style="font-weight:600"${A('nodx')}>It does not diagnose or prescribe.</div>
      <div>Your words are kept for this visit only. Voice recordings are not stored.</div>
      <div>This is a demo with synthetic data.</div>
      <div class="lbl" style="font-size:16px">This visit is for Fatima Al-Demo.</div>
      <div style="flex:1"></div><div class="btn${s.press ? ' press' : ''}"${A('bagree')}>I agree</div></div>`,
  chat: s => {
    const ms = s.msgs.map((m, i) => `<div class="bub ${m.who}${m.ar ? ' ar' : ''}"${A('m' + i)} style="${ani(m.op ?? 1, m.ty ?? 0)}">${m.text}</div>`).join('')
      + (s.dots ? `<div class="bub as" style="padding:0"><div class="dots">${[0, 1, 2].map(i => `<i style="opacity:${.3 + .7 * Math.max(0, Math.sin(s.t * 8 - i))}"></i>`).join('')}</div></div>` : '')
      + (s.sum ? `<div class="sum"${A('sum')} style="${ani(s.sum.op, s.sum.ty)}"><div class="ar" style="font-size:18px;line-height:28px">شكرا. هذا اللي بقوله للممرضة: حرارة وكحة، 3 أيام، الشدة 6 من 10. هل هذا صحيح؟</div>
          <div style="font-size:14px;color:var(--muted)">Is this right?</div><div class="btn${s.sum.press ? ' press' : ''}"${A('byes')} style="height:46px;font-size:16px">Yes, that's right</div><div class="btn q" style="height:42px;font-size:15px">Change something</div></div>` : '');
    const inp = s.input ? `<div class="in${s.ar ? ' ar' : ''}"${A('cin')}>${s.input}${s.caret ? '<span class="caret"></span>' : ''}</div>` : `<div class="in ph"${A('cin')}>Type your answer</div>`;
    return `<div class="abody" style="padding:16px 16px 8px"><div class="msgs${s.en ? ' en' : ''}">${ms}</div></div>
      <div class="comp"><div class="mic"${A('mic')} style="${s.mic ? `box-shadow:0 0 0 ${s.mic}px #d5e2f6;border-color:var(--data)` : ''}">${MIC}</div>${inp}<div class="snd"${A('snd')}>${SEND}</div></div>
      <div style="height:22px;background:var(--surface);flex:none"></div>`;
  },
  centre: s => {
    const pins = [['Al Wakra', 18, 262, 268, 'pw'], ['Mesaimeer', 26, 128, 150, 'pm'], ['Airport', 31, 250, 92, 'pa'], ['West Bay', 34, 168, 40, 'pb']];
    return `<div class="abody" style="gap:12px">
      <div class="seg2"><span class="on">Map</span><span>List</span></div>
      <div class="map"${A('map')}><svg width="374" height="340" viewBox="0 0 374 340" style="position:absolute;left:0;top:0">
        <rect width="374" height="340" fill="#dbe4ee"/>
        <path d="M0 0 H232 C222 40 248 70 236 104 C226 134 258 150 270 182 C282 214 300 236 296 270 C292 300 312 322 318 340 H0 Z" fill="#f4f5f7"/>
        <path d="M20 60 L230 90 M10 170 L280 200 M60 0 L120 340 M150 0 L210 340 M0 280 L300 300" stroke="#ffffff" stroke-width="7"/>
        <path d="M20 60 L230 90 M10 170 L280 200 M60 0 L120 340 M150 0 L210 340" stroke="#e1e4e8" stroke-width="1.5"/></svg>
        ${pins.map(([n, w, x, y, k], i) => `<div class="pin${s.selPin && i === 0 ? ' on' : ''}"${A(k)} style="left:${x}px;top:${y}px;${ani(s.pins?.[i] ?? 1, (1 - (s.pins?.[i] ?? 1)) * -10)}"><div class="lab">${n} · ${w} min</div><div class="dot"></div></div>`).join('')}
      </div>
      <div class="card" style="display:flex;flex-direction:column;gap:12px;${ani(s.cardOp ?? 1, (1 - (s.cardOp ?? 1)) * 14)}">
        <div class="row"><b style="font-size:18px">Al Wakra Health Centre</b><span class="pill data">Your centre</span></div>
        <div class="kv"><div><span class="lbl">Wait</span><b>18 min</b></div><div><span class="lbl">People ahead</span><b>4</b></div><div><span class="lbl">Distance</span><b>2.1 km</b></div></div>
        <div class="btn${s.press ? ' press' : ''}"${A('bcheck')}>Check in here</div></div></div>`;
  },
  reserved: s => `<div class="abody" style="gap:16px">
      <div class="card" style="display:flex;flex-direction:column;gap:6px"><b style="font-size:19px">Al Wakra Health Centre</b><span class="lbl">General practice</span></div>
      <div class="card" style="display:flex;flex-direction:column;gap:10px"${A('valid')}>
        <div style="font-size:17px;font-weight:600">Check-in valid for 45 minutes</div>
        <div class="row"><span class="lbl">Time left</span><b style="font-size:30px;font-variant-numeric:tabular-nums">${s.left || '44:58'}</b></div>
        <div class="pill neu" style="align-self:flex-start;font-size:15px;height:30px"${A('activ')}>Activates when you arrive</div></div>
      <div style="flex:1"></div>
      <div class="btn${s.press ? ' press' : ''}"${A('bhere')} style="height:64px;font-size:21px">I'm here</div>
      <div class="btn q">Check with my location</div></div>`,
  ticket: s => `<div class="abody" style="gap:14px">
      ${s.gonow ? `<div class="gonow"${A('gonow')} style="${ani(s.gonow, (1 - s.gonow) * -12)}">Go to Triage 2 now</div>` : ''}
      <div class="card" style="display:flex;flex-direction:column;gap:4px;align-items:flex-start">
        <span class="lbl">Your ticket number</span><div class="tnum"${A('tnum')}>${s.num || 'T-014'}</div></div>
      <div class="card kv"${A('ahead')} style="justify-content:space-between"><div><span class="lbl">People ahead</span><b>${s.ahead ?? 3}</b></div><div><span class="lbl">Estimated wait</span><b>${s.wait || '15 min'}</b></div></div>
      <div class="card"><div class="lbl" style="margin-bottom:6px">Steps of your visit</div><div class="steps">
        ${['Triage', 'Doctor', 'Pharmacy'].map((n, i) => `<div class="step ${i < (s.stage || 0) ? 'done' : i === (s.stage || 0) ? 'cur' : ''}"><i></i>${n}</div>`).join('')}</div></div>
      <div class="lbl">Last updated 10:42</div></div>`,
  complete: s => `<div class="abody" style="gap:14px">
      <div class="h1"${A('cdone')}>Visit complete</div>
      <div class="card" style="display:flex;flex-direction:column;gap:8px"><span class="lbl">Medicines</span>
        <div style="font-size:16.5px;font-weight:600">paracetamol 500 mg</div><div class="lbl" style="margin-top:-6px">1 tablet, 3 times a day, 5 days</div>
        <div style="font-size:16.5px;font-weight:600">dextromethorphan syrup</div><div class="lbl" style="margin-top:-6px">10 ml, 3 times a day, 5 days</div></div>
      <div class="card" style="display:flex;flex-direction:column;gap:6px"><span class="lbl">Follow-up</span><div style="font-size:15.5px;line-height:22px">Return to your centre if your symptoms get worse, and call 999 in an emergency.</div></div>
      <div class="card row"><span style="font-weight:600">Rate your visit</span><span style="font-size:24px;letter-spacing:2px;color:#c9ced6">★★★★★</span></div>
      <div class="lbl">Final ticket T-014</div></div>`,
  refill: s => `<div class="abody" style="gap:16px">
      <div class="h1"${A('rtitle')}>You can get this without a visit</div>
      <div class="card" style="display:flex;flex-direction:column;gap:6px"><span class="lbl">Your usual medicine</span><b style="font-size:19px">amlodipine 5 mg once daily</b></div>
      <div style="font-size:17px;line-height:25px">Your centre's refill line can arrange this, so you do not need to come in.</div>
      <div style="flex:1"></div><div class="btn">Message your centre</div><div class="btn q">I still want a visit</div></div>`,
  emergency: s => `<div class="abody" style="gap:16px">
      <div style="font-size:32px;line-height:38px;font-weight:700;color:var(--negative)"${A('etitle')}>Go to Emergency now</div>
      <div class="btn em" style="height:68px;font-size:24px"${A('e999')}>Call 999</div>
      <div class="card" style="display:flex;flex-direction:column;gap:4px"${A('enear')}><span class="lbl">Nearest emergency department</span>
        <b style="font-size:19px">Hamad General Hospital</b><span style="font-size:15px">7.0 km from your registered centre</span>
        <span style="font-size:15.5px;font-weight:500;text-decoration:underline;margin-top:6px">Open its location on the map</span></div>
      <div style="flex:1"></div><div class="btn q" style="border:none;text-decoration:underline">I'm not in danger — go back</div></div>`,
};

// ───── staff window
export function staff(p, s) {
  const nav = ['Nurse queue', 'Doctor', 'Pharmacy', 'Front desk', 'Display', 'Dashboard'];
  const on = { nurseQ: 0, nurse: 0, doctor: 1, pharmacy: 2 }[s.scr];
  const url = ['staff/nurse', 'staff/doctor', 'staff/pharmacy'][on];
  return `<div class="win"${A('staff')} style="${st({ left: p.x + 'px', top: p.y + 'px', width: p.w + 'px', height: p.h + 'px', filter: s.blur ? `blur(${s.blur}px)` : 'none', opacity: s.op ?? 1, transform: s.tf || 'none' })}">
    <div class="chrome"><span class="dd"><i></i><i></i><i></i></span><span class="tab">Dawri staff</span><span class="url">xtamim-dawri.hf.space/${url}</span></div>
    <div class="shd"><span class="br">Dawri staff</span><span class="nav">${nav.map((n, i) => `<span class="${i === on ? 'on' : ''}">${n}</span>`).join('')}</span>
      <span class="rt"><span class="pill pos">Live</span><span>AI: model</span><span style="color:var(--ink);font-weight:500">${['Nurse', 'Doctor', 'Pharmacy'][on]} · Al Wakra</span></span></div>
    <div class="sbody">${STF[s.scr](s)}</div></div>`;
}
const BANNER = (extra = '') => `<div class="ban"${A('ban')}><span class="nm">Fatima Al-Demo</span><span class="mt">34 · F · T-014 · General practice</span>
  <span style="margin-left:auto;display:flex;gap:8px;align-items:center"><span class="lbl">Allergy</span><span class="pill warn"${A('allergy')} style="font-size:15px;height:28px">penicillin</span>${extra}</span></div>`;
const STF = {
  nurseQ: s => `<div style="display:flex;align-items:baseline;gap:14px"><span class="h1">Triage 2</span><span class="lbl">3 waiting · next arrival waits about 15 min</span></div>
    <div class="pan"><table class="q"><tr><th>Place</th><th>Number</th><th>Patient</th><th>Age and sex</th><th>Complaint</th><th></th></tr>
    ${[['1', 'T-012', 'Layla Al-Demo', '7 · F', 'Ear pain', ''], ['2', 'T-013', 'Demo patient', '52 · M', 'Rash', ''], ['3', 'T-014', 'Fatima Al-Demo', '34 · F', 'Fever and cough', s.hl ? 'hl' : '']].slice(0, s.rows ?? 3)
      .map(r => `<tr class="${r[5]}"${r[1] === 'T-014' ? A('qrow') : ''}><td>${r[0]}</td><td><b>${r[1]}</b></td><td>${r[2]}</td><td>${r[3]}</td><td>${r[4]}</td><td style="text-align:end"><span class="btn q" style="display:inline-flex;height:34px;padding:0 12px;font-size:14px">Open intake card</span></td></tr>`).join('')}</table></div>`,
  nurse: s => `${BANNER()}<div class="cols" style="grid-template-columns:1fr 1.15fr 1fr">
    <div class="pan"${A('words')}><h3>Patient's words</h3>
      <div class="wl"><span class="who">Receptionist</span><span class="tx ar" style="text-align:right">شو اللي يتعبك اليوم؟</span></div>
      <div class="wl" style="background:#eef3fb;border-radius:6px;padding:8px 10px;margin:0 -10px"${A('exact')}><span class="who">Patient</span><span class="tx ar" style="text-align:right;font-weight:600">عندي حرارة وكحة من ثلاث أيام</span></div>
      <div class="wl"><span class="who">Receptionist</span><span class="tx ar" style="text-align:right">كم شدته من 0 إلى 10؟</span></div>
      <div class="wl"><span class="who">Patient</span><span class="tx ar" style="text-align:right">6</span></div>
      <div class="wl"><span class="who">Receptionist</span><span class="tx ar" style="text-align:right">أخذتي أي دواء لها؟</span></div>
      <div class="wl"><span class="who">Patient</span><span class="tx ar" style="text-align:right">باراسيتامول</span></div></div>
    <div class="pan"${A('intake')}><div class="row"><h3>Intake card</h3><span class="lbl">Edit</span></div>
      ${[['Reason (AI)', 'Fever and cough'], ['Duration', '3 days'], ['Severity', '6 of 10'], ['Medicines taken', 'paracetamol'],
        ['Allergies (record)', '<span class="pill warn" data-a="allergy2">penicillin</span>'], ['Red flags', 'none detected'], ['Suggested service', 'General practice']]
        .map(([k, v], i) => `<div class="ir"${A('ir' + i)} style="${i === s.irHot ? 'background:#fffbeb;margin:0 -10px;padding:8px 10px' : ''}"><span class="k">${k}</span><span>${v}</span></div>`).join('')}</div>
    ${s.handoff ? HANDOFF(s) : VITALS(s)}</div>`,
  doctor: s => `${BANNER('<span class="pill pos">Confirmed by the nurse</span>')}<div class="cols" style="grid-template-columns:1fr 1.1fr">
    <div class="pan"><h3>Handoff</h3>
      <div class="ir"><span class="k">Complaint</span><span>Fever and cough, 3 days</span></div>
      <div class="ir"><span class="k">Summary from triage</span><span>34-year-old woman, fever and cough for 3 days, severity 6 of 10, took paracetamol. Temp 38.4 °C, HR 92, SpO2 97%. Allergy: penicillin.</span></div>
      <div class="ir"><span class="k">Urgency</span><span>Routine</span></div>
      <div class="vg" style="margin-top:6px">${[['BP, mmHg', '118/76'], ['Heart rate, per min', '92'], ['Temperature, °C', '38.4'], ['SpO2, %', '97']].map(([k, v]) => `<div class="vf">${k}<div class="field">${v}</div></div>`).join('')}</div></div>
    <div class="pan"${A('rxpan')}><h3>Prescription</h3><div class="lbl">You choose the medicines. Nothing is selected for you.</div>
      ${s.rx ? `<div class="rx bad"${A('rxbad')} style="${ani(s.rx, (1 - s.rx) * 10)}"><div class="row"><b style="font-size:17px">amoxicillin 500 mg · Capsule</b><span class="pill neg" style="font-size:14px;height:28px">Allergy</span></div>
        <div style="color:var(--pneg);font-size:15.5px;font-weight:500">This prescription conflicts with an allergy on record.</div>
        <div class="chk"><i></i>I have checked this allergy</div></div>` : ''}
      ${['paracetamol', 'dextromethorphan syrup', 'amoxicillin', 'co-amoxiclav', 'azithromycin', 'ibuprofen', 'cetirizine'].map(n => `<div class="drug${s.hot === n ? ' hot' : ''}"${A('d-' + n.split(' ')[0])}><span>${n}</span><span class="lbl">Add</span></div>`).join('')}
      <div style="flex:1"></div><div class="btn q">Done</div></div></div>`,
  pharmacy: s => `${BANNER()}<div class="cols" style="grid-template-columns:1.3fr 1fr">
    <div class="pan"${A('handover')}><h3>To hand over</h3>
      ${[['paracetamol 500 mg', 'Tablet · 1 tablet · 3 times a day · 5 days'], ['dextromethorphan syrup', 'Syrup · 10 ml · 3 times a day · 5 days']].map(([n, d]) =>
        `<div class="rx"><b style="font-size:18px">${n}</b><span class="lbl" style="font-size:15px">${d}</span></div>`).join('')}
      <div style="flex:1"></div>${s.done ? `<div class="pill pos" style="font-size:17px;height:40px;padding:0 16px;align-self:flex-start"${A('handed')}>Handed over, visit complete: T-014</div>` : `<div class="btn${s.press ? ' press' : ''}"${A('bdisp')}>Dispensed</div>`}</div>
    <div class="pan"><h3>Queue for this counter</h3><table class="q"><tr><th>Number</th><th>Patient</th></tr><tr class="hl"><td><b>P-021</b></td><td>Fatima Al-Demo</td></tr><tr><td><b>P-022</b></td><td>Demo patient</td></tr></table></div></div>`,
};
const VITALS = s => {
  const v = s.vit || {};
  return `<div class="pan"${A('vitals')}><h3>Vitals and urgency</h3><div class="vg">
    ${[['BP systolic', 'bp_sys'], ['BP diastolic', 'bp_dia'], ['HR', 'hr'], ['Temp, C', 'temp'], ['SpO2, %', 'spo2'], ['Weight, kg', 'wt']].map(([l, k]) =>
      `<div class="vf">${l}<div class="field"${A('v-' + k)} style="${s.vf === k ? 'border-color:var(--data);box-shadow:0 0 0 3px #d5e2f6' : ''}">${v[k] || ''}${s.vf === k && s.caret ? '<span class="caret"></span>' : ''}</div></div>`).join('')}</div>
    <div class="lbl" style="margin-top:4px">Urgency (nurse decides)</div><div class="urg"${A('urg')}><span class="${s.urg ? 'on' : ''}">Routine</span><span>Soon</span><span>Urgent to ED</span></div>
    <div style="flex:1"></div><div class="btn${s.press ? ' press' : ''}"${A('bconf')}>Confirm &amp; generate handoff</div></div>`;
};
const HANDOFF = s => `<div class="pan"${A('handoff')} style="${ani(s.handoff, (1 - s.handoff) * 12)}"><h3>Handoff</h3>
  <div class="lbl">Summary for the doctor</div>
  <div class="field" style="height:auto;padding:12px 14px;font-size:15.5px;line-height:23px;align-items:flex-start">34-year-old woman, fever and cough for 3 days, severity 6 of 10, took paracetamol. Temp 38.4 °C, HR 92, SpO2 97%. Allergy: penicillin.</div>
  <span class="pill data" style="align-self:flex-start">Draft from the model</span>
  <div class="lbl">Doctor</div><div class="field">Dr. Noor · Room 4</div>
  <div class="lbl" style="font-size:13.5px">Nothing reaches the doctor until you confirm.</div>
  <div style="flex:1"></div>${s.sent ? `<div class="pill pos" style="font-size:17px;height:40px;padding:0 16px;align-self:flex-start"${A('sent')}>Sent to the doctor</div>` : `<div class="btn${s.press2 ? ' press' : ''}"${A('bsend')}>Confirm &amp; send</div>`}</div>`;

// ───── document window (the project README, in a browser preview)
export function doc(p, title, body, o = {}) {
  return `<div class="win doc"${A('doc')} style="${st({ left: p.x + 'px', top: p.y + 'px', width: p.w + 'px', height: p.h + 'px', opacity: o.op ?? 1 })}">
    <div class="chrome"><span class="dd"><i></i><i></i><i></i></span><span class="tab">README.md — Dawri</span><span class="url">${title}</span></div>
    <div class="dbody">${body}</div></div>`;
}
export { st, ani, A };
