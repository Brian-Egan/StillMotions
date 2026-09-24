// Encoding — GIF via gifski, video via AVAssetWriter.
//
// EMPTY BY DESIGN. The planning session writes no feature code.
//
//   GIF   gifski through its C API, for per-frame palettes and temporal dithering.
//         ImageIO's GIF encoder is explicitly not used — a single global palette is the
//         source of the banding gifski exists to avoid.
//         GifskiSettings.repeat = 0 for infinite loop.
//         gifski_set_write_callback streams output, so peak memory is flat in clip length.
//
//   MP4   AVAssetWriter, HEVC, source frame rate.
//         NO loop flag is written. None exists that Apple platforms honour — see
//         docs/decisions/0005-looping-export.md.
//
// Mode matrix (PRD R-10). Loop is GIF-only:
//
//            GIF    MP4
//   loop     yes    no
//   bounce   yes    yes     (a palindrome plays through once; needs no player cooperation)
//   once     yes    yes
//
// gifski reaches Swift via Sources/CGifski, a module map over Vendor/Gifski.xcframework
// built by scripts/build-gifski.sh. Both the binaryTarget and this module's dependency on
// it are commented out in Package.swift until that script has been run — SwiftPM cannot
// load a manifest whose binaryTarget path is missing.
