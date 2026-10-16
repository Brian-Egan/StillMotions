# 0010. Subject masking: what it takes to do no harm, and what it buys

- Status: **Accepted as opt-in** (issue #19). Masking ships OFF; turning it on by default is the developer's call
- Date: 2026-10-16
- Relates to: [0001](0001-motion-estimation.md), [0008](0008-chained-motion-estimation.md), PRD R-6

## Context

A child or a dog crossing the frame can drag the camera estimate toward itself, so PRD R-6 masks
moving subjects out of the estimate. #19 builds that: `SubjectMasker` (Vision person segmentation
plus foreground-instance segmentation) produces a `SubjectMask`, which is dropped from the flow
samples (`OpticalFlowEstimator`) or filled in before registration, and skipped entirely when it covers
more than 60% of the frame. `ClipAnalyzer.estimateMotion(masker:)` and the harness's `--masking` flag
turn it on. This record is what measuring it on 117 real Live Photos showed. The first version made
things worse, and why is worth keeping.

## Finding 1: painting the subject grey makes registration under-correct

The obvious way to mask registration, which has no mask input, is to paint the subject mid-grey in both
pictures (`SubjectMask.blanking`). Measured on 117 real clips that raised median crop retention from 77.6%
to 82.4% and cut clips below 60% from 29 to 17, and also raised background residual motion from a median
0.44 px to 0.72 px, with 44 clips at or above 1 px against 21. Re-running 18 of the clips with the residual
meter ALSO ignoring the subject changed nothing for the unmasked runs (0.87 to 0.81 px median), so the
meter was not the cause. The cause is the patch: it is in the same place in both frames, so its edges vote
for "no motion", the estimate shrinks toward the identity, less motion is removed (so the crop loses less,
which looked like an improvement) and more jitter is left (which the residual meter, correctly, reported).
Crop retention alone would have said "ship it". It was a mirage.

The fix is a fill with nothing to vote with. `SubjectMask.inpainting` continues the surrounding colors
smoothly into the hole (push-pull). On the same 18 clips the residual regression disappears (median
0.90 px against 0.81 unmasked, grey fill 2.63) while crop retention still rises. Flow needs none of this:
it drops the samples instead of changing pixels.

## Finding 2: segmentation finds salient things, not moving things

Vision's foreground-instance mask outlines a stationary sign as readily as a running child. On one clip it
covered the whole sign, the best thing in the frame to track. Person segmentation is accurate and follows
people well, and is the more trustworthy of the two. Both masks are aligned to the picture (IoU 0.85 against
the synthetic subject's true position, centroids within 0.01), so the failures are not a coordinate bug.
Telling a moving region from a stationary one reliably is its own problem: a first attempt, comparing the
residual difference inside and outside the mask after aligning, was dominated by image texture (a dark
background has almost no gradient, so any region looked "worse" against it) and was not kept.

## Result: full set, smooth fill, both runs using the same subject-aware meter

117 personal clips, registration with chained estimation (`--masked-meter` for the unmasked run, `--masking`
for the masked one):

| | unmasked | masked |
| --- | ---: | ---: |
| median crop retention | 77.6% | 76.9% |
| clips below 60% crop | 29 | 22 |
| median residual motion | 0.456 px | 0.483 px |
| clips at or above 1 px residual | 22 | 20 |
| clips passing all three thresholds | 16 | 16 |

Of the 37 clips that failed crop or residual unmasked, masking **fixed 10**. Of the 80 that were fine,
**4 are newly broken** (one badly: a scene of two people against a flat red wall leaves only a dark,
low-texture floor to track once they are filled in, and crop fell from 72% to 11%). Eight clips cross up
through 60% crop and one crosses down. Most clips are unaffected: the median change is 0.0 on both measures.
Net: +6 clips passing crop and residual. Cost: the estimate stage went from about 0.6 s to 3.4 s per clip
on an Apple M2 (the segmentation is about 35 ms a frame in an optimized build, the two inpainting passes
about 13 ms each); the iPhone 14 Pro figure needs the on-device check (#26).

On synthetic fixtures with no subject, registration error rises slightly (`translate-shake` 0.090 to 0.140
px, `rotate` 0.206 to 0.356, `combined` 0.235 to 0.331), all far inside the 0.75 px bar. Vision finds
"foreground" in the made-up scene and fills it in. That is the criterion "masking must not make subject-free
clips worse" not being met literally; on the one synthetic case with a real moving subject it does help
(`moving-subject-large`: 0.182 to 0.151 px; flow inlier ratio 0.75 to 0.94).

## Decision

Masking is implemented and tested but **off by default** everywhere (`masker: nil`). It is a modest net gain
(+10 fixed, 4 broken, none on most clips) for several seconds of extra work per clip, and its worst case is
severe. The developer decides whether to turn it on, ideally after seeing the on-device cost and a few more
clips. Until then the harness runs it only with `--masking`, and `--masked-meter` measures an unmasked
stabilization by background alone, which is the fair comparison.

## What would change this

- A reliable test for "this region moves independently of the background" would let masking skip stationary
  objects and low-texture leftovers, which are the four regressions. That is the next piece of work.
- Falling back to the unmasked estimate when the masked one disagrees sharply with it would remove the
  worst case (the 72% to 11% clip) at the price of a second estimate per masked frame.
- On-device cost much higher than the Mac's, or much lower.
- Apple adding a masked registration request (none exists).
