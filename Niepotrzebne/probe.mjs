// Sonar: drives the page in a real Chrome over CDP and dumps measured impulse responses.
// Usage: node probe.mjs <seconds> <band> <outPrefix> [cdpPort]
import fs from 'node:fs';

const seconds = +(process.argv[2] || 6), band = process.argv[3] || 'wide', out = process.argv[4] || '/tmp/sonar', port = +(process.argv[5] || 9337), vol = process.argv[6], mode = process.argv[7];
const sleep = ms => new Promise(r => setTimeout(r, ms));

const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = list.find(t => t.type === 'page' && (t.url.includes('8537') || t.url.includes('Sonar/index.html')));
if (!page) { console.log('no sonar tab'); process.exit(1); }
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
let id = 0;
const pending = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async expression => {
  const r = await send('Runtime.evaluate', { expression, userGesture: true, awaitPromise: true, returnByValue: true });
  if (r.result.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 600));
  return r.result.result.value;
};

await send('Page.reload', { ignoreCache: true });
await sleep(1200);
await ev(`document.getElementById('start').click(); 1`);
if (vol) await ev(`(() => { const v = document.getElementById('vol'); v.value = ${vol}; v.dispatchEvent(new Event('input')); })(); 1`);
await sleep(2500);
if (band !== 'wide') { await ev(`document.querySelector('[data-key=band] [data-v=${band}]').click(); 1`); await sleep(1500); }
if (mode) { await ev(`document.querySelector('[data-key=mode] [data-v=${mode}]').click(); 1`); await sleep(400); }
await ev(`
  window.__log = []; window.__sum = null; window.__sq = null; window.__mot = null; window.__n = 0;
  const __orig = onPing;
  onPing = function (m) {
    const before = seen;
    __orig(m);
    if (state.tau === null || seen === before) return;
    let pk = 0; for (let i = 0; i < m.rec.length; i += 1) { const a = Math.abs(m.rec[i]); if (a > pk) pk = a; }
    __log.push([Math.round(performance.now()), state.tau, state.tau, state.snr, state.clip, state.ref, pk]);
    if (seen < 12) return;
    if (!__sum) { __sum = new Float64Array(M); __sq = new Float64Array(M); __mot = new Float64Array(M); }
    for (let i = 0; i < M; i++) { __sum[i] += magAll[i]; __sq[i] += magAll[i] * magAll[i]; __mot[i] += magMot[i] * magMot[i]; }
    __n++;
  };
  1`);
await sleep(seconds * 1000);
const data = await ev(`JSON.stringify({ fs, vol: state.vol, lo: state.lo, hi: state.hi, status: statusEl.textContent, on: state.on, ref: state.ref, n: __n, log: __log,
  mean: __sum ? Array.from(__sum, v => v / __n) : [], rms: __sq ? Array.from(__sq, v => Math.sqrt(v / __n)) : [], mot: __mot ? Array.from(__mot, v => Math.sqrt(v / __n)) : [] })`);
const shot = await send('Page.captureScreenshot', { format: 'png' });
fs.writeFileSync(out + '.json', data);
fs.writeFileSync(out + '.png', Buffer.from(shot.result.data, 'base64'));
await ev(`document.getElementById('stop').click(); 1`);

const d = JSON.parse(data), C = 343, kr = C / (2 * d.fs);
console.log('slider now:', d.vol, '| scale lo/hi:', d.lo && d.lo.toFixed(1), d.hi && d.hi.toFixed(1));
console.log('status:', d.status, '| on:', d.on, '| pings:', d.log.length, '| averaged:', d.n);
if (d.log.length) {
  const taus = d.log.map(l => l[1]), snr = d.log.map(l => l[3]), clips = d.log.map(l => l[4]);
  const mean = taus.reduce((a, b) => a + b, 0) / taus.length;
  const sd = Math.sqrt(taus.reduce((a, b) => a + (b - mean) ** 2, 0) / taus.length);
  console.log('tau first/last:', taus[0].toFixed(3), taus.at(-1).toFixed(3), '| mean', mean.toFixed(3), 'sd', sd.toFixed(4), '| min', Math.min(...taus).toFixed(3), 'max', Math.max(...taus).toFixed(3));
  console.log('direct SNR dB min/max:', Math.min(...snr).toFixed(1), Math.max(...snr).toFixed(1), '| clipped samples max:', Math.max(...clips), '| ref:', d.ref.toExponential(3), '| mic peak max:', Math.max(...d.log.map(l => l[6])).toFixed(3));
  const dt = d.log.slice(1).map((l, i) => l[0] - d.log[i][0]);
  console.log('ping interval ms min/max:', Math.min(...dt), Math.max(...dt));
}
if (d.mean.length) {
  const db = d.mean.map(v => 20 * Math.log10(v / d.ref + 1e-12)), mot = d.mot.map(v => 20 * Math.log10(v / d.ref + 1e-12));
  const row = (a, b) => { let m = -999, at = 0, mm = -999; for (let i = Math.round(a / kr); i < Math.round(b / kr) && i < db.length; i++) { if (db[i] > m) { m = db[i]; at = i; } if (mot[i] > mm) mm = mot[i]; } return `${a.toFixed(2)}-${b.toFixed(2)} m  peak ${m.toFixed(1)} dB at ${(at * kr).toFixed(3)} m   motion-residual peak ${mm.toFixed(1)} dB`; };
  for (const [a, b] of [[0, 0.05], [0.05, 0.15], [0.15, 0.3], [0.3, 0.5], [0.5, 0.75], [0.75, 1], [1, 1.5], [1.5, 2], [2, 3], [3, 4], [4, 6], [6, 8]]) console.log(row(a, b));
  const peaks = [];
  for (let i = Math.round(0.3 / kr); i < db.length - 8; i++) {
    let isMax = true;
    for (let j = i - 8; j <= i + 8; j++) if (db[j] > db[i]) { isMax = false; break; }
    if (isMax) peaks.push([db[i] + 20 * Math.log10(i * kr), i * kr, db[i]]);
  }
  peaks.sort((a, b) => b[0] - a[0]);
  console.log('strongest echoes beyond 0.3 m (range-compensated):');
  for (const p of peaks.slice(0, 10)) console.log(`  ${p[1].toFixed(3)} m   ${p[2].toFixed(1)} dB re direct   (${p[0].toFixed(1)} dB with range gain)`);
  const sortedDb = db.slice(Math.round(0.3 / kr)).sort((a, b) => a - b);
  console.log('median level beyond 0.3 m:', sortedDb[sortedDb.length >> 1].toFixed(1), 'dB re direct');
}
ws.close();
