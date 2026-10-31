// Avo website configuration: every link, channel and switch you need to fill
// in or decide lives in this one file.
//
// Placeholders contain OWNER, TODO or example.org. `npm run build` lists the
// ones still left; `npm run build:strict` (used by the GitHub Pages workflow)
// refuses to build until they are all replaced. Wording lives in
// src/i18n/en.json and src/i18n/id.json.

export default {
  // Public address of this website, without a trailing slash. Used for
  // canonical links, the sitemap and social previews.
  siteUrl: 'https://avodroid.com',

  // The GitHub repository, and its default branch (for links into docs/).
  githubUrl: 'https://github.com/nizwar/avo',
  githubBranch: 'main',

  // Releases. While `available` is false the site says plainly that Avo is
  // not released yet and points to building from source and to GitHub.
  release: {
    available: true,
    version: '1.0.0',
    // The disk image itself, so the button downloads at once. Update with each release.
    downloadUrl: 'https://github.com/nizwar/avo/releases/download/v1.0.0/Avo-1.0.0-b123.dmg',
    // The disk image's size as visitors read it, next to the button. Update with each release.
    size: '26 MB',
  },

  // Avo Hub, Avo's sibling app that connects the phone in your pocket, has a
  // page of its own (/hub) and its own repository. Its release works like
  // `release` above: while `available` is false the page says it isn't out
  // yet and points to GitHub; set `available`, `version` and `downloadUrl`
  // when a preview is published.
  hub: {
    githubUrl: 'https://github.com/nizwar/avo_hub',
    // Whether its repository is public. While false the page shows no GitHub
    // link and claims no open source (a private repository is empty to
    // visitors); set it to true once github.com/nizwar/avo_hub is public.
    openSource: false,
    release: {
      available: false,
      version: null,
      downloadUrl: null,
    },
    // The Avo Hub account: where people sign in, start the free trial and
    // subscribe to Pro. The pricing page's buttons lead there (`?pro=month`
    // or `?pro=year` opens its Get Pro on that period), and the policy pages
    // lead back to its sign-in when they were opened from it (`?back=`, only
    // this address's own sign-in page).
    accountUrl: 'https://auth.avodroid.com/',
    // Avo Hub's pricing and policies are this site's pages, in both
    // languages: /hub/pricing/, /hub/terms/, /hub/privacy/, /hub/refunds/
    // (and /id/hub/...). Their text lives here, in src/hub/*.json and the
    // `hubPricing` wording; the account's old addresses
    // (auth.avodroid.com/pricing, /terms, /privacy, /refund) redirect here.
    // `legal` holds who sells Avo Hub and the plans' numbers the text quotes:
    // keep them equal to Avo Hub's docs/accounts.md and its server.
    legal: {
      // The seller, exactly as on the PayPal business account.
      seller: 'Mochamad Nizwar Syafuan',
      // Billing, privacy and refund questions.
      email: 'support@avodroid.com',
      // When the policies last changed (shown on each page).
      updated: '2026-10-31',
      plan: {
        trialDays: 14,
        trialDevices: 5,
        freeDevices: 2,
        freeBrowsers: 2,
        proBrowsers: 10,
        refundDays: 14,
        graceDays: 7,
        passDays: 7,
        noticeDays: 30,
        purgeDays: 30,
        usageMonths: 13,
        logDays: 14,
        freeInternet: '1 GB',
        fairUse: '200 GB',
      },
    },
    // Pro's prices in US dollars, per device: [first device, each one after]
    // (Avo Hub's docs/decisions.md D-17). The launch price is for
    // subscriptions started up to and including `launchEnds` (to the end of
    // that day anywhere on Earth), and stays with them for as long as they
    // last; the standard price is for those started later. The pages'
    // wording and their structured data read these; the pricing page shows
    // the launch price until then and the standard one after, by the
    // visitor's clock. They must match Avo Hub's PayPal plans (its D-17).
    pricing: {
      launchEnds: '2027-01-01',
      launch: { month: [2, 1], year: [20, 10] },
      standard: { month: [5, 3], year: [50, 30] },
    },
  },

  // Typefaces, one switch for the whole site (only the chosen set is published):
  //   'hubot-mona' (A) Hubot Sans headings, Mona Sans text, Mona Sans Mono labels
  //   'geist'      (B) Geist and Geist Mono
  //   'archivo'    (C) Archivo, wide headings, with JetBrains Mono
  //   'jakarta'    (D) Plus Jakarta Sans, with JetBrains Mono
  fonts: 'hubot-mona',

  // Named in the footer credit ("Made by …"). Set to null to say
  // "one developer" instead.
  maintainer: {
    name: null,
  },

  // Public contact address (questions about Avo and support).
  contact: {
    email: 'nizwar.id@gmail.com',
  },

  // Avo's own Terms of Use and Privacy Policy, apart from Avo Hub's:
  // /terms/ and /privacy/ (and /id/...), their text in src/avo/*.json, with
  // `contact.email` as their address. `updated`: when they last changed
  // (shown on each page and in its structured data).
  legal: {
    updated: '2026-11-01',
  },

  // Personal support for Avo's developer. `frequency`: 'monthly', 'once' or
  // 'monthly-or-once'. `details` is optional plain text (for example a bank
  // account); `url` may be null for a channel that only has details. An empty
  // list shows "Support links are coming soon". Use public profile pages
  // only: never a link that carries a key (Saweria's widget links carry the
  // stream key).
  support: {
    channels: [
      { name: 'GitHub Sponsors', url: 'https://github.com/sponsors/nizwar', currency: 'USD', frequency: 'monthly-or-once' },
      { name: 'PayPal', url: 'https://paypal.me/nizwar', currency: 'USD', frequency: 'once' },
      { name: 'Saweria', url: 'https://saweria.co/hangpuan', currency: 'IDR', frequency: 'once' },
    ],
  },
};
