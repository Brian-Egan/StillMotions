# 0001. Motion estimation: registration vs optical flow

- Status: **Accepted** — resolved by the phase-1 spike (#10); see "Outcome of the spike"
- Date: 2026-09-24
- Relates to: PROJECT_BRIEF.md §4.2 step 2, §6.1; docs/PRD.md "Stabilization quality"
- Amended by: [0008](0008-chained-motion-estimation.md): how frames are registered (chained, not each to the reference) changed after real footage; the choice of estimator below stands

## Context

Every downstream stage needs one transform per frame mapping that frame onto the
reference frame. The brief assumed Vision provides feature tracking with outlier
rejection, and defined the residual-motion metric as "mean displacement of tracked
background features between consecutive output frames".

**Vision provides no sparse keypoint or feature-point API.** Verified against current
Apple documentation (iOS 27, September 2026). The full inventory of relevant requests:

| API | Gives us | Does not give us |
| --- | --- | --- |
| `TrackHomographicImageRegistrationRequest` → `ImageHomographicAlignmentObservation.warpTransform` (`matrix_float3x3`) | A 3x3 warp per frame pair, one cheap call | Any correspondences, any confidence, any inlier set |
| `TrackTranslationalImageRegistrationRequest` → `ImageTranslationAlignmentObservation.alignmentTransform` (`CGAffineTransform`) | Translation only | Rotation, scale, correspondences |
| `TrackOpticalFlowRequest` → `OpticalFlowObservation` | A motion vector per pixel, `ComputationAccuracy` of `.low/.medium/.high/.veryHigh` | Cheapness — Apple: "very resource intensive, so perform only one request at a time" |
| `TrackObjectRequest`, `TrackRectangleRequest` | Bounding box / quad tracking | Point-level correspondences |
| `GenerateImageFeaturePrintRequest` | A whole-image similarity descriptor | Localized features, despite the name |

There is no SIFT/ORB/corner-detection equivalent, and none was added in iOS 26 or 27.

This breaks three things the brief takes for granted:

1. **Outlier rejection.** Registration returns a matrix with no evidence. If a bus
   crosses the frame and registration locks onto the bus, nothing in the return value
   says so. With correspondences we can RANSAC and discard the minority.
2. **Subject masking** (brief §4.2: mask people and animals so moving subjects do not
   influence the camera estimate). With grid-sampled correspondences this is a filter —
   drop samples inside the Vision segmentation mask. With registration there is no hook;
   the only lever is blanking the subject in the pixels before registering, which
   changes image content and may itself degrade the match.
3. **The residual-motion metric**, which is literally a correspondence measurement and
   is the primary regression gate. Without correspondences the nearest substitute is
   whole-frame pixel difference, which conflates camera shake with subject motion,
   exposure change, and rolling shutter — a much weaker quality signal.

Correspondences are obtainable from optical flow by sampling the dense field on a grid
(for example 32x32), treating each sample as a point pair, and fitting an affine or
homographic transform with RANSAC. This recovers all three capabilities. The cost is
unknown and Apple publishes no numbers.

## Deciding mechanism

This decision is **deliberately deferred to measurement**, because the tradeoff is
entirely quantitative and neither training data nor Apple's documentation supplies the
numbers. Apple publishes no accuracy bounds, no image-size limits, and no performance
figures for either API.

The spike issue (`spike` label, phase-1) must measure, on the **iPhone 14 Pro reference
device** and on the macOS harness:

- `TrackOpticalFlowRequest` wall-clock ms/frame and peak memory at 720 px and at native
  resolution, at each `ComputationAccuracy` level.
- `TrackHomographicImageRegistrationRequest` ms/frame at the same resolutions.
- Accuracy of both against the **synthetic fixtures**, where the motion path is known
  exactly, reported as RMS error in the recovered transform.
- Accuracy of both on a synthetic fixture **with a moving foreground object**, which is
  the case that distinguishes them.

The spike then updates this record with the numbers and sets the status to Accepted.

Decision rule, written down in advance so the outcome is not argued after the fact:

- If flow at the cheapest accuracy level that meets the transform-error bar costs
  **≤ 2.0 s total** for a 3 s clip at 720 px on the 14 Pro, use **flow everywhere**.
  One code path, correspondences in the app, masking and outlier rejection everywhere.
- Otherwise use the **split**: registration in the app for preview and export,
  flow in the harness for metrics and for RANSAC-verifying the app's warps.
- If registration's transform error on the moving-foreground fixture is **no worse**
  than flow's, prefer registration even if flow is affordable, because it is simpler.

## Outcome of the spike (#10)

Measured with `stillmotions-harness benchmark-estimators` on an **Apple M2 Mac, release
build**, 8 frames per fixture (every 10th), against the synthetic fixtures' known truth.
Reproduce with:

```
swift run -c release stillmotions-harness benchmark-estimators \
  --fixtures tests/fixtures/synthetic --out /tmp/bench
```

The full per-fixture table (every estimator, level, resolution and masking mode) is in the
#10 PR body; `summary.json` carries the same numbers. Averages over the five single-camera-
motion fixtures (`translate-linear`, `translate-shake`, `rotate`, `scale`, `combined`):

| Estimator | Resolution | ms/frame | Mean RMS px | Worst fixture RMS px | Peak memory growth |
| --- | --- | ---: | ---: | ---: | ---: |
| Registration | 720 long edge | 6.8 | 0.73 | 1.96 | ≤ 4 MB |
| Registration | native (1920x1080) | 10.9 | **0.15** | **0.23** | ≤ 11 MB |
| Flow `.low` | 720 | 30.6 | 1.23 | 1.70 | ≤ 17 MB |
| Flow `.medium` | 720 | 32.6 | 1.47 | 2.27 | ≤ 25 MB |
| Flow `.high` | 720 | 39.3 | 2.05 | 3.58 | ≤ 42 MB |
| Flow `.veryHigh` | 720 | 64.4 | 1.35 | 2.33 | ≤ 59 MB |
| Flow `.low` / `.veryHigh` | native | 37.9 / 64.1 | 1.29 / 1.38 | 1.77 / 2.28 | ≤ 35 / 53 MB |

RMS is in native pixels (estimates made at a smaller size are scaled back up). The bar is
0.75 px ([0007](0007-registration-accuracy-bar.md)). Memory is growth in `phys_footprint`
on a Mac, a relative signal only.

Moving foreground, RMS px (mean over frames), unmasked / Vision-masked / oracle-masked:

| Clip | Registration, native | Flow `.veryHigh`, native | Flow inlier ratio |
| --- | --- | --- | --- |
| `moving-subject` (160 px square, 0.8% of frame) | 0.13 / 0.13 / 0.12 | 1.04 / 1.04 / 1.04 | 0.98 |
| `moving-subject-large` (640 px square, ~20% of frame) | 0.17 / 0.14 / 0.14 | 1.02 / 1.03 / 1.02 | 0.77 unmasked, 0.96 masked |

`moving-subject-large` is an in-memory variant (not committed) added because the committed
subject is too small to stress either estimator. Vision's foreground-instance mask found
nothing on the 160 px square (0% coverage) and matched the oracle on the large one (24.2%
vs 23.8%).

Three Vision behaviours, each of which changes how the estimators must be used:

1. **Flow vectors come back scaled, by an undocumented factor.** Measured on a known pure
   translation, `flow(at:)` returns a fixed fraction of the true displacement: 0.31 / 0.34 /
   0.41 / 0.50 at 720 and 0.175 / 0.19 / 0.23 / 0.29 at native for `.low` / `.medium` /
   `.high` / `.veryHigh`. The factor is identical on the synthetic canvas and on a real
   photograph, so it is a property of the API and not the content; the legacy
   `VNGenerateOpticalFlowRequest` shows the same values. It is only approximately linear in
   displacement (±15% across 2 to 36 px). A one-point calibration then leaves 1 to 3.5 px of
   error on the rotation, scale and shake fixtures, which that nonlinearity plausibly
   explains (not isolated). Flow is defined on the *reference* grid and
   points toward the frame; its y component uses Vision's bottom-left origin. The spike
   calibrates per size and level with a known synthetic shift (one extra flow request,
   30 to 200 ms, once per configuration).
2. **Registration is non-monotonic in image size.** On this machine it is accurate at
   480 px (0.75 RMS on `combined`) and at 900 px and above (0.36 at 960, 0.29 at 1280,
   0.23 native), but between roughly 600 and 840 px it is bad: 1.6 at 660, 2.8 at 740, 3.9
   at 840, worst frame 16 px. **The 720 px Medium/preview size sits in the bad band.**
   Cause unknown; not an odd-dimension effect (718, 720 and 722 behave alike).
3. **First flow request on a new image shape was slow on a cold machine**: about 15 s per
   (accuracy, 720x405) configuration the first time, then 0.1 to 0.3 s. Not observed with
   registration. Whether an iPhone pays this, and whether it persists across launches, is
   unknown and goes to the on-device checklist (#26).

4. **Vision optical flow does not run on GitHub-hosted macOS runners** (found in #17): the
   request fails with `memFullErr` ("failed to analyze motion flow"), while registration,
   segmentation, Core Image and HEVC encoding all work there. Consequences: anything built on
   flow cannot be exercised in CI, so the harness probes for flow, records residual motion as
   "not measured" when it is missing, and the CI regression check then covers crop retention,
   loop seam and every per-clip verdict that does not need residual motion. The residual-motion
   clause of PRD §1.4 is enforced by local runs (and by `--update-baseline`, which refuses to
   run without flow). Tests of the production flow estimator (#11) must skip when flow is
   unavailable. The synthetic-clip baseline itself must therefore be written on a Mac.

### Outcome of #11: the production flow estimator

`OpticalFlowEstimator` (`Sources/MotionEstimation`) is the harness-only flow estimator. It samples
a 32x32 grid, calibrates Vision's flow scale once per size and level, and fits an affine
transform with the deterministic `AffineRANSAC`. It always reports a measured `inlierRatio` and
returns every grid sample as a `Correspondence`; `estimateWithEvidence` also returns which
samples were inliers and the mean inlier displacement, which is the residual-motion measurement.

Measured on the same Mac as the spike. A known shift is applied to a real fixture frame
(`translate-linear` frame 0) and read back. `inlierMeanDisplacement`, px:

| Size | Level | True 0.0 | True 0.5 | True 1.0 | True 2.0 |
| --- | --- | ---: | ---: | ---: | ---: |
| 720 | `.medium` | 0.28 | 0.66 | 1.09 | 2.05 |
| 720 | `.veryHigh` | 0.16 | **0.52** | **1.00** | 2.02 |
| native 1920 | `.medium` | 0.76 | 1.03 | 1.55 | 2.44 |
| native 1920 | `.veryHigh` | 0.39 | 0.73 | 1.18 | 2.14 |

Findings that changed the design:

1. **Flow has a noise floor that grows with image size.** Two identical images read 0.16 px at
   720 and 0.39 px at native, even at `.veryHigh`. The floor, not the flow-scale calibration, is
   what limits small residuals: moving the calibration shift from 0.4% to 2% of the width changed
   no reading by more than 0.03 px.
2. **Default accuracy is `.veryHigh`, not `.medium`.** `.medium` was chosen from #10's
   large-transform fixtures, which do not exercise sub-pixel motion. At the 720 px size the
   residual metric is measured at, only `.veryHigh` reads a 0.5 px and a 1.0 px residual within
   20% (4% and 0%). `ResidualMotionMeter` now uses it. This changes the residual-motion values
   the harness reports. No baseline is committed yet (`harness/baseline.json` is absent), so no
   regression gate moves, but any numbers recorded before #11 are not comparable.
3. **Measure residuals at 720 px, not native.** At native size a 0.5 px residual reads 0.73 px
   (46% high). The harness already measures at a 720 px long edge; keep it that way.
4. **Moving-subject rejection works but leaks on flat interiors.** On `moving-subject-large` (a
   flat orange square, about 23% of the grid) `inlierRatio` is 0.75, against 1.00 on
   `translate-shake`. Of the grid samples on the subject, 22% still count as inliers against 89%
   of background samples; 7% of all inliers sit on the subject. A flat interior has no texture for
   flow to lock onto, so some of its samples return background-like motion. Real subjects have
   texture, which should help; personal fixtures (#18) will show.
5. **Memory is not a concern here.** Peak `phys_footprint` growth is 9 MB at 720 and 11 MB at
   native, against the 200 MB flag. On a Mac, so a relative signal only.

The absolute-accuracy criteria #11 originally carried (at or better than registration on every
fixture, and lower error on `moving-subject`) were replaced before implementation, on the #10
measurements: see the comments on #11.

### Applying the decision rule

1. *Flow everywhere if the cheapest level meeting the transform-error bar costs ≤ 2.0 s for
   a 3 s clip at 720 px on the 14 Pro.* **Fails on two counts.** No flow level meets the
   0.75 px bar on every fixture (best is `.veryHigh`: 0.97 on `translate-shake`, 2.3 on
   `combined`). And the cheapest level costs 2.7 s on an M2 for 90 frames at 720 px
   (`.low`, 30 ms/frame), already over 2.0 s before any safety margin for the slower A16.
2. *Otherwise the split.* **Taken.**
3. *If registration is no worse than flow on the moving-foreground fixture, prefer
   registration.* **True on both subjects, masked and unmasked** (0.13 to 0.17 px against
   about 1.0 px), so registration is preferred on the merits too.

Registration's cost for a 3 s (90 frame) clip on the M2 is 0.5 s at 960 px, 0.6 s at 1280
and 0.9 s native. Safety margin applied: **2x** for the iPhone 14 Pro (A16) against the M2,
which puts native at about 1.8 s of a 2.0 s preview budget that also has to cover decode,
solve and cache. That is too tight, so the app estimates at **960 to 1280 px long edge**,
not native and not 720. The margin is a judgement, not a measurement, and the first
on-device timing replaces it.

**What would change this call:** an on-device measurement putting flow under budget *and*
Apple fixing the flow scaling (flow would then give inlier ratios and masking for free);
registration's bad band appearing at 960 to 1280 on the iPhone; or personal fixtures where
registration locks onto a moving subject, which the synthetic clips cannot show. The
masked-registration result also matters: blanking the subject helped at native but
*hurt* at 720 (0.71 to 0.99 on `moving-subject-large`), so masking registration is not a
free win.

## Decision

Build both behind a protocol so the spike's outcome is a configuration change, not a
rewrite:

```swift
public protocol MotionEstimator {
    /// Maps the reference frame's coordinates onto this frame's coordinates
    /// (`pFrame = transform * pReference`) — verified empirically against
    /// `VisionRegistrationEstimator` in #9. An earlier draft of this comment had the
    /// direction backwards ("mapping frame onto reference"); corrected via #9's PR,
    /// alongside `async` (Vision's request APIs have no synchronous equivalent).
    func estimate(frame: CVPixelBuffer, reference: CVPixelBuffer) async throws -> FrameMotion
}

public struct FrameMotion {
    public let transform: simd_float3x3
    /// Correspondences, when the estimator produces them. Empty for registration.
    public let correspondences: [Correspondence]
    /// Fraction of correspondences agreeing with `transform`. `nil` when unknown.
    public let inlierRatio: Double?
}
```

`inlierRatio` is `nil` rather than `1.0` for registration. This is deliberate: code
must distinguish "measured, and everything agreed" from "not measurable", and a
sentinel of `1.0` would silently claim confidence that does not exist.

Two implementations: `VisionRegistrationEstimator` and `OpticalFlowEstimator`. The
harness can run either, so the spike is a harness invocation rather than a branch.

**Chosen design (the split):**

- **App, preview and export:** `VisionRegistrationEstimator`, estimating at 960 to 1280 px
  long edge, never in the 600 to 840 px band. `inlierRatio` stays `nil`.
- **Harness:** `OpticalFlowEstimator` (#11, narrowed to harness-only) for the residual-
  motion metric and for checking the app's warps. It must calibrate Vision's flow scale
  (item 1 above) and its absolute accuracy is limited to roughly ±15%, which is adequate for
  a sub-pixel residual metric but not for producing the shipping transform.
- **Subject masking (R-6)** has no correspondence hook in the shipping path. Its remaining
  uses are the harness's flow samples and, optionally, blanking before registration, which
  helped at native and hurt at 720 and is therefore not enabled by default. #19 should be
  re-scoped accordingly.

## Consequences

- The residual-motion metric is defined against whatever correspondences are available
  at measurement time. In the split design it is computed by the harness's flow pass,
  not by the shipping estimator — so the harness measures a pipeline that is not
  bit-identical to the one shipping. This divergence is the split design's main cost
  and must be stated in the PRD.
- `FrameMotion.inlierRatio` being `nil` is a real signal: failure detection cannot use
  inlier ratio as a failure input in the split design and must rely on crop retention,
  residual motion, and loop seam only.
- If flow wins, the share extension is unaffected: the extension does no processing
  (see 0003), so its memory ceiling does not constrain this choice.

## Rejected alternatives

**Registration only, redefine the metric as whole-frame pixel difference.** Cheapest
and simplest. Rejected because it weakens the single most important regression gate in
the project, and because it makes subject masking impossible — and masking is called
out in the brief as the mechanism for handling kids and pets, which are named as
fixture coverage categories.

**Hand-rolled corner detection and tracking** (Harris/FAST + pyramidal Lucas-Kanade in
Metal or Accelerate). Full control, no Vision dependency, and the classical answer.
Rejected as disproportionate: it is a substantial subproject of its own, and the brief
is explicit that code should favour clarity over cleverness because the developer reads
and tweaks it.

**Third-party OpenCV.** Gives everything immediately and is the industry default.
Rejected on integration weight — a large binary dependency in a two-target personal app,
against a brief that limits dependencies to gifski.

**ARKit / camera pose.** Not applicable; we process already-captured assets with no
motion metadata.

## What would change this

- Apple shipping a sparse feature API: would supersede both options.
- Measured flow cost coming in far below expectation: collapses to one code path.
- Personal fixtures showing that moving-subject contamination is rare in practice
  (few clips with large foreground motion): weakens the case for correspondences and
  favours registration-only simplicity.
