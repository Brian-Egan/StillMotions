// HarnessCLI — the stillmotions-harness executable.
//
// EMPTY BY DESIGN. The planning session writes no feature code.
//
// A macOS CLI that processes a fixture folder and writes, per clip: the exported GIF and
// MP4, a before/after contact sheet, and a metrics JSON — plus an aggregate summary.
// Then compares the aggregate against harness/baseline.json (PRD R-22, R-23).
//
// Planned interface, as referenced by scripts/verify.sh:
//
//   stillmotions-harness --fixtures <dir> --out <dir> [--baseline harness/baseline.json]
//                        [--estimator registration|flow] [--solver warp|l1]
//                        [--update-baseline]
//
// Exits non-zero when the regression check fails, which is what gates auto-merge.
//
// The contact sheets exist so the build agent LOOKS AT THE OUTPUT when tuning rather than
// trusting the numbers. A clip can pass all three thresholds and still look wrong.
