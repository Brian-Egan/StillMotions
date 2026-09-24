// CameraPath — solves for the virtual camera and the crop valid across all frames.
//
// EMPTY BY DESIGN. The planning session writes no feature code.
//
//   WarpToReferenceSolver   Ships in phase 1. Warps every frame onto the reference, then
//                           takes the largest axis-aligned rectangle valid in every
//                           warped frame, preserving source aspect ratio. Perfectly still
//                           camera; the worst single frame sets the crop for the clip.
//
//   L1OptimalSolver         CONDITIONAL. Built only if the crop-retention gate trips on
//                           personal fixtures: median below 60%, or more than 25% of clips
//                           failing. See docs/decisions/0002-camera-path-solver.md — the
//                           gate is the issue's first acceptance criterion, and the issue
//                           is closed as not-needed if it does not trip.
//
// The reference frame defaults to the key photo's timestamp, which is usually mid-clip
// rather than at an end. That halves worst-case drift versus referencing frame 0 and is
// free. Do not change it without measuring.
