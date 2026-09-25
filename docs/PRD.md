# StillMotions — Product Requirements

Derived from [PROJECT_BRIEF.md](../PROJECT_BRIEF.md). Where this document and the brief
disagree, **this document wins** — the brief is the original concept, and three of its
assumptions were overturned by research (see
[decisions 0001](decisions/0001-motion-estimation.md),
[0003](decisions/0003-extension-strategy.md),
[0005](decisions/0005-looping-export.md)).

Every requirement has an ID (`R-n`) and acceptance criteria that can be checked by a
command or a named on-device action. GitHub issues reference these IDs.

---

## 0. Scope and environment

| Property | Value |
| --- | --- |
| Users | One — the developer. No accounts, servers, analytics, or telemetry. |
| Distribution | Direct device install from Xcode. No App Store. TestFlight needs a paid membership and is out of scope while development runs on a free Apple personal team. |
| Apple account | Free personal team. Profiles expire every 7 days, so the app must be rebuilt weekly to keep launching. |
| Minimum iOS | **27.0** |
| **Reference device** | **iPhone 14 Pro (A16, 6 GB RAM)** |
| Processing | Entirely on-device |
| Orientation | Portrait only. No iPad layout. |

**The reference device is normative.** Every performance and memory figure in this
document is a requirement *on an iPhone 14 Pro*, not on current-generation hardware. The
14 Pro has 6 GB RAM against 8 GB on newer models, and an A16 rather than an A18/A19, so
targets met only on a newer phone are not met.

Non-goals, restated so they are not re-litigated: clip stitching or movie mode, text or
stickers, filters, cloud sync, in-app export history, iPad layouts, Android, localization.

---

## 1. Numeric values

All values are tunable. Each is recorded with its basis so a change is an argument against
the basis rather than a matter of taste. Changing any value in the lower table requires a
decision record, because the harness baseline depends on them.

### 1.1 User-facing defaults (editable in Settings)

| Value | Default | Basis |
| --- | --- | --- |
| Size presets (long edge) | Small **480 px**, Medium **720 px**, Full **native** | Brief's suggestion. Medium deliberately equals the preview cache resolution (§5.2), so exporting Medium needs no re-render from source. |
| GIF frame rate | **20 fps** | GIF stores per-frame delay in **centiseconds**, so only integral-centisecond rates are exact. 20 fps is exactly 5 cs. 15 fps is 6.67 cs and cannot be represented; 30 fps is 3.33 cs and rounds to 3 cs, playing ~11% fast. 20 fps carries 33% more frames than 15 for a clear smoothness gain at roughly two thirds the size of 30 fps. |
| GIF frame rate options | 16.67 (6 cs), **20 (5 cs)**, 25 (4 cs) | The integral-centisecond rates in a useful range. Non-integral rates are not offered, because their playback speed would be wrong. |
| Video frame rate | Source rate, unchanged | Brief. No resampling artifacts. |
| Default mode | Loop | Brief. |
| Default format | GIF | GIF is the only format that loops in iMessage (0005), which is the primary destination. |

### 1.2 Quality thresholds (gate the harness baseline and the editor warning)

| Metric | Threshold | Basis |
| --- | --- | --- |
| Crop retention | **≥ 60%** of original frame area | Brief's suggestion. Below ~60% the output reads as a zoom rather than a crop, and the subject framing the user composed is lost. |
| Residual motion | **< 1.0 px** mean displacement at output resolution | Brief's suggestion. Sub-pixel residual is invisible; around 1 px begins to read as shimmer on static edges. |
| Loop seam | **≤ 1.5x** median consecutive-frame difference | Brief's suggestion. A seam at the median is indistinguishable from any other frame transition; 1.5x is detectable on close inspection but not an obvious jump. |

A clip failing **any** of the three is a stabilization failure (R-12, R-22).

### 1.3 Performance and resource budgets

| Budget | Value | Basis |
| --- | --- | --- |
| Preview latency | **≤ 2.0 s** from selection to first playable frame, 3 s clip, 720 px, iPhone 14 Pro | Brief says "a few seconds". 2.0 s sits under the point where a wait reads as a stall, and is measurable. |
| Extension peak memory | **≤ 100 MB** | The extension jetsam limit is an undocumented ~120 MB observed in crash reports, unconfirmed on iOS 27, and it is a high-water mark rather than an average. A 20 MB margin absorbs per-device and per-OS variance. |
| Export time | ≤ 10 s for a 3 s clip at Full preset, GIF, iPhone 14 Pro | Export is explicitly user-initiated with progress shown, so it tolerates more latency than preview. |

### 1.4 Regression tolerance (`harness/baseline.json`)

A change fails the regression check if, against the committed baseline:

- median crop retention drops by **more than 2 percentage points**, or
- median residual motion rises by **more than 10%**, or
- **any** clip that previously passed all three thresholds now fails one.

The third clause is the important one: medians can hide a single clip going badly wrong,
and per-clip regressions are what users actually notice. A PR that improves results
updates the baseline in the same PR.

---

## 2. Entry points

**R-1 — In-app gallery.** A grid of Live Photos from the library, newest first.

- Only assets with `PHAsset.mediaSubtypes.contains(.photoLive)` appear.
- Thumbnails load lazily; scrolling 500+ assets stays smooth on the reference device.
- Tapping an item opens the editor (R-8).
- First launch requests photo-library authorization; denial shows an explanation with a
  link to Settings, not a dead grid.
- *Verify:* on device, gallery shows only Live Photos, newest first; tap opens editor.

**R-2 — Share extension drop box.** Sharing a Live Photo from Photos stages it for the app.
See [0003](decisions/0003-extension-strategy.md).

- The extension copies the paired photo and video into the App Group container by file
  copy, never via an in-memory `Data`.
- It writes a JSON manifest with a UUID, timestamp, and the staged filenames.
- It shows a confirmation that **states the user must open StillMotions**, then completes.
- It does **not** process, encode, or attempt to launch the app.
- Peak memory ≤ 100 MB on the longest fixture clip (§1.3).
- *Verify:* on device, share a Live Photo; confirmation appears; Xcode memory gauge peak
  is under 100 MB; the App Group container holds the files and manifest.

**R-3 — Pending item drain.** The app ingests staged items on `didBecomeActive`.

- Ingestion is idempotent on the manifest UUID; a crash mid-ingest cannot duplicate or
  lose an item.
- Staged files are deleted after successful ingest.
- Manifests older than 7 days are discarded on launch so the container cannot grow
  without bound.
- A single pending item opens the editor directly; multiple items land in the gallery
  with the pending items first.
- *Verify:* share two photos without opening the app, then launch; both appear once;
  container is empty afterwards.

---

## 3. Pipeline

**R-4 — Import.** Obtain the paired video and still.

- App path: `PHAssetResourceManager.writeData(for:toFile:options:)` with
  `isNetworkAccessAllowed = true`, using `.photo` + `.pairedVideo` (originals) or
  `.fullSizePhoto` + `.fullSizePairedVideo` (edited). Tiers are never mixed — a still and
  video from different tiers do not correspond.
- Package path: a HEIC + MOV pair from the filesystem, with no PhotoKit dependency.
- The still's timestamp within the video is the **default reference frame**.
- Frames are streamed; the full frame set is never resident.
- *Verify:* `swift test` — importer yields the expected frame count and reference index
  for every synthetic fixture.

**R-5 — Motion estimation.** Per-frame transform onto the reference.
See [0001](decisions/0001-motion-estimation.md).

- Behind `MotionEstimator`, with a Vision-registration and an optical-flow implementation.
- The shipping default is set by the phase-1 spike, not assumed.
- *Verify:* `swift test` — recovered transforms match each synthetic fixture's known path
  within the tolerance recorded by the spike.

**R-6 — Subject masking.** Moving subjects must not drive the camera estimate.

- `GeneratePersonSegmentationRequest` for people; `GenerateForegroundInstanceMaskRequest`
  for animals and other movers, since Vision has no animal-segmentation request.
- With correspondences: samples inside the mask are discarded.
- Masking is skipped when the mask covers more than 60% of the frame — there is then
  insufficient background to register against, and masking would make the estimate worse
  rather than better.
- *Verify:* `swift test` — on the synthetic fixture with a moving foreground object,
  transform error with masking enabled is lower than with it disabled.

**R-7 — Camera path and crop.** See [0002](decisions/0002-camera-path-solver.md).

- Behind `CameraPathSolver`. `WarpToReferenceSolver` ships; `L1OptimalSolver` is built
  only if the §1.2 crop-retention gate trips on personal fixtures.
- The crop is the largest axis-aligned rectangle valid in every warped frame, preserving
  the source aspect ratio.
- `CameraPath` reports `cropRetention`.
- *Verify:* `swift test` — for a synthetic fixture with known translation, the computed
  crop matches the analytically-derived rectangle within 1 px.

**R-8 — Loop point selection.** Find the least-visible loop and hide it.

- Search frame pairs near the clip ends for the minimum difference; apply a short
  crossfade over the seam.
- Reports the achieved loop-seam metric (§1.2).
- Skipped in Bounce and Once modes, where no seam exists.
- *Verify:* `swift test` — on a synthetic fixture built from a genuinely periodic motion
  path, the selected loop length is within one frame of the known period.

---

## 4. Playback modes and export

**R-9 — Modes.** Loop (trimmed to loop points, crossfaded), Bounce (forward then
reversed), Once (single pass).

**R-10 — Formats and the mode matrix.** See [0005](decisions/0005-looping-export.md).

| Mode | GIF | MP4/HEVC |
| --- | --- | --- |
| Loop | yes (`repeat = 0`) | **no** |
| Bounce | yes | yes |
| Once | yes | yes |

- There is **no looping MP4 export.** No MP4 loop flag exists that Apple platforms
  honour. Loop is a property of the content, not the container.
- Bounce is offered for MP4 because a palindrome plays through once and needs no player
  cooperation.
- Selecting Loop disables MP4 with a visible one-line reason, not a silent grey-out.
- *Verify:* on device, Loop offers GIF only with a stated reason; Bounce and Once offer
  both.

**R-11 — Encoding.**

- GIF via gifski ([0004](decisions/0004-gifski-integration.md)) — per-frame palettes and
  temporal dithering. ImageIO's GIF encoder is not used.
- Video via `AVAssetWriter`, HEVC, source frame rate.
- Both stream frames; peak memory is independent of clip length.
- *Verify:* `swift test` plus harness output — every fixture produces a playable GIF and
  MP4; GIF loop count is infinite in Loop mode.

**R-12 — Export UX.**

- Nothing exports without an explicit action. Every clip is previewed first.
- Format, size preset, and (for GIF) frame rate are chosen per export. The frame-rate
  control is available **in the editor while previewing**, and the preview reflects it.
- An estimated file size is shown before export and updates as settings change.
- Destinations: iOS share sheet and save to Photos.
- Progress is shown; export is cancellable.
- *Verify:* on device, change preset and fps and watch the estimate update; export to both
  destinations; the GIF loops in iMessage.

**R-13 — Size estimate accuracy.** The pre-export estimate is within **±25%** of actual
for at least 80% of personal fixtures.

- Basis: the estimate exists to support a Small/Medium/Full choice, not to predict bytes.
  ±25% preserves the ordering between presets, which is the decision it informs. Tighter
  accuracy would require trial encoding, which costs more than the decision is worth.
- *Verify:* a harness mode comparing estimates against actual output sizes across the
  fixture set.

---

## 5. Editor

**R-14 — Preview.** The stabilized result in the selected mode, looping continuously.

- First playable frame within 2.0 s (§1.3).
- Updates on any settings change.
- *Verify:* on device, timed from tap to first frame on a 3 s clip.

**R-15 — Preview cache.** The solve runs once; cheap edits do not re-run it.

- After solving, stabilized frames are cached at **720 px long edge**.
- **Crop** changes the displayed rectangle — instant, no re-render.
- **Trim** changes an index range — instant, no re-solve, while the range stays within
  the solved span.
- **Frame rate** decimates cached frames — instant.
- A trim that extends **beyond the solved frame range** triggers a debounced re-solve
  (300 ms after the gesture ends) with the previous preview still playing. No spinner
  replaces a working preview.
- *Verify:* on device, drag crop and trim handles and observe no stall; extend trim past
  the solved range and observe the old preview continuing during re-solve.

**R-16 — Manual trim.** Adjustable start and end. The automatic result is the initial
editable state, not a final render. Resettable to automatic.

**R-17 — Manual crop.** Adjustable rectangle, constrained to the valid stabilized region
so the user cannot drag into black edges. Resettable to automatic.

**R-18 — Failure warning.** When any §1.2 threshold fails, show a **visible but
non-blocking** warning naming which signal failed, with trim and crop still usable and
export still permitted.

- Basis for non-blocking: the user may want the output anyway, and the thresholds are
  heuristics, not verdicts.
- *Verify:* on device, open a fixture known to fail; warning appears, editing and export
  still work.

**R-19 — Settings.** Defaults for preset, GIF frame rate, mode, and format are editable
and persist across launches (R-1 §1.1).

---

## 6. Quality measurement

**R-20 — Metrics.** Per clip, the harness computes crop retention, residual motion, loop
seam, output size per format and preset, and per-stage processing time.

**R-21 — Fixtures.**

- **Synthetic**, committed: generated clips with known motion — translation, rotation,
  scale, combinations, a periodic path for loop testing, and one with a moving foreground
  object. These are the ground truth for unit tests.
- **Personal**, gitignored: 30–50 of the developer's Live Photos as HEIC + MOV pairs in
  `tests/fixtures/personal/`, covering handheld shake, walking, kids and pets, low light,
  parallax with near and far objects, and several expected to fail.

**R-22 — Harness.** A macOS CLI in the pipeline package that processes a fixture folder and
writes, per clip, the GIF and MP4, a before/after contact sheet, and a metrics JSON, plus
an aggregate summary.

- The same failure signals drive both the harness verdict and the editor warning (R-18),
  computed by the same code. They cannot diverge.
- Contact sheets exist so the build agent **looks at output** rather than trusting numbers.
- *Verify:* `swift run stillmotions-harness --fixtures tests/fixtures/synthetic` produces
  outputs and an aggregate for every fixture.

**R-23 — Regression check.** Compares the aggregate against `harness/baseline.json` and
fails on any §1.4 condition.

- Run by `scripts/verify.sh`, against synthetic fixtures. Personal fixtures are gitignored, so
  the committed baseline covers synthetic clips only.
- **The baseline therefore guards correctness, not quality.** Real-world quality regressions are
  caught locally against personal fixtures plus contact-sheet review. This limitation is
  structural and must not be papered over.
- *Verify:* `scripts/verify.sh` exits non-zero on a deliberately regressed build.

---

## 7. Non-functional

**R-24 — Package purity.** `StillMotionsPipeline` has no UIKit, SwiftUI, or PhotoKit
dependency and builds and tests on macOS via `swift build` and `swift test`.

**R-25 — Code style.** Plain SwiftUI, clear module boundaries, small files, no clever
abstraction. The developer reads and tweaks this code.

**R-26 — No secrets in history.** Nothing under `tests/fixtures/personal/`, no signing
material, and no media outside the synthetic fixtures may ever be committed. The repo
becomes public at the end of the build and history is exposed in full.

- Enforced by `scripts/check-no-private-assets.sh`, which `verify.sh` runs first.
- *Verify:* staging a file under `tests/fixtures/personal/` makes `verify.sh` fail.

---

## 8. Open items

Resolved during the build, not assumed now:

| Item | Resolved by |
| --- | --- |
| Registration vs optical flow | Phase-1 spike ([0001](decisions/0001-motion-estimation.md)) |
| Whether L1 is needed | Phase-2 crop-retention gate ([0002](decisions/0002-camera-path-solver.md)) |
| Live Photo source frame rate (15 vs 30) — affects GIF decimation | Measured in R-4 |
| Real extension memory ceiling on iOS 27 | Measured in R-2 |
| Whether the QuickTime `LOOP` atom works in iMessage | Phase-5 `human` experiment ([0005](decisions/0005-looping-export.md)) |
