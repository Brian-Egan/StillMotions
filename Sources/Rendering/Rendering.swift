// Rendering — warps frames and streams them to an encoder.
//
// EMPTY BY DESIGN. The planning session writes no feature code.
//
// Applies the CameraPath corrections and the crop, at either preview resolution (720 px
// long edge, for the editor cache) or export resolution. Core Image or Metal; whichever
// meets the 2.0 s preview budget on the iPhone 14 Pro (PRD §1.3).
//
// Frames are streamed, one at a time. A full-resolution 3 s Live Photo is roughly 90
// frames at tens of megabytes each uncompressed, so the frame set is never resident.
//
// This module also owns the stabilized frame cache that makes crop, trim, and frame-rate
// changes free in the editor. See docs/ARCHITECTURE.md §5 — the cache is the reason the
// editor feels instant, and the reason a re-solve never blanks a working preview.
