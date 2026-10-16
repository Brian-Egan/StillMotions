# 0004. gifski built from source into an xcframework

- Status: Accepted
- Date: 2026-09-24
- Relates to: PROJECT_BRIEF.md §4.5, §11 Q3, §10; docs/ARCHITECTURE.md "Encoding stack"

## Context

GIF output quality is the highest encoding priority in the brief, and ImageIO's GIF
encoder is explicitly ruled out. gifski gives per-frame palettes and temporal dithering,
which is the entire reason GIFs from it do not band.

Current state, verified: the repo is active (last push June 2026, crate 1.34.0), and
`gifski.h` exposes the full C API — `gifski_new`, `gifski_add_frame_rgba`,
`gifski_set_file_output`, `gifski_set_write_callback`, `gifski_finish`, plus quality
controls `gifski_set_motion_quality`, `gifski_set_lossy_quality`,
`gifski_set_extra_effort`. `cargo build --release --lib` produces `libgifski.a`, and
upstream recommends static linking.

Two constraints shape the integration:

**The pipeline package must build on macOS via `swift build`.** The harness is a macOS
CLI in the same package, and it encodes GIFs. So gifski must be reachable from SwiftPM,
not only from Xcode. This rules out upstream's recommended approach — adding
`gifski.xcodeproj` as an Xcode subproject and linking `gifski-staticlib` — because that
serves the app target and does nothing for `swift build`.

**Both device and simulator slices are needed**, plus macOS. A single fat static library
cannot contain both `aarch64-apple-ios` and `aarch64-apple-ios-sim`; that collision is
exactly what `.xcframework` exists to resolve.

The `video` cargo feature must stay off. It requires ffmpeg 6.x and libclang with system
headers, drags in codec licensing, and is unnecessary: AVFoundation decodes, and gifski
is fed raw RGBA frames.

License is AGPL-3.0-or-later. The brief states licensing is not a constraint, which holds
for this project: the app is installed directly to the developer's own iPhone from Xcode,
which is not conveying to a third party. If the app were ever distributed further, a commercial
license from the author would be required — noted here so the constraint is not
rediscovered later.

## Decision

`scripts/build-gifski.sh`, committed, is the single source of truth. It:

1. Verifies `cargo` is present and fails with the rustup install command if not.
2. Adds targets `aarch64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`.
3. Builds `libgifski.a` for each with `--release --lib`, default features only.
4. Writes a `module.modulemap` alongside `gifski.h` so the static library is importable
   as a Clang module named `CGifski`.
5. Assembles `Vendor/Gifski.xcframework` via
   `xcodebuild -create-xcframework -library … -headers …` per slice.
6. Prints the resulting slice list so the build log shows what was built.

Package.swift consumes it as a binary target:

```swift
.binaryTarget(name: "CGifski", path: "Vendor/Gifski.xcframework")
```

`Vendor/Gifski.xcframework` is **gitignored**. The script is the artifact of record.

Intel slices (`x86_64-apple-ios`, `x86_64-apple-darwin`) are deliberately omitted. The
build machine and the target device are both Apple silicon. Adding them later is one line
each.

Rust installation is a `human` issue in phase 0 (it also covers Xcode and XcodeGen), and
it blocks the gifski build issue in phase 1.

## Consequences

- The build machine needs Rust. This is a one-time rustup install, and the script fails loudly
  with the exact command if it is missing, so the failure is self-explanatory. The xcframework is
  built once and reused, so the cost is not per-verification.
- gifski version bumps are deliberate: change the pinned version in the script, re-run,
  check harness metrics for size and quality drift. Pinning is required, not optional —
  an unpinned encoder makes the regression baseline meaningless.
- Nothing large enters git history. This matters because the repo becomes public at the
  end of the build (see docs/RUNBOOK.md), and history is exposed in full at that point.
- `gifski_set_write_callback` lets the encoder stream output instead of writing only to a
  file path, which keeps peak memory flat for long clips.

## Rejected alternatives

**Commit the prebuilt xcframework.** Removes the Rust dependency and the human blocker
entirely. Rejected because it puts tens of megabytes of binary into history that becomes
public later, and because updating gifski degrades into a manual step nobody remembers to
do. The one-time rustup install is a smaller cost.

**`gifski.xcodeproj` as an Xcode subproject** (upstream's recommendation). Correct for an
app-only integration and needs no script. Rejected because it does not serve
`swift build`, and the harness — the entire quality measurement apparatus — lives in the
package.

**`XMLHexagram/GifskiFramework` SwiftPM wrapper.** Would be zero work. Rejected on
maintenance: last pushed December 2023, 9 stars, ships a binary predating current gifski
releases by over two years. The wrapper's MIT license also does not change the AGPL terms
of the gifski binary it links, so it buys nothing legally either.

**`cargo-lipo`.** Appears in older gifski documentation and is gone from the current
README. Cannot express the device/simulator split, which is the actual problem.
Superseded by `-create-xcframework`.

**ImageIO's GIF encoder.** Ruled out by the brief, and correctly: a single global palette
per GIF is the source of the banding gifski exists to avoid.

## Integration findings (#16)

Facts learned wiring the C API, which the next reader should not have to rediscover:

- **gifski silently downsizes large frames unless told the output size.** With
  `GifskiSettings.width`/`height` left at 0, the library scales any frame much bigger than about
  800x600 pixels of area down by an integer factor (`dimensions_for_image` in `src/lib.rs`:
  factor = round(sqrt(w*h / 480000))). A 1880x1056 frame came out 940x528, which would have turned
  the Full preset into half size, while Small and Medium were unaffected and so hid it. The encoder
  therefore creates the gifski handle at the first frame and passes that frame's own width and
  height.
- **Frame delay comes from presentation timestamps, in seconds**, not from a per-frame delay
  argument. Frame n is given PTS `n * centiseconds / 100`, an exact centisecond multiple, and every
  frame (the last included) is read back from the file as exactly 6, 5 or 4 cs.
- **Frames must be RGBA**; Core Video's are BGRA, so each frame is permuted with vImage on the way in.
- **Callbacks must be installed before the first frame is added**, or `gifski_add_frame_*` blocks
  forever. The write callback runs on another thread, so the file sink takes a lock.
- **`gifski_finish` must always be called**, including on cancellation and errors, or it leaks.
- **Looping:** Loop and Bounce write `repeat = 0` (forever); Once writes `repeat = -1`, which
  emits no NETSCAPE extension at all (parsed from the bytes in the tests).
- **Quality check (looked at, not just measured):** the same 60 stabilized `moving-subject` frames
  at 720 px through gifski (quality 90) and through ImageIO's single-palette encoder. In the dark
  gradient background ImageIO shows faint radial contour streaks (banding); gifski shows a fine
  dither texture and no contour steps. gifski's file was 703 KB against 1,578 KB.

## What would change this

- Upstream publishing an official xcframework or SwiftPM package: drops the script.
- Needing to distribute beyond the developer: forces the commercial license question.
- Needing Intel simulator support: two added targets in the script.
