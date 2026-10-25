# Contributing

Thanks for helping. Avo is an early preview; bug reports with a diagnostics
archive (Help › Report a Problem) are as valuable as code.

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
Questions belong in [Discussions](https://github.com/nizwar/avo/discussions),
and security problems in a private report ([SECURITY.md](SECURITY.md)).

## Issues

- Use the forms on [New issue](https://github.com/nizwar/avo/issues/new/choose):
  **Bug report** for Avo itself, **App compatibility** for an app or game
  that does not run, **Feature request** for ideas.
- Attach the diagnostics archive from **Help › Report a Problem**.
- New issues are labelled `needs triage` until the maintainer has looked at
  them; `good first issue` marks ones that suit a first contribution.

## Before you start

- Read [README.md](README.md) for the build requirements and
  [docs/architecture.md](docs/architecture.md) for how the pieces fit.
- For anything larger than a small fix, open an issue or a discussion first so
  the approach can be agreed on.

## Code

- **Host (Swift).** `make test` must pass. Keep platform-independent logic in
  `host/AvoKit` with tests; AppKit and SwiftUI code goes in the Xcode targets,
  except the UI Avo Hub shares (`AvoHazeUI` and `AvoKeymapUI` in AvoKit),
  which keeps its public API small and its host hooks in KeymapHost.swift.
  Swift 6 language mode with strict concurrency. New user-facing strings go
  through the String Catalogs (`make strings` after a build), in English and
  Indonesian.
- **Engine (Rust).** `cargo test` in `engine/hvf` must pass; set
  `AVO_VMM_MUTE=1` to keep sound tests off the Mac's speakers. Document
  device behaviour in [docs/engine.md](docs/engine.md).
- **Android helpers.** The helpers in `guest/` are built by their `build.sh`
  (or `make helpers`) and embedded in the daemon as generated Swift files.
  Commit the regenerated file together with the source change.
- **Protocol.** Change `proto/avo/v1/*.proto`, run `scripts/gen-proto.sh`, bump
  `PROTOCOL_VERSION_CURRENT` only for incompatible changes, and update
  [docs/protocol.md](docs/protocol.md). Input record layout changes need
  `AVO_UPDATE_GOLDEN=1 swift test` and the Java check in
  `guest/bridge-agent/build.sh`.
- **Website.** `npm test` in `website/` must pass; wording lives in
  `website/src/i18n/en.json` and `id.json`, which must keep the same keys.

## Profiles

- **Device profiles.** Add `profiles/devices/<id>.json` with values from a
  stock `build.prop`; `DeviceProfileTests` validates every file.
- **Keymap profiles.** Add `profiles/keymaps/<package>.json`. Profiles with
  shooter mode may not contain repeated taps, macros, or swipes through the
  aim area; `KeymapProfileTests` checks them. Avo does not accept profiles
  that give an unfair advantage.

## Branding

Edit `branding/tools/generate.py`, not the generated files.

## Pull requests

1. Fork the repository and branch from `main` (`fix/…`, `feature/…`, `docs/…`).
2. Keep each commit to one topic, with an imperative subject line of 72
   characters or fewer and a body that explains why.
3. Run the tests for what you changed: `make test` (host), `cargo test` in
   `engine/hvf` (engine), `npm test` in `website/` (website). Avo has no CI
   for the apps: builds and releases are made on the release Mac, so these
   local runs are the check.
4. Open the pull request with the template filled in: what changed, why, and
   how you tested it (which app or game, which Mac).
5. `main` is protected: changes arrive through pull requests, reviewed by the
   maintainer (CODEOWNERS), and are squash-merged; conversations must be
   resolved first.

By contributing you agree that your contribution is licensed under the
project's license (Apache 2.0; BSD-3-Clause for `engine/hvf`).
