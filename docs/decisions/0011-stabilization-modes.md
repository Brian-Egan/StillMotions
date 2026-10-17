# 0011. Stabilization modes: Off, Smooth, Locked

- Status: **Accepted** (issue #84)
- Date: 2026-10-17
- Relates to: [0002](0002-camera-path-solver.md), [0009](0009-failure-signals.md), PRD R-7a

## Context

The app stabilized every clip one way: pin the camera to the reference frame and crop to what every
frame still covers (Locked). On the 117 personal clips that costs a median 22% of the frame, and 29
clips lose more than 40% of it. The original MotionStills let the user skip stabilization, and the
developer asked for three options instead of one: **Off** (as shot), **Smooth** (shake removed, slow
drift kept, smaller crop) and **Locked** (today). Locked is the default.

## Design

All three modes steer the footage toward a target camera path, so motion is estimated once and each
mode only solves a new path (`ClipAnalyzer.analyze(movieURL:motion:mode:)`). Off is the identity and the
whole frame. Locked is `WarpToReferenceSolver`, unchanged. Smooth is `SmoothedPathSolver`: a Gaussian
(8 frames) over the entries of each frame's transform, and each frame is moved by `S * T^-1` toward the
smoothed pose, with no corner of any frame moved by more than 6% of the frame diagonal, softly limited.
The crop for every mode comes from one shared computation (`CommonCrop`).

## How Smooth got its shape (117 real clips, registration with chained estimation)

Smooth was wrong three times before it was right, and each failure is worth keeping.

1. **Smoothing the pose as separate numbers added jitter.** The first version reduced each transform to a
   shift, a rotation and a scale and smoothed those independently. On half the clips (54 of 117) the result
   was shakier than the footage as shot, up to 15 times. Estimator noise is correlated across those numbers
   (a small rotation and a small shift can cancel at the points the estimator was matching), and smoothing
   them separately breaks the cancellation. The fix is to filter the transform's matrix entries. That is a
   linear filter, so the path of every point in the scene is filtered exactly as a plain Gaussian would,
   and a convex average cannot increase the mean second difference of any path
   (`testSmoothingNeverAddsJitterAtAnyPoint`).
2. **Correcting with the full inverse let garbage estimates through.** Some chained estimates begin with
   scale 0.3 and heavy shear (garbage). Locked is immune, since a wildly zoomed-out frame warps to a huge
   quad that still covers the crop; a smoother is not, and on one clip Locked kept 85% while this kept 26%.
   Bounding how far any frame may move fixes it, and gives Smooth a floor on what it can cost.
3. **A hard cap was itself jitter.** A path hovering around a hard limit switches between "as asked" and
   "capped" from frame to frame. A soft limit, `limit * tanh(move / limit)` applied to the whole correction,
   is continuous.

## Result

Measured with `stillmotions-harness compare-stabilization` on all 117 personal clips. Shake is the mean
distance, at 720 px long edge, between where five scene points land and the average of their two
neighbours in time (the second difference of the path): slow drift scores near zero, jitter scores high.
It is computed from the poses, so it needs no optical flow.

| Mode | Median crop kept | Clips under 60% crop | Median shake (px) | Median loop seam |
| --- | ---: | ---: | ---: | ---: |
| Off | 100% | 0 | 0.37 | 2.50 |
| Smooth (8 frames, 6%) | 90.7% | 1 | 0.05 | 2.43 |
| Locked | 77.6% | 29 | 0.00 | 2.41 |

Smooth cuts shake to 13% of the original on the median clip and is within 20% of the original on 2 of 117;
no clip is shakier than as shot. Other settings are close, so the defaults are not delicate: sigma 4 keeps
93.9% and leaves 19% of the shake; sigma 16 keeps 86.2% and leaves 15%; a limit of 3% keeps 92.0% and
leaves 22%; a limit of 12% keeps 90.2% and leaves 10%. The defaults sit in the middle.

## Failure signals per mode

The signals of decision 0009 mean different things per mode, so they are judged per mode:

- **Off** is never a stabilization failure: its crop is 100%, and its residual motion is not measured.
- **Smooth** is judged on crop retention and the loop seam. Residual motion is measured where flow runs
  but not judged: the meter counts slow drift as motion, which Smooth keeps on purpose, so a limit that
  fits a still camera would flag every clip with a pan.
- **Locked** is judged on all three, as before.

## Consequences

- #21 (the L1 solver) has little left to fix. The gate counted clips under 60% crop under Locked (29 of
  117). Smooth leaves 1. A user whose Locked crop is too tight can choose Smooth or Off. Recommend closing
  #21 as not needed; the developer's call.
- The editor needs a three-way control and should show the crop kept by each mode (R-7a). Changing mode
  re-solves the path, re-selects the loop and refreshes the preview cache, and does not re-estimate.
- Smooth's loop seam is no better than Locked's (2.43 vs 2.41), so decision 0009's concern about the seam
  as a warning signal applies equally.

## Not measured

- Whether Smooth looks right to a person. The shake number is computed from the estimated poses, which
  have their own noise, and a still frame sheet cannot show motion. #26's device checklist should include
  watching a Smooth GIF and an MP4 of a shaky clip.
- Variable-frame-rate clips use a Gaussian over frame index, not over time (decision 0008's chained
  estimation has the same property). At about 29 fps the difference is small; clips averaging 10 fps
  would be smoothed over a longer time.

## What would change this

- Smooth looking wrong on device, or the shake measure disagreeing with what a person sees.
- Real use showing people want something between Smooth and Locked (a strength control); `sigmaFrames` and
  `maxMoveFraction` are already parameters.
- A subject-masking or motion-estimation change that alters the pose noise Smooth is filtering.
