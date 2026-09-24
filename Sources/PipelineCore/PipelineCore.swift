// PipelineCore — shared value types and protocols for the pipeline.
//
// EMPTY BY DESIGN. The planning session writes no feature code.
//
// This module owns the vocabulary every other stage depends on: Correspondence,
// FrameMotion, CameraPath, MotionEstimator, CameraPathSolver, frame and clip
// descriptors, the metrics types, and the failure-signal definitions.
//
// The protocol shapes are specified in docs/ARCHITECTURE.md §4. Read that before
// implementing — FrameMotion.inlierRatio is deliberately Optional, and the reason
// matters (docs/decisions/0001-motion-estimation.md).
//
// Constraint (PRD R-24): no UIKit, no SwiftUI, no PhotoKit. Foundation, CoreVideo,
// CoreGraphics, and simd only. This module must compile on macOS.
