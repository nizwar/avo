// The static site: every page in both languages, links that resolve, no
// emoji, CSP-friendly markup, what search engines and link previews read,
// and the switches in site.config.mjs.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { build } from '../tools/build.mjs';

let out;
const PAGES = ['index.html', 'id/index.html', 'hub/index.html', 'id/hub/index.html', '404.html'];
const INDEXED = PAGES.filter((p) => p !== '404.html');
const read = (rel) => readFileSync(path.join(out, rel), 'utf8');
const meta = (html, attr, name) => html.match(new RegExp(`<meta ${attr}="${name.replace(/[.:]/g, '\\$&')}" content="([^"]*)">`))?.[1];
const jsonLd = (html) => JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
const ofType = (data, type) => data['@graph'].filter((node) => node['@type'] === type);
const text = (html) => html.replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/\s+/g, ' ').trim();

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
  for (const page of INDEXED) {
    const html = read(page);
    assert.match(html, /<link rel="alternate" hreflang="en" href="https:\/\/[^"]+">/, page);
    assert.match(html, /<link rel="alternate" hreflang="id" href="https:\/\/[^"]+\/id\/[^"]*">/, page);
    assert.match(html, /<link rel="alternate" hreflang="x-default" href="https:\/\/avodroid\.com\/(hub\/)?">/, page);
    assert.match(html, /<meta property="og:image" content="https:\/\/[^"]+\.jpg">/, page);
    assert.match(html, /<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self';/, page);
  }
});

const SLOGAN = { en: 'Android in your ecosystem.', id: 'Android di ekosistemmu.' };
const langOf = (page) => (page.startsWith('id/') ? 'id' : 'en');

test('the slogan opens both pages and closes every page, in both languages', () => {
  for (const page of INDEXED) {
    const html = read(page);
    const slogan = SLOGAN[langOf(page)];
    // Over the headline, never inside it: the headline says what the app is.
    assert.equal(text(html.match(/<p class="hero-eyebrow">([\s\S]*?)<\/p>\s*<h1 /)?.[1] ?? ''), slogan, page);
    assert.ok(html.match(/<title>([^<]+)<\/title>/)[1].endsWith(` · ${slogan.slice(0, -1)}`), `${page}: the title ends with the slogan`);
    assert.ok(meta(html, 'property', 'og:title').endsWith(slogan), `${page}: share card`);
    assert.equal(ofType(jsonLd(html), 'SoftwareApplication')[0].slogan, slogan, page);
    assert.doesNotMatch(html, /Android at heart|Jiwa Android/, `${page}: the old slogan is gone`);
  }
  for (const page of PAGES) assert.match(read(page), new RegExp(`<p class="footer-slogan" lang="(en|id)">(${SLOGAN.en}|${SLOGAN.id})</p>`.replace(/\./g, '\\.')), page);
  // Never Apple's name in the slogan, nor a claim to be part of Apple's own.
  for (const slogan of Object.values(SLOGAN)) assert.doesNotMatch(slogan, /Apple/);
});

test('each page leads with what people search for: title, description and headline', () => {
  const h1 = (page) => text(read(page).match(/<h1 id="hero-title" class="hero-title">([\s\S]*?)<\/h1>/)[1]);
  const title = (page) => read(page).match(/<title>([^<]+)<\/title>/)[1];
  const description = (page) => meta(read(page), 'name', 'description');
  assert.equal(h1('index.html'), 'Android emulator for your Mac.');
  assert.equal(h1('id/index.html'), 'Emulator Android untuk Mac.');
  assert.equal(h1('hub/index.html'), 'Your Android phone, on your Mac.');
  assert.equal(h1('id/hub/index.html'), 'Ponsel Android kamu, langsung di Mac.');
  assert.match(title('index.html'), /^Android Emulator for Mac \| Avo · /);
  assert.match(title('id/index.html'), /^Emulator Android untuk Mac \| Avo · /);
  assert.match(title('hub/index.html'), /^Mirror Android to Mac \| Avo Hub · /);
  assert.match(title('id/hub/index.html'), /^Mirror HP Android ke Mac \| Avo Hub · /);
  assert.match(description('index.html'), /^Android emulator for Mac with Apple silicon, M1 to M4/);
  assert.match(description('id/index.html'), /^Emulator Android untuk Mac dengan chip Apple, M1 sampai M4/);
  assert.match(description('hub/index.html'), /^Mirror your Android phone to your Mac and control it/);
  assert.match(description('id/hub/index.html'), /^Mirror dan kendalikan HP Android dari Mac/);
  // The pages link to each other with words that say where they lead.
  assert.match(read('index.html'), /<a class="btn btn-secondary" href="hub\/">Mirror your phone with Avo Hub/);
  assert.match(read('hub/index.html'), /<a class="btn btn-secondary" href="\.\.\/">Get Avo, the free Android emulator/);
});

test('every page has its own title, description and share card', () => {
  const titles = new Set();
  const descriptions = new Set();
  for (const page of INDEXED) {
    const html = read(page);
    const title = html.match(/<title>([^<]+)<\/title>/)[1];
    const description = meta(html, 'name', 'description');
    // What a results page shows without cutting it short.
    assert.ok(title.length >= 30 && title.length <= 60, `${page}: title of ${title.length} characters`);
    assert.ok([...description].length >= 120 && [...description].length <= 160, `${page}: description of ${[...description].length} characters`);
    titles.add(title);
    descriptions.add(description);
    assert.equal(meta(html, 'name', 'robots'), 'index, follow, max-image-preview:large', page);
    const canonical = html.match(/<link rel="canonical" href="([^"]+)">/)[1];
    assert.equal(meta(html, 'property', 'og:url'), canonical, page);
    for (const name of ['og:title', 'og:description', 'og:image:alt']) assert.ok(meta(html, 'property', name), `${page}: ${name}`);
    assert.equal(meta(html, 'name', 'twitter:card'), 'summary_large_image', page);
    assert.equal(meta(html, 'name', 'twitter:image'), meta(html, 'property', 'og:image'), page);
    assert.equal(meta(html, 'name', 'twitter:title'), meta(html, 'property', 'og:title'), page);
    const og = meta(html, 'property', 'og:image').replace('https://avodroid.com/', '');
    assert.ok(existsSync(path.join(out, og)), `${page}: ${og}`);
  }
  assert.equal(titles.size, INDEXED.length, 'titles are unique');
  assert.equal(descriptions.size, INDEXED.length, 'descriptions are unique');
  assert.equal(meta(read('404.html'), 'name', 'robots'), 'noindex');
});

test('structured data: the organisation, the site, each app, its questions and the way to /hub', () => {
  const home = jsonLd(read('index.html'));
  assert.equal(home['@context'], 'https://schema.org');
  assert.equal(ofType(home, 'Organization')[0].name, 'Avo');
  assert.equal(ofType(home, 'WebSite')[0].url, 'https://avodroid.com/');
  const [avo] = ofType(home, 'SoftwareApplication');
  assert.equal(avo.name, 'Avo');
  assert.equal(avo.applicationCategory, 'UtilitiesApplication');
  assert.match(avo.operatingSystem, /macOS 15/);
  assert.equal(avo.offers.price, '0');
  assert.equal(avo.offers.priceCurrency, 'USD');
  assert.match(avo.downloadUrl, /\.dmg$/);
  assert.ok(avo.screenshot.length >= 4);
  // The questions in the data are the questions on the page.
  const faq = ofType(home, 'FAQPage')[0];
  const summaries = [...read('index.html').matchAll(/<summary>([\s\S]*?)<span class="faq-sign"/g)].map(([, q]) => text(q));
  assert.equal(faq.mainEntity.length, 10);
  assert.deepEqual(faq.mainEntity.map((q) => q.name), summaries);
  assert.ok(ofType(home, 'Organization')[0].slogan);
  assert.ok(avo.featureList.length >= 5);

  for (const page of ['hub/index.html', 'id/hub/index.html']) {
    const hub = jsonLd(read(page));
    const [app] = ofType(hub, 'SoftwareApplication');
    assert.equal(app.name, 'Avo Hub', page);
    assert.match(app.operatingSystem, /Android 11/, page);
    // Free, then Pro at the launch price until its last day and the standard price after.
    assert.deepEqual(
      app.offers.map((o) => [o.name, o.price, o.priceCurrency, o.priceValidUntil ?? o.validFrom ?? null]),
      [
        ['Free', '0', 'USD', null],
        ['Pro, monthly (launch price)', '2', 'USD', '2027-01-01'],
        ['Pro, yearly (launch price)', '20', 'USD', '2027-01-01'],
        ['Pro, monthly', '5', 'USD', '2027-01-02'],
        ['Pro, yearly', '50', 'USD', '2027-01-02'],
      ],
      page,
    );
    assert.deepEqual(app.offers.slice(1).map((o) => o.priceSpecification.map((p) => [p.price, p.billingDuration])), [
      [['2', 'P1M'], ['1', 'P1M']],
      [['20', 'P1Y'], ['10', 'P1Y']],
      [['5', 'P1M'], ['3', 'P1M']],
      [['50', 'P1Y'], ['30', 'P1Y']],
    ], page);
    assert.ok(app.featureList.length >= 5, page);
    const crumbs = ofType(hub, 'BreadcrumbList')[0].itemListElement;
    assert.deepEqual(crumbs.map((c) => c.name), ['Avo', 'Avo Hub'], page);
    // The questions in the data are the questions on the page.
    const summaries = [...read(page).matchAll(/<summary>([\s\S]*?)<span class="faq-sign"/g)].map(([, q]) => text(q));
    assert.deepEqual(ofType(hub, 'FAQPage')[0].mainEntity.map((q) => q.name), summaries, page);
    assert.ok(summaries.length >= 10, page);
  }
  assert.equal(ofType(jsonLd(read('id/hub/index.html')), 'BreadcrumbList')[0].itemListElement[1].item, 'https://avodroid.com/id/hub/');
});

test('the sitemap lists every page with its languages and screenshots; robots point to it', () => {
  const sitemap = read('sitemap.xml');
  const urls = [...sitemap.matchAll(/<url>([\s\S]*?)<\/url>/g)].map(([, body]) => body);
  assert.equal(urls.length, 4);
  for (const body of urls) {
    assert.match(body, /<lastmod>\d{4}-\d{2}-\d{2}<\/lastmod>/);
    assert.match(body, /hreflang="en"/);
    assert.match(body, /hreflang="id"/);
    assert.match(body, /hreflang="x-default"/);
    assert.match(body, /<image:image><image:loc>https:\/\/avodroid\.com\/assets\/img\/screens\/[^<]+\.jpg<\/image:loc><\/image:image>/);
  }
  for (const loc of sitemap.matchAll(/<image:loc>https:\/\/avodroid\.com\/([^<]+)<\/image:loc>/g)) assert.ok(existsSync(path.join(out, loc[1])), loc[1]);
  assert.match(read('robots.txt'), /^Sitemap: https:\/\/avodroid\.com\/sitemap\.xml$/m);
});

test('llms.txt describes both apps plainly, with their pages and prices', () => {
  const llms = read('llms.txt');
  assert.match(llms, /^# Avo\n\n> Android in your ecosystem\. /);
  for (const url of ['https://avodroid.com/', 'https://avodroid.com/id/', 'https://avodroid.com/hub/', 'https://avodroid.com/id/hub/']) assert.ok(llms.includes(`(${url})`), url);
  assert.match(llms, /launch price until January 1, 2027, \$2 a month for the first device and \$1 for each one after/);
  assert.match(llms, /after that \$5 and \$3 a month, or \$50 and \$30 a year/);
  assert.doesNotMatch(llms, /<[a-z]/i, "plain text, no markup");
});

test('the first screen loads first: hero picture preloaded and not lazy, fonts preloaded', () => {
  for (const [page, picture] of [['index.html', 'library'], ['hub/index.html', 'hub-overview']]) {
    const html = read(page);
    assert.match(html, new RegExp(`<link rel="preload" as="image" type="image/avif" imagesrcset="[^"]*${picture}-640\\.avif 640w[^"]*" imagesizes="[^"]+" fetchpriority="high">`), page);
    assert.match(html, /<link rel="preload" href="[^"]*hubot-sans\.woff2" as="font"/, page);
    const first = html.match(/<img [^>]*>/g).find((img) => img.includes(`${picture}-`));
    assert.match(first, /fetchpriority="high"/, page);
    assert.doesNotMatch(first, /loading="lazy"/, page);
  }
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
  // Every page's menu leads to it, and on its own page the link says so.
  for (const page of PAGES) assert.match(read(page), /<li><a href="[^"]*hub\/"( aria-current="page")?>Avo Hub<\/a><\/li>/, page);
  assert.match(en, /<a href="\.\.\/hub\/" aria-current="page">Avo Hub<\/a>/);

  // Its plans and policies, in the page's language.
  for (const name of ['pricing', 'terms', 'privacy', 'refund']) {
    assert.ok(en.includes(`href="https://auth.avodroid.com/${name}?lang=en"`), `en: ${name}`);
    assert.ok(id.includes(`href="https://auth.avodroid.com/${name}?lang=id"`), `id: ${name}`);
  }
  assert.match(en, /<span class="plan-figure">\$2<\/span> <span class="plan-per">a month for the first device<\/span>/);
  // The launch price, said as the price it is, then what comes after: no
  // crossed-out price that was never charged.
  assert.match(en, /<p class="plan-launch">Launch price until January\u00a01,\u00a02027<\/p>/);
  assert.match(id, /<p class="plan-launch">Harga peluncuran sampai 1\u00a0Januari\u00a02027<\/p>/);
  assert.match(en, /\$1 a month for each one after, or \$20 and \$10 a year\./);
  assert.match(en, /After the launch, new subscriptions are \$5 and \$3 a month, or \$50 and \$30 a year\. Subscribe at the launch price and you keep it for as long as you stay subscribed/);
  for (const html of [en, id]) assert.doesNotMatch(html, /<(s|del|strike)\b|line-through/);
  assert.doesNotMatch(read('assets/css/site.css'), /line-through/);

  // Not released, its repository private: no download, and no link to a
  // repository visitors would find empty, nor an open-source claim.
  assert.match(en, /In development\. The first preview is on its way\./);
  assert.doesNotMatch(en, /github\.com\/nizwar\/avo_hub/);
  assert.doesNotMatch(en, /Download for Mac|Follow on GitHub|Build it yourself|<li>Open source<\/li>|Open source like Avo/);
  assert.doesNotMatch(id, /github\.com\/nizwar\/avo_hub|<li>Open source<\/li>|Open source seperti Avo/);
  assert.doesNotMatch(en, /<p class="cta-row">\s*<\/p>/);

  const dir = await mkdtemp(path.join(tmpdir(), 'avo-site-'));
  try {
    // The repository public: GitHub and the open-source line.
    await build({ outDir: dir, quiet: true, overrides: { hub: { openSource: true } } });
    const open = readFileSync(path.join(dir, 'hub/index.html'), 'utf8');
    assert.match(open, /href="https:\/\/github\.com\/nizwar\/avo_hub"/);
    assert.match(open, /<li>Open source<\/li>/);
    assert.match(open, /Open source like Avo/);
    assert.equal(jsonLd(open)['@graph'].find((n) => n.name === 'Avo Hub').license, 'https://www.apache.org/licenses/LICENSE-2.0');

    const downloadUrl = 'https://github.com/nizwar/avo_hub/releases/download/v0.1.0/AvoHub-0.1.0-b2.dmg';
    await build({ outDir: dir, quiet: true, overrides: { hub: { openSource: true, release: { available: true, version: '0.1.0 Preview 1', downloadUrl } } } });
    const released = readFileSync(path.join(dir, 'hub/index.html'), 'utf8');
    assert.match(released, /Avo Hub 0\.1\.0 Preview 1 is out\./);
    assert.match(released, /Download for Mac/);
    assert.ok(released.includes(`href="${downloadUrl}"`));
    assert.doesNotMatch(released, /The first preview is on its way|Coming soon/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('no emoji anywhere in the built site', () => {
  for (const rel of files(out)) {
    if (!/\.(html|css|js|json|txt|xml|webmanifest|svg)$/.test(rel)) continue;
    const content = readFileSync(path.join(out, rel), 'utf8');
    const match = content.match(/\p{Extended_Pictographic}/u);
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
    for (const [, target] of html.matchAll(/\saria-(?:controls|labelledby)="([^"]+)"/g)) assert.ok(ids.includes(target), `${page}: aria reference to missing #${target}`);
    assert.equal((html.match(/<h1\b/g) || []).length, 1, `${page}: one h1`);
    assert.match(html, /<a class="skip-link" href="#main">/);
    assert.match(html, /<main id="main"/);
    const visible = html.replace(/<script[\s\S]*?<\/script>/g, '').replace(/<style[\s\S]*?<\/style>/g, '');
    assert.doesNotMatch(visible, /\{\{|\{[a-z][a-zA-Z]*\}/, `${page}: unreplaced placeholder`);
  }
});

test('every section is named by a heading, and headings go down one level at a time', () => {
  for (const page of INDEXED) {
    const html = read(page);
    for (const [, id] of html.matchAll(/<section [^>]*aria-labelledby="([^"]+)"/g)) assert.match(html, new RegExp(`<h[12] id="${id}"`), `${page}: section ${id}`);
    let previous = 1;
    for (const [, level] of html.replace(/<footer[\s\S]*<\/footer>/, '').matchAll(/<h([1-6])\b/g)) {
      assert.ok(Number(level) <= previous + 1, `${page}: h${level} after h${previous}`);
      previous = Number(level);
    }
  }
});

test('internal links and assets resolve', () => {
  for (const page of INDEXED) {
    const html = read(page);
    const dir = path.dirname(path.join(out, page));
    const srcsets = [...html.matchAll(/\s(?:image)?srcset="([^"]+)"/g)].flatMap(([, list]) => list.split(',').map((entry) => ` src="${entry.trim().split(/\s+/)[0]}"`));
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
  // Avo Hub's own windows, each described in both languages.
  for (const page of ['hub/index.html', 'id/hub/index.html']) {
    const pictures = read(page).match(/<picture>[\s\S]*?<\/picture>/g) || [];
    assert.ok(pictures.length >= 8, `${page}: ${pictures.length} screenshots`);
    for (const picture of pictures) assert.match(picture, /alt="[^"]{40,}"/, `${page}: describe the screenshot`);
  }
  assert.notEqual(read('hub/index.html').match(/hub-calls[^>]*alt="([^"]+)"/)?.[1], read('id/hub/index.html').match(/hub-calls[^>]*alt="([^"]+)"/)?.[1]);
});

test('the unreleased state is honest; a release shows the download', async () => {
  // The published build: the button downloads the disk image itself.
  const home = read('index.html');
  assert.match(home, /Download for Mac/);
  assert.match(home, /href="https:\/\/github\.com\/nizwar\/avo\/releases\/download\/v[^"]+\.dmg"/);
  assert.match(home, /Avo 1\.0\.0 · 26 MB · free/);

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
    await build({ outDir: dir, quiet: true, overrides: { release: { available: true, version: '0.1.0', size: null, downloadUrl: 'https://github.com/nizwar/avo/releases/download/v0.1.0/Avo.dmg' } } });
    const released = readFileSync(path.join(dir, 'index.html'), 'utf8');
    assert.match(released, /Download for Mac/);
    assert.match(released, /Avo 0\.1\.0 · free/);
    assert.match(released, /href="https:\/\/github\.com\/nizwar\/avo\/releases\/download\/v0\.1\.0\/Avo\.dmg"/);
    assert.doesNotMatch(released, /The download<\/span>/, 'no size, no size figure');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('support goes to the developer: one section with its channels', async () => {
  for (const page of ['index.html', 'id/index.html']) {
    const html = read(page);
    assert.match(html, /<section class="section support" id="support"/, page);
    assert.match(html, /<a href="[^"]*#support">/, `${page}: the footer links to it`);
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

test('the page has no ornaments: no gradients, no blur, no WebGL haze', () => {
  const css = read('assets/css/site.css');
  assert.doesNotMatch(css, /(linear|radial|conic)-gradient\(/);
  assert.doesNotMatch(css, /backdrop-filter/);
  for (const page of PAGES) assert.doesNotMatch(read(page), /<canvas|data-haze/, page);
  assert.ok(!existsSync(path.join(out, 'assets/js/haze-field.js')));
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
    const visible = read(page).replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<head[\s\S]*?<\/head>/, ' ').replace(/<[^>]+>/g, ' ');
    assert.doesNotMatch(visible, jargon, page);
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
