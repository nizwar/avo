// Avo Hub's pricing and policy pages (/hub/pricing/, /hub/terms/,
// /hub/privacy/, /hub/refunds/), which the Avo Hub account links to and its
// old addresses redirect to:
//
// - `?lang=en|id` (the old addresses' language, kept by the redirect) moves
//   to the page in that language;
// - `?back=` (a page opened from the account's sign-in) shows the way back
//   to that sign-in and keeps it on the links between these pages; opened
//   from an app's sign-in (the Mac's or the phone's, `client_id`), the page
//   offers only that way back, so nobody wanders off while the app waits;
// - the pricing page shows the launch price until it ends, by the visitor's
//   clock, and the standard price after.
//
// The functions above setupHubPages() are pure, for the tests.

const HUB_PAGE = /^\/(?:id\/)?hub\/(?:pricing|terms|privacy|refunds)\/$/;

/**
 * The account's sign-in a page was opened from (`?back=`): only the
 * account's own sign-in page (`accountUrl`'s origin, path `/`), so the
 * parameter can't send anyone anywhere else.
 */
export function wayBack(search, accountUrl) {
  const raw = new URLSearchParams(search).get('back');
  if (!raw || !accountUrl) return null;
  try {
    const url = new URL(raw);
    const account = new URL(accountUrl);
    return url.origin === account.origin && url.pathname === '/' ? url.href : null;
  } catch {
    return null;
  }
}

/** Whether `back` is an app's sign-in (the Mac's or the phone's), not a web app's. */
export function isAppSignIn(back) {
  try {
    return new URL(back).searchParams.has('client_id');
  } catch {
    return false;
  }
}

/**
 * Where `?lang=` asks to go: the same page in that language (`alternates`:
 * language -> address), with the rest of the address kept; null when the
 * page already is in it or has no such version.
 */
export function languageMove(href, current, alternates) {
  const url = new URL(href);
  const lang = url.searchParams.get('lang');
  if (!lang || lang === current || !alternates[lang]) return null;
  url.searchParams.delete('lang');
  const target = new URL(alternates[lang], url);
  target.search = url.search;
  target.hash = url.hash;
  return target.href;
}

/**
 * A link on a page opened from the account's sign-in, kept with it: the
 * account itself (sign in, Get Pro, the trial) becomes `back`, and another
 * of these pages carries `back` on. Anything else stays as it is.
 */
export function keepBack(href, back, base, accountUrl) {
  if (!back || href.startsWith('#')) return href;
  let url;
  try {
    url = new URL(href, base);
  } catch {
    return href;
  }
  if (url.origin === new URL(accountUrl).origin) return back;
  if (url.origin !== new URL(base).origin || !HUB_PAGE.test(url.pathname)) return href;
  url.searchParams.set('back', back);
  return url.href;
}

/** Which prices are in force at `now`: the launch ones until `launchEnds`, the standard ones after. */
export function priceList(now, launchEnds) {
  const end = Date.parse(launchEnds);
  return Number.isFinite(end) && now >= end ? 'standard' : 'launch';
}

export function setupHubPages() {
  const body = document.body;
  // Any page: an old address's language.
  const alternates = {};
  for (const link of document.querySelectorAll('link[rel="alternate"][hreflang]')) alternates[link.hreflang] = link.href;
  const move = languageMove(window.location.href, document.documentElement.lang, alternates);
  if (move) {
    window.location.replace(move);
    return;
  }
  if (!body.classList.contains('page-hub-pages')) return;

  // The pricing page: the visitor's clock decides which prices show.
  if (body.dataset.launchEnds) {
    const list = priceList(Date.now(), body.dataset.launchEnds);
    for (const el of document.querySelectorAll('[data-price-list]')) el.hidden = el.dataset.priceList !== list;
  }

  const account = body.dataset.account;
  const back = wayBack(window.location.search, account);
  if (!back) return;
  const bar = document.querySelector('[data-hub-back]');
  if (bar) {
    bar.querySelector('a').href = back;
    bar.hidden = false;
  }
  for (const link of document.querySelectorAll('a[href]')) {
    if (link.closest('[data-hub-back]')) continue;
    link.href = keepBack(link.getAttribute('href'), back, window.location.href, account);
  }
  if (!isAppSignIn(back)) return;
  // From an app's sign-in: nothing but the way back, the pages and the language.
  document.documentElement.classList.add('from-app');
  const brand = document.querySelector('.site-header .brand');
  if (brand) brand.removeAttribute('href');
  // A link to another site (PayPal) opens beside the sign-in, never in its place.
  const here = window.location.origin;
  for (const link of document.querySelectorAll('main a[href^="http"]')) {
    if (new URL(link.href).origin === here || link.href === back) continue;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
  }
}
