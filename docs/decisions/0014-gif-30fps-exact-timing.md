# 0014. A 30 fps GIF rate, written with exact timing

- Status: **Accepted** (issue #99)
- Date: 2026-11-04
- Relates to: [0005](0005-looping-export.md), PRD §1.1

## Context

The developer prefers how motion looks in Google's MotionStills GIF, which plays at about 30 fps: on the
reference clip it has 76 frames, a 30 ms delay on 74 of them, and a total of 2.35 s for a clip shot over
2.58 s. This app offered 16.67, 20 and 25 fps. They were chosen because a GIF stores each frame's delay in
whole centiseconds, so a rate is exact only when its frame time is a whole number of them (6, 5 and 4 cs).
30 fps is 3.33 cs.

## Options

1. **Flat 3 cs, as MotionStills wrote.** Every frame is 30 ms, so the GIF plays at 33.3 fps: about 11% fast,
   and a clip of 90 frames lasts 2.7 s instead of 3.0 s. Motion reads as faster than it was.
2. **A mix of 3 and 4 cs that averages 3.33.** The speed is right. Every delay is a legal GIF value (the
   decoders that clamp very short delays, below 2 cs, do not touch 3 or 4).

## Decision

**Option 2**, offered as a fourth rate next to 16.67, 20 and 25. This is a stabilization app, and playing a
clip faster than it was shot makes shake look worse and motion look hurried, which is the opposite of what
the user is trying to fix. The flat-3 cs version is deliberately not offered; it can be added if the
developer prefers how it looks, and the cost is known.

## How the delays come out

`GifEncoder` gives gifski an exact presentation time per frame (`GifFrameRate.presentationTime(ofFrame:)`:
`n / 30` s at 30 fps, an exact multiple of a centisecond for the other rates). gifski turns times into
delays by rounding the RUNNING TOTAL, `round(end time x 100)` less the delays already written, not each
frame on its own, so the error never accumulates: the delays are a repeating 3, 4, 3. A test reads them
back out of the written file (`3, 4, 3, 3, 4, 3, 3, 4, 3`) and checks that 90 frames last 3.00 s.

## Consequences

- `GifFrameRate.centiseconds` (an integer) became `averageCentiseconds` (3.33 for 30 fps) and
  `delaysWritten` (the set of delays actually in the file).
- Preview and export agree: `PlaybackPlan` already steps at `1 / framesPerSecond` and uses the exporter's
  decimation, and the existing test that holds them equal now covers 30 fps.
- A 30 fps GIF has 1.5 times the frames of 20 fps, so it is larger. The size estimate was re-checked at the
  new rate (see the PR for #99).
- **Not verified here, and only testable on a phone:** that Messages plays and loops a GIF with mixed 3 and 4
  cs delays correctly. Every GIF decoder should honour per-frame delays, but this is the one place a
  surprise could be. It goes on the device checklist.

## What would change this

- Messages or Photos mishandling mixed delays: fall back to flat 3 cs, or to a rate that is a whole number
  of centiseconds.
- The developer preferring MotionStills' exact 30 ms look despite the speed-up.
