// LoopSelection — finds the least-visible loop point and hides the seam.
//
// EMPTY BY DESIGN. The planning session writes no feature code.
//
// Searches frame pairs near the clip ends for the minimum difference, then applies a short
// crossfade across the seam. Reports the loop-seam metric: seam difference relative to the
// median consecutive-frame difference, which must be at or below 1.5x (PRD §1.2).
//
// Skipped entirely in Bounce and Once modes — a palindrome has no seam, and a single pass
// has no join.
