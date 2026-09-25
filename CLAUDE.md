# CLAUDE.md — instructions for the build agent

You are implementing StillMotions by working through GitHub issues one pull request at a
time. You have no access to the planning conversation. Everything you need is in this repo
and in the issues.

Read this file, then [docs/PRD.md](docs/PRD.md) and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), before your first task.

---

## What this is

A personal iOS app that turns Live Photos into stabilized, cleanly looping GIFs and videos.
One user, TestFlight only, no App Store. A successor to Google's deprecated MotionStills.

The processing pipeline is a Swift package with no UI dependency, so it builds and tests on
macOS — which is what lets you measure stabilization quality without a phone. The app and
share extension are thin layers on top.

**Stabilization quality is most of the risk in this project.** You cannot judge it from a
simulator, and you should not try to judge it from numbers alone. The harness writes contact
sheets so you can look at the output. Look at them.

---

## Prerequisites on the build machine

| Tool | Install | Needed for |
| --- | --- | --- |
| Xcode 27 | App Store | iOS builds, `swift test` (XCTest needs full Xcode) |
| XcodeGen | `brew bundle install` | generating `StillMotions.xcodeproj` |
| Rust (rustup) | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` | building gifski from source |

Confirm before starting work:

```bash
xcodebuild -version      # expect Xcode 27
swift --version
xcodegen --version
cargo --version
```

If any is missing, the phase-0 `human` setup issue has not been completed. **Stop and report
which one**, rather than working around it.

---

## Commands

```bash
# Verification — the single entry point. Run this before every PR.
./scripts/verify.sh

# Its parts, for iterating:
swift build
swift test
swift test --filter CameraPathTests
./scripts/check-no-private-assets.sh

# Harness, synthetic fixtures (ground truth, committed, what CI runs)
swift run stillmotions-harness --fixtures tests/fixtures/synthetic --out /tmp/h \
  --baseline harness/baseline.json

# Harness, personal fixtures (real quality signal, gitignored, local only)
swift run stillmotions-harness --fixtures tests/fixtures/personal --out /tmp/hp

# Update the baseline when a change legitimately improves results
swift run stillmotions-harness --fixtures tests/fixtures/synthetic \
  --out /tmp/h --baseline harness/baseline.json --update-baseline

# gifski xcframework (gitignored artifact; rebuild when missing)
./scripts/build-gifski.sh

# Xcode project — REQUIRED before any xcodebuild. .xcodeproj is not in git.
xcodegen generate
xcodebuild -scheme StillMotions -destination 'generic/platform=iOS' build
```

Runner and CI operations are in [docs/RUNBOOK.md](docs/RUNBOOK.md). You do not manage the
runner; the developer does. In particular, **never run `scripts/teardown-runner.sh`** — it
removes the runner and restores the Mac's sleep settings, which would stop your own
verification from running. It is the developer's cleanup tool for after the build.

---

## The task loop

1. **Pick the next task.** The lowest-numbered open issue, in the earliest open milestone,
   whose `Blocked by` issues are all closed, and which is **not** labeled `human`.
2. **If that issue is blocked by an open `human` issue, stop.** Report which issue needs the
   developer and what it requires. Do not attempt the human step yourself, and do not skip
   ahead to unrelated work to stay busy.
3. **Branch:** `issue-N-short-slug`.
4. **Implement.** Stay inside the issue's Scope. Read the referenced PRD sections and
   decision records first — they contain constraints that are not repeated in the issue.
5. **Verify.** Run the issue's Verify commands, plus `./scripts/verify.sh` for any change
   touching the package. For pipeline changes, also run the harness against personal
   fixtures if they exist, and **look at the contact sheets**.
6. **Open a PR** with `Closes #N`, the verification output pasted in, and for pipeline work
   the harness metrics diff against `main`.
7. **Merge:** `gh pr merge --auto --squash --delete-branch`.

### Merge policy

- `--auto` is required, not optional. It queues the merge so GitHub lands it only when the
  required `verify` check passes. **Never** merge with failing verification.
- **Never close an issue directly.** The merge closes it via `Closes #N`.
- If the required check is queued and the runner is offline, **stop and report**. Do not
  bypass the check.
- One issue per PR. Do not bundle.

### When an issue is wrong

If an issue's scope proves wrong — too large for one session, or resting on a false
assumption — **comment on the issue with the finding and propose a split.** Do not silently
expand scope, and do not implement something materially different from what the issue says.

Design changes go in `docs/decisions/` **via the PR**, never only in an issue comment. An
issue comment is not documentation; the next agent reads the repo, not the issue history.

---

## Things that will waste a session if you do not know them

**`tests/`, never `Tests/`.** macOS APFS is case-insensitive, so SwiftPM's conventional
`Tests/` directory and the brief-mandated `tests/fixtures/` are the *same directory*. The
test target uses an explicit `path: "tests/PipelineTests"`. Creating `Tests/` silently merges
them and produces baffling errors.

**`xcodegen generate` before any `xcodebuild`.** `.xcodeproj` is gitignored. A missing
generate step surfaces as "scheme not found", which reads like a project problem.

**gifski is commented out in `Package.swift` on purpose.** SwiftPM cannot load a manifest
whose `binaryTarget` path is missing, and `Vendor/Gifski.xcframework` is a gitignored
artifact. Run `./scripts/build-gifski.sh`, then uncomment both the `binaryTarget` and the
`Encoding` dependency. See [0004](docs/decisions/0004-gifski-integration.md).

**Vision has no sparse feature-tracking API.** Only whole-image registration (returns a warp,
no correspondences) or dense optical flow. Do not write code assuming keypoints exist. See
[0001](docs/decisions/0001-motion-estimation.md).

**The extension must not import `StillMotionsPipeline`.** It is a drop box: copy files to the
App Group container, write a manifest, exit. It does not process, encode, or launch the app —
`NSExtensionContext.open(_:)` is unsupported for share extensions. See
[0003](docs/decisions/0003-extension-strategy.md).

**There is no looping MP4.** No loop flag exists that Apple platforms honour. Loop is a
property of the content, and Loop mode is GIF-only. See
[0005](docs/decisions/0005-looping-export.md).

**Never commit personal fixtures or signing material.** The repo becomes public at the end of
the build, and making a repo public exposes the entire history.
`scripts/check-no-private-assets.sh` enforces this and runs first in `verify.sh`.

**`swift test` was never validated on the planning machine** (Command Line Tools only, where
XCTest does not resolve). `swift build` was. Confirm `swift test` runs early.

---

## Conventions

- **Plain SwiftUI, small files, clear module boundaries, no clever abstraction.** The
  developer reads and tweaks this code and is not an iOS specialist. A longer obvious
  implementation beats a shorter clever one.
- The app imports **only** `StillMotionsPipeline`. Internal modules stay internal.
- No `UIKit`, `SwiftUI`, or `PhotoKit` anywhere in `Sources/` (PRD R-24). PhotoKit adapts
  into the package's file-based input, in the app.
- Never hand-edit `.xcodeproj`. Change `project.yml`.
- Numeric thresholds live in [docs/PRD.md §1](docs/PRD.md). Changing one requires a decision
  record, because the harness baseline depends on them.
- Do not relax a threshold or a test to make a build pass. If a threshold is wrong, say so in
  a decision record with the measurements behind it.
- Commit messages: imperative, one line, `#N` referenced.

---

## Repo map

| Path | Contents |
| --- | --- |
| `PROJECT_BRIEF.md` | Original concept. Historical — the PRD supersedes it where they differ. |
| `docs/PRD.md` | Requirements `R-n` with acceptance criteria, thresholds, presets |
| `docs/ARCHITECTURE.md` | Targets, modules, data flow, protocols, editor state, traps |
| `docs/decisions/` | Contested choices, rejected alternatives, what would change them |
| `docs/ROADMAP.md` | Milestone and issue index |
| `docs/RUNBOOK.md` | Runner and verification operations (developer-facing) |
| `project.yml` | XcodeGen manifest — the project's source of truth |
| `Package.swift` | `StillMotionsPipeline` |
| `Sources/` | Pipeline modules. No UI, no PhotoKit. |
| `App/StillMotions/` | App: gallery, editor, export |
| `App/StillMotionsShare/` | Share extension: drop box only |
| `tests/PipelineTests/` | Unit tests |
| `tests/fixtures/synthetic/` | Committed clips with known motion — ground truth |
| `tests/fixtures/personal/` | Real Live Photos. **Gitignored. Never commit.** |
| `harness/baseline.json` | Regression baseline |
| `scripts/` | `verify.sh`, `build-gifski.sh`, `check-no-private-assets.sh`, `teardown-runner.sh` |

---

## Two unresolved decisions, by design

Do not resolve these by picking one and moving on. Each has a written deciding mechanism.

1. **Registration vs optical flow** for motion estimation. Settled by the phase-1 `spike`
   issue, which measures cost on the iPhone 14 Pro and accuracy against synthetic fixtures,
   then updates [0001](docs/decisions/0001-motion-estimation.md) with numbers. The decision
   rule is written there in advance.
2. **Whether the L1-optimal solver is needed.** Gated on measured crop retention across
   personal fixtures: median below 60%, or more than 25% of clips failing. If the gate does
   not trip, close the issue as not-needed with the numbers in the closing comment. See
   [0002](docs/decisions/0002-camera-path-solver.md).

The reference device for every performance and memory figure is the **iPhone 14 Pro**
(A16, 6 GB RAM). Targets met only on newer hardware are not met.
