#!/usr/bin/env node
// Builds the static website into dist/: every page in English and Indonesian
// from src/pages, wording from src/i18n, links and switches from
// site.config.mjs. No dependencies; Node 22 or later.
//
//   node tools/build.mjs [--strict] [--out DIR] [--site-url URL] [--fonts SET] [--quiet]
//
// --strict fails while site.config.mjs still has placeholders (used before
// deploying). The template language is tiny:
//   {{t:key}}   text from the dictionary (may contain HTML)
//   {{a:key}}   the same, as a plain attribute value
//   {{v:name}}  a page variable, escaped
//   {{h:name}}  HTML built here from the configuration
//   {{p:name|alt.key|sizes|flags}}  a screenshot as <picture> (AVIF, WebP, JPEG)
//               from PICTURES, with its alt text from the dictionary, a
//               `sizes` preset from SIZES and flags: eager (the first screen's
//               picture: high priority, not lazy) or decor (empty alt)
//   {{> name}}  a partial from src/partials

import { createHash } from 'node:crypto';
import { cp, mkdir, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const LANGS = ['en', 'id'];
const PLACEHOLDER = /OWNER|TODO|example\.(org|com)/;

// Typeface sets: site.config.mjs `fonts` picks one (by name or letter). Only
// the chosen set's files are published; its CSS (src/assets/css/fonts/) is
// appended to site.css, where it overrides the --font-* variables.
export const FONT_SETS = {
  'hubot-mona': { letter: 'A', label: 'Hubot Sans + Mona Sans + Mona Sans Mono', families: ['hubot-sans', 'mona-sans', 'mona-sans-mono'], preload: ['hubot-sans/hubot-sans.woff2', 'mona-sans/mona-sans.woff2'] },
  geist: { letter: 'B', label: 'Geist + Geist Mono', families: ['geist', 'geist-mono'], preload: ['geist/geist.woff2'] },
  archivo: { letter: 'C', label: 'Archivo (wide headings) + JetBrains Mono', families: ['archivo', 'jetbrains-mono'], preload: ['archivo/archivo.woff2'] },
  jakarta: { letter: 'D', label: 'Plus Jakarta Sans + JetBrains Mono', families: ['plus-jakarta-sans', 'jetbrains-mono'], preload: ['plus-jakarta-sans/plus-jakarta-sans.woff2'] },
};

export function fontSetName(value) {
  const key = String(value ?? 'hubot-mona');
  if (FONT_SETS[key]) return key;
  const byLetter = Object.entries(FONT_SETS).find(([, set]) => set.letter === key.toUpperCase());
  if (byLetter) return byLetter[0];
  throw new Error(`site.config.mjs: fonts must be one of ${Object.entries(FONT_SETS).map(([k, v]) => `'${k}' (${v.letter})`).join(', ')}`);
}

// `og`: the social preview image, assets/img/og/<og>-<lang>.jpg (tools/og-image.html), and its description.
const PAGES = [
  { id: 'home', template: 'index.html', paths: { en: '', id: 'id/' }, title: 'meta.homeTitle', ogTitle: 'meta.homeOgTitle', description: 'meta.homeDescription',
    og: 'og', ogAlt: 'meta.ogAlt' },
  { id: 'hub', template: 'hub.html', paths: { en: 'hub/', id: 'id/hub/' }, title: 'meta.hubTitle', ogTitle: 'meta.hubOgTitle', description: 'meta.hubDescription',
    og: 'og-hub', ogAlt: 'meta.hubOgAlt' },
  { id: '404', template: '404.html', paths: { en: '404.html' }, title: 'meta.notFoundTitle', description: 'meta.homeDescription',
    og: 'og', ogAlt: 'meta.ogAlt' },
];

// Screenshots in src/assets/img/screens/<file>-<width>.{avif,webp,jpg}: Avo's
// own windows, Avo Hub's (rendered by its snapshot tests, with sample data),
// and the disk image's background. `width`/`height` are the largest file's.
export const PICTURES = {
  library: { widths: [640, 1080], width: 1080, height: 760 },
  'game-play': { widths: [640, 1309], width: 1309, height: 770 },
  'game-keys': { widths: [640, 1309], width: 1309, height: 770 },
  'settings-android': { widths: [640, 955], width: 955, height: 662 },
  'settings-graphics': { widths: [640, 955], width: 955, height: 662 },
  'settings-privacy': { widths: [640, 955], width: 955, height: 662 },
  'settings-google': { widths: [640, 955], width: 955, height: 662 },
  'hub-overview': { widths: [640, 1200], width: 1200, height: 724 },
  'hub-notifications': { widths: [640, 936], width: 936, height: 724 },
  'hub-messages': { widths: [640, 1200], width: 1200, height: 724 },
  'hub-calls': { widths: [640, 1200], width: 1200, height: 724 },
  'hub-files': { widths: [640, 1200], width: 1200, height: 724 },
  'hub-readiness': { widths: [640, 1200], width: 1200, height: 724 },
  'hub-menubar': { widths: [320], width: 320, height: 318 },
  dmg: { widths: [640, 1280], width: 1280, height: 960 },
};

// How wide each picture shows, for the browser to pick a file (site.css).
const SIZES = {
  hero: '(max-width: 1099px) calc(100vw - 32px), min(44vw, 760px)',
  half: '(max-width: 899px) calc(100vw - 32px), 44vw',
  story: '(max-width: 899px) calc(100vw - 32px), 52vw',
  teaser: '(max-width: 899px) calc(100vw - 32px), 50vw',
  index: '(max-width: 899px) calc(100vw - 32px), 54vw',
  menu: '280px',
  dmg: '(max-width: 899px) calc(100vw - 32px), 560px',
};

// ------------------------------------------------------------------ helpers

// Every attribute in the templates is double-quoted, so ' needs no escaping.
const escapeHtml = (value) =>
  String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');

const stripTags = (html) => String(html).replace(/<[^>]*>/g, '');

/** JSON that is safe inside a <script type="application/json"> element. */
const scriptJson = (value) => JSON.stringify(value).replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');

const hash = (text) => createHash('sha256').update(text).digest('hex').slice(0, 10);

function flatten(object, prefix = '', out = {}) {
  for (const [key, value] of Object.entries(object)) {
    const name = prefix ? `${prefix}.${key}` : key;
    if (value && typeof value === 'object' && !Array.isArray(value)) flatten(value, name, out);
    else out[name] = value;
  }
  return out;
}

function lookup(dict, key, lang) {
  const value = key.split('.').reduce((node, part) => (node && typeof node === 'object' ? node[part] : undefined), dict);
  if (typeof value !== 'string') throw new Error(`missing text "${key}" for ${lang}`);
  return value;
}

function lookupOptional(dict, key) {
  return key.split('.').reduce((node, part) => (node && typeof node === 'object' ? node[part] : undefined), dict);
}

function findPlaceholders(value, where = 'config', out = []) {
  if (typeof value === 'string') {
    if (PLACEHOLDER.test(value)) out.push(`${where}: ${value}`);
  } else if (Array.isArray(value)) value.forEach((v, i) => findPlaceholders(v, `${where}[${i}]`, out));
  else if (value && typeof value === 'object') for (const [k, v] of Object.entries(value)) findPlaceholders(v, `${where}.${k}`, out);
  return out;
}

function mergeDeep(base, extra) {
  const out = structuredClone(base);
  for (const [key, value] of Object.entries(extra || {})) {
    if (value && typeof value === 'object' && !Array.isArray(value) && out[key] && typeof out[key] === 'object') out[key] = mergeDeep(out[key], value);
    else out[key] = value;
  }
  return out;
}

export async function loadConfig(overrides = {}) {
  const file = pathToFileURL(path.join(ROOT, 'site.config.mjs')).href;
  const { default: config } = await import(`${file}?v=${Date.now()}`);
  return mergeDeep(config, overrides);
}

function checkConfig(config) {
  const errors = [];
  const url = (value, name, { optional = false } = {}) => {
    if (value === null || value === undefined || value === '') {
      if (!optional) errors.push(`${name} is required`);
      return;
    }
    try {
      const u = new URL(value);
      if (!['https:', 'http:', 'mailto:'].includes(u.protocol)) errors.push(`${name} must be an http(s) URL`);
    } catch {
      errors.push(`${name} is not a valid URL: ${value}`);
    }
  };
  url(config.siteUrl, 'siteUrl');
  url(config.githubUrl, 'githubUrl');
  url(config.release?.downloadUrl, 'release.downloadUrl', { optional: true });
  url(config.hub?.githubUrl, 'hub.githubUrl');
  url(config.hub?.release?.downloadUrl, 'hub.release.downloadUrl', { optional: true });
  for (const key of ['pricingUrl', 'termsUrl', 'privacyUrl', 'refundUrl']) url(config.hub?.[key], `hub.${key}`);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(config.contact?.email || '')) errors.push('contact.email is not an email address');
  try {
    fontSetName(config.fonts);
  } catch (error) {
    errors.push(error.message.replace('site.config.mjs: ', ''));
  }
  const channels = config.support?.channels;
  if (!Array.isArray(channels)) errors.push('support.channels must be a list');
  else {
    channels.forEach((c, i) => {
      if (!c.name) errors.push(`support.channels[${i}].name is required`);
      if (!c.url && !c.details) errors.push(`support.channels[${i}] needs a url or details`);
      url(c.url, `support.channels[${i}].url`, { optional: true });
      if (c.frequency && !['monthly', 'once', 'monthly-or-once'].includes(c.frequency)) errors.push(`support.channels[${i}].frequency is not valid`);
    });
  }
  if (errors.length) throw new Error(`site.config.mjs:\n  - ${errors.join('\n  - ')}`);
}

async function checkDictionaries(dicts) {
  const keys = Object.fromEntries(LANGS.map((lang) => [lang, Object.keys(flatten(dicts[lang])).sort()]));
  const [first, ...rest] = LANGS;
  for (const lang of rest) {
    const missing = keys[first].filter((k) => !keys[lang].includes(k));
    const extra = keys[lang].filter((k) => !keys[first].includes(k));
    if (missing.length || extra.length) {
      throw new Error(`src/i18n/${lang}.json differs from ${first}.json\n  missing: ${missing.join(', ') || '-'}\n  extra: ${extra.join(', ') || '-'}`);
    }
  }
}

// ------------------------------------------------------------------- render

function render(template, ctx, depth = 0) {
  if (depth > 6) throw new Error('partials nest too deeply');
  template = template.replace(/\{\{\s*p:([^}]+)\}\}/g, (match, args) => ctx.picture(...args.split('|').map((a) => a.trim())));
  return template.replace(/\{\{\s*(>|[tavh]:)\s*([\w.-]+)\s*\}\}/g, (match, kind, key) => {
    switch (kind) {
      case '>': {
        const partial = ctx.partials[key];
        if (partial === undefined) throw new Error(`unknown partial "${key}"`);
        return render(partial, ctx, depth + 1);
      }
      case 't:':
        return ctx.text(key);
      case 'a:':
        return escapeHtml(stripTags(ctx.text(key)));
      case 'v:':
        if (!(key in ctx.vars)) throw new Error(`unknown variable "${key}" in ${ctx.page}`);
        return escapeHtml(ctx.vars[key]);
      case 'h:':
        if (!(key in ctx.html)) throw new Error(`unknown block "${key}" in ${ctx.page}`);
        return ctx.html[key];
      default:
        return match;
    }
  });
}

function relativeRoot(outPath) {
  const depth = outPath.split('/').length - 1;
  return '../'.repeat(depth);
}

function channelList(channels, t) {
  const frequency = { monthly: t('support.monthly'), once: t('support.once'), 'monthly-or-once': t('support.monthlyOrOnce') };
  const items = channels.map((c) => {
    const meta = [frequency[c.frequency], c.currency].filter(Boolean).join(' · ');
    const inner = [
      `<span class="channel-name">${escapeHtml(c.name)}</span>`,
      meta ? `<span class="channel-meta">${escapeHtml(meta)}</span>` : '',
      c.url ? `<svg class="icon" aria-hidden="true" focusable="false"><use href="#i-arrow"/></svg>` : '',
      c.details ? `<span class="channel-details">${escapeHtml(c.details)}</span>` : '',
    ].join('');
    return c.url
      ? `<li><a class="channel" href="${escapeHtml(c.url)}" rel="noopener">${inner}</a></li>`
      : `<li><div class="channel">${inner}</div></li>`;
  });
  return `<ul class="channels">\n${items.join('\n')}\n</ul>`;
}

// -------------------------------------------------------------------- build

export async function build({ outDir = path.join(ROOT, 'dist'), strict = false, overrides = {}, quiet = false } = {}) {
  const log = quiet ? () => {} : (...args) => console.log(...args);
  const config = await loadConfig(overrides);
  checkConfig(config);
  const placeholders = findPlaceholders(config);
  if (strict && placeholders.length) {
    throw new Error(`site.config.mjs still has placeholders:\n  - ${placeholders.join('\n  - ')}`);
  }

  const dicts = {};
  for (const lang of LANGS) dicts[lang] = JSON.parse(await readFile(path.join(ROOT, 'src/i18n', `${lang}.json`), 'utf8'));
  await checkDictionaries(dicts);

  const partials = {};
  for (const file of await readdir(path.join(ROOT, 'src/partials'))) {
    if (file.endsWith('.html')) partials[file.slice(0, -5)] = await readFile(path.join(ROOT, 'src/partials', file), 'utf8');
  }

  // Everything is written to a staging folder and swapped in at the end, so a
  // failed build (say, a typo while editing) never leaves a broken site behind.
  const finalDir = outDir;
  outDir = `${finalDir}.building-${process.pid}`;
  await rm(outDir, { recursive: true, force: true });
  await mkdir(outDir, { recursive: true });
  // Assets, without the typeface library: only the chosen set is published.
  const fontSet = FONT_SETS[fontSetName(config.fonts)];
  const fontsDir = path.join(ROOT, 'src/assets/fonts');
  const fontCssDir = path.join(ROOT, 'src/assets/css/fonts');
  await cp(path.join(ROOT, 'src/assets'), path.join(outDir, 'assets'), {
    recursive: true,
    filter: (source) => !source.startsWith(fontsDir) && !source.startsWith(fontCssDir),
  });
  for (const family of fontSet.families) {
    await cp(path.join(fontsDir, family), path.join(outDir, 'assets/fonts', family), { recursive: true });
  }
  const fontCss = await readFile(path.join(fontCssDir, `${fontSetName(config.fonts)}.css`), 'utf8');
  const siteCssPath = path.join(outDir, 'assets/css/site.css');
  await writeFile(siteCssPath, `${await readFile(siteCssPath, 'utf8')}\n/* ------------------------------------------- Typeface set ${fontSet.letter} */\n\n${fontCss}`);

  const css = await readFile(path.join(outDir, 'assets/css/site.css'), 'utf8');
  const jsFiles = (await readdir(path.join(outDir, 'assets/js'))).sort();
  const js = (await Promise.all(jsFiles.map((f) => readFile(path.join(outDir, 'assets/js', f), 'utf8')))).join('\n');
  const cssVersion = hash(css);
  const jsVersion = hash(js);

  const siteUrl = config.siteUrl.replace(/\/+$/, '');
  const basePath = new URL(`${siteUrl}/`).pathname;
  const githubUrl = config.githubUrl.replace(/\/+$/, '');
  const blobUrl = `${githubUrl}/blob/${config.githubBranch || 'main'}`;
  const hubGithubUrl = config.hub.githubUrl.replace(/\/+$/, '');
  const hubRelease = config.hub.release || {};
  // A private repository is empty to visitors: no links to it, no open-source claim.
  const hubOpen = Boolean(config.hub.openSource);
  const csp = [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'none'",
    "frame-src 'none'",
    "manifest-src 'self'",
  ].join('; ');
  const year = String(new Date().getUTCFullYear());
  const written = [];
  const imageEntries = {}; // page id -> [{ loc, title }] for the sitemap
  const release = config.release || {};
  const downloadUrl = release.downloadUrl || `${githubUrl}/releases/latest`;
  const hubDownloadUrl = hubRelease.downloadUrl || `${hubGithubUrl}/releases/latest`;
  const icon = (name) => `<svg class="icon" aria-hidden="true" focusable="false"><use href="#i-${name}"/></svg>`;
  const shotUrl = (name) => `${siteUrl}/assets/img/screens/${name}-${PICTURES[name].widths.at(-1)}.jpg`;

  for (const page of PAGES) {
    const template = await readFile(path.join(ROOT, 'src/pages', page.template), 'utf8');
    for (const lang of Object.keys(page.paths)) {
      const other = lang === 'en' ? 'id' : 'en';
      const outPath = page.paths[lang] ? (page.paths[lang].endsWith('/') ? `${page.paths[lang]}index.html` : page.paths[lang]) : 'index.html';
      const is404 = page.id === '404';
      // GitHub Pages serves 404.html at any depth, so it links from the site root.
      const root = is404 ? basePath : relativeRoot(outPath);
      const dict = dicts[lang];
      const homePath = lang === 'en' ? '' : 'id/';
      const hubPath = lang === 'en' ? 'hub/' : 'id/hub/';
      const hrefTo = (target) => `${root}${target}` || './';
      // Avo Hub's plans and policies, in the page's language.
      const hubLink = (url) => `${url}?lang=${lang}`;
      const hubLinks = {
        pricing: hubLink(config.hub.pricingUrl),
        terms: hubLink(config.hub.termsUrl),
        privacy: hubLink(config.hub.privacyUrl),
        refund: hubLink(config.hub.refundUrl),
      };
      const tokens = { github: githubUrl, blob: blobUrl, contactEmail: config.contact.email, hubGithub: hubGithubUrl, hubPricing: hubLinks.pricing };
      const text = (key, extra = {}) => lookup(dict, key, lang).replace(/\{(\w+)\}/g, (m, name) => (name in extra ? extra[name] : name in tokens ? escapeHtml(tokens[name]) : m));
      const t = (key, extra) => text(key, extra);
      const counterpart = page.paths[other] ?? null;
      const canonical = `${siteUrl}/${page.paths[lang]}`;
      const homeUrl = `${siteUrl}/${homePath}`;
      const hubUrl = `${siteUrl}/${hubPath}`;
      const pictures = [];

      const picture = (name, altKey, sizesKey, ...flags) => {
        const info = PICTURES[name];
        if (!info) throw new Error(`unknown picture "${name}" in ${page.template}`);
        const sizes = SIZES[sizesKey];
        if (!sizes) throw new Error(`unknown sizes "${sizesKey}" in ${page.template}`);
        const decor = flags.includes('decor');
        const eager = flags.includes('eager');
        const alt = decor ? '' : escapeHtml(stripTags(t(altKey)));
        const set = (ext) => info.widths.map((w) => `${root}assets/img/screens/${name}-${w}.${ext} ${w}w`).join(', ');
        const largest = info.widths.at(-1);
        if (!decor) pictures.push({ loc: shotUrl(name), title: stripTags(t(altKey)) });
        const loading = eager ? 'fetchpriority="high"' : 'loading="lazy" decoding="async"';
        return [
          '<picture>',
          `<source type="image/avif" srcset="${escapeHtml(set('avif'))}" sizes="${escapeHtml(sizes)}">`,
          `<source type="image/webp" srcset="${escapeHtml(set('webp'))}" sizes="${escapeHtml(sizes)}">`,
          `<img src="${escapeHtml(`${root}assets/img/screens/${name}-${largest}.jpg`)}" srcset="${escapeHtml(set('jpg'))}" sizes="${escapeHtml(sizes)}" width="${info.width}" height="${info.height}" alt="${alt}" ${loading}>`,
          '</picture>',
        ].join('');
      };
      // The first screen's picture, fetched before the stylesheet asks for it.
      const heroPicture = { home: 'library', hub: 'hub-overview' }[page.id];
      const heroPreload = heroPicture
        ? `<link rel="preload" as="image" type="image/avif" imagesrcset="${escapeHtml(PICTURES[heroPicture].widths.map((w) => `${root}assets/img/screens/${heroPicture}-${w}.avif ${w}w`).join(', '))}" imagesizes="${escapeHtml(SIZES.hero)}" fetchpriority="high">`
        : '';

      const pageHome = page.id === 'home' ? '' : hrefTo(homePath);
      const pageHub = page.id === 'hub' ? '' : hrefTo(hubPath);
      const navItems = page.id === 'hub'
        ? [
            [`#features`, t('nav.hubFeatures')],
            [`#how`, t('nav.hubHow')],
            [`#faq`, t('nav.hubFaq')],
            [hrefTo(hubPath), t('nav.hub'), 'page'],
          ]
        : [
            [`${pageHome}#mac`, t('nav.mac')],
            [`${pageHome}#gaming`, t('nav.gaming')],
            [`${pageHome}#how`, t('nav.how')],
            [`${pageHome}#faq`, t('nav.faq')],
            [hrefTo(hubPath), t('nav.hub')],
          ];

      // ------------------------------------------------ Avo: release switches
      const releaseLine = release.available
        ? escapeHtml(stripTags(t('release.statusReleased', { version: release.version || '', size: release.size ? ` · ${release.size}` : '' })))
        : t('release.statusUnreleased');
      const releaseFacts = release.available
        ? `        <li class="fact-strong">${releaseLine}</li>\n        <li>${t('release.downloadMeta')}</li>`
        : `        <li class="fact-strong" title="${escapeHtml(stripTags(t('release.unreleasedNote')))}">${releaseLine}</li>`;
      const heroCtas = release.available
        ? [
            '<p class="cta-row">',
            `<a class="btn btn-primary" href="${escapeHtml(downloadUrl)}">${icon('down')}${t('release.download')}</a>`,
            `<a class="text-link" href="${escapeHtml(hrefTo(hubPath))}">${t('hero.hubLink')}${icon('arrow')}</a>`,
            '</p>',
          ].join('\n')
        : [
            '<p class="cta-row">',
            `<a class="btn btn-primary" href="${escapeHtml(githubUrl)}">${t('release.watch')}${icon('arrow')}</a>`,
            `<a class="text-link" href="${escapeHtml(githubUrl)}#building">${t('release.build')}</a>`,
            '</p>',
          ].join('\n');
      const ctaButtons = release.available
        ? `<p class="cta-row"><a class="btn btn-ink" href="${escapeHtml(downloadUrl)}">${icon('down')}${t('release.download')}</a><span class="cta-meta">${releaseLine}</span></p>`
        : `<p class="cta-row"><a class="btn btn-ink" href="${escapeHtml(githubUrl)}">${t('release.watch')}${icon('arrow')}</a></p>`;
      const sizeFigure = release.available && release.size
        ? `        <div class="figure-item"><dt><span class="figure">${escapeHtml(release.size)}</span><span class="figure-label">${t('req.sizeLabel')}</span></dt><dd>${t('req.sizeText')}</dd></div>`
        : '';
      const headerAction = page.id === 'hub'
        ? `      <a class="btn btn-primary btn-small header-action" href="${escapeHtml(hubLinks.pricing)}">${t('common.pricing')}</a>`
        : release.available
          ? `      <a class="btn btn-primary btn-small header-action" href="${escapeHtml(downloadUrl)}">${icon('down')}${t('common.download')}</a>`
          : `      <a class="btn btn-primary btn-small header-action" href="${escapeHtml(githubUrl)}">${t('common.github')}</a>`;

      // -------------------------------------------- Avo Hub: release switches
      const hubStatus = hubRelease.available
        ? `<strong>${escapeHtml(stripTags(t('hub.statusReleased', { version: escapeHtml(hubRelease.version || '') })))}</strong>`
        : `<strong title="${escapeHtml(stripTags(t(hubOpen ? 'hub.unreleasedNote' : 'hub.unreleasedNotePrivate')))}">${t('hub.statusUnreleased')}</strong>`;
      const hubCtas = hubRelease.available
        ? [
            '<p class="cta-row">',
            `<a class="btn btn-primary" href="${escapeHtml(hubDownloadUrl)}">${icon('down')}${t('hub.download')}</a>`,
            `<a class="text-link" href="${escapeHtml(hubLinks.pricing)}">${t('hub.pricingCta')}${icon('out')}</a>`,
            '</p>',
            `<p class="cta-meta">${t('hub.downloadMeta')}</p>`,
          ].join('\n')
        : [
            '<p class="cta-row">',
            `<a class="btn btn-primary" href="${escapeHtml(hubLinks.pricing)}">${t('hub.pricingCta')}${icon('out')}</a>`,
            `<a class="text-link" href="#how">${t('hub.howLink')}${icon('down')}</a>`,
            '</p>',
          ].join('\n');
      const hubGetCtas = hubRelease.available
        ? `<p class="cta-row"><a class="btn btn-ink" href="${escapeHtml(hubDownloadUrl)}">${icon('down')}${t('hub.download')}</a><span class="cta-meta">${t('hub.downloadMeta')}</span></p>`
        : [
            '<p class="cta-row">',
            `<a class="btn btn-ink" href="${escapeHtml(hubLinks.pricing)}">${t('hub.pricingCta')}${icon('out')}</a>`,
            `<a class="btn btn-quiet-ink" href="${escapeHtml(hrefTo(homePath))}">${t('hub.get.avoCta')}${icon('arrow')}</a>`,
            ...(hubOpen ? [`<a class="text-link" href="${escapeHtml(hubGithubUrl)}">${t('hub.watch')}${icon('arrow')}</a>`] : []),
            '</p>',
          ].join('\n');

      const supportChannels = config.support.channels.length ? channelList(config.support.channels, t) : `<p class="muted">${t('support.noChannels')}</p>`;
      const maintainer = config.maintainer?.name;
      const builtText = maintainer ? t('built.textNamed', { maintainer: escapeHtml(maintainer) }) : t('built.textAnon');

      // The questions on this page, for the page and for search engines.
      const faqPrefix = page.id === 'hub' ? 'hub.faq' : 'faq';
      const faq = [];
      for (let i = 1; lookupOptional(dict, `${faqPrefix}.q${i}`) !== undefined; i++) faq.push({ q: t(`${faqPrefix}.q${i}`), a: t(`${faqPrefix}.a${i}`) });
      const faqItems = faq
        .map(({ q, a }, i) => `        <details class="faq-item" name="faq"${i === 0 ? ' open' : ''}><summary>${q}<span class="faq-sign" aria-hidden="true"></span></summary><div class="faq-answer"><p>${a}</p></div></details>`)
        .join('\n');

      // ------------------------------------------------------ structured data
      const orgId = `${siteUrl}/#organization`;
      const siteId = `${siteUrl}/#website`;
      const avoId = `${siteUrl}/#avo`;
      const hubId = `${siteUrl}/hub/#avo-hub`;
      const organization = {
        '@type': 'Organization',
        '@id': orgId,
        name: 'Avo',
        url: `${siteUrl}/`,
        logo: { '@type': 'ImageObject', url: `${siteUrl}/assets/img/favicon-512.png`, width: 512, height: 512 },
        email: config.contact.email,
        description: stripTags(t('meta.orgDescription')),
        sameAs: [githubUrl],
      };
      const website = {
        '@type': 'WebSite',
        '@id': siteId,
        url: `${siteUrl}/`,
        name: 'Avo',
        alternateName: 'avodroid.com',
        description: stripTags(t('meta.homeDescription')),
        inLanguage: ['en', 'id'],
        publisher: { '@id': orgId },
      };
      const avoApp = {
        '@type': 'SoftwareApplication',
        '@id': avoId,
        name: 'Avo',
        url: homeUrl,
        description: stripTags(t('meta.homeDescription')),
        slogan: stripTags(t('meta.slogan')),
        applicationCategory: 'UtilitiesApplication',
        applicationSubCategory: 'Android app player',
        operatingSystem: 'macOS 15 or later on Apple silicon',
        processorRequirements: 'Apple silicon (M1 or newer)',
        storageRequirements: '10 GB',
        ...(release.available ? { softwareVersion: release.version, downloadUrl, ...(release.size ? { fileSize: release.size.replace(/\s+/g, '') } : {}) } : {}),
        isAccessibleForFree: true,
        license: 'https://www.apache.org/licenses/LICENSE-2.0',
        image: shotUrl('library'),
        screenshot: ['library', 'game-play', 'game-keys', 'settings-graphics'].map(shotUrl),
        offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD', ...(release.available ? { availability: 'https://schema.org/InStock' } : {}) },
        publisher: { '@id': orgId },
        inLanguage: lang,
      };
      const hubApp = {
        '@type': 'SoftwareApplication',
        '@id': hubId,
        name: 'Avo Hub',
        url: hubUrl,
        description: stripTags(t('meta.hubDescription')),
        slogan: stripTags(t('meta.slogan')),
        applicationCategory: 'UtilitiesApplication',
        operatingSystem: 'macOS 15 or later on Apple silicon; Android 11 or later',
        processorRequirements: 'Apple silicon (M1 or newer)',
        ...(hubRelease.available ? { softwareVersion: hubRelease.version, downloadUrl: hubDownloadUrl } : {}),
        ...(hubOpen ? { license: 'https://www.apache.org/licenses/LICENSE-2.0' } : {}),
        image: shotUrl('hub-overview'),
        screenshot: ['hub-overview', 'hub-notifications', 'hub-messages', 'hub-calls', 'hub-files', 'hub-readiness'].map(shotUrl),
        offers: [
          { '@type': 'Offer', name: 'Free', price: '0', priceCurrency: 'USD', url: hubLinks.pricing },
          {
            '@type': 'Offer',
            name: 'Pro',
            price: '2',
            priceCurrency: 'USD',
            url: hubLinks.pricing,
            priceSpecification: { '@type': 'UnitPriceSpecification', price: '2', priceCurrency: 'USD', billingDuration: 'P1M', referenceQuantity: { '@type': 'QuantitativeValue', value: 1, unitText: 'device' } },
          },
        ],
        isRelatedTo: { '@id': avoId },
        publisher: { '@id': orgId },
        inLanguage: lang,
      };
      const pageTitle = stripTags(t(page.title));
      const webPage = {
        '@type': 'WebPage',
        '@id': `${canonical}#webpage`,
        url: canonical,
        name: pageTitle,
        description: stripTags(t(page.description)),
        inLanguage: lang,
        isPartOf: { '@id': siteId },
        about: { '@id': page.id === 'hub' ? hubId : avoId },
        primaryImageOfPage: { '@type': 'ImageObject', url: `${siteUrl}/assets/img/og/${page.og}-${lang}.jpg`, width: 1200, height: 630 },
        ...(page.id === 'hub' ? { breadcrumb: { '@id': `${canonical}#breadcrumb` } } : {}),
      };
      const graph = page.id === '404'
        ? [organization, website]
        : [
            organization,
            website,
            webPage,
            page.id === 'hub' ? hubApp : avoApp,
            ...(page.id === 'hub'
              ? [{
                  '@type': 'BreadcrumbList',
                  '@id': `${canonical}#breadcrumb`,
                  itemListElement: [
                    { '@type': 'ListItem', position: 1, name: stripTags(t('meta.breadcrumbHome')), item: homeUrl },
                    { '@type': 'ListItem', position: 2, name: 'Avo Hub', item: hubUrl },
                  ],
                }]
              : []),
            ...(faq.length
              ? [{
                  '@type': 'FAQPage',
                  '@id': `${canonical}#faq`,
                  inLanguage: lang,
                  isPartOf: { '@id': `${canonical}#webpage` },
                  mainEntity: faq.map(({ q, a }) => ({ '@type': 'Question', name: stripTags(q), acceptedAnswer: { '@type': 'Answer', text: a } })),
                }]
              : []),
          ];
      const jsonLd = { '@context': 'https://schema.org', '@graph': graph };

      const ogName = `${page.og}-${lang}.jpg`;
      const ctx = {
        page: `${page.template} (${lang})`,
        partials,
        text: (key) => t(key),
        picture,
        vars: {
          lang,
          otherLang: other,
          root,
          title: pageTitle,
          ogTitle: stripTags(t(page.ogTitle ?? page.title)),
          description: stripTags(t(page.description)),
          robots: is404 ? 'noindex' : 'index, follow, max-image-preview:large',
          author: 'Avo',
          csp,
          canonical,
          altEn: `${siteUrl}/${page.paths.en}`,
          altId: `${siteUrl}/${page.paths.id ?? page.paths.en}`,
          ogLocale: lang === 'en' ? 'en_US' : 'id_ID',
          ogLocaleAlt: lang === 'en' ? 'id_ID' : 'en_US',
          ogImage: `${siteUrl}/assets/img/og/${ogName}`,
          ogAlt: stripTags(t(page.ogAlt)),
          cssVersion,
          jsVersion,
          homeHref: hrefTo(homePath),
          hubHref: hrefTo(hubPath),
          langHref: counterpart !== null ? hrefTo(counterpart) : hrefTo(lang === 'en' ? 'id/' : ''),
          githubUrl,
          blobUrl,
          contactEmail: config.contact.email,
          hubPricingUrl: hubLinks.pricing,
          hubTermsUrl: hubLinks.terms,
          hubPrivacyUrl: hubLinks.privacy,
          hubRefundUrl: hubLinks.refund,
          dmgName: release.available && release.version ? `Avo ${release.version}` : 'Avo',
          otherNotFound: stripTags(lookup(dicts[other], 'notFound.title', other)),
          otherHomeHref: hrefTo(other === 'en' ? '' : 'id/'),
          otherHomeLabel: stripTags(lookup(dicts[other], 'notFound.home', other)),
        },
        html: {
          navItems: navItems
            .map(([href, label, current]) => `        <li><a href="${escapeHtml(href)}"${current ? ` aria-current="${current}"` : ''}>${label}</a></li>`)
            .join('\n'),
          headerAction,
          heroPreload,
          heroCtas,
          releaseFacts,
          sizeFigure,
          ctaButtons,
          hubStatus,
          hubCtas,
          hubGetCtas,
          hubFactOpen: hubOpen ? `<li>${t('hub.hero.factOpen')}</li>` : '',
          hubOpenText: hubOpen ? `<p>${t('hub.avo.openText')}</p>` : '',
          hubGetTitle: t(hubRelease.available ? 'hub.get.titleReleased' : 'hub.get.titleUnreleased'),
          hubGetText: t(hubRelease.available ? 'hub.get.textReleased' : hubOpen ? 'hub.get.textUnreleased' : 'hub.get.textUnreleasedPrivate'),
          faqItems,
          supportChannels,
          builtText,
          copyright: t('footer.copyright', { year }),
          fontPreloads: fontSet.preload
            .map((file) => `<link rel="preload" href="${escapeHtml(`${root}assets/fonts/${file}`)}" as="font" type="font/woff2" crossorigin>`)
            .join('\n'),
          jsonLd: scriptJson(jsonLd),
        },
      };
      const html = render(template, ctx);
      const leftover = html.match(/\{\{[^}]*\}\}/);
      if (leftover) throw new Error(`unrendered "${leftover[0]}" in ${ctx.page}`);
      const target = path.join(outDir, outPath);
      await mkdir(path.dirname(target), { recursive: true });
      await writeFile(target, html);
      written.push(outPath);
      if (!is404) imageEntries[`${page.id}:${lang}`] = [...new Map(pictures.map((p) => [p.loc, p])).values()];
    }
  }

  // Search engines and browsers: every page in both languages, each with its
  // alternates and the screenshots on it.
  const urls = PAGES.filter((p) => p.id !== '404');
  const sitemap = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">',
    ...urls.flatMap((p) =>
      LANGS.map((lang) =>
        [
          '  <url>',
          `    <loc>${escapeHtml(`${siteUrl}/${p.paths[lang]}`)}</loc>`,
          ...LANGS.map((alt) => `    <xhtml:link rel="alternate" hreflang="${alt}" href="${escapeHtml(`${siteUrl}/${p.paths[alt]}`)}"/>`),
          `    <xhtml:link rel="alternate" hreflang="x-default" href="${escapeHtml(`${siteUrl}/${p.paths.en}`)}"/>`,
          ...(imageEntries[`${p.id}:${lang}`] || []).map((img) => `    <image:image><image:loc>${escapeHtml(img.loc)}</image:loc></image:image>`),
          '  </url>',
        ].join('\n'),
      ),
    ),
    '</urlset>',
    '',
  ].join('\n');
  await writeFile(path.join(outDir, 'sitemap.xml'), sitemap);
  await writeFile(path.join(outDir, 'robots.txt'), `User-agent: *\nAllow: /\nDisallow: /404.html\n\nSitemap: ${siteUrl}/sitemap.xml\n`);
  await writeFile(
    path.join(outDir, 'site.webmanifest'),
    `${JSON.stringify(
      {
        name: 'Avo',
        short_name: 'Avo',
        description: stripTags(lookup(dicts.en, 'meta.homeDescription', 'en')),
        lang: 'en',
        start_url: './',
        display: 'browser',
        background_color: '#0a1108',
        theme_color: '#0a1108',
        icons: [
          { src: 'assets/img/favicon-192.png', sizes: '192x192', type: 'image/png' },
          { src: 'assets/img/favicon-512.png', sizes: '512x512', type: 'image/png' },
        ],
      },
      null,
      2,
    )}\n`,
  );
  await writeFile(path.join(outDir, '.nojekyll'), '');
  await cp(path.join(ROOT, 'src/assets/img/favicon.ico'), path.join(outDir, 'favicon.ico'));

  const previous = `${finalDir}.previous-${process.pid}`;
  await rm(previous, { recursive: true, force: true });
  await rename(finalDir, previous).catch(() => {});
  await rename(outDir, finalDir);
  await rm(previous, { recursive: true, force: true });
  outDir = finalDir;

  log(`built ${written.length} pages into ${path.relative(process.cwd(), outDir) || '.'} (typefaces ${fontSet.letter}: ${fontSet.label}; css ${cssVersion}, js ${jsVersion})`);
  if (placeholders.length) {
    log(`\nsite.config.mjs still has ${placeholders.length} placeholder(s) to fill in before deploying:`);
    for (const p of placeholders) log(`  - ${p}`);
  }
  return { outDir, pages: written, placeholders, basePath, fonts: fontSetName(config.fonts) };
}

// ---------------------------------------------------------------------- cli

function parseArgs(argv) {
  const args = { strict: false, quiet: false, overrides: {} };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--strict') args.strict = true;
    else if (arg === '--quiet') args.quiet = true;
    else if (arg === '--out') args.outDir = path.resolve(argv[++i]);
    else if (arg === '--site-url') args.overrides = mergeDeep(args.overrides, { siteUrl: argv[++i] });
    else if (arg === '--fonts') args.overrides = mergeDeep(args.overrides, { fonts: argv[++i] });
    else if (arg === '-h' || arg === '--help') {
      console.log('usage: node tools/build.mjs [--strict] [--out DIR] [--site-url URL] [--fonts SET] [--quiet]');
      process.exit(0);
    } else throw new Error(`unknown argument ${arg}`);
  }
  return args;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await build(parseArgs(process.argv.slice(2)));
  } catch (error) {
    console.error(`build failed: ${error.message}`);
    process.exit(1);
  }
}
