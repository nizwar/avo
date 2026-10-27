# Versioning

How Avo's releases are numbered and named: the version, the beta label and
the build number, where each one appears, and when each one goes up.
[releasing.md](releasing.md) covers how a release is built and published.

These rules cover `Avo.app` and everything inside it (the Control Panel,
the daemon, `avoctl`, avo-vmm and the helpers), which always ship together
under one version. The Android image, the GPU renderer's patch revision and
Avo Hub are versioned on their own.

## In one line

**Avo 0.4.0** is a release; **Avo 0.5.0 Beta 2** is an early, published
try of the next one; **build 121** is the exact build. Said out loud, a
trailing ".0" is dropped: "Avo zero point four", "Avo zero point five beta
two", "Avo zero point four point one", with "build 121" only when the exact
build matters (a bug report, a tester's question). Written down, the
version always has all three numbers.

## The three parts

| Part | Example | What it says | Where it lives |
|---|---|---|---|
| Version | `0.4.0` | what a release is, for players and the changelog | `MARKETING_VERSION` (`host/Config/Base.xcconfig`, `--version`) → `CFBundleShortVersionString` |
| Beta label | `Beta 2` | that this is not the final 0.4.0 yet, and which try it is | the git tag, the release title, the changelog heading; not in the app |
| Build number | `121` | which exact build, of every build ever made | `--build` → `CURRENT_PROJECT_VERSION` → `CFBundleVersion`; the DMG name |

The version and the label are for people. The build number is for
machines: Sparkle compares `CFBundleVersion` with the feed's
`sparkle:version` (generate_appcast reads it from the app in the DMG), and
App Shims compare it with their template. None of them look at the
version.

## The version: MAJOR.MINOR.PATCH

Avo follows [Semantic Versioning 2.0](https://semver.org). The version is
three plain numbers with no letters, since macOS expects
`CFBundleShortVersionString` to be just that.

### While Avo is 0.x

A version that starts with 0 says that Avo is still taking shape. In 0.x:

| Bump | When | Example |
|---|---|---|
| MINOR (0.4.0 → 0.5.0) | the release adds or changes something players see: anything under **New** or **Changed** in the changelog, and every change listed under *What counts as breaking* below | a new setting, a new key mapping control, OpenGL ES 3.2 |
| PATCH (0.4.0 → 0.4.1) | the release only fixes or polishes what the last release had: **Fixed**, small **Improved** items, translations; no new setting, no new feature, nothing that moves players' data | a crash fix, a layout fix |
| MAJOR | never in 0.x; it goes to 1 once, for 1.0 | |

When in doubt, it is a minor release. A patch release must be safe to
install without reading its notes.

### What counts as breaking

Anything a player has to act on, or could lose, when they update:

- Android's data does not carry over (a new disk format, a wipe, apps that
  must be installed again);
- a newer macOS, or a newer Mac, is required;
- an Android version Avo offered is dropped;
- key mappings, app settings or checkpoints from the last release no
  longer load;
- macOS asks again for permissions or the background item (a new bundle
  identifier, a new signing identity);
- `avoctl` commands or options, or what apps can detect
  ([for-game-developers.md](for-game-developers.md)), change or go away.

In 0.x a breaking change makes the release a minor one and puts a
**Before you update** section first in its changelog entry. From 1.0 on it
takes a major release.

### The way to 1.0

1.0 says "Avo is ready for everyone, and an update will not break your
setup". It comes when all of these hold:

- updates have installed themselves, end to end, across several releases,
  with Android's data carried over each time;
- settings, key mappings and checkpoints have kept a stable format for
  several releases;
- no known issue loses data or leaves Android unable to start;
- the supported Macs and macOS versions are written down and tested;
- the updater can keep betas away from players who did not ask for them
  (*Who gets a beta* below).

From 1.0, MINOR means new features that break nothing, PATCH means fixes,
and MAJOR means anything in *What counts as breaking*.

## Betas

A beta is a test version of a release that has not shipped yet, published
for players who want it early:

- **Only before a version ships.** 0.5.0 Beta 1, Beta 2, … come before
  0.5.0. Once 0.5.0 is out there is no 0.5.0 Beta 3; the next beta is of
  0.5.1 or 0.6.0.
- **The count starts at 1 for each version** and goes up by one per
  published beta. It never carries from one version to the next.
- **Every beta ends in a final.** A version is not done until it is
  released without a label; a line of betas that never ends in a final is
  what made the old "Preview" names hard to follow.
- **The final is a build of its own.** It gets a new build number, even when
  its code is the last beta's, so testers on the beta get it as an update
  and land on the final.
- **Betas are optional.** A release that is ready ships as a final straight
  away. A beta is for changes that need wider testing first: a new engine
  piece, a data migration, a breaking change.

Avo uses no other labels: no alpha (internal test builds play that part),
no release candidates (a beta that holds up is followed by its final), and
no "Preview". SemVer orders the tags correctly:
`v0.5.0-beta.1` < `v0.5.0-beta.2` < `v0.5.0` < `v0.5.1`.

### Who gets a beta

Avo's updater reads the feed of GitHub's *latest* release, which is never
a pre-release (docs/releasing.md): a published beta reaches nobody by
itself. Testers download it from its release page. A copy on a beta then
updates itself to the next final, a higher build, like any other copy.
Until a "Get beta versions" switch in Settings › About lets players ask for
betas:

- publish a beta for the testers who will download it;
- tell them where it is (the release page, the issue they reported).

## The build number

One counter for every build of Avo, whatever its version:

- **A whole number** (`121`), never with dots or letters: the updater and
  Sparkle compare it as a number.
- **It only goes up.** Every build gets a number higher than every build
  before it, released or not. It is never reset for a new version.
- **A number is used once.** Once a DMG with a number exists, that number is
  spent, even if the build is thrown away. A rebuild of the same code gets
  the next number.
- **Gaps are normal.** Released builds skip the numbers test builds used:
  0.3.1 Preview 3 was build 107 and Preview 4 was build 113.

### Test builds

A test build is any DMG that is not published as a release: for the
maintainer, for a tester, or to try an update.

- **It takes a build number from the same counter.** A tester installs it
  over a release, so it has to be higher than that release for the app and
  its shims to treat it as newer. The next release then has to be higher
  than every test build, so that testers are updated off it. One counter
  does both.
- **Its `--version` is the version it is heading for:** `0.5.0` if new
  features are in, `0.4.1` if only fixes. Nothing has to be committed for
  that; `Base.xcconfig` changes in the release-prep commit.
- **It has no beta label and no tag.** It is called by its number: "build
  118", or `b118`. A test build is never published as a GitHub release, not
  even as a draft with its own tag.
- **Ad hoc or notarized, both count.** Only a notarized build can be
  installed by the updater, but either one spends its number.

### Taking a number

Several people (and several worktrees) build on the release Mac, so two
builds can reach for the same number. Until the build script takes numbers
itself (*Moving over*, step 4):

1. Find the highest number used anywhere: the published releases
   (`gh release list --repo nizwar/avo`), the `Avo-*-b*.dmg` files on the
   Desktop, and any range already promised to someone.
2. Take the next one.
3. Never let a build overwrite a DMG that already has that name: if the
   file exists, the number is taken.

A range kept for one line of work (say 90–99) is fine, as long as everyone
building knows it.

### Local builds

`CURRENT_PROJECT_VERSION` in `Base.xcconfig` stays **1**. A Debug build from
Xcode or `make build` is therefore older than every real build, and any
release installs over it. Real build numbers are only ever given to
`scripts/build-dmg.sh --build`; never commit one to the xcconfig.

## Names, place by place

| Where | Final | Beta | Test build |
|---|---|---|---|
| `scripts/build-dmg.sh` | `--version 0.4.0 --build 125` | `--version 0.5.0 --build 131` | `--version 0.5.0 --build 128` |
| `MARKETING_VERSION` (`Base.xcconfig`) | `0.4.0`, set in the release-prep commit | `0.5.0`, set in the release-prep commit | unchanged |
| The app's About | `0.4.0 (125)` | `0.5.0 (131)` | `0.5.0 (128)` |
| DMG | `Avo-0.4.0-b125.dmg` | `Avo-0.5.0-b131.dmg` | `Avo-0.5.0-b128.dmg` |
| Git tag | `v0.4.0` | `v0.5.0-beta.2` | none |
| GitHub release title | `Avo 0.4.0` | `Avo 0.5.0 Beta 2` | none |
| GitHub release kind | a regular release | a pre-release | none |
| Changelog heading | `## 0.4.0 (build 125)` | `## 0.5.0 Beta 2 (build 131)` | none |
| Release-prep commit | `Prepare 0.4.0 as build 125` | `Prepare 0.5.0 Beta 2 as build 131` | none |
| Website (`site.config.mjs`) | `version: '0.4.0'` | `version: '0.5.0 Beta 2'` | none |

The tag points at the release-prep commit. The DMG keeps its
`Avo-<version>-b<build>.dmg` shape, because every installed copy since
build 105 finds updates by that name. The beta label is left out of it: the
build number already makes each DMG unique.

## Referring to a release

In code comments, docs and migration notes, name a past release by its
build number ("before build 105"), and add the version if it helps a reader
("before build 105, 0.3.1 Preview 2"). A build number never changes
meaning; a version that was planned may ship under another name.

## Fixing a release while main moves on

A patch release normally comes from `main`. When `main` already holds
features that are not ready, the fix goes out from the release instead:

1. Branch `release/0.4` from the tag `v0.4.0`.
2. Put the fix on it (it lands on `main` too, by its own PR).
3. Build `0.4.1` with the next build number, which is higher than anything
   built from `main` so far, and tag `v0.4.1` on that branch.

## Today's releases under these rules

Avo's releases so far were all named "X.Y.Z Preview N". The names stay as
they were published; this is how they read under the rules above, as betas
toward a final (the reading closest to what was meant):

| Shipped as | Tag | Build | What it held | Under these rules |
|---|---|---|---|---|
| 0.1.0 Preview 1 | `v0.1.0-preview.1` | 35 | the first public build | 0.1.0 Beta 1 |
| 0.1.0 Preview 2 | `v0.1.0-preview.2` | 40 | new features and fixes | 0.1.0 Beta 2, then a final 0.1.0 was due |
| 0.2.0 Preview 1 | `v0.2.0-preview.1` | 54 | new features | 0.2.0 Beta 1 |
| 0.2.0 Preview 2 | `v0.2.0-preview.2` | 59 | new features | 0.2.0 Beta 2 |
| 0.2.0 Preview 3 | `v0.2.0-preview.3` | 72 | new features | 0.2.0 Beta 3, then a final 0.2.0 was due |
| 0.3.0 Preview 1 | `v0.3.0-preview.1` | 79 | new features | 0.3.0 Beta 1, or 0.3.0 |
| 0.3.1 Preview 2 | `v0.3.1-preview.2` | 105 | new features, and new bundle identifiers (breaking) | 0.4.0 Beta 1: features and a breaking change are never a patch, and the count starts again at 1 |
| 0.3.1 Preview 3 | `v0.3.1-preview.3` | 107 | one fix | 0.4.0 Beta 2 |
| 0.3.1 Preview 4 | `v0.3.1-preview.4` | 113 | new features | 0.4.0 Beta 3 |

What these rules change, against what happened:

- **"Preview N" never reached a final.** Every release was a pre-release of
  a version that was never released; nothing said "this one is done".
- **The Preview count crossed versions.** 0.3.0 Preview 1 was followed by
  0.3.1 Preview **2**, so "Preview 2" alone meant nothing, and code and docs
  still name a "0.3.0 Preview 2" that never shipped.
- **A patch number carried features.** 0.3.1 brought new features and new
  bundle identifiers; 0.3.0 → 0.3.1 told players it was a bug fix.
- **One version, three builds.** Previews 2, 3 and 4 all show `0.3.1` in
  the app and in the DMG name; only the build number told them apart, and
  the label was nowhere in the app.
- **Test builds had release-shaped names and shared numbers.** Several
  worktrees took numbers at once, one DMG overwrote another of the same
  number, and a test build once got a draft release and a tag of its own
  (`v0.3.0-preview.1-test-b101`).
- **The docs said to raise `CURRENT_PROJECT_VERSION`**, while it stays 1 and
  the number comes from `--build`.

## Moving over from "Preview" (proposal)

Nothing below has been done; each step waits for the maintainer's yes.
Published tags, releases and their version numbers stay as they are.

1. **0.3.1 Preview 4 (build 113) is the last "Preview".** It reads as
   0.4.0 Beta 3.
2. **The next release is Avo 0.4.0**, a final, with the next free build
   number: the 0.4.0 line's features shipped in the Previews, and 0.4.0 is
   higher than 0.3.1 for SemVer. After it, fixes make 0.4.1 and features
   0.5.0 (or 0.5.0 Beta 1 first).
3. **Finals become regular GitHub releases** (not pre-releases), so the
   newest final is GitHub's "Latest". The updater reads both kinds, so this
   changes nothing for installed copies.
4. **The build script takes numbers itself:** `--build next` picks the next
   free number under a lock, writes it to a ledger outside the repository
   that every worktree shares, and refuses to overwrite an existing DMG or
   reuse a number in the ledger.
5. **The app shows the beta label:** an Info.plist key (for example
   `AvoVersionLabel = Beta 2`, set by a `--label` option of the build
   script), shown in Settings › About and in Report a Problem as
   `0.5.0 Beta 2 (131)`.
6. **The updater gets a beta switch** ("Get beta versions", off by default)
   and offers pre-releases only with it on; required before 1.0.
7. **Old names are tidied:** code comments and docs that name "0.3.0
   Preview 2" say "build 105" instead, and the README stops calling builds
   "Preview builds" (it also still says they are not notarized and do not
   update themselves, which is no longer true).
