// The static site: every page in both languages, links that resolve, no
// emoji, CSP-friendly markup, what search engines and link previews read,
// and the switches in site.config.mjs.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { AVO_PAGES, build, HUB_PAGES } from '../tools/build.mjs';
import site from '../site.config.mjs';
import { isAppSignIn, keepBack, languageMove, priceList, wayBack } from '../src/assets/js/hub-pages.js';

let out;
// The product pages, Avo's policies, Avo Hub's pricing and policies, then the 404 page.
const PRODUCT = ['index.html', 'id/index.html', 'hub/index.html', 'id/hub/index.html'];
const AVO = AVO_PAGES.flatMap((name) => [`${name}/index.html`, `id/${name}/index.html`]);
const HUB = HUB_PAGES.flatMap((name) => [`hub/${name}/index.html`, `id/hub/${name}/index.html`]);
const PAGES = [...PRODUCT, ...AVO, ...HUB, '404.html'];
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
    assert.match(html, /<link rel="alternate" hreflang="x-default" href="https:\/\/avodroid\.com\/(hub\/((pricing|terms|privacy|refunds)\/)?|(terms|privacy)\/)?">/, page);
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
    assert.ok(html.match(/<title>([^<]+)<\/title>/)[1].endsWith(` · ${slogan.slice(0, -1)}`), `${page}: the title ends with the slogan`);
    assert.doesNotMatch(html, /Android at heart|Jiwa Android/, `${page}: the old slogan is gone`);
  }
  for (const page of PRODUCT) {
    const html = read(page);
    const slogan = SLOGAN[langOf(page)];
    // Over the headline, never inside it: the headline says what the app is.
    assert.equal(text(html.match(/<p class="hero-eyebrow">([\s\S]*?)<\/p>\s*<h1 /)?.[1] ?? ''), slogan, page);
    assert.ok(meta(html, 'property', 'og:title').endsWith(slogan), `${page}: share card`);
    assert.equal(ofType(jsonLd(html), 'SoftwareApplication')[0].slogan, slogan, page);
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
  assert.equal(urls.length, INDEXED.length);
  for (const page of INDEXED) assert.ok(sitemap.includes(`<loc>https://avodroid.com/${page.replace(/index\.html$/, '')}</loc>`), page);
  for (const body of urls) {
    assert.match(body, /<lastmod>\d{4}-\d{2}-\d{2}<\/lastmod>/);
    assert.match(body, /hreflang="en"/);
    assert.match(body, /hreflang="id"/);
    assert.match(body, /hreflang="x-default"/);
    // The product pages show their screenshots; the pricing and policies have none.
    if (/<loc>https:\/\/avodroid\.com\/(id\/)?(hub\/)?<\/loc>/.test(body)) {
      assert.match(body, /<image:image><image:loc>https:\/\/avodroid\.com\/assets\/img\/screens\/[^<]+\.jpg<\/image:loc><\/image:image>/);
    }
  }
  for (const loc of sitemap.matchAll(/<image:loc>https:\/\/avodroid\.com\/([^<]+)<\/image:loc>/g)) assert.ok(existsSync(path.join(out, loc[1])), loc[1]);
  assert.match(read('robots.txt'), /^Sitemap: https:\/\/avodroid\.com\/sitemap\.xml$/m);
});

test('llms.txt describes both apps plainly, with their pages and prices', () => {
  const llms = read('llms.txt');
  assert.match(llms, /^# Avo\n\n> Android in your ecosystem\. /);
  for (const url of ['https://avodroid.com/', 'https://avodroid.com/id/', 'https://avodroid.com/hub/', 'https://avodroid.com/id/hub/']) assert.ok(llms.includes(`(${url})`), url);
  for (const name of HUB_PAGES) assert.ok(llms.includes(`(https://avodroid.com/hub/${name}/)`), name);
  assert.doesNotMatch(llms, /auth\.avodroid\.com\/(pricing|terms|privacy|refund)/);
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

  // Its plans and policies: this site's pages, in the page's language.
  for (const name of HUB_PAGES) {
    assert.ok(en.includes(`href="../hub/${name}/"`), `en: ${name}`);
    assert.ok(id.includes(`href="../../id/hub/${name}/"`), `id: ${name}`);
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
  assert.ok(home.includes(`Avo ${site.release.version} · ${site.release.size} · free`), 'the release line names the configured version and size');

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

// ------------------------------------------------------- Avo's own policies

const AVO_POLICIES = { terms: ['Terms of Use', 'Ketentuan Penggunaan'], privacy: ['Privacy Policy', 'Kebijakan Privasi'] };
const SRC = path.join(path.dirname(new URL(import.meta.url).pathname), '..', 'src');

test("Avo's terms and privacy are pages of their own, in both languages, apart from Avo Hub's", () => {
  for (const name of AVO_PAGES) {
    const en = read(`${name}/index.html`);
    const id = read(`id/${name}/index.html`);
    assert.match(en, /<html lang="en">/, name);
    assert.match(id, /<html lang="id">/, name);
    assert.ok(en.includes(`<link rel="canonical" href="https://avodroid.com/${name}/">`), name);
    assert.ok(id.includes(`<link rel="canonical" href="https://avodroid.com/id/${name}/">`), name);
    assert.equal(h1Of(en), AVO_POLICIES[name][0]);
    assert.equal(h1Of(id), AVO_POLICIES[name][1]);
    for (const html of [en, id]) {
      assert.ok(html.includes(`<link rel="alternate" hreflang="en" href="https://avodroid.com/${name}/">`), name);
      assert.ok(html.includes(`<link rel="alternate" hreflang="id" href="https://avodroid.com/id/${name}/">`), name);
      assert.ok(html.includes(`<link rel="alternate" hreflang="x-default" href="https://avodroid.com/${name}/">`), name);
      // Avo's two pages side by side, this one marked; never Avo Hub's tabs, its seller or its account.
      const tabs = html.match(/<nav class="legal-tabs"[\s\S]*?<\/nav>/)[0];
      assert.equal((tabs.match(/<li>/g) || []).length, 2, name);
      assert.match(tabs, new RegExp(`<a href="\\./" aria-current="page" data-avo-tab="${name}">`), name);
      for (const other of AVO_PAGES.filter((n) => n !== name)) assert.ok(tabs.includes(`href="../${other}/"`), `${name} -> ${other}`);
      const main = html.slice(html.indexOf('<main'), html.indexOf('</main>'));
      assert.doesNotMatch(main, /hub-tabs|data-hub-back|Mochamad Nizwar Syafuan|auth\.avodroid\.com/, name);
      assert.match(html, /<body class="page page-avo-legal">/, name);
      // Their own address, and the date they last changed.
      assert.match(main, /<a href="mailto:support@avodroid\.com">support@avodroid\.com<\/a>/, name);
      assert.match(main, /<p class="legal-pages-updated">(Last updated November 1, 2026|Terakhir diperbarui 1 November 2026)<\/p>/, name);
      const data = jsonLd(html);
      const [webPage] = ofType(data, 'WebPage');
      assert.equal(webPage.dateModified, '2026-11-01', name);
      assert.equal(webPage.about['@id'], 'https://avodroid.com/#avo', name);
      assert.equal(ofType(data, 'SoftwareApplication').length, 0, name);
      // A breadcrumb: Avo, then the page.
      const crumbs = ofType(data, 'BreadcrumbList')[0].itemListElement;
      assert.deepEqual(crumbs.map((c) => c.position), [1, 2], name);
      assert.equal(crumbs[0].name, 'Avo', name);
      assert.equal(crumbs[1].item, html.match(/<link rel="canonical" href="([^"]+)">/)[1], name);
      assert.equal(crumbs[1].name, h1Of(html), name);
    }
    assert.ok(en.includes(`<a class="lang-switch" href="../id/${name}/"`), name);
    assert.ok(id.includes(`<a class="lang-switch" href="../../${name}/"`), name);
  }
});

test("Avo's policies say all of their text, the same shape in both languages, with their links working", () => {
  for (const name of AVO_PAGES) {
    const source = JSON.parse(readFileSync(path.join(SRC, 'avo', `${name}.json`), 'utf8'));
    const shape = (policy) => policy.sections.map((section) => section.body.map((block) => (Array.isArray(block) ? block.length : 's')).join(',')).join('|');
    assert.equal(shape(source.id), shape(source.en), name);
    for (const lang of ['en', 'id']) {
      const page = lang === 'en' ? `${name}/index.html` : `id/${name}/index.html`;
      const html = read(page);
      const sections = [...html.matchAll(/<section class="legal-section" id="section-(\d+)"/g)];
      assert.equal(sections.length, source[lang].sections.length, page);
      assert.equal((html.match(/<li><a href="#section-\d+">/g) || []).length, sections.length, page);
      const body = text(html.slice(html.indexOf('<div class="legal-body">'), html.indexOf('<p class="legal-pages-about">')));
      const words = (line) => line.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/\{\w+\}/g, ' ').split(/\s+/).filter((w) => w.length > 3);
      for (const section of source[lang].sections) {
        for (const word of words(section.heading)) assert.ok(body.includes(word), `${page}: ${word}`);
        for (const block of section.body) for (const line of [block].flat()) for (const word of words(line)) assert.ok(body.includes(word), `${page}: ${word}`);
      }
      assert.doesNotMatch(html.replace(/<script[\s\S]*?<\/script>/g, ''), /\{[a-zA-Z]+\}/, page);
      // The licence, the notice, the issues, a private way to report security problems, Avo Hub's own policy.
      assert.match(html, /<a href="https:\/\/github\.com\/nizwar\/avo\/security\/advisories\/new" rel="noopener">GitHub<\/a>/, page);
      assert.match(html, new RegExp(`<a href="(\\.\\./)+(id/)?hub/${name}/">`), `${page}: Avo Hub's ${name}`);
    }
  }
  const terms = read('terms/index.html');
  assert.match(terms, /<a href="https:\/\/github\.com\/nizwar\/avo\/blob\/main\/LICENSE" rel="noopener">Apache License 2\.0<\/a>/);
  assert.match(terms, /<a href="https:\/\/github\.com\/nizwar\/avo\/blob\/main\/NOTICE" rel="noopener">NOTICE<\/a>/);
  assert.match(terms, /provided “as is”, without warranties of any kind/);
  assert.match(terms, /Android is a trademark of Google LLC\. Mac and macOS are trademarks of Apple Inc\./);
  assert.match(terms, /<a href="\.\.\/#support">support the developer<\/a>/);
  assert.match(read('id/terms/index.html'), /<a href="\.\.\/\.\.\/id\/#support">mendukung pengembangnya<\/a>/);
  const privacy = read('privacy/index.html');
  assert.match(privacy, /<a href="\.\.\/terms\/" aria-current="page"|<a href="\.\.\/terms\/" data-avo-tab="terms">/);
  assert.match(privacy, /GitHub logs each visitor’s IP address/);
  assert.match(privacy, /Avo sends no analytics and no crash reports\./);
  // Avo is free: no refund page of its own, no prices.
  assert.ok(!existsSync(path.join(out, 'refunds/index.html')));
  assert.doesNotMatch(text(terms), /\$\d/);
});

test("the home page leads to Avo's privacy policy from its question about privacy, and llms.txt to both", () => {
  for (const [page, href] of [['index.html', 'privacy/'], ['id/index.html', '../id/privacy/']]) {
    const html = read(page);
    const answer = html.match(/<details class="faq-item"[^>]*><summary>(Is it safe and private\?|Apakah aman dan menjaga privasi\?)[\s\S]*?<\/details>/)[0];
    assert.ok(answer.includes(`href="${href}"`), page);
    // The same link in the structured data, as a full address.
    const faq = ofType(jsonLd(html), 'FAQPage')[0].mainEntity.find((q) => /privat|privasi/i.test(q.name));
    assert.match(faq.acceptedAnswer.text, page === 'index.html' ? /href="https:\/\/avodroid\.com\/privacy\/"/ : /href="https:\/\/avodroid\.com\/id\/privacy\/"/, page);
  }
  const llms = read('llms.txt');
  assert.ok(llms.includes('[Terms of Use](https://avodroid.com/terms/)'));
  assert.ok(llms.includes('[Privacy Policy](https://avodroid.com/privacy/)'));
});

// ------------------------------------------- Avo Hub's pricing and policies

const POLICIES = { terms: ['Terms of Service', 'Ketentuan Layanan'], privacy: ['Privacy Policy', 'Kebijakan Privasi'], refunds: ['Refund Policy', 'Kebijakan Pengembalian Dana'] };
const h1Of = (html) => text(html.match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/)[1]);
const visibleText = (html) => text(html.replace(/<(\w+)[^>]*\shidden[^>]*>[\s\S]*?<\/\1>/g, ' '));

test("Avo Hub's pricing and policies are this site's pages, in both languages, each with its own address", () => {
  for (const name of HUB_PAGES) {
    const en = read(`hub/${name}/index.html`);
    const id = read(`id/hub/${name}/index.html`);
    assert.match(en, /<html lang="en">/, name);
    assert.match(id, /<html lang="id">/, name);
    assert.ok(en.includes(`<link rel="canonical" href="https://avodroid.com/hub/${name}/">`), name);
    assert.ok(id.includes(`<link rel="canonical" href="https://avodroid.com/id/hub/${name}/">`), name);
    for (const html of [en, id]) {
      assert.ok(html.includes(`<link rel="alternate" hreflang="en" href="https://avodroid.com/hub/${name}/">`), name);
      assert.ok(html.includes(`<link rel="alternate" hreflang="id" href="https://avodroid.com/id/hub/${name}/">`), name);
      // The four pages side by side, this one marked; each leads to the others in the same language.
      const tabs = html.match(/<nav class="hub-tabs"[\s\S]*?<\/nav>/)[0];
      assert.equal((tabs.match(/<li>/g) || []).length, 4, name);
      assert.match(tabs, new RegExp(`<a href="\\./" aria-current="page" data-hub-tab="${name}">`), name);
      for (const other of HUB_PAGES.filter((n) => n !== name)) assert.ok(tabs.includes(`href="../${other}/"`), `${name} -> ${other}`);
      // Who sells Avo Hub, and how to reach them.
      assert.match(html, /Mochamad Nizwar Syafuan/, name);
      assert.match(html, /<a href="mailto:support@avodroid\.com">support@avodroid\.com<\/a>/, name);
      // The way back to the account's sign-in, shown only when the page was opened from it.
      assert.match(html, /<p class="hub-back" data-hub-back hidden><a class="btn btn-secondary btn-small" href="https:\/\/auth\.avodroid\.com\/">/, name);
      assert.match(html, /<body class="page page-hub-pages [^"]*" data-account="https:\/\/auth\.avodroid\.com\/"/, name);
      // A breadcrumb: Avo, Avo Hub, the page.
      const crumbs = ofType(jsonLd(html), 'BreadcrumbList')[0].itemListElement;
      assert.equal(crumbs.length, 3, name);
      assert.equal(crumbs[2].item, html.match(/<link rel="canonical" href="([^"]+)">/)[1], name);
    }
    assert.ok(en.includes(`<a class="lang-switch" href="../../id/hub/${name}/"`), name);
    assert.ok(id.includes(`<a class="lang-switch" href="../../../hub/${name}/"`), name);
  }
  for (const [name, [en, id]] of Object.entries(POLICIES)) {
    assert.equal(h1Of(read(`hub/${name}/index.html`)), en);
    assert.equal(h1Of(read(`id/hub/${name}/index.html`)), id);
  }
});

test('every page leads to them: the footer and the Avo Hub page', () => {
  for (const page of PAGES) {
    const footer = read(page).slice(read(page).indexOf('<footer'));
    for (const name of HUB_PAGES) assert.match(footer, new RegExp(`<li><a href="[^"]*hub/${name}/">`), `${page}: ${name}`);
    // Each app's policies in a group of their own: Avo's, then Avo Hub's.
    const policies = footer.match(/<nav class="footer-policies"[\s\S]*?<\/nav>/)?.[0];
    assert.ok(policies, `${page}: the footer's policies`);
    const group = (name) => policies.match(new RegExp(`<div class="footer-policy" data-policies="${name}">([\\s\\S]*?)</div>`))[1];
    const hrefs = (html) => [...html.matchAll(/<li><a href="([^"]+)">/g)].map(([, href]) => href);
    assert.deepEqual(hrefs(group('avo')).map((href) => href.replace(/^(\.\.\/|\/)+/, '').replace(/^id\//, '')), ['terms/', 'privacy/'], page);
    assert.deepEqual(hrefs(group('hub')).map((href) => href.replace(/^.*hub\//, '')), HUB_PAGES.map((name) => `${name}/`), page);
    assert.match(group('avo'), langOf(page) === 'en' ? /<h2 class="footer-title">Avo’s policies<\/h2>/ : /<h2 class="footer-title">Kebijakan Avo<\/h2>/, page);
    assert.match(group('hub'), langOf(page) === 'en' ? /<h2 class="footer-title">Avo Hub’s pricing and policies<\/h2>/ : /<h2 class="footer-title">Harga dan kebijakan Avo Hub<\/h2>/, page);
    // In the page's language.
    if (page !== '404.html') for (const href of hrefs(policies)) assert.equal(href.includes('id/'), langOf(page) === 'id', `${page}: ${href}`);
  }
  for (const page of ['hub/index.html', 'id/hub/index.html']) {
    const main = read(page).slice(read(page).indexOf('<main'), read(page).indexOf('</main>'));
    for (const name of HUB_PAGES) assert.match(main, new RegExp(`href="[^"]*hub/${name}/"`), `${page}: ${name}`);
  }
  // Nothing leads to the account's old pages any more.
  for (const rel of files(out)) {
    if (!/\.(html|txt|xml)$/.test(rel)) continue;
    assert.doesNotMatch(readFileSync(path.join(out, rel), 'utf8'), /auth\.avodroid\.com\/(pricing|terms|privacy|refund)/, rel);
  }
});

test('the policies say all of their text, in both languages, with their links working', () => {
  for (const name of Object.keys(POLICIES)) {
    const source = JSON.parse(readFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), '..', 'src/hub', `${name}.json`), 'utf8'));
    for (const lang of ['en', 'id']) {
      const page = lang === 'en' ? `hub/${name}/index.html` : `id/hub/${name}/index.html`;
      const html = read(page);
      const sections = [...html.matchAll(/<section class="legal-section" id="section-(\d+)"/g)];
      assert.equal(sections.length, source[lang].sections.length, page);
      // Listed beside the text, each entry leading to its section.
      assert.equal((html.match(/<li><a href="#section-\d+">/g) || []).length, sections.length, page);
      const body = text(html.slice(html.indexOf('<div class="legal-body">'), html.indexOf('<p class="hub-pages-seller">')));
      for (const section of source[lang].sections) {
        const words = (line) => line.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/\{\w+\}/g, ' ').split(/\s+/).filter((w) => w.length > 3).slice(0, 6);
        for (const word of words(section.heading)) assert.ok(body.includes(word), `${page}: ${word}`);
        for (const block of section.body) for (const line of [block].flat()) for (const word of words(line)) assert.ok(body.includes(word), `${page}: ${word}`);
      }
      // The numbers the text quotes, filled in.
      assert.doesNotMatch(html.replace(/<script[\s\S]*?<\/script>/g, ''), /\{[a-zA-Z]+\}/, page);
    }
  }
  const terms = read('hub/terms/index.html');
  assert.match(terms, /<a href="\.\.\/pricing\/">Pricing<\/a>/);
  assert.match(terms, /<a href="\.\.\/refunds\/">Refund Policy<\/a>/);
  assert.match(terms, /<a href="\.\.\/privacy\/">Privacy Policy<\/a>/);
  assert.match(terms, /<a href="https:\/\/www\.paypal\.com\/legalhub\/paypal\/useragreement-full" rel="noopener">User Agreement<\/a>/);
  assert.match(terms, /Launch prices apply to subscriptions started up to and including January 1, 2027\./);
  assert.match(read('id/hub/terms/index.html'), /<a href="\.\.\/refunds\/">Kebijakan Pengembalian Dana<\/a>/);
  assert.match(read('hub/refunds/index.html'), /Full refund within 14 days/);
  assert.match(read('hub/privacy/index.html'), /up to 30 days after you close it/);
  // Their structured data: when they last changed.
  assert.equal(ofType(jsonLd(terms), 'WebPage')[0].dateModified, '2026-11-01');
  assert.equal(ofType(jsonLd(terms), 'SoftwareApplication').length, 0);
  // One name for the web app that reaches the Mac, as Avo Hub's own pages say it.
  assert.doesNotMatch(terms, /Avo Remote Web/);
});

test('the pricing page: Free and Pro per device, the launch price until it ends, and Get Pro at the account', async () => {
  const en = read('hub/pricing/index.html');
  const id = read('id/hub/pricing/index.html');
  // Built before the launch price ends: it shows, the standard price waits hidden for the visitor's clock.
  assert.equal(text(visibleText(en).match(/Free over a cable and Wi‑Fi\. Pro from \$\d+ a month\./)[0]), 'Free over a cable and Wi‑Fi. Pro from $2 a month.');
  assert.match(visibleText(id), /Gratis lewat kabel dan Wi‑Fi\. Pro mulai \$2 per bulan\./);
  // Browsers never count, so the page never counts them (judge A K4).
  for (const page of [en, id]) assert.doesNotMatch(visibleText(page), /linked browsers|browser tertaut/);
  // The web apps are for subscribers (Avo Hub Tambahan 80): listed under Pro, never under Free.
  for (const [page, web] of [[en, 'Avo Hub Web and Avo Remote in any browser'], [id, 'Avo Hub Web dan Avo Remote di browser apa pun']]) {
    const plans = page.split('hub-plan-pro');
    assert.ok(plans.length > 1, 'the Pro plan is on the page');
    assert.doesNotMatch(visibleText(plans[0]), new RegExp(web), 'the web apps are not in Free');
    assert.match(visibleText(plans.slice(1).join('')), new RegExp(web), 'the web apps are in Pro');
  }
  // Indonesian: the site's own voice (kamu) on the pricing page, as on /id/hub/ and the footer (judge A K11).
  assert.doesNotMatch(visibleText(id), /\bAnda\b/);
  assert.match(id, />Pengembalian Dana</);
  assert.match(en, /<body class="page page-hub-pages page-hub-pricing" data-account="https:\/\/auth\.avodroid\.com\/" data-launch-ends="2027-01-02T12:00:00Z">/);
  // The date kept whole (no-break spaces) where the line wraps.
  assert.match(en, /<p class="hub-plan-launch" data-price-list="launch">Launch price until January\u00a01,\u00a02027<\/p>/);
  assert.match(visibleText(en), /\$1 a month for each device after that\./);
  assert.match(visibleText(en), /Or \$20 a year for the first device and \$10 for each one after it/);
  assert.match(visibleText(en), /Then \$5 a month for the first device and \$3 for each one after it, or \$50 and \$30 a year\./);
  assert.match(visibleText(en), /keep this price for as long as your subscription stays active/);
  assert.match(visibleText(en), /3 devices ?\$4 \$40/);
  assert.match(visibleText(en), /5 devices ?\$6 \$60/);
  // Never a struck-through "former" price.
  assert.doesNotMatch(en, /<(s|del|strike)\b/);
  // Getting started and Get Pro: the account (signing in first), its Get Pro on the period chosen.
  assert.match(en, /<a class="btn btn-secondary" href="https:\/\/auth\.avodroid\.com\/">Get Started<\/a>/);
  assert.match(en, /<a class="btn btn-primary" href="https:\/\/auth\.avodroid\.com\/\?pro=month">Get Pro<\/a>/);
  assert.match(en, /<a class="text-link" href="https:\/\/auth\.avodroid\.com\/\?pro=year">Get Pro yearly/);
  assert.match(en, /<a href="https:\/\/auth\.avodroid\.com\/">try Pro free for 14 days<\/a>/);
  assert.match(en, /<a class="btn btn-primary btn-small header-action" href="https:\/\/auth\.avodroid\.com\/\?pro=month">Get Pro<\/a>/);
  assert.match(id, /<a class="btn btn-primary" href="https:\/\/auth\.avodroid\.com\/\?pro=month">Ambil Pro<\/a>/);
  assert.match(en, /one Mac you look from is free, and browsers never count\./);
  assert.match(en, /see the <a href="\.\.\/refunds\/">Refund Policy<\/a>/);
  assert.doesNotMatch(en, /Paddle|Merchant of Record/);
  // Avo Hub and its offers, as on the Avo Hub page.
  const [app] = ofType(jsonLd(en), 'SoftwareApplication');
  assert.equal(app.name, 'Avo Hub');
  assert.ok(app.offers.every((offer) => offer.url === 'https://avodroid.com/hub/pricing/'));

  // Built after the launch price ended: the standard price by itself.
  const dir = await mkdtemp(path.join(tmpdir(), 'avo-site-'));
  try {
    await build({ outDir: dir, quiet: true, now: new Date('2027-01-02T12:00:00Z') });
    const later = readFileSync(path.join(dir, 'hub/pricing/index.html'), 'utf8');
    assert.match(visibleText(later), /Pro from \$5 a month\./);
    assert.doesNotMatch(visibleText(later), /Launch price|\$2 a month/);
    assert.match(visibleText(later), /\$3 a month for each device after that\./);
    assert.match(visibleText(later), /3 devices ?\$11 \$110/);
    // Still 1 January somewhere on Earth: the launch price.
    await build({ outDir: dir, quiet: true, now: new Date('2027-01-02T11:59:00Z') });
    assert.match(visibleText(readFileSync(path.join(dir, 'hub/pricing/index.html'), 'utf8')), /Pro from \$2 a month\./);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("the pages' script: the old addresses' language, the way back to the sign-in, the prices in force", () => {
  const account = 'https://auth.avodroid.com/';
  const signIn = 'https://auth.avodroid.com/?client_id=mac&redirect_uri=avohub%3A%2F%2Fauth%2Fcallback&state=x';
  const search = (back) => `?${new URLSearchParams({ back })}`;
  assert.equal(wayBack(search(signIn), account), signIn);
  assert.equal(wayBack(search('https://auth.avodroid.com/?return=https%3A%2F%2Fhub.avodroid.com%2F'), account), 'https://auth.avodroid.com/?return=https%3A%2F%2Fhub.avodroid.com%2F');
  // Only the account's own sign-in page.
  assert.equal(wayBack(search('https://evil.example/'), account), null);
  assert.equal(wayBack(search('https://auth.avodroid.com.evil.example/'), account), null);
  assert.equal(wayBack(search('https://auth.avodroid.com/pricing'), account), null);
  assert.equal(wayBack(search('javascript:alert(1)'), account), null);
  assert.equal(wayBack('?back=not%20a%20url', account), null);
  assert.equal(wayBack('', account), null);
  assert.equal(isAppSignIn(signIn), true);
  assert.equal(isAppSignIn('https://auth.avodroid.com/?return=x'), false);

  // auth.avodroid.com/privacy?lang=id&back=… arrives at /hub/privacy/ with its query.
  const alternates = { en: 'https://avodroid.com/hub/privacy/', id: 'https://avodroid.com/id/hub/privacy/' };
  assert.equal(languageMove(`https://avodroid.com/hub/privacy/?lang=id&back=${encodeURIComponent(signIn)}`, 'en', alternates), `https://avodroid.com/id/hub/privacy/?back=${encodeURIComponent(signIn)}`);
  assert.equal(languageMove('https://avodroid.com/id/hub/privacy/?lang=en#section-2', 'id', alternates), 'https://avodroid.com/hub/privacy/#section-2');
  assert.equal(languageMove('https://avodroid.com/hub/privacy/?lang=en', 'en', alternates), null);
  assert.equal(languageMove('https://avodroid.com/hub/privacy/?lang=fr', 'en', alternates), null);
  assert.equal(languageMove('https://avodroid.com/hub/privacy/', 'en', alternates), null);

  const base = 'https://avodroid.com/hub/terms/';
  assert.equal(keepBack('../privacy/', signIn, base, account), `https://avodroid.com/hub/privacy/?back=${encodeURIComponent(signIn)}`);
  assert.equal(keepBack('../../../id/hub/terms/', signIn, base, account), `https://avodroid.com/id/hub/terms/?back=${encodeURIComponent(signIn)}`);
  assert.equal(keepBack('https://auth.avodroid.com/?pro=month', signIn, base, account), signIn);
  assert.equal(keepBack('https://www.paypal.com/disputes/', signIn, base, account), 'https://www.paypal.com/disputes/');
  assert.equal(keepBack('../../', signIn, base, account), '../../');
  assert.equal(keepBack('#section-2', signIn, base, account), '#section-2');
  assert.equal(keepBack('../privacy/', null, base, account), '../privacy/');

  assert.equal(priceList(Date.parse('2026-11-15T10:00:00Z'), '2027-01-02T12:00:00Z'), 'launch');
  assert.equal(priceList(Date.parse('2027-01-02T11:59:59Z'), '2027-01-02T12:00:00Z'), 'launch');
  assert.equal(priceList(Date.parse('2027-01-02T12:00:00Z'), '2027-01-02T12:00:00Z'), 'standard');
});

test('a policy whose languages differ in shape stops the build', async () => {
  const { inlineHtml } = await import('../tools/build.mjs');
  assert.equal(inlineHtml('See the [Refund Policy](../refunds/). Write to support@avodroid.com <now>.'), 'See the <a href="../refunds/">Refund Policy</a>. Write to <a href="mailto:support@avodroid.com">support@avodroid.com</a> &lt;now&gt;.');
  assert.equal(inlineHtml('[PayPal](https://www.paypal.com/x)'), '<a href="https://www.paypal.com/x" rel="noopener">PayPal</a>');
  await assert.rejects(build({ outDir: path.join(tmpdir(), 'avo-never'), quiet: true, overrides: { hub: { accountUrl: 'https://auth.avodroid.com/pricing' } } }), /hub\.accountUrl must be the account's address itself/);
  await assert.rejects(build({ outDir: path.join(tmpdir(), 'avo-never'), quiet: true, overrides: { hub: { legal: { email: 'nobody' } } } }), /hub\.legal\.email/);
  await assert.rejects(build({ outDir: path.join(tmpdir(), 'avo-never'), quiet: true, overrides: { legal: { updated: 'soon' } } }), /legal\.updated must be a date/);
});
