# 0013. Smooth's ends, a gentler start for pan-heavy clips, and what masking can and cannot do

- Status: **Accepted** (issue #98)
- Date: 2026-10-19
- Relates to: [0009](0009-failure-signals.md), [0010](0010-subject-masking.md), [0011](0011-stabilization-modes.md), PRD R-7a

## Context

The developer compared one handheld selfie clip (76 frames, 2.6 s, portrait, two people turning) with
Google's MotionStills output of the same Live Photo. MotionStills kept about 95% of the frame, left
0.40 px of jitter against the original's 0.86, and followed the camera's pan instead of locking it.
This app's Locked kept about 33% of the frame; Smooth kept about 68%, added jitter, and had a background
jump near frame 13. The clip is a standing local fixture (`tests/fixtures/personal`, gitignored, never
committed). Everything below is numbers; no photos or filenames.

## How it was measured

The first job was to measure the same thing for every picture. `stillmotions-harness reference-compare`
and `policy-study` render each variant's frames at a small fixed size and measure the **picture** by
FFT phase correlation (`OutputMotion`), a different method from the stabilizer's registration. Measuring
our output with our own estimator would hide the errors that matter, because the stabilizer minimizes
that estimator's error by construction. Jitter is the RMS distance of the picture's path from its own
**0.3 s** moving average, in pixels at 180x240. It is a window of time, not frames: a 33 fps GIF and a
20 fps export would otherwise be judged over different spans.

Checked against the developer's own script on the reference clip: original 0.68 to 0.77 px (theirs 0.86),
MotionStills GIF 0.25 to 0.37 (theirs 0.40), net pan 87 and 87 (theirs 86 and 90). Close enough to trust
the comparisons; the absolute values differ with the window and sub-pixel handling.

## Findings

**1. Locked cannot hold this clip, and it is not a pan.** The estimated pose swings in scale (1.29 to 0.89)
and roll (+8.6 to -11 degrees) as well as shift: the arm moves. Locked has to undo all of it and keeps 35%.

**2. Smooth lagged the trend at both ends of the clip.** The Gaussian was cut off at the ends and
renormalized, so the first and last 20 frames were averaged from one side and pulled toward the middle of
the clip. On a path that trends, the smoothed value then trails the real one and the correction shrinks
and turns whole frames: that alone cost this clip about five points of crop. Reflecting the path through
its last sample fixed the trend but doubled the noise in that sample, and on two real near-steady clips
Smooth then kept up to 4.9 points LESS than Locked (a test that Smooth keeps at least as much as Locked
caught it). The shipped fix continues the path along a straight line **fitted to the last `sigma` frames**:
a steady zoom, roll or pan is left alone right to the first and last frame, and one noisy sample is not
doubled.

**3. Strength.** On 40 clips, jitter left as a fraction of the original's (median): sigma 8 0.47, 10 0.44,
12 0.41, 16 0.41; crop kept 92.8%, 91.7%, 91.0%, 90.6%. It stops helping past 12. Sigma 12 is the default
(was 8).

**4. Results on 118 personal clips, shipped code, unmasked:**

| | median crop kept | clips under 60% | jitter left (median, fraction of Off) | jitter worse than Off |
| --- | ---: | ---: | ---: | ---: |
| Locked | 77.4% | 28 | 0.09 | 6 of 113 |
| Smooth, sigma 8 | 94.5% | 0 | 0.47 | 12 of 115 |
| **Smooth, sigma 12 (shipped)** | **92.8%** | **0** | **0.37** | 11 of 115 |
| Smooth, sigma 16 | 91.9% | 0 | 0.37 | 12 of 115 |

Smooth keeps at least as much of the frame as Locked on 113 of 116 clips, by a median 14 points. Locked is
the better SHAKE remover where it can afford the crop (it leaves 9% of the shake, Smooth 37%).

**5. The start rule.** Locked stays the default (PRD R-7a), but a clip where Locked would keep under 60%
(the same line the failure warning uses, 0009) starts in Smooth instead; the user can still choose Locked.
Over the 118 clips that moves clips under 60% from 28 to 0 and median crop from 77.4% to 82.4%, with the
jitter left at a median 0.13 of Off's. No threshold changed.

**6. Masking is the remedy for THIS clip, and it is not a general one.** With people masked out of the
estimate (people-only segmentation at 360 px), Smooth on the whole clip kept 93% (79% unmasked) with 0.28 px
of jitter (0.61), net pan 89, and none of the jumps above 3 px: the estimator had been following the faces
instead of the background. Across all 118 clips (the earlier run, Smooth sigma 8): masking improved jitter by
more than 15% on 11 clips (6 by more than 30%) and made it worse by more than 15% on 26. Person coverage does
not separate the two groups (helped at 27 to 48%, hurt at 18 to 92%), so there is no "mask when people are
prominent" rule the data supports. Cost on this Mac: a median 0.7 s unmasked against 2.4 s masked, and 1.8 s
against 4.6 s on the reference clip. The phone's figure is unmeasured.

**7. What the exported GIFs show (reference clip, Medium, 20 fps, whole clip, i.e. Once):**

| | frame kept | jitter | steps over 3 px |
| --- | ---: | ---: | ---: |
| MotionStills GIF | about 95% (developer's estimate) | 0.25 | none |
| Off | 100% | 0.75 | 4 |
| Smooth (the new default for this clip), unmasked | 77% | 0.69 | 8 |
| Smooth, people masked | 90% | 0.45 | 7, late in the clip |
| Locked, unmasked | 35% | 0.76 | 3 |

Before this change the default here was Locked at 35%. Loop mode trims this clip to about 1.5 s and the
crossfade blends pictures that are tens of pixels apart when the camera pans, which reads as a jump, so Loop
numbers on a pan-heavy clip are not comparable with the whole-clip ones and were not used for the above.

## Decision

- `SmoothedPathSolver.smooth` continues the path past each end with a line fitted to its last `sigma` frames.
- Smooth's default sigma is 12.
- A clip starts in Locked, or in Smooth when Locked would keep under 60% of the frame (`ClipAnalyzer.recommendedMode`).
  The editor says why when it does.
- **Masking stays opt-in** (0010 stands). It is not enabled automatically, because the evidence does not support a rule.

## Not solved, and filed

- **Smooth, and the default rule, still make about one clip in ten jitterier than Off.** Mostly near-steady
  clips (original jitter 0.08 to 0.41 px), where the estimate's own noise is as large as the shake being
  removed, often with rejected frames or people over a third of the frame. Smoothing cannot remove noise that
  is in the estimate. A correction scaled by how much of the measured motion is real shake would.
- **On the reference clip the default is better but not MotionStills' level** (jitter 0.69 against 0.25 at 77%
  crop). The remedy that reaches 0.45 at 90% is masking, which needs a per-clip choice by the user.
- The GIF frame-rate request that followed this comparison (about 30 fps with exact 3,3,4 centisecond timing) is #99.

## What would change this

- A cheap signal that separates the clips masking helps from those it hurts, or a measured on-device cost low
  enough to estimate both ways.
- The phone's measured estimate time for the masked path.
- A way to estimate how much of the measured motion is shake, which would let Smooth scale its correction and
  stop adding jitter on near-steady clips.
