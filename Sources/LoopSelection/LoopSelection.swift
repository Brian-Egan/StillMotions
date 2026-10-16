// LoopSelection — finds the least-visible loop point and hides the seam.
//
// LoopSelector searches frame pairs near the clip ends for the minimum difference, then plans
// a short crossfade across the seam. It reports the loop-seam metric: seam difference relative
// to the median consecutive-frame difference, which must be at or below 1.5x (PRD §1.2).
//
// Skipped entirely in Bounce and Once modes — a palindrome has no seam, and a single pass
// has no join.
//
// It works on FrameSignatures (tiny grayscale pictures of the stabilized, cropped frames),
// not pixels, and returns a recipe for the renderer to apply (see LoopFrameRecipe).
