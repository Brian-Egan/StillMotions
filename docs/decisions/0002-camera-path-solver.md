# 0002. Camera path: warp-to-reference baseline, L1-optimal gated on evidence

- Status: Accepted (L1 conditional, see "Gate")
- Date: 2026-09-24
- Relates to: PROJECT_BRIEF.md §4.2 step 3, §11 Q1; docs/PRD.md "Crop retention"

## Context

Two ways to define the virtual camera.

**Warp-to-reference.** Pick one frame as reference (default: the Live Photo's key photo
timestamp). Warp every other frame onto it. The camera is then perfectly, absolutely
still — the tripod look that is the product thesis. The crop must be the largest
axis-aligned rectangle valid in *every* warped frame, so the worst single frame sets the
crop for the whole clip. A clip that drifts steadily for 3 seconds, or has one lurch near
the end, gets punished hard.

**L1-optimal path** (Grundmann, Kwatra, Essa, CVPR 2011 — the approach behind both
MotionStills and YouTube's stabilizer). Instead of forcing the camera to one pose, solve
for a *smooth* path: prefer static, allow constant velocity, allow constant acceleration,
minimising the L1 norm of the derivatives subject to the crop window staying inside the
frame. Output looks professionally shot rather than locked, and retains substantially
more of the frame because the crop window is allowed to travel.

The relevant asymmetry for this product: **clips are about 3 seconds.** Cumulative drift
over 3 seconds of handheld is bounded in a way it is not over 30 seconds. Warp-to-
reference may therefore be entirely adequate here even though it would be unusable for
general video stabilization. That is an empirical question about this developer's actual
photos, not something to reason about from first principles.

L1 is also the single largest discrete chunk of effort in the project: it needs a linear
program (the objective is L1, so it linearises), a solver, per-frame crop-containment
constraints, and tuning of three derivative weights.

## Decision

Ship **warp-to-reference** in phase 1, behind a protocol:

```swift
public protocol CameraPathSolver {
    /// Given per-frame motion relative to the reference, return the corrective
    /// transform to apply to each frame, plus the crop valid across all of them.
    func solve(motion: [FrameMotion], frameSize: CGSize) throws -> CameraPath
}

public struct CameraPath {
    public let corrections: [simd_float3x3]
    public let crop: CGRect
    /// crop.area / frameSize.area, in 0...1
    public let cropRetention: Double
}
```

Implement `WarpToReferenceSolver` now. `L1OptimalSolver` is a conditional phase-2 issue.

## Gate

The L1 issue is **not** unconditional work. Its first acceptance criterion is to run the
harness against the personal fixture set and read the aggregate. Implement L1 only if
either holds:

- **median crop retention < 60%**, or
- **more than 25% of clips** fall below the 60% crop-retention threshold.

If neither holds, the build agent closes the issue as not-needed, with the aggregate
numbers in the closing comment, and moves on. That comment is the permanent record of
why the project does not have an L1 solver.

The gate is expressed in the harness aggregate the agent can read directly, so no
judgement call is required.

## Consequences

- Phase 1 is meaningfully smaller and reaches a working end-to-end pipeline sooner,
  which matters because the encoders and harness cannot be validated until something
  produces stabilized frames.
- If the gate trips, L1 lands in phase 2 *after* the baseline established a regression
  baseline — so L1's improvement is measurable rather than asserted. This is strictly
  better than building L1 first, where there would be nothing to compare against.
- Manual crop override (phase 4) partially compensates for a poor automatic crop
  regardless of which solver ships, which lowers the stakes on this decision.
- The reference frame defaults to the key photo timestamp, which means it is usually
  near the middle of the clip rather than at an end. This halves worst-case drift
  compared to referencing frame 0, and is free. Do not change it without measuring.

## Rejected alternatives

**L1 unconditionally in phase 2.** Highest quality ceiling and matches MotionStills.
Rejected as speculative effort: for 3-second clips the baseline may clear the bar, and
the harness can tell us for a fraction of the cost. The gate preserves the option at the
price of one harness run.

**Warp-to-reference only, never L1.** Lowest effort. Rejected because crop retention is
precisely the dimension MotionStills was good at, and shipping a visibly tighter crop
than the app being replaced would undercut the project's reason to exist. The gate is
cheap insurance against that outcome.

**Smoothed-path heuristic** (low-pass filter the motion instead of solving an LP).
Much cheaper than L1 and better than nothing. Rejected as a middle option that is hard
to reason about: it has no crop-containment guarantee, so it can smooth the path into a
position where no valid crop exists, and then needs ad-hoc clamping. If the baseline is
insufficient, solve the actual problem.

## What would change this

- Median crop retention on personal fixtures below 60%: trips the gate, L1 gets built.
- Fixtures turning out to be mostly walking rather than standing shake: walking produces
  steady translation, the case where warp-to-reference is weakest, and would likely trip
  the gate.
- A future need for longer clips: warp-to-reference does not scale past a few seconds and
  the decision would have to be revisited wholesale.
