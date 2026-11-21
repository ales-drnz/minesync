// Misure dello spike con Chrome headless via DevTools Protocol (nessuna
// dipendenza npm: WebSocket globale di Node >= 22).
//
// node measure/measure.mjs --chrome <percorso> --url http://hub.test:18080
//   [--out .tmp/results.json] [--shots .tmp/shots]
//
// Scenari:
//  - carico a freddo / a caldo con throttling 2 Mbit/s, 150 ms (CDP), per
//    build wasm (skwasm) e JS (canvaskit, ?renderer=canvaskit);
//  - memoria del processo renderer (PSS da /proc) e heap JS;
//  - routing: link vero, URL, tasto indietro, deep link;
//  - accessibilità: flt-semantics, etichette dei campi (albero AX), Tab;
//  - Ctrl+F simulato con window.find().
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const arg = (n, d) => {
  const i = process.argv.indexOf(`--${n}`);
  return i > 0 ? process.argv[i + 1] : d;
};
const CHROME = arg('chrome');
const BASE = arg('url', 'http://hub.test:18080');
const OUT = arg('out', '.tmp/results.json');
const SHOTS = arg('shots', '.tmp/shots');
const MBIT = Number(arg('mbit', '2'));
const LAT = Number(arg('latency', '150'));
const RUNS = Number(arg('runs', '3'));
const LOADS_ONLY = process.argv.includes('--loads-only');
fs.mkdirSync(SHOTS, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- avvio di Chrome e client CDP minimale ----------
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'spike-web-chrome-'));
const chrome = spawn(CHROME, [
  '--remote-debugging-port=0',
  `--user-data-dir=${profile}`,
  '--host-resolver-rules=MAP hub.test 127.0.0.1',
  '--no-first-run',
  '--window-size=1280,900',
  // WebGL software (skwasm/canvaskit lo richiedono): niente GPU in headless.
  '--use-angle=swiftshader',
  '--enable-unsafe-swiftshader',
], { stdio: ['ignore', 'ignore', 'pipe'] });
let wsUrl;
for (let i = 0; i < 100 && !wsUrl; i++) {
  await sleep(100);
  try {
    const port = fs.readFileSync(path.join(profile, 'DevToolsActivePort'), 'utf8').split('\n');
    wsUrl = `ws://127.0.0.1:${port[0]}${port[1]}`;
  } catch {}
}
if (!wsUrl) throw new Error('Chrome non partito');

const ws = new WebSocket(wsUrl);
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
let seq = 0;
const pending = new Map();
const listeners = new Set();
ws.onmessage = (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id && pending.has(msg.id)) {
    const { res, rej } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? rej(new Error(JSON.stringify(msg.error))) : res(msg.result);
  } else if (msg.method) {
    for (const l of listeners) l(msg);
  }
};
const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
  const id = ++seq;
  pending.set(id, { res, rej });
  ws.send(JSON.stringify({ id, method, params, sessionId }));
});

async function newTab(contextId) {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank', browserContextId: contextId });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const s = (m, p) => send(m, p, sessionId);
  await s('Page.enable');
  await s('Network.enable');
  await s('Runtime.enable');
  return { targetId, sessionId, s };
}
const evalJs = async (tab, expr) => {
  const r = await tab.s('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  return r.result.value;
};
async function waitFor(tab, expr, timeout = 90000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeout) {
    try { if (await evalJs(tab, expr)) return true; } catch {}
    await sleep(50);
  }
  return false;
}
async function shot(tab, name) {
  const { data } = await tab.s('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(SHOTS, `${name}.png`), Buffer.from(data, 'base64'));
}

// ---------- carico con throttling ----------
async function load(contextId, url, label, throttle = true) {
  const tab = await newTab(contextId);
  const reqs = new Map();
  const onEv = (m) => {
    if (m.sessionId !== tab.sessionId) return;
    const p = m.params;
    if (m.method === 'Network.responseReceived') {
      reqs.set(p.requestId, { url: p.response.url, status: p.response.status,
        cached: p.response.fromDiskCache || p.response.fromMemoryCache || false,
        enc: p.response.headers['content-encoding'] || '', bytes: 0 });
    } else if (m.method === 'Network.loadingFinished') {
      const r = reqs.get(p.requestId);
      if (r) r.bytes = p.encodedDataLength;
    }
  };
  listeners.add(onEv);
  if (throttle) {
    await tab.s('Network.emulateNetworkConditions', {
      offline: false, latency: LAT,
      downloadThroughput: (MBIT * 1e6) / 8, uploadThroughput: (MBIT * 1e6) / 8 / 2,
    });
  }
  await tab.s('Network.setCacheDisabled', { cacheDisabled: false });
  const t0 = Date.now();
  await tab.s('Page.navigate', { url });
  const ok = await waitFor(tab, "document.body && document.body.dataset.firstFrame === '1'");
  const wall = Date.now() - t0;
  await sleep(300);
  const perf = await evalJs(tab, `(() => {
    const m = performance.getEntriesByName('flutter-first-frame')[0];
    const fcp = performance.getEntriesByName('first-contentful-paint')[0];
    const nav = performance.getEntriesByType('navigation')[0];
    return { firstFrame: m ? Math.round(m.startTime) : null,
      splashFcp: fcp ? Math.round(fcp.startTime) : null,
      htmlDone: nav ? Math.round(nav.responseEnd) : null,
      wasm: !!window._flutter && typeof WebAssembly !== 'undefined' &&
        performance.getEntriesByType('resource').some(e => e.name.endsWith('main.dart.wasm')),
      crossOriginIsolated: window.crossOriginIsolated, isSecureContext };
  })()`);
  await shot(tab, label);
  listeners.delete(onEv);
  const list = [...reqs.values()];
  const transferred = list.reduce((a, r) => a + r.bytes, 0);
  return { tab, ok, wall, ...perf, requests: list.length, transferred,
    files: list.map((r) => ({ f: r.url.replace(/^https?:\/\/[^/]+/, ''), st: r.status, enc: r.enc, kb: +(r.bytes / 1024).toFixed(1), cached: r.cached })) };
}

async function memory(tab) {
  const m = await tab.s('Performance.enable').then(() => tab.s('Performance.getMetrics'));
  const js = m.metrics.find((x) => x.name === 'JSHeapUsedSize')?.value ?? 0;
  // PSS di tutti i processi renderer (una sola scheda aperta in quel momento).
  const info = await send('SystemInfo.getProcessInfo');
  let pss = 0;
  for (const p of info.processInfo.filter((p) => p.type === 'renderer')) {
    try {
      const t = fs.readFileSync(`/proc/${p.id}/smaps_rollup`, 'utf8');
      pss += Number(/^Pss:\s+(\d+)/m.exec(t)[1]);
    } catch {}
  }
  return { jsHeapMB: +(js / 1048576).toFixed(1), rendererPssMB: +(pss / 1024).toFixed(1) };
}

const median = (a) => { const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };

const results = { base: BASE, mbit: MBIT, latencyMs: LAT, runs: RUNS, chrome: (await send('Browser.getVersion')).product, loads: {} };

for (const [name, query] of RUNS > 0 ? [['wasm', ''], ['js', '?renderer=canvaskit']] : []) {
  const cold = [], warm = [];
  let mem, sampleCold, sampleWarm;
  for (let i = 0; i < RUNS; i++) {
    // Contesto nuovo = cache HTTP vuota (cache fredda).
    const { browserContextId } = await send('Target.createBrowserContext');
    const c = await load(browserContextId, `${BASE}/${query}`, `${name}-cold-${i}`);
    await send('Target.closeTarget', { targetId: c.tab.targetId });
    // Seconda visita nello stesso contesto = cache calda (nuova scheda).
    const w = await load(browserContextId, `${BASE}/${query}`, `${name}-warm-${i}`);
    if (i === 0) { await sleep(3000); mem = await memory(w.tab); }
    await send('Target.closeTarget', { targetId: w.tab.targetId });
    await send('Target.disposeBrowserContext', { browserContextId });
    delete c.tab; delete w.tab;
    cold.push(c); warm.push(w);
    if (i === 0) { sampleCold = c; sampleWarm = w; }
    console.error(`${name} run ${i}: cold ${c.firstFrame} ms (${(c.transferred / 1024).toFixed(0)} KB), warm ${w.firstFrame} ms (${(w.transferred / 1024).toFixed(0)} KB)`);
  }
  results.loads[name] = {
    coldFirstFrameMs: cold.map((r) => r.firstFrame), warmFirstFrameMs: warm.map((r) => r.firstFrame),
    coldMedianMs: median(cold.map((r) => r.firstFrame)), warmMedianMs: median(warm.map((r) => r.firstFrame)),
    coldSplashFcpMs: median(cold.map((r) => r.splashFcp)), warmSplashFcpMs: median(warm.map((r) => r.splashFcp)),
    coldTransferredKB: Math.round(sampleCold.transferred / 1024), warmTransferredKB: Math.round(sampleWarm.transferred / 1024),
    usedWasm: sampleCold.wasm, crossOriginIsolated: sampleCold.crossOriginIsolated, secureContext: sampleCold.isSecureContext,
    memory: mem, coldFiles: sampleCold.files, warmFiles: sampleWarm.files,
  };
}

// ---------- routing ----------
async function routingRun(query) {
  const { browserContextId } = await send('Target.createBrowserContext');
  const r = await load(browserContextId, `${BASE}/${query}`, `route${query ? '-a11y' : ''}`, false);
  const tab = r.tab;
  const out = {};
  await sleep(800);
  // Click vero sul link "Admin": coordinate dall'elemento <a> o dal nodo semantico.
  const rect = await evalJs(tab, `(() => {
    const all = [...document.querySelectorAll('a')].filter(a => a.getAttribute('href') === '/admin');
    const el = all.find(a => a.id.startsWith('flt-semantic')) || all[0];
    if (!el) return null;
    const b = el.getBoundingClientRect(); return { x: b.x + b.width / 2, y: b.y + b.height / 2, tag: el.tagName, href: el.href };
  })()`);
  out.adminAnchor = rect;
  if (rect) {
    for (const type of ['mousePressed', 'mouseReleased']) {
      await tab.s('Input.dispatchMouseEvent', { type, x: rect.x, y: rect.y, button: 'left', clickCount: 1 });
    }
  }
  await waitFor(tab, "location.pathname === '/admin' && document.title === 'Hub · Admin'", 5000);
  out.afterClick = await evalJs(tab, '({ path: location.pathname, title: document.title, hist: history.length })');
  const h = await tab.s('Page.getNavigationHistory');
  if (h.currentIndex > 0) await tab.s('Page.navigateToHistoryEntry', { entryId: h.entries[h.currentIndex - 1].id });
  await waitFor(tab, "location.pathname === '/' && document.title === 'Hub · Panoramica'", 5000);
  out.afterBack = await evalJs(tab, '({ path: location.pathname, title: document.title })');
  // Deep link + reload su un percorso interno.
  await tab.s('Page.navigate', { url: `${BASE}/server/isola` });
  await waitFor(tab, "document.title === 'Hub · Server isola'", 20000);
  out.deepLink = await evalJs(tab, '({ path: location.pathname, title: document.title })');
  out.pass = out.afterClick?.path === '/admin' && out.afterClick?.title === 'Hub · Admin' &&
    out.afterBack?.path === '/' && out.afterBack?.title === 'Hub · Panoramica' &&
    out.deepLink?.title === 'Hub · Server isola';
  
  await send('Target.disposeBrowserContext', { browserContextId });
  return out;
}
if (!LOADS_ONLY) {
  results.routing = await routingRun('');
  results.routingA11y = await routingRun('?a11y=1');
}

// ---------- accessibilità, tastiera, Ctrl+F ----------
async function a11yRun(query) {
  const { browserContextId } = await send('Target.createBrowserContext');
  const r = await load(browserContextId, `${BASE}/admin${query}`, `admin${query ? '-a11y' : ''}`, false);
  const tab = r.tab;
  await sleep(500);
  const out = {};
  out.dom = await evalJs(tab, `(() => ({
    fltSemantics: document.querySelectorAll('flt-semantics').length,
    placeholder: (() => { const p = document.querySelector('flt-semantics-placeholder');
      return p ? { label: p.getAttribute('aria-label'), role: p.getAttribute('role') } : null; })(),
    inputs: document.querySelectorAll('input, textarea').length,
  }))()`);
  await tab.s('Accessibility.enable');
  const { nodes } = await tab.s('Accessibility.getFullAXTree');
  const roles = {};
  const fields = [];
  for (const n of nodes) {
    const role = n.role?.value;
    if (!role || n.ignored) continue;
    roles[role] = (roles[role] || 0) + 1;
    if (['textbox', 'combobox', 'switch', 'checkbox', 'spinbutton', 'button', 'link'].includes(role)) {
      fields.push({ role, name: n.name?.value || '' });
    }
  }
  out.axRoles = roles;
  const formFields = fields.filter((f) => ['textbox', 'combobox', 'switch', 'checkbox', 'spinbutton'].includes(f.role));
  out.formFields = formFields.length;
  out.formFieldsLabelled = formFields.filter((f) => f.name.trim()).length;
  out.sampleFields = formFields.slice(0, 8);
  out.links = fields.filter((f) => f.role === 'link');
  out.buttons = fields.filter((f) => f.role === 'button');
  // Ctrl+F simulato: window.find usa lo stesso motore di "trova nella pagina".
  out.findTopOfAdmin = await evalJs(tab, `(() => ({
    'Porta HTTP': window.find('Porta HTTP'),
    'Avvisa se (fuori schermo)': (getSelection().removeAllRanges(), window.find('Avvisa se un server aperto')),
    'Europe/Rome': (getSelection().removeAllRanges(), window.find('Europe/Rome')),
  }))()`);
  // Tab: sequenza dei fuochi (gancio data-focus) e activeElement del DOM.
  const seqs = [];
  for (let i = 0; i < 14; i++) {
    await tab.s('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
    await tab.s('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
    await sleep(120);
    seqs.push(await evalJs(tab, `(() => { const a = document.activeElement;
      return { flutter: document.body.dataset.focus || '', dom: a ? a.tagName.toLowerCase() + (a.getAttribute('aria-label') ? '[' + a.getAttribute('aria-label') + ']' : '') : '' }; })()`));
  }
  out.tabSequence = seqs;
  // Scrittura da tastiera: ricarica, Tab fino al campo "Porta HTTP",
  // scrive un valore fuori intervallo, poi Tab fino a "Salva" e Invio.
  const press = async (key, vk, extra = {}) => {
    await tab.s('Input.dispatchKeyEvent', { type: 'keyDown', key, code: key, windowsVirtualKeyCode: vk, ...extra });
    await tab.s('Input.dispatchKeyEvent', { type: 'keyUp', key, code: key, windowsVirtualKeyCode: vk });
  };
  await tab.s('Page.navigate', { url: `${BASE}/admin${query}` });
  await waitFor(tab, "document.body && document.body.dataset.firstFrame === '1'", 30000);
  await sleep(800);
  for (let i = 0; i < 30 && !(await evalJs(tab, "(document.body.dataset.focus||'').includes('Porta HTTP')")); i++) {
    await press('Tab', 9);
    await sleep(100);
  }
  const reached = await evalJs(tab, "(document.body.dataset.focus||'').includes('Porta HTTP')");
  if (reached) {
    await tab.s('Input.dispatchKeyEvent', { type: 'keyDown', key: 'a', code: 'KeyA', modifiers: 2, windowsVirtualKeyCode: 65, commands: ['selectAll'] });
    await tab.s('Input.dispatchKeyEvent', { type: 'keyUp', key: 'a', code: 'KeyA', modifiers: 2, windowsVirtualKeyCode: 65 });
    await tab.s('Input.insertText', { text: '99999' });
    await sleep(300);
    out.portValueInDom = await evalJs(tab, "document.activeElement && document.activeElement.value");
  }
  let tabs = 0;
  while (tabs < 120 && !(await evalJs(tab, "(document.body.dataset.focus||'') === 'pulsante: Salva'"))) {
    await press('Tab', 9);
    await sleep(60);
    tabs++;
  }
  out.tabsToSave = tabs;
  out.reachedSave = await evalJs(tab, "(document.body.dataset.focus||'') === 'pulsante: Salva'");
  await press('Enter', 13, { text: '\r' });
  await sleep(800);
  await shot(tab, `admin-after-save${query ? '-a11y' : ''}`);
  const ax2 = (await tab.s('Accessibility.getFullAXTree')).nodes.map((n) => n.name?.value || '').join('\n');
  out.typedIntoPort = reached && out.portValueInDom === '99999';
  out.validationVisibleInAX = ax2.includes('Fuori intervallo') || ax2.includes('Controlla i campi');
  await tab.s('Page.navigate', { url: `${BASE}/${query}` });
  await waitFor(tab, "document.title === 'Hub · Panoramica'", 20000);
  await sleep(800);
  out.findOverview = await evalJs(tab, `(() => { getSelection().removeAllRanges(); return {
    'Sara, Luca, Teo': window.find('Sara, Luca, Teo'),
    'quasi pieno': (getSelection().removeAllRanges(), window.find('quasi pieno')) }; })()`);
  await send('Target.disposeBrowserContext', { browserContextId });
  return out;
}
if (!LOADS_ONLY) {
  results.a11yDefault = await a11yRun('');
  results.a11yForced = await a11yRun('?a11y=1');
}

fs.writeFileSync(OUT, JSON.stringify(results, null, 2));
console.log(JSON.stringify({
  wasm: { cold: results.loads.wasm?.coldMedianMs, warm: results.loads.wasm?.warmMedianMs, kb: results.loads.wasm?.coldTransferredKB, mem: results.loads.wasm?.memory },
  js: { cold: results.loads.js?.coldMedianMs, warm: results.loads.js?.warmMedianMs, kb: results.loads.js?.coldTransferredKB, mem: results.loads.js?.memory },
  keyboard: LOADS_ONLY ? null : [results.a11yDefault.reachedSave, results.a11yDefault.typedIntoPort, results.a11yForced.reachedSave, results.a11yForced.typedIntoPort],
  labels: LOADS_ONLY ? null : `${results.a11yForced.formFieldsLabelled}/${results.a11yForced.formFields}`,
  routing: results.routing?.pass, routingA11y: results.routingA11y?.pass,
}));
ws.close();
chrome.kill();
fs.rmSync(profile, { recursive: true, force: true });
process.exit(0);
