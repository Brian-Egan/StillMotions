# StillMotions

A personal iOS app that turns Live Photos into stabilized, cleanly looping GIFs and videos.
It's a successor to Google's MotionStills, which did this better than anything currently on
the App Store and has since been deprecated.

This app is for one user and is installed directly to his own iPhone from Xcode.

## What it does

Pick a Live Photo from the in-app gallery or share one from Photos. The app locks the
background in place as if the phone had been on a tripod, crops to the largest clean frame,
and finds a loop point that doesn't visibly jump. You preview the result, adjust trim or crop
if needed, and export.

- Modes: loop, bounce (forward then reverse), and play once.
- Exports: GIF and MP4/HEVC, at a size preset you choose per export.
- Destinations: the share sheet and your photo library.
- Everything runs on-device. No accounts, servers, or analytics.

**Looping is GIF-only.** No loop flag exists in MP4 that Apple platforms honour, so a
"looping video" export would be a menu item that does nothing. Loop is instead a property of
the content: the clip is trimmed to its best loop point and crossfaded, so it's seamless
wherever a player does repeat it. GIF is the format that actually loops in iMessage. Details
in [docs/decisions/0005-looping-export.md](docs/decisions/0005-looping-export.md).

| Mode | GIF | MP4/HEVC |
| --- | --- | --- |
| Loop | yes | no |
| Bounce | yes | yes |
| Once | yes | yes |

Target: iOS 27, iPhone 14 Pro or newer. The 14 Pro is the reference device — every
performance figure in the PRD is a requirement on that hardware, not on the latest phone.

## How this repo is built

The code is written by Claude Code agents working in three stages:

1. **Concept:** [PROJECT_BRIEF.md](PROJECT_BRIEF.md), written in a chat session with the
   developer.
2. **Planning:** a Claude Code session reads the brief and produces the PRD, architecture,
   decision records, scaffolding, and GitHub issues. It writes no feature code.
3. **Build:** a fresh Claude Code session works through the issues one PR at a time,
   following [CLAUDE.md](CLAUDE.md).

Issues labeled `human` are steps only the developer can do (signing, exporting test photos,
on-device checks). The build agent stops when one of these blocks its next task.

Research during planning overturned three assumptions in the brief — Vision has no sparse
feature-tracking API, share extensions cannot launch their containing app, and no MP4 loop
flag is honoured. Where the brief and [docs/PRD.md](docs/PRD.md) disagree, the PRD wins.

## Repo guide

| Path | Contents |
| --- | --- |
| `PROJECT_BRIEF.md` | Original concept. Historical; the PRD supersedes it. |
| `CLAUDE.md` | Instructions for the build agent: commands, conventions, task loop. |
| `docs/PRD.md` | Requirements with acceptance criteria and quality thresholds. |
| `docs/ARCHITECTURE.md` | Modules, data flow, protocols, editor state, diagrams. |
| `docs/decisions/` | Contested design choices and rejected alternatives. |
| `docs/ROADMAP.md` | Milestones and issue order. |
| `docs/RUNBOOK.md` | Setup, running a build session, verification, going public. |
| `project.yml` | XcodeGen manifest. `.xcodeproj` is generated, never hand-edited. |
| `tests/fixtures/synthetic/` | Generated clips with known motion. Committed. |
| `tests/fixtures/personal/` | Real Live Photos for quality testing. Gitignored. |

## Architecture in brief

The processing pipeline (tracking, stabilization, loop selection, rendering, encoding) is a
Swift package with no UI dependencies. It builds and tests on macOS, which lets agents measure
stabilization quality without a phone. The iOS app and share extension are thin layers on top.

The share extension is a **drop box**: it copies the asset into an App Group container and
exits. It does no processing, because an extension runs under an undocumented ~120 MB memory
ceiling, and it cannot launch the containing app — `NSExtensionContext.open(_:)` is supported
only for Today and iMessage extensions. Sharing therefore costs one extra step: share, then
open StillMotions.

GIFs are encoded with gifski for per-frame palettes and temporal dithering.

## Setup

```bash
brew bundle install                                              # XcodeGen, pinned
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # Rust, for gifski
./scripts/build-gifski.sh                                        # Vendor/Gifski.xcframework
```

Xcode 27 is required — `swift test` uses XCTest, which needs a full Xcode install.

## Build and test

```bash
./scripts/verify.sh          # build, test, harness regression, private-asset check

swift build
swift test
swift run stillmotions-harness --fixtures tests/fixtures/synthetic --out /tmp/h \
  --baseline harness/baseline.json

xcodegen generate            # REQUIRED before any xcodebuild; .xcodeproj is not in git
xcodebuild -scheme StillMotions -destination 'generic/platform=iOS' build
```

`scripts/verify.sh` is the single entry point for verification. There is no CI: no GitHub Actions
workflow, no runner, no status checks. The build agent is instructed to run it against a clean
`git worktree` checkout of each pushed branch before opening a pull request, which catches the
common case of a file that exists locally but was never committed. Nothing enforces that, so the
pull request bodies are the audit trail. Verification deliberately never runs `xcodebuild`;
whether the app compiles is established by the on-device checks at the end of each app
milestone. See [docs/RUNBOOK.md](docs/RUNBOOK.md).

Note: `tests/` is lowercase throughout, including the SwiftPM test target. macOS APFS is
case-insensitive, so a conventional `Tests/` directory would collide with `tests/fixtures/`.

## Test photos

Stabilization quality is measured against real Live Photos kept out of git. To add them, open
Photos on a Mac and select Live Photos. Use File > Export > Export Unmodified Original, which
produces a HEIC and MOV pair for each photo. Put the pairs in `tests/fixtures/personal/`.

Aim for 30 to 50 clips covering handheld shake, walking, kids and pets, low light, scenes with
near and far objects, and a few you'd expect to fail.

These must never be committed. The repo becomes public at the end of the build, and making a
repo public exposes the entire history. `scripts/check-no-private-assets.sh` enforces this.

## Quality harness

The harness processes every fixture and writes, per clip, the exported GIF and MP4, a
before/after contact sheet, and metrics for crop retention, leftover motion, and loop seam. A
committed baseline blocks any change that makes the fixture set worse overall. Thresholds are
in [docs/PRD.md §1](docs/PRD.md).

The regression check covers synthetic fixtures only, since personal fixtures aren't in git, so it
guards correctness rather than quality. Real-world quality regressions are caught locally,
against personal fixtures, by reading the contact sheets.

## Credits

Inspired by Google Research's MotionStills and the stabilization work in Grundmann, Kwatra,
and Essa, "Auto-Directed Video Stabilization with Robust L1 Optimal Camera Paths" (CVPR 2011).
This project is unaffiliated with Google.

GIF encoding uses [gifski](https://github.com/ImageOptim/gifski), AGPL-3.0-or-later.
