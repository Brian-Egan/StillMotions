# Live Photo Stills (working title)

A personal iOS app that turns Live Photos into stabilized, cleanly looping GIFs and videos. It's a successor to Google's MotionStills, which did this better than anything currently on the App Store and has since been deprecated.

This app is for one user and is distributed through TestFlight only.

## What it does

Pick a Live Photo from the in-app gallery or share one from Photos. The app locks the background in place as if the phone had been on a tripod, crops to the largest clean frame, and finds a loop point that doesn't visibly jump. You preview the result, adjust trim or crop if needed, and export.

- Modes: loop, bounce (forward then reverse), and play once.
- Exports: GIF, looping MP4/HEVC, and non-looping MP4/HEVC, at a size preset you choose per export.
- Destinations: the share sheet and your photo library.
- Everything runs on-device. No accounts, servers, or analytics.

## How this repo is built

The code is written by Claude Code agents working in three stages:

1. Concept: `PROJECT_BRIEF.md`, written in a chat session with the developer.
2. Planning: a Claude Code session reads the brief and produces the PRD, architecture, decision records, scaffolding, and GitHub issues. It writes no feature code.
3. Build: a fresh Claude Code session works through the issues one PR at a time, following `CLAUDE.md`.

Issues labeled `human` are steps only the developer can do (signing, exporting test photos, on-device checks). The build agent stops when one of these blocks its next task.

## Repo guide

| Path | Contents |
| --- | --- |
| `PROJECT_BRIEF.md` | Original concept and requirements. Input to planning. |
| `CLAUDE.md` | Instructions for the build agent: commands, conventions, task loop. |
| `docs/PRD.md` | Requirements with acceptance criteria and quality thresholds. |
| `docs/ARCHITECTURE.md` | Modules, data flow, and diagrams. |
| `docs/decisions/` | Records of contested design choices and rejected alternatives. |
| `docs/ROADMAP.md` | Milestones and issue order. |
| `tests/fixtures/synthetic/` | Generated clips with known motion, committed. |
| `tests/fixtures/personal/` | Real Live Photos for quality testing. Gitignored. |

Some of these are created by the planning session and won't exist until it runs.

## Architecture in brief

The processing pipeline (tracking, stabilization, loop selection, rendering, encoding) is a Swift package with no UI dependencies. It builds and tests on macOS, which lets agents measure stabilization quality without a phone. The iOS app and share extension are thin layers on top of it. The Xcode project is generated from a text definition and shouldn't be edited by hand.

GIFs are encoded with gifski for per-frame palettes and temporal dithering.

## Build and test

<!-- Planning session: replace this section with the actual commands once scaffolding exists. -->

To be filled in by the planning session. Expect commands for:

- Generating the Xcode project
- Building and testing the pipeline package on macOS
- Running the quality harness against `tests/fixtures/`
- Building to a device

## Test photos

Stabilization quality is measured against real Live Photos kept out of git. To add them, open Photos on a Mac and select Live Photos. Use File > Export > Export Unmodified Original, which produces a HEIC and MOV pair for each photo. Put the pairs in `tests/fixtures/personal/`.

Aim for 30 to 50 clips covering handheld shake, walking, kids and pets, low light, scenes with near and far objects, and a few you'd expect to fail.

## Quality harness

The harness processes every fixture and writes, per clip, the exported GIF and MP4, a before/after contact sheet, and metrics for crop retention, leftover motion, and loop seam. A committed baseline blocks any change that makes the fixture set worse overall. See `docs/PRD.md` for thresholds.

## Credits

Inspired by Google Research's MotionStills and the stabilization work in Grundmann, Kwatra, and Essa, "Auto-Directed Video Stabilization with Robust L1 Optimal Camera Paths" (CVPR 2011). This project is unaffiliated with Google.
