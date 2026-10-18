# 0012. Name the color space when rendering

- Status: **Accepted** (issue #90)
- Date: 2026-10-18
- Relates to: [0001](0001-motion-estimation.md), [0008](0008-chained-motion-estimation.md)

## Context

The first on-device check (#26) found the preview visibly darker than the same Live Photo in
Photos, in every mode, and a dark flash at the Loop seam. A Mac reproduction confirmed the cause:
`StabilizedRenderer.render` and `blend` called `CIContext.render(..., colorSpace: nil)`.

Core Image works in linear light. A render that names no output color space writes those linear
numbers into the BGRA buffer unconverted, and everything downstream (the preview, the GIF and
video encoders, `blend`) reads the buffer as sRGB. Measured on a solid mid-grey of 127:

| step | value |
| --- | ---: |
| source frame | 127 |
| after `render` (before the fix) | **54** |
| after `blend` of two such frames (before the fix) | **9** |

Exports use the same renderer, so GIFs and videos were dark too. `FrameSequence` had the same
call when it turns a rotated clip upright, and portrait Live Photos are rotated: those frames
were darkened once there and again in the renderer (a rotated test clip rendered at 13 where the
same clip unrotated rendered at 63).

## Decision

**Render into sRGB and say so.** `StabilizedRenderer.render` and `blend` pass an explicit sRGB
color space and tag the buffers they produce as sRGB. `FrameSequence`'s upright step does the same.
Wide-gamut sources are mapped into sRGB, which is what a GIF is anyway.

The Loop crossfade still mixes in linear light, which is the physically correct way to blend; the
fix is that its inputs and output are now in one agreed space.

`ColorFidelityTests` pin it: a rendered mid-grey stays 127 (and four other colors survive scaling
and a second render), a blend of two equal frames equals the frame at every weight, a blend lies
between its inputs, and a portrait clip renders at the same brightness as the same clip unrotated.

## Effect on the harness

Everything downstream of the renderer now sees correctly bright pixels, including the frames the
estimators and the residual-motion meter look at, so the measurements move. This is a correction
to the measurement input, not a change in stabilization.

**Synthetic baseline (8 clips), re-recorded.** The regression check failed on the new numbers
(median residual 0.070 to 0.091 px, past the allowed 10% rise), so `harness/baseline.json` was
updated with `--update-baseline`. No threshold was changed.

| clip | crop % | residual px | seam |
| --- | --- | --- | --- |
| combined | 79.4 to 79.5 | 0.076 to 0.097 | 0.64 to 0.76 |
| moving-subject | 95.5 to 96.0 | 0.195 to 0.205 | 1.35 to 1.31 |
| parallax | 97.8 to 97.9 | 0.064 to 0.068 | 0.71 to 0.62 |
| periodic | 95.9 to 96.1 | 0.171 to 0.185 | 0.42 to 0.56 |
| rotate | 85.4 to 85.7 | 0.056 to 0.068 | 0.37 to 0.45 |
| scale | 92.0 to 91.7 | 0.050 to 0.060 | 0.31 to 0.41 |
| translate-linear | 96.3 to 96.2 | 0.063 to 0.084 | 0.49 to 0.61 |
| translate-shake | 96.5 to 96.4 | 0.186 to 0.201 | 0.27 to 0.46 |

Crop moves by under 0.6 points either way. Residual rises on all eight clips, by 5 to 35%.
Recovered-motion error against the synthetic ground truth is mixed, not worse: parallax 2.83 to
0.90 px, translate-shake 1.06 to 1.70 px, moving-subject 1.87 to 2.18 px, the other five within
0.3 px. The synthetic scenes are small and flat, so a shift in what the meter sees is not a sign
that stabilization changed.

**Real clips (117 personal Live Photos), before and after, same code otherwise.**

| | before | after |
| --- | ---: | ---: |
| median crop kept | 77.6% | 77.4% |
| median residual motion | 0.438 px | 0.425 px |
| median loop seam | 2.41x | 2.42x |
| clips failing crop retention | 29 | 29 |
| clips failing residual motion | 21 | 21 |
| clips failing the loop seam (harness-only, [0009](0009-failure-signals.md)) | 92 | 101 |
| frames the estimator rejected, all clips | 7 | **54** |

The aggregates are stable. Per clip the numbers move (32 clips changed which signals they fail),
as the estimator reacts to different input; the swaps cancel for crop and residual.

**One result is not neutral:** frames rejected by the motion estimator rise from 7 to 54, almost
all on five clips (10 or 11 each), while some clips improve a lot (a clip kept 6% of the frame
before and 45% after). A rejected step assumes no motion, so those frames are not stabilized. This
is reported rather than explained away; it is tracked in a follow-up issue.

## Not changed

- `SubjectMasker` and the harness-only tools (`OpticalFlowEstimator`, `SpikeTools`,
  `FixtureGenerator`) still call `render(..., colorSpace: nil)`. Masking is off by default
  ([0010](0010-subject-masking.md)); changing its input would move the numbers that decision was
  made on. The synthetic fixtures are ground truth and are not regenerated.
- Extended-range or Display P3 output. Revisit if the app ever exports wide-gamut video.

## What would change this

If a device shows color shifts on wide-gamut (Display P3) clips that Photos does not, render into
a wider space and tag accordingly; the tag added here makes that a one-line change.
