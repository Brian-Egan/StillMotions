// Rendering — turns corrections and a crop into pixels, and owns the stabilized frame cache.
//
//   StabilizedRenderer       Core Image warp + crop + scale, at any output size. Streams.
//   StabilizedFrameCache     Whole stabilized frames at preview size, read by index range and
//                            sub-rectangle with no re-render (ARCHITECTURE §5).
//   OutputSize               Even-dimension sizing for presets, shared with the encoders.
