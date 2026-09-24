// MotionEstimation — per-frame transforms onto the reference frame.
//
// EMPTY BY DESIGN. The planning session writes no feature code.
//
// Two implementations of MotionEstimator are planned:
//
//   VisionRegistrationEstimator  TrackHomographicImageRegistrationRequest.
//                                Cheap, one call per pair, returns a warpTransform with
//                                no correspondences and no measurable inlier ratio.
//
//   OpticalFlowEstimator         TrackOpticalFlowRequest sampled on a grid, then RANSAC.
//                                Produces correspondences, so it supports outlier
//                                rejection, subject masking, and the residual-motion
//                                metric. Apple documents it as "very resource intensive".
//
// WHICH ONE SHIPS IS NOT YET DECIDED. It is settled by the phase-1 spike, which measures
// cost on the iPhone 14 Pro and accuracy against the synthetic fixtures, then updates
// docs/decisions/0001-motion-estimation.md with numbers. The decision rule is written
// down there in advance. Do not pick one before running the spike.
//
// Subject masking (PRD R-6) lives here: GeneratePersonSegmentationRequest and
// GenerateForegroundInstanceMaskRequest. Vision has no animal-specific segmentation
// request, which is why foreground-instance masking covers pets.
