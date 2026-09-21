# Project brief: Live Photo stabilizer and exporter (MotionStills successor)

This file is the input for the planning session. Read it fully before doing anything else.

## 1. Workflow and your role

This project runs as a three-stage LLM workflow:

1. Concept: this document, written with the developer in a chat session.
2. Planning (you, a Claude Code session): turn this brief into a PRD, architecture, decision records, repo scaffolding, and a complete set of GitHub issues. You write no feature code.
3. Build (a separate Claude Code session with fresh context): implements the app by working through the GitHub issues. It has no access to this chat or to your session. It only sees the repo, the docs you write, and the issues.

Everything the build agent needs must be in the repo or in the issues. If a decision matters, write it down.

The developer can read and tweak Swift but will not write most of it. He reviews results mainly by running the app on his iPhone and by reading PR summaries.

## 2. Product context

Google's MotionStills (iOS, 2016, since deprecated) converted Live Photos into stabilized, cleanly looping GIFs and videos. No current app matches its ease of use or output quality. Its quality came from three things:

- Stabilization that solves for a perfectly still virtual camera across all frames, then crops to the largest rectangle valid in every frame. Background: Grundmann, Kwatra, Essa, "Auto-Directed Video Stabilization with Robust L1 Optimal Camera Paths" (CVPR 2011), the same line of work behind YouTube's stabilizer.
- Good loop point selection so loops don't visibly jump.
- Encoding that avoids GIF banding and bloat.

The goal is to match that output quality with a similarly simple interface, for one user.

## 3. User, distribution, environment

- Single user, personal use. Distributed via TestFlight on a paid Apple developer account. No App Store review, monetization, accounts, backend, analytics, or telemetry.
- Target the latest iOS release only, on a recent iPhone. No backward compatibility work.
- Licensing is not a constraint. AGPL dependencies (such as gifski) are acceptable.
- Development environment: Mac with Xcode and Claude Code, the gh CLI, and a physical iPhone for on-device testing.
- Repo: private GitHub repo created by the developer. This file lives in it.

## 4. Functional requirements

### 4.1 Entry points

1. In-app gallery: grid of Live Photos from the photo library, newest first. Tapping one opens the editor.
2. Share extension from Photos: select a Live Photo in Photos, share to the app, land in the same editor flow.

The share extension runs under a tight memory ceiling (plan for about 120 MB). A full-resolution 3 second Live Photo is roughly 90 frames at over 10 MB each uncompressed, so frames must be streamed, never held all at once. Decide between processing at reduced resolution inside the extension and handing the asset to the main app (for example via an App Group container and a URL scheme), and record the decision.

### 4.2 Processing pipeline (on-device only)

1. Import: obtain the paired video and key photo. In the app this comes through PhotoKit (`PHAssetResource`). In the pipeline package it comes from files (HEIC + MOV pair). The key photo's timestamp is the default reference frame.
2. Motion tracking: frame-to-frame registration using Apple's Vision framework (homographic registration and/or optical flow) with outlier rejection. Consider masking people and animals with Vision segmentation so moving subjects don't influence the camera motion estimate.
3. Still-camera solve and crop: at minimum, warp all frames to the reference frame and compute the largest axis-aligned crop valid in every warped frame. Evaluate whether an L1-optimal path and crop solve is worth the added complexity over this baseline. Design the solver behind an interface so either can be used.
4. Loop point selection: find the most similar frame pair near the clip ends and apply a short crossfade.
5. Render: Metal or Core Image warps, streaming frames.
6. Encode: see 4.5.

### 4.3 Playback modes

- Loop (default): stabilized, trimmed to the best loop points, crossfaded.
- Bounce: stabilized, plays forward then reversed. No loop point search needed.
- Once: stabilized, plays one time. Used for non-looping video export.

### 4.4 Editor and preview

- Every clip is previewed before export. Nothing exports automatically.
- The preview shows the stabilized result in the selected mode and updates when settings change.
- Manual overrides: trim start and end, and adjust the crop rectangle. The solver's automatic trim and crop are the initial editable state, not a final render. Changing a trim may require re-running the solve on the new frame range.
- Stabilization failure: detect it, show a visible but non-blocking warning, and let the user adjust trim or crop. Failure signals are defined in section 6.

### 4.5 Export

- Formats: GIF, looping MP4/HEVC, non-looping MP4/HEVC.
- GIF quality is the highest priority for encoding. Use gifski (per-frame palettes, temporal dithering), not ImageIO's GIF encoder. gifski is Rust with a C API; decide between building an xcframework from source and using an existing Swift wrapper, and record the decision.
- Looping video must actually loop where the destination supports it (for example iMessage). Research how to mark or structure the file for this and record findings.
- Output size is chosen per export from presets. Suggested starting presets (tunable): Small, 480 px long edge; Medium, 720 px; Full, native resolution. Suggested GIF default frame rate: 15 fps (tunable). Video keeps the source frame rate.
- Show an estimated file size for the selected format and preset before export.
- Destinations: the iOS share sheet, and save to Photos.

### 4.6 Non-goals

Clip stitching or movie mode, text or stickers, filters, cloud sync, in-app export history, iPad-specific layouts, Android, localization.

## 5. Non-functional requirements

- All processing on-device.
- Share extension stays within its memory limit on the longest fixture clip.
- Preview of a typical clip should appear within a few seconds on the target iPhone. Record a concrete target in the PRD and measure it in the on-device verification issues.
- Code favors plain SwiftUI, clear module boundaries, and small files over clever abstraction, since the developer will read and tweak it.

## 6. Quality measurement

Stabilization quality is most of the project's risk and effort. The build agent cannot judge it from a simulator, so it must be measurable headlessly.

### 6.1 Metrics

The harness computes, per clip:

- Crop retention: final crop area as a percentage of the original frame area.
- Residual motion: mean displacement of tracked background features between consecutive output frames, in pixels at output resolution.
- Loop seam: pixel difference between the last and first output frames, relative to the median difference between consecutive frames.
- Output file size per format and preset.
- Processing time per stage.

Suggested starting thresholds (all tunable, record final values in the PRD):

- Crop retention at or above 60%. Below this, flag as a stabilization failure.
- Residual motion under 1.0 px. Above this, flag as a stabilization failure.
- Loop seam at or below 1.5x the median consecutive-frame difference.

The same failure signals drive the warning in the editor (4.4).

### 6.2 Fixtures

- Synthetic fixtures, committed to the repo: small generated clips with known motion (a still image translated, rotated, and scaled along a known path, optionally with a moving foreground object). These give ground truth for unit tests of the tracker and solver.
- Personal fixtures, not committed: 30 to 50 of the developer's own Live Photos exported as HEIC + MOV pairs into `tests/fixtures/personal/`, which is gitignored. The set should cover handheld shake, walking, pets and kids, low light, parallax (near and far objects), and a few clips that should fail.

### 6.3 Harness

A macOS CLI in the pipeline package that processes a fixture folder and writes, per clip: output GIF and MP4, a contact sheet image (sampled frames before and after stabilization), and a metrics JSON. It also writes an aggregate summary.

A regression check compares the aggregate against a committed baseline (for example `harness/baseline.json`). It fails if the change makes the fixture set worse beyond a tolerance you define (for example median crop retention drops more than 2 points, or median residual motion rises more than 10%). A PR that improves results updates the baseline.

The build agent should view contact sheets itself when tuning, not rely only on numbers.

## 7. Architecture constraints

- The processing pipeline (file import, tracking, solve, loop selection, render, encode) is a Swift package with no UIKit or SwiftUI dependency. It must build and test on macOS via `swift build`, `swift test`, and the harness CLI.
- PhotoKit access, the share extension, and all UI are thin layers in the app that call into the package.
- The Xcode project is generated from a text definition (XcodeGen or Tuist; choose one and record why). Never hand-edit `.xcodeproj`.
- The app and extension share code through the pipeline package and, if needed, an App Group container.

## 8. Your deliverables

### 8.1 Files

1. `docs/PRD.md`: requirements from this brief, each with testable acceptance criteria. Includes final metric thresholds and presets.
2. `docs/ARCHITECTURE.md`: targets and modules, pipeline data flow, memory strategy for the extension, editor state model (automatic results as editable state), encoding stack, and a diagram (Mermaid is fine).
3. `docs/decisions/`: one short decision record per contested choice, with rejected alternatives. At minimum: stabilization algorithm, extension processing strategy, gifski integration, project generator, looping video format.
4. `docs/ROADMAP.md`: a short ordered index of milestones and issue numbers so the dependency graph is readable in one place. It must not restate issue content.
5. `CLAUDE.md`: build, test, and harness commands; repo map; conventions; and the build agent loop from section 9.
6. Repo scaffolding only: project generator definition, empty app and extension targets, pipeline package manifest with empty modules, `.gitignore` (including `tests/fixtures/personal/`). No feature code.

### 8.2 GitHub issues

Create the full build plan as issues using the gh CLI.

Suggested phases (refine as needed):

1. Pipeline package, synthetic fixtures, and harness with a baseline stabilizer, loop selection, and both encoders.
2. Stabilization quality on personal fixtures: tuning, failure detection, regression baseline.
3. App shell: gallery, PhotoKit adapter, editor with live preview and mode switching.
4. Manual trim and crop overrides, failure warning UI.
5. Export: presets, size estimates, share sheet, save to Photos.
6. Share extension.

Conventions:

- One milestone per phase.
- Each issue is sized for one agent session and one PR, and ends with a check the build agent can run itself.
- Labels: `phase-N`; one of `pipeline`, `harness`, `encoding`, `app`, `extension`; and `human` for developer-only steps.
- Issue body template:

```
Context: why this task exists (2 to 4 sentences)
References: links to specific sections of docs/PRD.md,
  docs/ARCHITECTURE.md, and decision records
Scope: what to build; what is explicitly out of scope
Acceptance criteria: checklist, each item verifiable
Verify: exact command(s) and expected result
Blocked by: #N, #M (or "none")
```

- `human` issues are assigned to the developer and contain step-by-step instructions written for someone who can read Swift but is not an iOS specialist.
- Every app-facing milestone (phases 3 to 6) ends with a `human` on-device verification issue that blocks the next milestone. Its checklist names what to try on the phone and what counts as a pass.

## 9. Build agent loop and merge policy

Document this in `CLAUDE.md`:

- Next task: the lowest-numbered open issue in the earliest open milestone whose blockers are all closed and which is not labeled `human`.
- If the next task is blocked by an open `human` issue, stop and report which issue needs the developer.
- Work on a branch named `issue-N-short-slug`.
- Run the issue's Verify commands, plus `swift test` and the harness regression check for any change touching the pipeline package.
- Open a PR with `Closes #N`, the verification output, and for pipeline work the harness metrics diff against main.
- Auto-merge is allowed: once verification passes, merge with `gh pr merge --squash --delete-branch`. Never merge with failing verification. Never close an issue directly; the merge closes it.
- If an issue's scope proves wrong, comment on the issue with the finding and propose a split rather than silently expanding scope.
- Design changes go in `docs/decisions/` via the PR, never only in issue comments.

## 10. Known human steps

Create `human` issues for at least these, placed where they block the right work:

- Install the Rust toolchain if the gifski decision requires building from source.
- Export personal fixtures: in Photos on the Mac, select Live Photos and use File, Export, Export Unmodified Original, which produces HEIC + MOV pairs. Place them in `tests/fixtures/personal/`. Include the coverage list from 6.2.
- Configure signing, bundle identifiers, and the App Group for the app and extension in the Apple developer portal and Xcode.
- First TestFlight upload, or direct device install, whichever the planning session recommends for fastest iteration.
- On-device verification at the end of each app-facing milestone.

## 11. Open questions for you to resolve

Record each answer in a decision record:

1. Baseline warp-to-reference versus L1-optimal path and crop solve. How will the harness show whether the extra complexity pays off?
2. Extension strategy: process in the extension at reduced resolution, or hand off to the main app.
3. gifski integration method.
4. XcodeGen versus Tuist.
5. How looping MP4/HEVC is produced so it loops in iMessage and similar destinations.
6. Editor preview strategy: render on the fly versus render once per settings change and cache.

## 12. Before you start

The developer has created this repo and authenticated gh. Confirm `gh auth status` succeeds and the repo remote is set before creating issues. Then read this file, write the docs, scaffold, create issues, and finish with a short summary listing the milestones, the first three unblocked issues, and every open `human` issue.
