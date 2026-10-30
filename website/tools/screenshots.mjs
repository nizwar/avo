#!/usr/bin/env node
// Full-page screenshots and layout checks with headless Chrome over the
// DevTools protocol (no Puppeteer). Uses a throwaway Chrome profile, so it
// never touches your own browser windows.
//
//   node tools/screenshots.mjs --out DIR [--site http://localhost:8788/]
//                              [--chrome PATH] [--only NAME] [--views desktop,phone]
//
// For every page and width it saves a PNG, and reports content that sticks
// out sideways (horizontal scroll on phones), console errors and failed
// requests. Exit code 1 if any check fails. Start `npm run dev` first.

import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { crc32, deflateSync, inflateSync } from 'node:zlib';
import path from 'node:path';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const OUT = path.resolve(option('--out', 'screenshots'));
const SITE = option('--site', 'http://localhost:8788/');
const CHROME = option('--chrome', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
const ONLY = option('--only', null);
const VIEWS = option('--views', null);

const VIEWPORTS = {
  desktop: { width: 1440, height: 900, scale: 1, mobile: false },
  laptop: { width: 1280, height: 800, scale: 1, mobile: false },
  tablet: { width: 820, height: 1180, scale: 1, mobile: false },
  phone: { width: 390, height: 844, scale: 2, mobile: true },
  small: { width: 320, height: 640, scale: 2, mobile: true },
};

const ALL = ['desktop', 'laptop', 'tablet', 'phone', 'small'];
const SHOTS = [
  { name: 'home-en', url: SITE, views: ALL },
  { name: 'home-id', url: `${SITE}id/`, views: ALL },
  { name: 'hub-en', url: `${SITE}hub/`, views: ALL },
  { name: 'hub-id', url: `${SITE}id/hub/`, views: ALL },
  { name: 'notfound', url: `${SITE}does-not-exist/deeper/`, views: ['desktop', 'phone'], expectStatus: 404 },
  { name: 'home-en-reduced-motion', url: SITE, views: ['desktop'], reducedMotion: true },
  // Without JavaScript every word and picture must still be there.
  { name: 'home-en-no-script', url: SITE, views: ['desktop', 'phone'], noScript: true },
  { name: 'hub-en-no-script', url: `${SITE}hub/`, views: ['desktop', 'phone'], noScript: true },
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const started = Date.now();
const debug = (...m) => { if (process.env.DEBUG_SHOTS) console.log(`[${((Date.now() - started) / 1000).toFixed(1)}s]`, ...m); };

async function launch() {
  const profile = await mkdtemp(path.join(tmpdir(), 'avo-shots-'));
  const chrome = spawn(CHROME, [
    '--headless=new',
    '--remote-debugging-port=0',
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--hide-scrollbars',
    'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  const wsUrl = await new Promise((resolve, reject) => {
    let buffer = '';
    const timer = setTimeout(() => reject(new Error('Chrome did not start')), 20000);
    chrome.stderr.on('data', (chunk) => {
      buffer += chunk;
      const m = /DevTools listening on (ws:\/\/\S+)/.exec(buffer);
      if (m) {
        clearTimeout(timer);
        resolve(m[1]);
      }
    });
    chrome.on('exit', () => reject(new Error('Chrome exited')));
  });
  return { chrome, profile, wsUrl };
}

function connect(wsUrl) {
  const ws = new WebSocket(wsUrl);
  let id = 0;
  const pending = new Map();
  const listeners = new Set();
  ws.addEventListener('message', (event) => {
    const msg = JSON.parse(event.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(`${msg.error.message} ${msg.error.data || ''}`));
      else resolve(msg.result);
    } else {
      for (const fn of listeners) fn(msg);
    }
  });
  const ready = new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve);
    ws.addEventListener('error', reject);
  });
  return {
    ready,
    send(method, params = {}, sessionId) {
      const msgId = ++id;
      ws.send(JSON.stringify({ id: msgId, method, params, sessionId }));
      return new Promise((resolve, reject) => pending.set(msgId, { resolve, reject }));
    },
    on(fn) {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },
    close: () => ws.close(),
  };
}

const OVERFLOW_CHECK = `(() => {
  const vw = document.documentElement.clientWidth;
  const clips = (el) => {
    for (let a = el.parentElement; a && a !== document.body; a = a.parentElement) {
      const s = getComputedStyle(a);
      if (/(hidden|clip|auto|scroll)/.test(s.overflowX)) {
        const r = a.getBoundingClientRect();
        if (r.left >= -1 && r.right <= vw + 1) return true;
      }
    }
    return false;
  };
  const offenders = [];
  for (const el of document.querySelectorAll('body *')) {
    if (el.closest('.glow, .haze-canvas, .hero-sky, .sprite, .visually-hidden, .skip-link, dialog:not([open])')) continue;
    const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden') continue;
    const r = el.getBoundingClientRect();
    if (!r.width || !r.height) continue;
    if ((r.right > vw + 1 || r.left < -1) && !clips(el)) {
      offenders.push((el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\\s+/).join('.') : '')) + ' [' + Math.round(r.left) + ',' + Math.round(r.right) + ']');
    }
  }
  return { vw, scrollWidth: document.documentElement.scrollWidth, offenders: offenders.slice(0, 12), count: offenders.length };
})()`;

let page = null;

/** One page for all shots: new targets in headless Chrome may never paint. */
async function pageSession(browser) {
  if (page) return page;
  const { targetInfos } = await browser.send('Target.getTargets');
  let target = targetInfos.find((t) => t.type === 'page');
  if (!target) target = { targetId: (await browser.send('Target.createTarget', { url: 'about:blank' })).targetId };
  const { sessionId } = await browser.send('Target.attachToTarget', { targetId: target.targetId, flatten: true });
  page = { sessionId, targetId: target.targetId };
  for (const domain of ['Page', 'Runtime', 'Log', 'Network']) await browser.send(`${domain}.enable`, {}, sessionId);
  return page;
}

async function shoot(browser, shot, viewName) {
  const view = VIEWPORTS[viewName];
  const { sessionId } = await pageSession(browser);
  const send = (method, params) => browser.send(method, params, sessionId);
  const problems = [];
  let status = null;
  const off = browser.on((msg) => {
    if (msg.sessionId !== sessionId) return;
    if (msg.method === 'Runtime.exceptionThrown') problems.push(`exception: ${msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text}`);
    if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') problems.push(`console.error: ${msg.params.args.map((a) => a.value ?? a.description).join(' ')}`);
    if (msg.method === 'Log.entryAdded' && msg.params.entry.level === 'error' && !/favicon/.test(msg.params.entry.url || '')) {
      const expected404 = (shot.expectStatus === 404 && /status of 404/.test(msg.params.entry.text)) || shot.expectLog?.test(msg.params.entry.text);
      if (!expected404) problems.push(`log: ${msg.params.entry.text} ${msg.params.entry.url || ''}`);
    }
    if (msg.method === 'Network.responseReceived' && msg.params.type === 'Document') status = msg.params.response.status;
    if (msg.method === 'Network.loadingFailed' && !msg.params.canceled) problems.push(`request failed: ${msg.params.errorText}`);
  });
  await send('Network.clearBrowserCookies');
  await send('Emulation.setDeviceMetricsOverride', { width: view.width, height: view.height, deviceScaleFactor: view.scale, mobile: view.mobile });
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: shot.reducedMotion ? 'reduce' : 'no-preference' }, { name: 'prefers-color-scheme', value: 'dark' }] });
  await send('Emulation.setTouchEmulationEnabled', { enabled: view.mobile, maxTouchPoints: view.mobile ? 5 : 1 });
  await send('Emulation.setScriptExecutionDisabled', { value: Boolean(shot.noScript) });

  const loaded = new Promise((resolve) => {
    const stop = browser.on((msg) => {
      if (msg.sessionId === sessionId && msg.method === 'Page.loadEventFired') {
        stop();
        resolve();
      }
    });
  });
  debug('navigate ' + shot.url);
  await send('Page.navigate', { url: shot.url });
  await Promise.race([loaded, sleep(15000)]);
  const evaluate = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })).result.value;
  debug('fonts');
  await evaluate('document.fonts.ready.then(() => true)');
  await sleep(900);
  if (shot.waitFor) await evaluate(`(async () => { for (let i = 0; i < 50 && !(${shot.waitFor}); i++) await new Promise((r) => setTimeout(r, 100)); return true; })()`);

  const inPage = (body) => evaluate(`(async () => {
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    const set = (sel, v) => { const el = document.querySelector(sel); el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); };
    ${body}
    return true;
  })()`);
  if (shot.prepare) {
    debug('prepare');
    await inPage(shot.prepare);
  }
  if (shot.after) await inPage(shot.after);

  if (shot.viewportOnly) {
    const { data } = await send('Page.captureScreenshot', { format: 'png' });
    const file = path.join(OUT, `${shot.name}-${viewName}-${view.width}.png`);
    await writeFile(file, Buffer.from(data, 'base64'));
    off();
    await send('Page.navigate', { url: 'about:blank' });
    return { file, problems, height: view.height };
  }

  debug('scroll');
  // Scroll through once so scroll-triggered content shows, then back to the top.
  await evaluate(`(async () => {
    document.documentElement.style.scrollBehavior = 'auto';
    const step = Math.round(innerHeight * 0.7);
    for (let y = 0; y < document.documentElement.scrollHeight; y += step) { scrollTo({ top: y, behavior: 'instant' }); await new Promise((r) => setTimeout(r, 120)); }
    scrollTo({ top: 0, behavior: 'instant' });
    await new Promise((r) => setTimeout(r, 1200));
    return true;
  })()`);

  debug('overflow check');
  const overflow = await evaluate(OVERFLOW_CHECK);
  if (overflow.count) problems.push(`content wider than the ${overflow.vw}px viewport: ${overflow.offenders.join(', ')}`);
  // Even clipped or decorative content counts here: on phones a wider page
  // can be zoomed out or nudged sideways.
  if (overflow.scrollWidth > overflow.vw + 1) problems.push(`the page is ${overflow.scrollWidth}px wide on a ${overflow.vw}px screen`);
  if (shot.expectStatus && status !== shot.expectStatus) problems.push(`expected HTTP ${shot.expectStatus}, got ${status}`);
  if (!shot.expectStatus && status && status !== 200) problems.push(`HTTP ${status}`);

  debug('metrics');
  // Full page: captured slice by slice and joined, because one tall capture
  // of a long page can stall headless Chrome.
  const { data, height } = await fullPage(send, evaluate, view);
  debug('captured');
  const file = path.join(OUT, `${shot.name}-${viewName}-${view.width}.png`);
  await writeFile(file, Buffer.from(data, 'base64'));

  off();
  await send('Page.navigate', { url: 'about:blank' });
  return { file, problems, height };
}

const MAX_HEIGHT = 24000;

async function fullPage(send, evaluate, view) {
  // Held (sticky) things would repeat in every slice: put them back in the
  // flow, and show the header only at the top.
  await evaluate(`(() => {
    for (const el of document.querySelectorAll('.story-text, .story-figure, .faq-title, .index-stage, .pair-stage')) el.style.position = 'static';
    // Entrances that the quick scroll above passed by: let them all in.
    for (const el of document.querySelectorAll('[data-rise]')) el.classList.add('is-in');
    return true;
  })()`);
  const total = await evaluate('document.documentElement.scrollHeight');
  const height = Math.min(total, MAX_HEIGHT);
  const slices = [];
  for (let y = 0; ; y += view.height) {
    const top = Math.max(0, Math.min(y, height - view.height));
    const actual = await evaluate(`(async () => {
      document.documentElement.style.scrollBehavior = 'auto';
      scrollTo({ top: ${top}, behavior: 'instant' });
      const header = document.querySelector('.site-header, .bar');
      if (header) header.style.visibility = ${top} > 0 ? 'hidden' : '';
      for (let i = 0; i < 20 && Math.abs(scrollY - ${top}) > 1; i++) await new Promise((r) => setTimeout(r, 50));
      await new Promise((r) => setTimeout(r, 220));
      return scrollY;
    })()`);
    debug('slice', top, 'scrollY', actual);
    const { data } = await send('Page.captureScreenshot', { format: 'png' });
    // Place each slice where the page really scrolled to, so a short scroll
    // can never repeat a strip of the page.
    slices.push({ top: actual, data });
    if (top + view.height >= height || (slices.length > 1 && actual <= slices[slices.length - 2].top)) break;
  }
  debug('restore');
  await evaluate(`(() => { const h = document.querySelector('.site-header, .bar'); if (h) h.style.visibility = ''; scrollTo({ top: 0, behavior: 'instant' }); return true; })()`);
  debug('join');
  if (slices.length === 1) return { data: slices[0].data, height };
  debug('join', slices.length);
  const captured = Math.max(...slices.map((s) => s.top + view.height));
  return { data: joinPngs(slices, view.scale).toString('base64'), height: Math.min(height, captured) };
}

// Minimal PNG reading and writing (8-bit RGB/RGBA, not interlaced, which is
// what Chrome produces), to join slices without any image library.
function readPng(buffer) {
  let offset = 8;
  let width = 0;
  let height = 0;
  let channels = 0;
  const idat = [];
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString('ascii', offset + 4, offset + 8);
    const body = buffer.subarray(offset + 8, offset + 8 + length);
    if (type === 'IHDR') {
      width = body.readUInt32BE(0);
      height = body.readUInt32BE(4);
      const [depth, color, , , interlace] = body.subarray(8, 13);
      if (depth !== 8 || interlace !== 0 || (color !== 2 && color !== 6)) throw new Error('unsupported PNG');
      channels = color === 6 ? 4 : 3;
    } else if (type === 'IDAT') idat.push(body);
    offset += 12 + length;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const pixels = Buffer.alloc(width * height * 4);
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = Buffer.from(raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)));
    for (let x = 0; x < stride; x++) {
      const a = x >= channels ? line[x - channels] : 0;
      const b = prev[x];
      const c = x >= channels ? prev[x - channels] : 0;
      let add = 0;
      if (filter === 1) add = a;
      else if (filter === 2) add = b;
      else if (filter === 3) add = (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - b);
        const pc = Math.abs(p - c);
        add = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      line[x] = (line[x] + add) & 0xff;
    }
    for (let x = 0; x < width; x++) {
      pixels[(y * width + x) * 4] = line[x * channels];
      pixels[(y * width + x) * 4 + 1] = line[x * channels + 1];
      pixels[(y * width + x) * 4 + 2] = line[x * channels + 2];
      pixels[(y * width + x) * 4 + 3] = channels === 4 ? line[x * channels + 3] : 255;
    }
    prev = line;
  }
  return { width, height, pixels };
}

function writePng(width, height, pixels) {
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) pixels.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  const chunk = (type, body) => {
    const head = Buffer.alloc(8);
    head.writeUInt32BE(body.length, 0);
    head.write(type, 4, 'ascii');
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), body])) >>> 0, 0);
    return Buffer.concat([head, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 6 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function joinPngs(slices, scale) {
  const images = slices.map((s) => ({ top: Math.round(s.top * scale), ...readPng(Buffer.from(s.data, 'base64')) }));
  const width = images[0].width;
  const height = Math.max(...images.map((i) => i.top + i.height));
  const pixels = Buffer.alloc(width * height * 4);
  for (const image of images) image.pixels.copy(pixels, image.top * width * 4);
  return writePng(width, height, pixels);
}

await mkdir(OUT, { recursive: true });
const { chrome, profile, wsUrl } = await launch();
const browser = connect(wsUrl);
await browser.ready;
let failed = false;
try {
  for (const shot of SHOTS) {
    if (ONLY && shot.name !== ONLY) continue;
    for (const viewName of VIEWS ? VIEWS.split(',') : shot.views) {
      const result = await shoot(browser, shot, viewName);
      const ok = result.problems.length === 0;
      failed ||= !ok;
      console.log(`${ok ? 'ok  ' : 'FAIL'} ${path.basename(result.file)} (${result.height}px)`);
      for (const p of result.problems) console.log(`       ${p}`);
    }
  }
} finally {
  browser.close();
  chrome.kill();
  await sleep(300);
  await rm(profile, { recursive: true, force: true }).catch(() => {});
}
process.exit(failed ? 1 : 0);
