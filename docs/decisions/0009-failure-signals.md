# 0009. The three failure signals: what they can and cannot see

- Status: **Proposed**. Nothing in code changes with this record; the thresholds stay as PRD §1.2 has them until the developer decides (issue #20)
- Date: 2026-10-16
- Relates to: [0001](0001-motion-estimation.md), [0002](0002-camera-path-solver.md), PRD §1.2, R-18, R-22

## Context

Issue #20 makes stabilization failure a pipeline RESULT: `StabilizationAssessment` carries, for each
of crop retention, residual motion and the loop seam, the measured value, the PRD limit and whether it
failed. The harness and the editor read the same assessment (`ClipAnalyzer.analyze`), so they cannot
disagree. Its acceptance criteria also ask for the false-positive rate on clips that look fine, and say
that if good clips are being flagged "the thresholds are wrong and that belongs in a decision record,
not a quiet adjustment". This is that record. Two things came out of measuring.

## Finding 1: the loop seam flags most clips that look fine

Source: the labelled per-clip table in `harness/personal-baseline-notes.md` (#18: 115 processed
clips, each judged by eye from its contact sheet). "Looks fine" means the reviewer found nothing wrong.

| Signals used | Clips that look fine, flagged (of 68) | Clips with a real cause, flagged (of 47) |
| --- | ---: | ---: |
| all three (as in PRD §1.2) | **59 (87%)** | 46 (98%) |
| crop retention and residual motion only | **1 (1%)** | 41 (87%) |
| loop seam only | 59 (87%) | 38 (81%) |

The seam is the whole false-positive problem. It divides the loop's seam difference by the typical
frame-to-frame change; in a near-static scene that denominator is tiny, so any non-repeating motion
(a child walking across a stable room) is a large multiple of it however good the loop point is. The
crossfade already helps (median 8.4x before, 2.5x after) and the 1.5x threshold is still missed.

Sweeping the seam threshold on the same table:

| Seam limit | Looks-fine clips flagged (of 68) | Clips with a real cause flagged by the seam alone (of 47) |
| ---: | ---: | ---: |
| 1.5x (PRD) | 57 | 38 |
| 2x | 41 | 32 |
| 2.5x | 34 | 25 |
| 3x | 12 | 13 |
| 4x | 3 | 8 |

(57 rather than 59 at 1.5x because the table prints the ratio to one decimal, so two clips at 1.5
print as passing.) Raising the limit trades false positives against missed real failures roughly
one for one; no single limit separates the two groups.

Caveat on residual motion: that column was measured at flow `.medium` and reads about 20 to 40%
high at sub-pixel levels (decision 0001, finding 6). The crop clause is exact. Re-measured at
`.veryHigh`, fewer clips fail residual motion, so the "crop and residual only" row's hit rate may
drop a little and its false-positive rate cannot rise.

## Finding 2: the signals cannot see parallax

The `parallax` synthetic fixture (a near layer over a moving far layer) passes all three signals
(crop 0.978, residual 0.064 px, seam 0.711; pinned by `testParallaxIsNotFlaggedBecauseTheSignalsOnlySeeTheDominantLayer`).
That is not a threshold that is too loose. All three signals describe the dominant layer: a single
homography stabilizes it well, and residual motion is measured on the RANSAC inliers, which are that
layer. The near layer's jitter is invisible to them. Seeing it needs a signal about the MINORITY,
for example the optical-flow inlier ratio, which #20 rules out as an input because it is `nil` when
the shipping estimator is registration. So #20's first acceptance criterion ("parallax is flagged")
cannot be met by these inputs, and nothing was tuned to make it appear to be.

## Options for the seam (not chosen here)

1. **Leave the PRD thresholds.** The editor warning would then fire on most clips, which teaches users
   to ignore it. Not recommended.
2. **Keep the seam as a harness metric but do not use it in the user-facing warning (#29).** Crop and
   residual alone flag 87% of the clips that have a real cause with a 1% false-positive rate. The seam
   still gates loop quality in the harness, where a human reads it with context. This needs no change to
   the thresholds; #29 chooses which readings to show, and `StabilizationAssessment` already exposes all
   three. This is the recommendation.
3. **Change what the seam measures** (for example floor the denominator at a perceptible difference,
   so a static scene's tiny step does not inflate the ratio), then re-derive its limit from the labelled
   clips. Worth doing if loop quality needs a user-facing signal, but it is new measurement work and
   changes PRD §1.2, so it needs its own issue.
4. **Raise the limit** (3x leaves 12 false positives of 68 but misses about two thirds of the real
   failures the seam alone catches). A blunt version of option 3.

## What would change this

- Re-measuring the personal clips at `.veryHigh` (and after #19's masking) changes the residual column and
  could change the crop-and-residual row.
- A signal that sees the minority layer would let parallax be flagged.
- Real use: if a warning the developer sees on a clip that looks fine is the common experience, option 2
  is what to do first.
