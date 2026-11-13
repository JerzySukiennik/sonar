// Sonar: grabs raw microphone frames (chirp on, then chirp off) to separate ambient noise from non-repeatable signal.
// Usage: node raw.mjs <outFile> [cdpPort]
import fs from 'node:fs';

const out = process.argv[2] || '/tmp/sonar-raw.json', port = +(process.argv[3] || 9337);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = list.find(t => t.type === 'page' && t.url.includes('8537'));
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
await sleep(2500);
await ev(`window.__raw = []; const __o = onPing; onPing = function (m) { if (m.k >= 3) __raw.push([m.g, Array.from(m.rec)]); __o(m); }; 1`);
await sleep(1500);
await ev(`node.port.postMessage({ gain: 0 }); 1`);
await sleep(1800);
const data = await ev(`JSON.stringify({ fs, raw: __raw, settings: stream.getAudioTracks()[0].getSettings(), label: stream.getAudioTracks()[0].label, base: ctx.baseLatency, outLat: ctx.outputLatency })`);
await ev(`document.getElementById('stop').click(); 1`);
fs.writeFileSync(out, data);

const d = JSON.parse(data);
console.log('mic:', d.label, JSON.stringify(d.settings));
console.log('latency base/output:', d.base, d.outLat);
const rms = a => Math.sqrt(a.reduce((s, v) => s + v * v, 0) / a.length), dbfs = v => (20 * Math.log10(v + 1e-12)).toFixed(1);
const on = d.raw.filter(r => r[0] > 0).map(r => r[1]), off = d.raw.filter(r => r[0] === 0).map(r => r[1]).slice(2);
console.log('frames on/off:', on.length, off.length);
for (const [name, set] of [['chirp on ', on], ['chirp off', off]]) {
  if (!set.length) continue;
  console.log(name, 'rms dBFS per frame:', set.map(f => dbfs(rms(f))).join(' '), '| peak', Math.max(...set.map(f => Math.max(...f.map(Math.abs)))).toFixed(3));
}
for (let i = 1; i < on.length; i++) {
  const diff = on[i].map((v, j) => v - on[i - 1][j]);
  console.log(`on frame ${i} minus ${i - 1}: diff rms ${dbfs(rms(diff))} dBFS  (${(20 * Math.log10(rms(diff) / rms(on[i]))).toFixed(1)} dB re frame)`);
}
ws.close();
