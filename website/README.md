# Avo website

The public website for Avo, in English and Indonesian: a landing page, Avo's
own Terms of Use and Privacy Policy (`/terms/`, `/privacy/`), a page for Avo
Hub (`/hub`, Avo's sibling app for the phone), Avo Hub's pricing and
policies (`/hub/pricing/`, `/hub/terms/`, `/hub/privacy/`, `/hub/refunds/`)
and a 404 page, built by a small Node script. Plain HTML, CSS and
JavaScript; no framework, no npm dependencies, no cookies, no analytics. It
is hosted on GitHub Pages as is.

The slogan is **Android in your ecosystem.** (Indonesian: **Android di
ekosistemmu.**). It stands over both pages' headlines, which say what each
app is (Android emulator for your Mac; Your Android phone, on your Mac) in
two halves split by the product's real windows; it ends every title and
share card, and the footer closes with it. The look is Avo's
haze palette set flat: no gradients, glows, blur or shadows at rest; the
pictures are the apps' own windows.

## Contents

```
website/
├── site.config.mjs          Everything to fill in or decide: URLs, release state, contact,
│                            support channels, typeface set
├── src/
│   ├── pages/               index.html (landing page), avo-legal.html (Avo's /terms/ and
│   │                        /privacy/), hub.html (Avo Hub, at /hub), hub-pricing.html
│   │                        (/hub/pricing/), hub-legal.html (/hub/terms/, /hub/privacy/,
│   │                        /hub/refunds/), 404.html
│   ├── partials/            head, header, footer, SVG sprite, the hub pages' tabs and seller line
│   ├── i18n/en.json, id.json  All wording, English and Indonesian (same keys; the build checks)
│   ├── avo/                 Avo's own Terms of Use and Privacy Policy (terms.json,
│   │                        privacy.json: { en, id }, the same shape in both)
│   ├── hub/                 Avo Hub's Terms, Privacy Policy and Refund Policy (terms.json,
│   │                        privacy.json, refunds.json: { en, id }, the same shape in both)
│   └── assets/              css/site.css, css/fonts/ (one file per typeface set), js/ (site.js:
│                            header, entrances; reel.js: the hero's windows; commands.js: Avo's
│                            commands and the game keys; story.js: the held story, Avo Hub's
│                            index and pairing walk-through; lightbox.js: click to zoom;
│                            hub-pages.js: the hub pages' language, way back and prices),
│                            fonts/ (one folder per family, each with its OFL.txt), img/ (Avo
│                            mark and icon from branding/, favicons, og/, screens/: Avo's
│                            windows, Avo Hub's windows from its snapshot tests and the disk
│                            image's background, in AVIF, WebP and JPEG at 640 px and full
│                            width, with player names and device IDs blurred)
├── tools/
│   ├── build.mjs            Builds dist/ (npm run build); --strict refuses placeholders
│   ├── serve.mjs            Local development server with rebuild on change
│   ├── screenshots.mjs      Headless Chrome screenshots and layout checks
│   └── og-image.html        Template for the social preview images (src/assets/img/og/)
├── tests/                   node --test: the built site (both languages, links, no emoji,
│                            CSP-friendly markup, titles, share cards, structured data,
│                            sitemap, configuration switches)
├── deploy/github-pages.yml  GitHub Actions workflow to copy into .github/workflows/
└── dist/                    Build output (ignored by git)
```

## Requirements

Node.js 22.5 or later. Nothing to install with npm.

## Configure

Everything you need to fill in is in **`site.config.mjs`**, with comments.
Placeholders contain `OWNER`, `TODO` or `example.org`; `npm run build` lists
the ones left and `npm run build:strict` refuses to build until none are.

| Setting | What it is |
| --- | --- |
| `siteUrl` | Public address of the site (`https://avodroid.com`). Used for canonical links, the sitemap and social previews. |
| `githubUrl`, `githubBranch` | The repository and its branch, for links into `docs/`. |
| `release` | `available: false` says plainly that no build is published and offers "Build from source". Set `available: true`, `version`, `downloadUrl` and `size` (the disk image's size, shown beside the button and as a figure) when a release is out. |
| `hub` | Avo Hub's page: its repository (`githubUrl`, linked only once `openSource` is true), `release`, which works like Avo's, the Avo Hub account (`accountUrl`: sign in, the trial and Get Pro), who sells it and the plans' numbers the policies quote (`legal`: `seller`, `email`, `updated`, `plan`), and Pro's prices (`pricing`: the launch price, the day it ends and the standard price, which the wording and the structured data both read). While `available` is false the page says Avo Hub isn't released yet and leads to its pricing. |
| `fonts` | The typeface set, one switch for the whole site: `'hubot-mona'` (A, default: Hubot Sans headings, Mona Sans text, Mona Sans Mono labels), `'geist'` (B), `'archivo'` (C), `'jakarta'` (D, Plus Jakarta Sans). Letters work too. Only the chosen set's files are published. |
| `maintainer.name` | Named in the footer credit ("Made by … in West Kalimantan, with help from Claude."). `null` says "an independent developer". |
| `contact.email` | Public contact address, also the address Avo's own policies give. |
| `legal.updated` | When Avo's own Terms of Use and Privacy Policy last changed (shown on both pages and in their structured data). |
| `support.channels` | Ways to support the developer personally (GitHub Sponsors, Saweria, ...): `name`, `url`, `currency`, `frequency` (`monthly`, `once`, `monthly-or-once`), optional `details` text (for example a bank account). An empty list shows "Support links are coming soon". |

The wording is in `src/i18n/en.json` and `src/i18n/id.json`. Both files must
have the same keys; the build stops if they differ. Strings may contain
`{github}`, `{blob}`, `{contactEmail}`, `{avoTerms}`, `{avoPrivacy}`, `{hubGithub}`, `{hubPricing}`,
`{hubTerms}`, `{hubPrivacy}`, `{hubRefunds}`, `{account}`, `{seller}`,
`{hubEmail}`, the plans' numbers (`{trialDays}`, `{refundDays}`… from
`hub.legal.plan`), `{launchEnds}` and Pro's prices (`{launchFirstMonth}`,
`{launchExtraMonth}`, `{launchFirstYear}`, `{launchExtraYear}` and the same
with `standard`), which the build fills in.

## Avo's terms and privacy

Avo's own policies are `/terms/` (Terms of Use) and `/privacy/` (Privacy
Policy), with `/id/terms/` and `/id/privacy/` in Indonesian, their text in
`src/avo/terms.json` and `src/avo/privacy.json`. They are apart from Avo
Hub's: their own two tabs, no seller, no prices, no refunds (Avo is free),
and `contact.email` as their address. The footer of every page keeps the
two apart too: **Avo's policies** (Terms, Privacy) and **Avo Hub's pricing
and policies** (Pricing, Terms, Privacy, Refunds), under the columns they
belong to; the home page's question about privacy links to Avo's.

- They say only what Avo does, in plain words: the Apache License 2.0 (and
  NOTICE) as the licence, no warranty, what Avo keeps on the Mac, the only
  places it goes online (Google's server for Android, GitHub for updates
  and, when asked, Google apps and Magisk), Apple's services some features
  use, no analytics or crash reports, the camera, microphone, location and
  clipboard as set in Settings, Report a Problem saving locally, the
  trademarks, and this site (no cookies or analytics; GitHub Pages logs
  visitors' IP addresses). When Avo changes any of that (a new connection,
  telemetry, an account), change the policy in both languages and
  `legal.updated` with it.
- Edit both languages together: the build refuses a policy whose languages
  differ in sections, paragraphs or lists. Links are `[label](href)`, with
  `{github}`, `{license}`, `{notice}`, `{issues}`, `{security}` (a private
  security report), `{support}`, `{avoTerms}`, `{avoPrivacy}`, `{hubTerms}`
  and `{hubPrivacy}` for the addresses, and `{email}` for `contact.email`.

## Avo Hub's pricing and policies

This site owns them: `/hub/pricing/`, `/hub/terms/`, `/hub/privacy/` and
`/hub/refunds/`, with `/id/hub/…` in Indonesian, are the only copy of their
text (the policies in `src/hub/*.json`, the pricing page in the `hubPricing`
wording). Avo Hub's account (`auth.avodroid.com`) no longer has pages of its
own: its old addresses (`/pricing`, `/terms`, `/privacy`, `/refund`, with or
without `.html`) redirect here permanently, with their query kept, and its
apps, emails and sign-in page link here. Change the text here, never there.

- The policies keep their legal meaning; edit both languages together (the
  build refuses a policy whose languages differ in sections, paragraphs or
  lists). Links are `[label](href)`, with `{hubPricing}`, `{hubTerms}`,
  `{hubPrivacy}`, `{hubRefunds}` and `{account}` for the addresses; a bare
  email address becomes a link. Update `hub.legal.updated` when they change.
- The numbers they quote (trial, refund window, retention…) come from
  `hub.legal.plan` and the prices from `hub.pricing`; keep both equal to Avo
  Hub's `docs/accounts.md` and its server's PayPal plans.
- The pricing page carries both price lists; the one not in force is
  hidden, by the build's clock and then by the visitor's (`hub-pages.js`),
  so the launch price disappears on its own after its last day.
- `?lang=en|id` (an old address's language) moves to that language's page.
  `?back=` (a page opened from the account's sign-in, only
  `hub.accountUrl`'s own sign-in page) shows "Back to Sign In" and keeps it
  on the links between these pages; opened from the Mac's or the phone's
  sign-in (`client_id`), the page shows nothing else to wander off through
  (no menu, no footer links, no pricing), and links to other sites open
  beside it.
- Get Started and the trial lead to `hub.accountUrl`; Get Pro to
  `hub.accountUrl?pro=month` (or `?pro=year`), whose Get Pro opens on that
  period after signing in.

Product claims on the page follow `docs/` and the code. The Avo Hub page
follows Avo Hub's own repository (its README, docs and changelog). When a feature lands
or changes, update the wording in both languages.

## Local development

```sh
cd website
npm run dev            # build, serve at http://localhost:8788/ and rebuild on change
npm test               # build into a temporary folder and check it
npm run build          # build dist/ only
npm run build:strict   # the same, refusing any placeholder left in site.config.mjs
```

The site is served under the path of `siteUrl` (here the root, `/`), as GitHub
Pages serves it on the custom domain.

Screenshots and layout checks (content wider than the screen, console errors,
HTTP status) with headless Chrome in a throwaway profile, while `npm run dev`
runs:

```sh
node tools/screenshots.mjs --out /tmp/avo-shots [--only home-en] [--views desktop,phone]
```

It takes the product pages at 1440 (desktop), 1280 (laptop), 820 (tablet),
390 (phone) and 320 px (small), Avo's terms and privacy and Avo Hub's
pricing and policies at 1440 and 390 (also opened from an app's sign-in, and from an old address with
`?lang=id`), in both languages.

## Search engines and link previews

Each page leads with the phrase people search for, in its title (at most 60
characters, ending with the slogan), its description (120 to 160) and its
headline: **Android emulator for Mac** / **Emulator Android untuk Mac** on
the home page, **Mirror Android to Mac** / **Mirror HP Android ke Mac** on
/hub. Section headings and the questions cover the rest (Apple silicon from
M1 to M4, games with keys and mouse, BlueStacks, Phone Link on the Mac,
scrcpy, AirDroid), saying only what the apps do; keep it that way when the
wording changes.

The build gives every page a canonical link, `hreflang` alternates (en, id,
x-default), Open Graph and Twitter cards with the images in
`src/assets/img/og/` (rendered from `tools/og-image.html`), and one JSON-LD
graph: the organisation, the website, the page, the app (Avo, or Avo Hub
with Free and Pro at its launch and standard prices) with its feature list,
the page's questions as a FAQPage (links in the answers as full
addresses), and a breadcrumb on Avo's policies (Avo › the policy), on /hub
and on its pricing and policy pages (Avo › Avo Hub › the page; the pricing
page also carries Avo Hub's offers, a policy the day it last changed). `sitemap.xml`
lists both languages of each page with their alternates, screenshots and
the date of the last commit that changed them (so the workflow checks out
the whole history); `robots.txt` points to it; `llms.txt` describes both
apps in plain text. The first screen's picture is preloaded (AVIF) along
with the two typefaces. The 404 page is `noindex`.

## Deploy

The site is published on GitHub Pages at https://avodroid.com (the
repository's custom domain, with HTTPS enforced) by
`.github/workflows/website.yml` (a copy is in `deploy/github-pages.yml`):
every push to `main` that touches `website/` runs the tests, builds with
`--strict` and publishes `website/dist`. The repository's Settings › Pages
source is **GitHub Actions**. Check with `npm run build:strict` before
pushing.

The custom domain's DNS (at the registrar) points the apex at GitHub Pages
(A records 185.199.108.153, .109.153, .110.153, .111.153 and AAAA records
2606:50c0:8000::153 to 8003::153) and `www` at `nizwar.github.io` (CNAME).
`siteUrl` must match the domain.

## Checklist before going live

- [ ] Whether to show `maintainer.name`
- [ ] When a release is published: `release.available`, `version`, `downloadUrl`
- [ ] When Avo Hub's first preview is published: `hub.release.available`, `version`, `downloadUrl`

## Licenses

Code: Apache License 2.0, like the rest of Avo. Typefaces are self-hosted and
all under the SIL Open Font License 1.1, with the license next to each font in
`src/assets/fonts/<family>/OFL.txt`: Hubot Sans, Mona Sans and Mona Sans Mono
(GitHub), Geist and Geist Mono (Vercel), Archivo (Omnibus-Type), Plus Jakarta
Sans (Tokotype) and JetBrains Mono (JetBrains). The files are the Latin files
Google Fonts publishes (Mona Sans Mono: GitHub's release), unmodified, so
families with Reserved Font Names (Hubot, Mona) are not altered. Only the set
chosen in `site.config.mjs` is published. The Avo mark and icon come from
`branding/`.

Typeface sets live in `src/assets/css/fonts/<set>.css`: each declares its
`@font-face` rules and the `--font-display`, `--font-sans`, `--font-mono` and
`--display-*` variables (weight, width, tracking, leading) that `site.css`
uses. To add a set, add the family folder with its license, a CSS file, and
an entry in `FONT_SETS` in `tools/build.mjs`.
