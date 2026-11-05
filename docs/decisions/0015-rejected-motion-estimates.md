# 0015. Rejected motion estimates: what they are, and why nothing changes

- Status: **Accepted** (issue #92)
- Date: 2026-11-05
- Relates to: [0001](0001-motion-estimation.md), [0008](0008-chained-motion-estimation.md), [0012](0012-renderer-color-space.md)

## Context

Decision 0012 (the renderer's color fix, #90) found that the number of frames the motion estimator rejected,
across the 117 personal clips, rose from 7 to 54, almost all on a handful of clips. A rejected step assumes no
motion, so those frames are not stabilized. #92 asked what was happening and whether the estimator, its
plausibility bounds or its input should change. Everything here is numbers; no photos or filenames.

## What the rejections are

New diagnostics make the estimator say WHY it rejects a frame (`MotionResult.failureReasons`, one line per
rejected frame) and a harness command groups them (`stillmotions-harness estimation-failures`).

- **All 54 rejections are the scale rule.** None came from the rotation rule, the shift rule, or Vision finding
  nothing. 7 of 118 clips have any; 6 have three or more; four have 10 or 11 of their 74 to 86 frames.
- **The clips share a profile: dim and flat.** Mean brightness about 73 against 124 for all clips, and detail
  (mean brightness gradient) about 1.7 against 8.0. All are landscape 1744x1308.
- **The rejected scales are impossible, not borderline.** The bound allows a step between neighbouring frames to
  scale the picture by 0.8 to 1.25. The rejected values run from 0.27 to 5.76. About a third are within 0.05 of
  the bound, but 0.78 or 1.28 is still a picture growing or shrinking by a fifth in 1/30 of a second. The
  bound is right; Vision is returning a wrong answer on footage with little to register against.

## Why it rose: the old color bug was acting as a preprocessing step

Before #90 every frame given to the estimator was written without naming a color space, which darkened it by
about gamma 2.2. Re-creating that darkening in front of the estimator, in the harness only, brings the
rejections back from 54 to 5, and the four worst clips from 11, 11, 11 and 10 to 0.

## But the darkening is not a better input

The same 118 clips, Smooth at strength 12, jitter measured on the rendered frames (decision 0013):

| | correct brightness | darkened like the old bug |
| --- | ---: | ---: |
| frames rejected | 54 | 5 |
| median crop kept, Smooth | 92.8% | 93.2% |
| median crop kept, Locked | 77.4% | 77.7% |
| jitter left vs Off, Smooth (median) | 0.372 | 0.404 |
| clips under 60% crop, Locked | 28 | 26 |

Clip by clip, darkened input gives a picture more than 15% better on 15 clips, more than 15% worse on 23, and
within 15% on 78: no net gain. On the dim clips it is a mixed result: of the five worst, two stabilize with the
correct input (77% and 79% of the frame) and **do not stabilize at all with the darkened one** (the estimates
collapse and no path can be solved), one is better darkened (jitter 0.14 to 0.06, against 0.11 as shot), and two
are the same.

## Rejections are not what hurts those clips

A rejected step falls back to "no motion", which is a safe default, and the clips still get a valid path. What
does hurt is that two of the four worst end up jitterier than the footage as shot (Smooth 0.63 against 0.41 as
shot, and 0.43 against 0.27): the estimate is noisy, and Smooth cannot remove noise that is in the estimate.
That is the problem tracked in #102.

## Decision

**No change to the estimator, its bounds or its input.** The bound is correct, putting the old darkening back is
neutral overall and breaks stabilization on some of the clips it is meant to help, and the accidental
preprocessing was not a considered design. What is kept is the diagnostic, so the next report is a table and not
a count.

For #102: **the share of a clip's steps that were rejected is a ready-made reliability signal.** A clip with 13%
of its steps rejected has an estimate that cannot be trusted at the frames in between either; scaling Smooth's
correction down for such clips is a more direct fix than anything done to the pixels.

## What would change this

- A preprocessing step for dim footage (denoise, local contrast normalization, a tone curve chosen for
  registration and not borrowed from a bug), judged across ALL clips and not just the dim ones.
- A second estimator (optical flow, which already runs in the harness) as a fallback for steps Vision rejects.
- A different failure pattern on the phone: these figures are from a Mac; Vision on the device may behave
  differently on the same clips.
