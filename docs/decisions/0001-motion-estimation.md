# 0001. Motion estimation: registration vs optical flow

- Status: **Provisional — resolved by spike issue, see "Deciding mechanism"**
- Date: 2026-09-24
- Relates to: PROJECT_BRIEF.md §4.2 step 2, §6.1; docs/PRD.md "Stabilization quality"

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

## Decision

Build both behind a protocol so the spike's outcome is a configuration change, not a
rewrite:

```swift
public protocol MotionEstimator {
    /// Transform mapping `frame` onto `reference`.
    func estimate(frame: CVPixelBuffer, reference: CVPixelBuffer) throws -> FrameMotion
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
