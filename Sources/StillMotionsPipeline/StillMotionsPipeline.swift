// StillMotionsPipeline — the public façade.
//
// EMPTY BY DESIGN. The planning session writes no feature code.
//
// The only module the app may import. Everything else in Sources/ is implementation
// detail, so the pipeline's internals can be restructured without touching app code.
//
// The app and the harness both call through here. That is deliberate and load-bearing:
// it is what makes headless quality measurement meaningful, because the harness exercises
// the shipping pipeline rather than a parallel implementation (PRD R-22).
//
// Expected surface: a clip descriptor in, a stabilized result plus metrics out, with the
// estimator and solver injectable so the spike and the conditional L1 work are
// configuration rather than forks.
//
// Constraint (PRD R-24): no UIKit, no SwiftUI, no PhotoKit. PhotoKit access lives in the
// app and adapts into this module's file-based input.
