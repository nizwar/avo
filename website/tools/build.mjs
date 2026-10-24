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
  { id: 'home', template: 'index.html', paths: { en: '', id: 'id/' }, title: 'meta.homeTitle', description: 'meta.homeDescription',
    og: 'og', ogAlt: 'meta.ogAlt' },
  { id: 'hub', template: 'hub.html', paths: { en: 'hub/', id: 'id/hub/' }, title: 'meta.hubTitle', description: 'meta.hubDescription',
    og: 'og-hub', ogAlt: 'meta.hubOgAlt' },
  { id: '404', template: '404.html', paths: { en: '404.html' }, title: 'meta.notFoundTitle', description: 'meta.homeDescription',
    og: 'og', ogAlt: 'meta.ogAlt' },
];

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
      const tokens = { github: githubUrl, blob: blobUrl, contactEmail: config.contact.email, hubGithub: hubGithubUrl };
      const text = (key, extra = {}) => lookup(dict, key, lang).replace(/\{(\w+)\}/g, (m, name) => (name in extra ? extra[name] : name in tokens ? escapeHtml(tokens[name]) : m));
      const t = (key, extra) => text(key, extra);
      const counterpart = page.paths[other] ?? null;
      const canonical = `${siteUrl}/${page.paths[lang]}`;

      const navHome = page.id === 'home' ? '' : hrefTo(homePath);
      const navItems = [
        [`${navHome}#gaming`, t('nav.gaming')],
        [`${navHome}#mac`, t('nav.mac')],
        [`${navHome}#how`, t('nav.how')],
        [`${navHome}#faq`, t('nav.faq')],
        [`${navHome}#support`, t('nav.support')],
        [hrefTo(hubPath), t('nav.hub'), page.id === 'hub' ? 'page' : null],
      ];

      const release = config.release || {};
      const downloadUrl = release.downloadUrl || `${githubUrl}/releases/latest`;
      const releasePill = release.available
        ? `<p class="status-pill is-released">${escapeHtml(stripTags(t('release.statusReleased', { version: escapeHtml(release.version || '') })))}</p>`
        : `<p class="status-pill" title="${escapeHtml(stripTags(t('release.unreleasedNote')))}">${t('release.statusUnreleased')}</p>`;
      const heroCtas = release.available
        ? [
            `<a class="btn btn-primary" href="${escapeHtml(downloadUrl)}"><svg class="icon" aria-hidden="true" focusable="false"><use href="#i-down"/></svg>${t('release.download')}</a>`,
            `<a class="btn btn-quiet" href="${escapeHtml(githubUrl)}">${t('release.watch')}<svg class="icon" aria-hidden="true" focusable="false"><use href="#i-arrow"/></svg></a>`,
          ].join('\n')
        : [
            `<a class="btn btn-primary" href="${escapeHtml(githubUrl)}">${t('release.watch')}<svg class="icon" aria-hidden="true" focusable="false"><use href="#i-arrow"/></svg></a>`,
            `<a class="btn btn-quiet" href="${escapeHtml(githubUrl)}#building">${t('release.build')}</a>`,
          ].join('\n');
      // What the download is, under both buttons (beside one, it pushed the other away).
      const heroMeta = release.available ? `<p class="cta-meta">${t('release.downloadMeta')}</p>` : '';

      // Avo Hub's page: the same switches, from config.hub.release.
      const hubDownloadUrl = hubRelease.downloadUrl || `${hubGithubUrl}/releases/latest`;
      const hubPill = hubRelease.available
        ? `<p class="status-pill is-released">${escapeHtml(stripTags(t('hub.statusReleased', { version: escapeHtml(hubRelease.version || '') })))}</p>`
        : `<p class="status-pill" title="${escapeHtml(stripTags(t('hub.unreleasedNote')))}">${t('hub.statusUnreleased')}</p>`;
      const hubCtas = hubRelease.available
        ? [
            `<a class="btn btn-primary" href="${escapeHtml(hubDownloadUrl)}"><svg class="icon" aria-hidden="true" focusable="false"><use href="#i-down"/></svg>${t('hub.download')}</a>`,
            `<a class="btn btn-quiet" href="${escapeHtml(hubGithubUrl)}">${t('hub.watch')}<svg class="icon" aria-hidden="true" focusable="false"><use href="#i-arrow"/></svg></a>`,
          ].join('\n')
        : [
            `<a class="btn btn-primary" href="${escapeHtml(hubGithubUrl)}">${t('hub.watch')}<svg class="icon" aria-hidden="true" focusable="false"><use href="#i-arrow"/></svg></a>`,
            `<a class="btn btn-quiet" href="${escapeHtml(hubGithubUrl)}#building-from-source">${t('hub.build')}</a>`,
          ].join('\n');
      const hubMeta = hubRelease.available ? `<p class="cta-meta">${t('hub.downloadMeta')}</p>` : '';

      const supportChannels = config.support.channels.length ? channelList(config.support.channels, t) : `<p class="note">${t('support.noChannels')}</p>`;
      const maintainer = config.maintainer?.name;
      const builtText = maintainer ? t('built.textNamed', { maintainer: escapeHtml(maintainer) }) : t('built.textAnon');

      const jsonLd = page.id === 'hub'
        ? {
            '@context': 'https://schema.org',
            '@type': 'SoftwareApplication',
            name: 'Avo Hub',
            description: t('meta.hubDescription'),
            url: canonical,
            applicationCategory: 'UtilitiesApplication',
            operatingSystem: 'macOS 15 or later, Apple silicon; Android 11 or later',
            license: 'https://www.apache.org/licenses/LICENSE-2.0',
            inLanguage: lang,
          }
        : {
            '@context': 'https://schema.org',
            '@type': 'SoftwareApplication',
            name: 'Avo',
            description: t('meta.homeDescription'),
            url: canonical,
            applicationCategory: 'UtilitiesApplication',
            operatingSystem: 'macOS 15 or later, Apple silicon',
            isAccessibleForFree: true,
            license: 'https://www.apache.org/licenses/LICENSE-2.0',
            offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
            inLanguage: lang,
          };

      const ogName = `${page.og}-${lang}.jpg`;
      const ctx = {
        page: `${page.template} (${lang})`,
        partials,
        text: (key) => t(key),
        vars: {
          lang,
          otherLang: other,
          root,
          title: stripTags(t(page.title)),
          description: stripTags(t(page.description)),
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
          otherNotFound: stripTags(lookup(dicts[other], 'notFound.title', other)),
          otherHomeHref: hrefTo(other === 'en' ? '' : 'id/'),
          otherHomeLabel: stripTags(lookup(dicts[other], 'notFound.home', other)),
        },
        html: {
          navItems: navItems
            .map(([href, label, current]) => `        <li><a href="${escapeHtml(href)}"${current ? ` aria-current="${current}"` : ''}>${label}</a></li>`)
            .join('\n'),
          releasePill,
          heroCtas,
          heroMeta,
          hubPill,
          hubCtas,
          hubMeta,
          hubGetTitle: t(hubRelease.available ? 'hub.get.titleReleased' : 'hub.get.titleUnreleased'),
          hubGetText: t(hubRelease.available ? 'hub.get.textReleased' : 'hub.get.textUnreleased'),
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
    }
  }

  // Search engines and browsers.
  const urls = PAGES.filter((p) => p.id !== '404');
  const sitemap = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">',
    ...urls.flatMap((p) =>
      LANGS.map((lang) =>
        [
          '  <url>',
          `    <loc>${escapeHtml(`${siteUrl}/${p.paths[lang]}`)}</loc>`,
          ...LANGS.map((alt) => `    <xhtml:link rel="alternate" hreflang="${alt}" href="${escapeHtml(`${siteUrl}/${p.paths[alt]}`)}"/>`),
          '  </url>',
        ].join('\n'),
      ),
    ),
    '</urlset>',
    '',
  ].join('\n');
  await writeFile(path.join(outDir, 'sitemap.xml'), sitemap);
  await writeFile(path.join(outDir, 'robots.txt'), `User-agent: *\nAllow: /\n\nSitemap: ${siteUrl}/sitemap.xml\n`);
  await writeFile(
    path.join(outDir, 'site.webmanifest'),
    `${JSON.stringify(
      {
        name: 'Avo',
        short_name: 'Avo',
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
