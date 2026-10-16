# 0008. Estimate motion by chaining consecutive frames

- Status: **Accepted** (issue #61)
- Date: 2026-10-16
- Relates to: [0001](0001-motion-estimation.md), [0007](0007-registration-accuracy-bar.md)

## Context

Decision 0001 settled *which* estimator ships (Vision registration) and decision 0007 set its
accuracy bar on the synthetic clips, where every frame registered directly to the reference
agrees with ground truth to 0.1 to 0.35 px. The first run over 115 real Live Photos (#18) showed
that does not carry over: registering every frame **directly to the reference** is erratic on real
footage. Frames far from the reference (large displacement, a moved subject, an exposure change)
fall outside what registration converges on; each frame's error is independent, so the corrected
output jitters by the size of those errors, which is exactly what the residual-motion metric
measures. Per-frame estimates on a real clip jumped from scale 1.10 to 1.55 and back within a few
frames.

## Decision

**Chain consecutive frames.** Register each frame to its neighbour (a small, reliable step) and
compose the steps back to the reference: `T_i = step_i * T_(i-1)`, forward from the reference and
backward for the frames before it. `ClipAnalyzer.estimateMotion(strategy: .chained)` is the
default; `.reference` (direct) remains available, and the harness exposes both as
`--estimator registration` (chained) and `--estimator registration-direct`.

Details that matter:
- **A step must be plausible for neighbouring frames** (`ClipAnalyzer.stepPlausibility`: at most
  8 degrees, scale 0.8 to 1.25, translation 25% of the diagonal), far tighter than the whole-clip
  bounds. Neighbouring frames cannot differ by half in scale.
- **A step that fails assumes no motion** (identity). Reusing the previous step would extrapolate
  through a blackout and could run away over several bad frames. Failures are counted and
  reported, never hidden.
- Frames are estimated at 960 px on the long edge (decision 0001), each transform scaled back to
  native pixels.
- **Memory:** backward chaining needs the (scaled) frames before the reference, because decoding
  only runs forward: about 3 MB a frame at 960 px, the reference being usually mid-clip.

## Evidence

Over the personal fixtures (115 clips common to both runs, reference frame from the Live Photo's
own marker, #59), same code, only the strategy differs. Numbers only; the photos stay private.

| | direct | chained |
| --- | ---: | ---: |
| median residual motion | 3.34 px | **0.55 px** |
| residual p90 | 14.8 px | **1.9 px** |
| clips with residual at or above 1.0 px | 88 of 110 | **29 of 113** |
| median crop retention | 78.7% | 77.0% |
| clips below 60% crop retention | 37 (32.2%) | **29 (25.2%)** |
| frames where estimation failed | 102 of 5879 (1.73%) | **8 of 6077 (0.13%)** |
| clips with no common area to crop to | 5 | **2** |
| median loop seam | 1.77x | 2.60x |
| clips passing all three thresholds | 10 | 10 |

Paired per clip, chained has lower residual motion on **106 of 108**. Crop retention is mixed
(better by more than 5 points on 30 clips, worse by more than 5 on 26).

On the synthetic fixtures chaining stays inside the §1.4 tolerance of the committed baseline
(median crop 96.1% to 95.7%; residual motion improves, 0.170 to 0.118 px).

## The cost: drift, and where it comes from

Chaining trades jitter for **drift**: error accumulates along the chain, so recovered-versus-truth
error on the synthetic clips grows to 1 to 8 px by frame 89, against 0.1 to 0.35 px for direct.
Measured by regressing estimated against true single steps (synthetic clips, 960 px):

- Steps of about **2 px and larger are unbiased** (`translate-shake`, mean step 4.7 px: slope
  1.003). Genuine handheld shake is mostly this.
- Steps **below about 2 px are under-estimated by roughly 0.15 to 0.3 px each** (slopes 0.72 to
  0.84 on the 0.3 to 0.45 px steps of the slow pans). Slow, smooth motion therefore loses a little
  every frame. Estimating at native resolution reduces it (0.72 to 0.84) but does not remove it.

So the worst drift is on the slow synthetic pans and the smooth sinusoid of `periodic`
(worst measured 0.23 px per frame). It is an *absolute offset that grows slowly*, not jitter, so
the residual-motion metric (a frame-to-frame measure) is unaffected, and the crop is computed from
the estimated path so it cannot show black edges. The tests bound drift at 0.3 px per frame and
10 px in total.

## What would change this

- **Drift proves visible** on real clips (slow creep in a stabilized output): chain over a short
  hop (frame `i` to frame `i-k`, k of 3 to 6) so each hop's motion clears the 2 px floor and the
  composition has k times fewer steps; or anchor to the direct estimate with a slow complementary
  filter. Not built, because nothing yet shows it is needed.
- **Vision fixes the small-motion bias**, or the plausibility bounds prove too tight on real
  fast pans (the failure count would show it).
- The 26 clips whose crop got worse deserve a look in #18; if they point at a systematic cause
  (for example the first step after a blackout), it belongs here.

## Rejected alternatives

**Keep direct estimation and smooth the result.** Smoothing the corrected path would also smooth
away the signal: the direct estimates are wrong, not merely noisy, on the frames that matter.

**Optical flow for the steps.** Flow is accurate at small displacements (decision 0001), which is
the regime of a step, but costs about 5x as much per frame and does not run on CI. Registration
steps are cheap enough that chaining adds little over direct estimation.
