// The static site: every page in both languages, links that resolve, no
// emoji, CSP-friendly markup, and the switches in site.config.mjs.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { build } from '../tools/build.mjs';

let out;
const PAGES = ['index.html', 'id/index.html', 'hub/index.html', 'id/hub/index.html', '404.html'];
const read = (rel) => readFileSync(path.join(out, rel), 'utf8');

function files(dir, base = dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    return statSync(full).isDirectory() ? files(full, base) : [path.relative(base, full)];
  });
}

before(async () => {
  out = await mkdtemp(path.join(tmpdir(), 'avo-site-'));
  await build({ outDir: out, quiet: true });
  process.on('exit', () => rm(out, { recursive: true, force: true }));
});

test('every page exists in both languages with the right lang and alternates', () => {
  for (const page of PAGES) assert.ok(existsSync(path.join(out, page)), page);
  assert.match(read('index.html'), /<html lang="en">/);
  assert.match(read('id/index.html'), /<html lang="id">/);
  for (const page of ['index.html', 'id/index.html']) {
    const html = read(page);
    assert.match(html, /<link rel="alternate" hreflang="en" href="https:\/\/[^"]+">/);
    assert.match(html, /<link rel="alternate" hreflang="id" href="https:\/\/[^"]+\/id\/[^"]*">/);
    assert.match(html, /<meta property="og:image" content="https:\/\/[^"]+\.jpg">/);
    assert.match(html, /<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self';/);
  }
  assert.match(read('id/index.html'), /<h1 id="hero-title" class="display">Aplikasi dan game Android, langsung di Mac kamu\.<\/h1>/);
});

test('Avo Hub has its page in both languages, in the menu, honest about its release', async () => {
  const en = read('hub/index.html');
  const id = read('id/hub/index.html');
  assert.match(en, /<html lang="en">/);
  assert.match(id, /<html lang="id">/);
  assert.match(en, /<link rel="canonical" href="https:\/\/[^"]+\/hub\/">/);
  assert.match(en, /<link rel="alternate" hreflang="id" href="https:\/\/[^"]+\/id\/hub\/">/);
  assert.match(id, /<link rel="alternate" hreflang="en" href="https:\/\/[^"]+\/hub\/">/);
  assert.match(en, /<a class="lang-switch" href="\.\.\/id\/hub\/"/);
  assert.match(id, /<a class="lang-switch" href="\.\.\/\.\.\/hub\/"/);
  assert.match(en, /<h1 id="hero-title" class="display">Your Android phone, at home on your Mac\.<\/h1>/);
  assert.match(id, /<h1 id="hero-title" class="display">Ponsel Android kamu, menyatu dengan Mac\.<\/h1>/);
  assert.match(en, /"name":"Avo Hub"/);
  // Every page's menu leads to it, and on its own page the link says so.
  for (const page of PAGES) assert.match(read(page), /<li><a href="[^"]*hub\/"( aria-current="page")?>Avo Hub<\/a><\/li>/, page);
  assert.match(en, /<a href="\.\.\/hub\/" aria-current="page">Avo Hub<\/a>/);
  assert.match(read('sitemap.xml'), /<loc>https:\/\/[^<]+\/id\/hub\/<\/loc>/);

  // Not released: no download, GitHub and building from source instead.
  assert.match(en, /In development: not released yet/);
  assert.match(en, /href="https:\/\/github\.com\/nizwar\/avo_hub"/);
  assert.match(en, /href="https:\/\/github\.com\/nizwar\/avo_hub#building-from-source"/);
  assert.doesNotMatch(en, /Download for Mac/);

  const dir = await mkdtemp(path.join(tmpdir(), 'avo-site-'));
  try {
    const downloadUrl = 'https://github.com/nizwar/avo_hub/releases/download/v0.1.0/AvoHub-0.1.0-b2.dmg';
    await build({ outDir: dir, quiet: true, overrides: { hub: { release: { available: true, version: '0.1.0 Preview 1', downloadUrl } } } });
    const released = readFileSync(path.join(dir, 'hub/index.html'), 'utf8');
    assert.match(released, /Version 0\.1\.0 Preview 1 is out/);
    assert.match(released, /Download for Mac/);
    assert.ok(released.includes(`href="${downloadUrl}"`));
    assert.doesNotMatch(released, /not released yet|Coming soon/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('no emoji anywhere in the built site', () => {
  for (const rel of files(out)) {
    if (!/\.(html|css|js|json|txt|xml|webmanifest|svg)$/.test(rel)) continue;
    const text = readFileSync(path.join(out, rel), 'utf8');
    const match = text.match(/\p{Extended_Pictographic}/u);
    assert.equal(match, null, `${rel} contains ${match?.[0]}`);
  }
});

test('markup is CSP-friendly and accessible at the basics', () => {
  for (const page of PAGES) {
    const html = read(page);
    assert.doesNotMatch(html, /\son[a-z]+="/i, `${page}: inline event handler`);
    assert.doesNotMatch(html, /\sstyle="/i, `${page}: inline style`);
    assert.doesNotMatch(html, /<script(?![^>]*\b(type="(application\/json|application\/ld\+json|module)"))[^>]*>/, `${page}: classic or inline script`);
    for (const img of html.match(/<img\b[^>]*>/g) || []) {
      assert.match(img, /\balt="/, `${page}: ${img}`);
      assert.match(img, /\bwidth="\d+"[^>]*\bheight="\d+"/, `${page}: give every image its size, so nothing jumps while loading: ${img}`);
    }
    const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]);
    assert.equal(new Set(ids).size, ids.length, `${page}: duplicate id`);
    assert.equal((html.match(/<h1\b/g) || []).length, 1, `${page}: one h1`);
    assert.match(html, /<a class="skip-link" href="#main">/);
    assert.match(html, /<main id="main"/);
    const visible = html.replace(/<script[\s\S]*?<\/script>/g, '').replace(/<style[\s\S]*?<\/style>/g, '');
    assert.doesNotMatch(visible, /\{\{|\{[a-z][a-zA-Z]*\}/, `${page}: unreplaced placeholder`);
  }
});

test('internal links and assets resolve', () => {
  for (const page of PAGES.filter((p) => p !== '404.html')) {
    const html = read(page);
    const dir = path.dirname(path.join(out, page));
    const srcsets = [...html.matchAll(/\ssrcset="([^"]+)"/g)].flatMap(([, list]) => list.split(',').map((entry) => ` src="${entry.trim().split(/\s+/)[0]}"`));
    for (const [, attr] of `${html}${srcsets.join('')}`.matchAll(/\s(?:href|src)="([^"]+)"/g)) {
      if (/^(https?:|mailto:|data:|#)/.test(attr)) continue;
      const [file, hash] = attr.split('#');
      const clean = file.split('?')[0];
      let target = path.resolve(dir, clean || '.');
      if (existsSync(target) && statSync(target).isDirectory()) target = path.join(target, 'index.html');
      assert.ok(existsSync(target), `${page}: ${attr} -> missing ${path.relative(out, target)}`);
      if (hash && target.endsWith('.html')) assert.match(readFileSync(target, 'utf8'), new RegExp(`id="${hash}"`), `${page}: ${attr} -> no #${hash}`);
    }
  }
  // 404.html is served at any depth, so it links from the site root.
  assert.match(read('404.html'), /href="\/assets\/css\/site\.css\?v=/);
});

test('screenshots: AVIF and WebP with a JPEG fallback, translated alt text, lazy below the fold', () => {
  for (const [page, heroAlt] of [['index.html', /alt="Avo's library window/], ['id/index.html', /alt="Jendela pustaka Avo/]]) {
    const pictures = read(page).match(/<picture>[\s\S]*?<\/picture>/g) || [];
    assert.ok(pictures.length >= 9, `${page}: ${pictures.length} screenshots`);
    assert.match(pictures[0], heroAlt, page);
    pictures.forEach((picture, i) => {
      assert.match(picture, /<source type="image\/avif" srcset="[^"]+ 640w, [^"]+ \d+w" sizes="[^"]+">/, `${page}: picture ${i}`);
      assert.match(picture, /<source type="image\/webp" srcset="[^"]+ 640w, [^"]+ \d+w" sizes="[^"]+">/, `${page}: picture ${i}`);
      assert.match(picture, /<img src="[^"]+\.jpg" srcset="[^"]+"/, `${page}: picture ${i}`);
      // The hero image is on screen at once; the rest wait until scrolled to.
      if (i === 0) assert.doesNotMatch(picture, /loading="lazy"/, page);
      else assert.match(picture, /loading="lazy"/, `${page}: picture ${i}`);
    });
  }
});

test('the unreleased state is honest; a release shows the download', async () => {
  // The published build: the button downloads the disk image itself.
  const home = read('index.html');
  assert.match(home, /Download for Mac/);
  assert.match(home, /href="https:\/\/github\.com\/nizwar\/avo\/releases\/download\/v[^"]+\.dmg"/);

  const unreleased = await mkdtemp(path.join(tmpdir(), 'avo-site-'));
  try {
    await build({ outDir: unreleased, quiet: true, overrides: { release: { available: false } } });
    const html = readFileSync(path.join(unreleased, 'index.html'), 'utf8');
    assert.match(html, /preview builds only/);
    assert.match(html, /Follow on GitHub/);
    assert.doesNotMatch(html, /Download for Mac/);
  } finally {
    await rm(unreleased, { recursive: true, force: true });
  }

  const dir = await mkdtemp(path.join(tmpdir(), 'avo-site-'));
  try {
    await build({ outDir: dir, quiet: true, overrides: { release: { available: true, version: '0.1.0', downloadUrl: 'https://github.com/nizwar/avo/releases/download/v0.1.0/Avo.dmg' } } });
    const released = readFileSync(path.join(dir, 'index.html'), 'utf8');
    assert.match(released, /Download for Mac/);
    assert.match(released, /Version 0\.1\.0 is out/);
    assert.match(released, /href="https:\/\/github\.com\/nizwar\/avo\/releases\/download\/v0\.1\.0\/Avo\.dmg"/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('support goes to the developer: one section with its channels', async () => {
  for (const page of ['index.html', 'id/index.html']) {
    const html = read(page);
    assert.match(html, /<section class="section support" id="support"/, page);
    assert.match(html, /<a href="[^"]*#support">/, `${page}: the menu links to it`);
  }
  const home = read('index.html');
  assert.match(home, /href="https:\/\/github\.com\/sponsors\/nizwar"/);
  assert.match(home, /href="https:\/\/paypal\.me\/nizwar"/);
  assert.match(home, /href="https:\/\/saweria\.co\/hangpuan"/);
  assert.match(home, /Monthly or one-time · USD/);
  assert.doesNotMatch(home, /streamKey/, 'no link that carries a key');
  // No channel at all: said plainly.
  const dir = await mkdtemp(path.join(tmpdir(), 'avo-site-'));
  try {
    await build({ outDir: dir, quiet: true, overrides: { support: { channels: [] } } });
    assert.match(readFileSync(path.join(dir, 'index.html'), 'utf8'), /Support links are coming soon\./);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('headings are plain: no italic accent words, no serif', () => {
  for (const page of PAGES) {
    for (const [heading] of read(page).matchAll(/<h[1-6][^>]*>[\s\S]*?<\/h[1-6]>/g)) {
      assert.doesNotMatch(heading, /<(em|i)\b/, `${page}: ${heading}`);
    }
  }
  for (const rel of files(out)) assert.doesNotMatch(rel, /fraunces/i);
  assert.doesNotMatch(read('assets/css/site.css'), /Fraunces|font-style:\s*italic/);
});

test('only the chosen typeface set is published, each family with its license', async () => {
  const families = readdirSync(path.join(out, 'assets/fonts')).sort();
  assert.deepEqual(families, ['hubot-sans', 'mona-sans', 'mona-sans-mono']);
  for (const family of families) {
    assert.ok(existsSync(path.join(out, 'assets/fonts', family, `${family}.woff2`)), family);
    assert.match(readFileSync(path.join(out, 'assets/fonts', family, 'OFL.txt'), 'utf8'), /SIL OPEN FONT LICENSE/i, family);
  }
  const css = read('assets/css/site.css');
  assert.match(css, /--font-display: 'Hubot Sans'/);
  assert.match(read('index.html'), /<link rel="preload" href="assets\/fonts\/hubot-sans\/hubot-sans\.woff2" as="font"/);

  const dir = await mkdtemp(path.join(tmpdir(), 'avo-site-'));
  try {
    await build({ outDir: dir, quiet: true, overrides: { fonts: 'C' } });
    assert.deepEqual(readdirSync(path.join(dir, 'assets/fonts')).sort(), ['archivo', 'jetbrains-mono']);
    assert.match(readFileSync(path.join(dir, 'assets/css/site.css'), 'utf8'), /--font-display: 'Archivo'/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
  await assert.rejects(build({ outDir: path.join(tmpdir(), 'avo-never'), quiet: true, overrides: { fonts: 'comic' } }), /fonts must be one of/);
});

test('the public pages speak plainly: no engineering jargon', () => {
  const jargon = /gfxstream|Hypervisor\.framework|virtio|MetalFX|Vulkan|GLES|SHA-256|sha256|append-only|ETag|\bD1\b|rate limit|chain head|hash/i;
  for (const page of PAGES) {
    const text = read(page).replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<head[\s\S]*?<\/head>/, ' ').replace(/<[^>]+>/g, ' ');
    assert.doesNotMatch(text, jargon, page);
  }
});

test('the credit is one plain line in the footer', () => {
  for (const page of PAGES) {
    const footer = read(page).slice(read(page).indexOf('<footer'));
    assert.match(footer, /<p class="footer-credit">(Made by|Dibuat oleh) [^<]+ (in West Kalimantan|di Kalimantan Barat), (with help from|dengan bantuan) Claude\.<\/p>/, page);
  }
  for (const page of ['index.html', 'id/index.html']) {
    const html = read(page);
    assert.doesNotMatch(html.slice(0, html.indexOf('<footer')), /Claude/, `${page}: the credit appears only in the footer`);
  }
});

test('a strict build refuses placeholders', async () => {
  const overrides = { contact: { email: 'hello@example.org' } };
  await assert.rejects(build({ outDir: path.join(tmpdir(), 'avo-never'), quiet: true, strict: true, overrides }), /placeholders/);
});
