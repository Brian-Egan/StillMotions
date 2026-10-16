# Personal-fixture baseline notes

Issue #18. **Numbers only.** Clips are identified by an anonymous index (`clip-NNN`, assigned in alphabetical order of the source file names), the descriptions are generic categories, and nothing here identifies a photo. The fixtures themselves are gitignored (PRD R-26) and CI never sees them, so this file is the only committed record of how the pipeline does on real footage.

## How this was produced

- Pipeline as of #61: registration at 960 px long edge, chained consecutive frames (decision 0008), reference frame from each Live Photo's own metadata (#59), warp-to-reference solver (decision 0002), loop selection with crossfade (#13), residual motion by optical flow (#17).
- 117 Live Photos from an iPhone 14 Pro (every clip is 1744x1308), exported one folder per photo. Two have no common region after warping, so no crop exists for them; they are counted as failures and shown as `unprocessable`.
- **Every contact sheet was looked at: all 115 that exist** (the two unprocessable clips produce none, so their cause comes from the error text). The cause column below comes from that review. Notes were written one batch at a time, after seeing the batch; any note written without a sheet in view was discarded and redone.
- Frame counts 8 to 88 (median 52), durations 0.27 to 3.03 s (median 1.97 s), frame rate 10 to 30 fps (variable; see PRD §8).

## Aggregate

| signal | threshold | min | p10 | p25 | median | p75 | p90 | max | clips failing |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| crop retention (%) | >= 60 | 0 | 37 | 61 | 78 | 87 | 91 | 97 | 29 of 117 (24.8%) |
| residual motion (px) (see caveat) | < 1.0 | 0.28 | 0.33 | 0.41 | 0.54 | 1.03 | 1.88 | 8.79 | 29 of 115 |
| loop seam (x median step) | <= 1.5 | 0.91 | 1.35 | 1.66 | 2.60 | 2.95 | 4.02 | 13.41 | 97 of 115 |

Clips passing all three thresholds: **10 of 117**. Estimation: 8 of 6,077 frames needed a step to be held (0.13%).

### Before and after #61 (same clips, same code, only the estimation strategy differs; 115 clips common to both runs)

| | direct to reference | chained (decision 0008) |
| --- | ---: | ---: |
| median residual motion | 3.34 px | 0.55 px |
| clips with residual at or above 1.0 px | 88 of 110 | 29 of 113 |
| median crop retention | 78.7% | 77.0% |
| clips below 60% crop retention | 37 of 115 (32.2%) | 29 of 117 (24.8%) |
| clips with no common area | 5 | 2 |

### Caveat: the residual-motion column is not stable across sessions (#72)

Crop retention and loop seam are exactly repeatable: re-running 17 of these clips hours later reproduced them to every printed digit. **Residual motion is not.** The same stabilized frames read **0.71x to 0.99x** of the values in this file when measured again (median 0.79x), because the optical-flow meter itself shifted; the stabilization did not. Rescaling this table by that range, the number of clips at or above 1.0 px would be between **17 and 29 of 115** instead of exactly 29, and the median would be between 0.38 and 0.54 px. The conclusions that survive: residual motion is far better than before #61 (3.3 px median), it is high only on the same kinds of clips that fail on crop (subject-dominated, moving background and platform, low light), and clips that look fine are almost all well under 1 px. The exact count of clips over the threshold is not reliable until #72 is resolved.

## The L1 gate (decision 0002, issue #21)

The gate, written before the numbers existed: build the L1 solver only if **median crop retention < 60%**, or **more than 25% of clips fall below 60%**.

- Median crop retention: **77.6%**. Not below 60%.
- Clips below 60%: **29 of 117 = 24.79%**. The trip point is 25% = 29.25 clips, so the margin is **0.25 of a clip**: one more clip below 60% would trip it. (Excluding the two unprocessable clips, 27 of 115 = 23.5%.)
- **Verdict: the gate does not trip, by the letter.** The margin is thin enough that it should be read together with the causes below.

What the 29 clips below 60% are (from the contact sheets):

| cause | clips below 60% |
| --- | ---: |
| excessive camera motion | 11 |
| subject dominates the frame | 8 |
| non-rigid moving background | 4 |
| moving platform (camera rides the scene) | 3 |
| unprocessable (no common area) | 2 |
| parallax (near subject over moving background) | 1 |

**No clip that looks fine is below 60%.** All 68 clips judged to look fine have crop retention of at least 60%, so the crop metric agrees with what a person sees. The loss is concentrated in footage no camera-path solver could fully rescue (a ride that carries the camera, a tunnel slide, a subject that fills the frame). Only the **11 excessive-camera-motion clips** are the textbook case for L1 (the stabilized view is steady but the crop shrinks because warp-to-reference needs every frame's visible area); L1 could plausibly recover part of those and nothing in the other categories.

## Failures by cause

All clips, by cause:

| cause | clips | crop < 60% | residual >= 1 px | seam > 1.5x |
| --- | ---: | ---: | ---: | ---: |
| subject dominates the frame | 17 | 8 | 12 | 16 |
| excessive camera motion | 11 | 11 | 2 | 9 |
| low light | 10 | 0 | 6 | 8 |
| non-rigid moving background | 5 | 4 | 4 | 4 |
| moving platform (camera rides the scene) | 3 | 3 | 3 | 1 |
| unprocessable (no common area) | 2 | 2 | 0 | 0 |
| parallax (near subject over moving background) | 1 | 1 | 1 | 0 |
| looks fine | 68 | 0 | 1 | 59 |

Residual motion also agrees with the eye: of the 68 clips that look fine, **1** is at or above 1.0 px (a scene dominated by low-texture floor). Of the 10 low-light clips, 6 fail residual motion, mostly where the exposure collapses to black partway through the clip, which leaves nothing to measure.

### The loop seam is the odd one out

Of the 68 clips that look fine, **59 fail the 1.5x loop-seam threshold** (median 2.47x, p90 3.53x). The seam measures how different the loop's last frame is from its first, in units of the typical frame-to-frame change. In a near-static scene the typical step is tiny, so any non-repeating motion (a child walking across a stable scene) is a large multiple of it, however good the loop point. The crossfade already helps (median 8.4x before, 2.5x after), and the threshold is still missed. **As written, this metric would flag most clips that look fine**, which is the false-positive problem issue #20 says belongs in a decision record. Raising the threshold to 3x would pass 55 of 68; at 4x, 65 of 68.

## Per-clip results

`cause` is from the contact-sheet review; `-` means nothing beyond the seam. `ref` is the reference frame's position in the clip.

| clip | frames | fps | ref | crop % | residual px | seam x | failing | cause |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| clip-001 | 45 | 26 | 84% | 90 | 0.34 | 1.2 | PASS | - |
| clip-002 | 86 | 30 | 48% | 78 | 0.41 | 3.5 | seam | subject dominates the frame |
| clip-003 | 86 | 29 | 49% | 46 | 1.16 | 1.3 | crop, residual | non-rigid moving background |
| clip-004 | 85 | 29 | 48% | 9 | 8.79 | 1.3 | crop, residual | moving platform (camera rides the scene) |
| clip-005 | 59 | 30 | 64% | 36 | 7.61 | 1.6 | crop, residual, seam | moving platform (camera rides the scene) |
| clip-006 | 84 | 28 | 48% | 77 | 0.38 | 1.5 | PASS | - |
| clip-007 | 16 | 28 | 20% | 93 | 0.42 | 1.5 | seam | - |
| clip-008 | 85 | 29 | 49% | 96 | 0.30 | 3.9 | seam | - |
| clip-009 | 55 | 29 | 19% | 87 | 0.62 | 2.9 | seam | - |
| clip-010 | 48 | 29 | 6% | 57 | 0.28 | 1.4 | crop | subject dominates the frame |
| clip-011 | 30 | 18 | 66% | 54 | 1.92 | 1.9 | crop, residual, seam | subject dominates the frame |
| clip-012 | 82 | 29 | 47% | 15 | 2.13 | 1.5 | crop, residual | excessive camera motion |
| clip-013 | 63 | 29 | 65% | 24 | 1.64 | 1.2 | crop, residual | excessive camera motion |
| clip-014 | 21 | 13 | 90% | 79 | 0.68 | 1.1 | PASS | low light |
| clip-015 | 81 | 29 | 49% | 88 | 0.39 | 2.6 | seam | - |
| clip-016 | 50 | 28 | 78% | 94 | 0.35 | 1.3 | PASS | - |
| clip-017 | 49 | 30 | 83% | 75 | 0.44 | 3.6 | seam | - |
| clip-018 | 56 | 29 | 76% | 71 | 1.03 | 3.2 | residual, seam | subject dominates the frame |
| clip-019 | 81 | 29 | 50% | 91 | 0.32 | 3.5 | seam | - |
| clip-020 | 49 | 29 | 83% | 91 | 0.30 | 3.0 | seam | - |
| clip-021 | 44 | 29 | 77% | 47 | 0.83 | 2.9 | crop, seam | subject dominates the frame |
| clip-022 | 32 | 15 | 84% | 72 | 1.03 | 1.6 | residual, seam | low light |
| clip-023 | 53 | 29 | 77% | 66 | 0.44 | 2.2 | seam | - |
| clip-024 | 60 | 30 | 69% | 64 | 0.38 | 3.3 | seam | - |
| clip-025 | 58 | 29 | 61% | 78 | 0.46 | 2.8 | seam | - |
| clip-026 | 85 | 29 | 50% | 43 | 0.62 | 2.5 | crop, seam | excessive camera motion |
| clip-027 | 54 | 29 | 75% | 75 | 0.37 | 2.3 | seam | - |
| clip-028 | 87 | 30 | 49% | 22 | 0.66 | 3.8 | crop, seam | excessive camera motion |
| clip-029 | 53 | 29 | 83% | 59 | 0.45 | 1.6 | crop, seam | excessive camera motion |
| clip-030 | 51 | 29 | 84% | 90 | 0.39 | 2.6 | seam | - |
| clip-031 | 44 | 28 | 100% | 92 | 0.39 | 2.6 | seam | - |
| clip-032 | 32 | 29 | 32% | 80 | 0.50 | 2.8 | seam | - |
| clip-033 | 26 | 29 | 60% | 89 | 0.44 | 3.7 | seam | - |
| clip-034 | 58 | 29 | 70% | 93 | 0.33 | 2.7 | seam | - |
| clip-035 | 54 | 29 | 79% | 81 | 0.41 | 2.8 | seam | - |
| clip-036 | 36 | 29 | 86% | 67 | 0.85 | 2.8 | seam | - |
| clip-037 | 51 | 29 | 80% | 84 | 0.43 | 1.7 | seam | - |
| clip-038 | 84 | 30 | 47% | 77 | 0.46 | 1.6 | seam | - |
| clip-039 | 57 | 29 | 75% | 74 | 0.54 | 1.4 | PASS | - |
| clip-040 | 51 | 29 | 72% | 54 | 0.62 | 2.1 | crop, seam | subject dominates the frame |
| clip-041 | 27 | 30 | 69% | 91 | 0.39 | 4.2 | seam | - |
| clip-042 | 58 | 29 | 74% | 67 | 0.42 | 2.4 | seam | - |
| clip-043 | 32 | 15 | 68% | 86 | 1.29 | 13.4 | residual, seam | low light |
| clip-044 | 31 | 15 | 70% | 96 | 0.68 | 3.0 | seam | low light |
| clip-045 | 76 | 29 | 59% | 71 | 0.69 | 2.7 | seam | - |
| clip-046 | 83 | 30 | 48% | 52 | 0.39 | 2.6 | crop, seam | excessive camera motion |
| clip-047 | 46 | 22 | 76% | 80 | 0.51 | 2.4 | seam | - |
| clip-048 | 37 | 22 | 72% | 73 | 0.87 | 2.7 | seam | - |
| clip-049 | 52 | 29 | 80% | 79 | 0.40 | 2.0 | seam | - |
| clip-050 | 58 | 29 | 63% | 35 | 2.46 | 1.4 | crop, residual | moving platform (camera rides the scene) |
| clip-051 | 44 | 29 | 98% | 92 | 0.28 | 1.4 | PASS | - |
| clip-052 | 0 | 0 | 0% | 0 | n/a | n/a | crop | unprocessable (no common area) |
| clip-053 | 0 | 0 | 0% | 0 | n/a | n/a | crop | unprocessable (no common area) |
| clip-054 | 86 | 28 | 51% | 32 | 1.88 | 2.9 | crop, residual, seam | non-rigid moving background |
| clip-055 | 82 | 28 | 47% | 36 | 1.94 | 2.8 | crop, residual, seam | non-rigid moving background |
| clip-056 | 74 | 29 | 56% | 60 | 1.58 | 2.7 | crop, residual, seam | non-rigid moving background |
| clip-057 | 81 | 28 | 51% | 86 | 0.89 | 5.5 | seam | non-rigid moving background |
| clip-058 | 41 | 23 | 78% | 69 | 1.97 | 2.0 | residual, seam | - |
| clip-059 | 50 | 29 | 84% | 93 | 0.32 | 1.7 | seam | - |
| clip-060 | 60 | 18 | 44% | 94 | 0.38 | 1.7 | seam | - |
| clip-061 | 56 | 20 | 40% | 83 | 0.64 | 1.6 | seam | - |
| clip-062 | 63 | 22 | 65% | 80 | 0.40 | 3.0 | seam | - |
| clip-063 | 63 | 22 | 44% | 89 | 0.37 | 2.2 | seam | - |
| clip-064 | 51 | 23 | 38% | 61 | 1.17 | 2.7 | residual, seam | subject dominates the frame |
| clip-065 | 26 | 12 | 84% | 79 | 0.57 | 1.3 | PASS | - |
| clip-066 | 49 | 29 | 83% | 80 | 0.33 | 2.6 | seam | - |
| clip-067 | 87 | 30 | 49% | 37 | 0.80 | 4.1 | crop, seam | excessive camera motion |
| clip-068 | 83 | 29 | 48% | 79 | 0.55 | 7.0 | seam | - |
| clip-069 | 86 | 30 | 48% | 59 | 0.52 | 2.8 | crop, seam | excessive camera motion |
| clip-070 | 78 | 29 | 55% | 61 | 0.55 | 3.6 | seam | - |
| clip-071 | 60 | 29 | 29% | 89 | 0.41 | 2.0 | seam | - |
| clip-072 | 51 | 28 | 82% | 80 | 0.43 | 2.6 | seam | - |
| clip-073 | 47 | 29 | 61% | 43 | 1.85 | 4.0 | crop, residual, seam | subject dominates the frame |
| clip-074 | 67 | 25 | 52% | 66 | 0.47 | 2.7 | seam | - |
| clip-075 | 49 | 29 | 79% | 75 | 0.42 | 3.4 | seam | - |
| clip-076 | 34 | 16 | 36% | 85 | 0.77 | 1.6 | seam | - |
| clip-077 | 26 | 15 | 16% | 78 | 1.15 | 1.3 | residual | low light |
| clip-078 | 36 | 13 | 60% | 84 | 1.24 | 4.2 | residual, seam | low light |
| clip-079 | 17 | 10 | 81% | 77 | 4.82 | 10.5 | residual, seam | low light |
| clip-080 | 17 | 10 | 81% | 97 | 1.36 | 5.5 | residual, seam | low light |
| clip-081 | 17 | 10 | 81% | 91 | 0.89 | 7.7 | seam | low light |
| clip-082 | 81 | 28 | 46% | 37 | 6.61 | 1.2 | crop, residual | parallax (near subject over moving background) |
| clip-083 | 25 | 29 | 46% | 77 | 0.63 | 2.4 | seam | - |
| clip-084 | 19 | 30 | 67% | 91 | 0.33 | 3.3 | seam | - |
| clip-085 | 61 | 30 | 70% | 65 | 0.44 | 2.8 | seam | - |
| clip-086 | 43 | 29 | 71% | 59 | 0.68 | 3.7 | crop, seam | excessive camera motion |
| clip-087 | 56 | 28 | 73% | 88 | 0.33 | 2.3 | seam | - |
| clip-088 | 88 | 30 | 49% | 50 | 0.55 | 2.9 | crop, seam | excessive camera motion |
| clip-089 | 73 | 25 | 56% | 88 | 0.42 | 1.6 | seam | - |
| clip-090 | 44 | 25 | 93% | 88 | 0.31 | 0.9 | PASS | - |
| clip-091 | 19 | 13 | 61% | 79 | 0.40 | 2.7 | seam | low light |
| clip-092 | 83 | 29 | 50% | 80 | 0.36 | 2.9 | seam | - |
| clip-093 | 50 | 29 | 24% | 59 | 0.40 | 2.2 | crop, seam | excessive camera motion |
| clip-094 | 88 | 30 | 49% | 31 | 6.84 | 2.8 | crop, residual, seam | subject dominates the frame |
| clip-095 | 48 | 25 | 77% | 75 | 0.41 | 2.8 | seam | - |
| clip-096 | 45 | 25 | 93% | 81 | 0.75 | 2.7 | seam | - |
| clip-097 | 54 | 18 | 53% | 83 | 0.79 | 1.8 | seam | - |
| clip-098 | 41 | 19 | 40% | 77 | 0.70 | 4.4 | seam | - |
| clip-099 | 43 | 16 | 52% | 80 | 0.61 | 1.5 | seam | - |
| clip-100 | 31 | 17 | 90% | 83 | 0.51 | 1.9 | seam | - |
| clip-101 | 19 | 22 | 83% | 91 | 1.10 | 2.4 | residual, seam | subject dominates the frame |
| clip-102 | 8 | 25 | 100% | 93 | 0.75 | 1.0 | PASS | - |
| clip-103 | 30 | 21 | 62% | 55 | 0.93 | 2.3 | crop, seam | subject dominates the frame |
| clip-104 | 46 | 25 | 84% | 58 | 1.65 | 2.1 | crop, residual, seam | subject dominates the frame |
| clip-105 | 53 | 29 | 81% | 62 | 0.31 | 2.9 | seam | - |
| clip-106 | 41 | 22 | 22% | 75 | 2.39 | 1.6 | residual, seam | subject dominates the frame |
| clip-107 | 69 | 30 | 34% | 83 | 1.42 | 2.2 | residual, seam | subject dominates the frame |
| clip-108 | 88 | 30 | 48% | 67 | 0.97 | 3.2 | seam | - |
| clip-109 | 67 | 23 | 59% | 82 | 1.09 | 5.6 | residual, seam | subject dominates the frame |
| clip-110 | 33 | 18 | 81% | 81 | 1.26 | 1.8 | residual, seam | subject dominates the frame |
| clip-111 | 26 | 13 | 80% | 90 | 0.53 | 1.9 | seam | - |
| clip-112 | 75 | 25 | 54% | 91 | 0.47 | 1.8 | seam | - |
| clip-113 | 72 | 25 | 56% | 92 | 0.46 | 3.0 | seam | - |
| clip-114 | 51 | 29 | 80% | 83 | 0.43 | 1.8 | seam | - |
| clip-115 | 84 | 30 | 47% | 76 | 0.47 | 1.6 | seam | - |
| clip-116 | 57 | 29 | 75% | 74 | 0.53 | 1.3 | PASS | - |
| clip-117 | 51 | 23 | 38% | 61 | 1.19 | 2.8 | residual, seam | subject dominates the frame |

## What this does not tell us

- Everything here is on a Mac. Preview latency, memory and on-device behaviour are #26.
- The set is one family's photos from one phone over a few weeks, with several scenes shot repeatedly (the same field, the same ride, the same table). Treat the percentages as a description of this set, not a population estimate.
- Loop quality was judged from metrics and contact sheets, never from watching the loops play.
