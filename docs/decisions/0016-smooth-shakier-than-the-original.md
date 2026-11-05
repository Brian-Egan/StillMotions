# 0016. Smooth sometimes makes a clip shakier than the original: evidence, and a guard that needs a decision

- Status: **Proposed** (issue #102). The measurements are done; the change itself needs the developer's call, for the reasons under "What is not decided".
- Date: 2026-11-05
- Relates to: [0009](0009-failure-signals.md), [0011](0011-stabilization-modes.md), [0013](0013-smooth-ends-and-pan-heavy-clips.md), [0015](0015-rejected-motion-estimates.md)

## Context

"Smooth never adds jitter relative to Off" was a #98 criterion, and 0013 reported that it is not met: on about
one clip in ten the stabilized picture shakes more than the clip as shot. Everything below is numbers on the 115
personal clips with enough shake to measure (jitter of the picture as shot above 0.05 px at 180x240), jitter
measured on the RENDERED frames by phase correlation over a 0.3 s window (0013), Smooth at strength 12.

## How big the problem is

Smooth is shakier than Off on **11 of 115 clips**: by 0.02 to 0.10 px on six (not something anyone would see) and
by 0.16, 0.22, 0.24, 0.27, 0.46 and 0.47 px on five. The worst is 2.64 times the original's jitter; the
original's own jitter on those five is 0.27 to 1.3 px. Locked has the same problem on 6 of 113.

## Why: the estimate's noise

The output is the smooth path minus the estimate's error, so a correction removes the real shake and adds the
estimator's noise (0013, 0015). When the real shake is small next to that noise, correcting makes it worse.
The share of steps the estimator rejected (0015) does NOT predict it: only 5 of the 11 clips have any rejected
step, and the median share is 0% both for the clips that got worse and for those that did not.

## Two ways of fixing it were tried and one worked

1. **Scale every clip's correction by the ideal amount** (leftover jitter `sqrt((1-s)^2 a^2 + s^2 b^2)` is least at
   `s = a^2 / (a^2 + b^2)`, for real shake `a` and estimate noise `b`, taken from the picture's jitter without and
   with the correction). It predicts every clip ends no worse than Off and the median improves from 0.372 to
   0.349. **Measured, it does not hold:** the median goes to 0.408 (worse), because on the typical clip what is
   left after smoothing is slow real shake, which is correlated with the shake that was removed, so the
   independence the formula assumes is false. It does repair the worst clips (0.76 to 0.29 against 0.29 as shot),
   but 9 of the 11 stay slightly worse than the original and one gets worse than before (0.32 to 0.54 against 0.27).
2. **Only act when the stabilized picture measures shakier than the original, and then show the original.**

| | worse than Off | worst case | median jitter vs Off | median crop |
| --- | ---: | ---: | ---: | ---: |
| today | 11 | 2.64x | 0.372 | 92.4% |
| fall back to damped correction | 9 | 2.03x | 0.372 | 93.5% |
| **fall back to Off** | **0** | **1.00x** | **0.372** | **94.1%** |

The fallback to Off removes every case, changes nothing for the 104 clips Smooth helps, and keeps more of the
frame. (It cannot do worse than Off on the instrument it uses; whether a viewer agrees is the developer's A/B
to judge.) `stillmotions-harness policy-study` prints this summary at the end of a run.

## What is not decided

Doing this in the app needs the app to MEASURE the pictures: gray frames of the source and of the stabilized
preview, phase-correlated (the harness has the code in `OutputMotion`), once for the original and once per
stabilization, about 76 small FFTs each. That raises choices that are not mine to make silently:

- **Cost.** It adds time on open and on every stabilization switch. On this Mac the measurement pass is about a
  second per variant; **the phone's figure is unmeasured**, and the preview budget is 2 s (PRD §1.3).
- **Override or warn.** Falling back to Off overrides the mode the person chose; the alternative is to keep their
  mode and say so ("Smooth made this clip shakier than it was shot; Off may look better").
- **Decision 0009.** It kept jitter-style signals out of the in-app warning (they gave false alarms). This one is
  different (it compares the picture with its own original, not with a threshold), but it reopens the question.
- **Locked.** The same rule would apply to it.

## Decision

**No app change yet.** Recorded: the evidence, the rule that works (fall back to Off when the stabilized picture
measures shakier than the original), the ones that do not (per-clip damping), and the questions above. #102 stays
open for the developer's answer. The harness summary is added so the numbers can be reproduced.

## What would change this

- The phone's measured cost of the measurement pass. If it is a few hundred milliseconds it is cheap enough; if
  it is a second or more it would have to run after the first frame is shown.
- A better estimate (0015) making the problem smaller.
