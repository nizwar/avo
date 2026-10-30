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
    // Avo Hub's plans and policies live with its accounts (auth.avodroid.com).
    pricingUrl: 'https://auth.avodroid.com/pricing',
    termsUrl: 'https://auth.avodroid.com/terms',
    privacyUrl: 'https://auth.avodroid.com/privacy',
    refundUrl: 'https://auth.avodroid.com/refund',
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
