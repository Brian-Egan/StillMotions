# 0005. Looping is GIF-only; loop is a property of content, not the container

- Status: Accepted
- Date: 2026-09-24
- Relates to: PROJECT_BRIEF.md §4.3, §4.5, §11 Q5; docs/PRD.md "Export formats and modes"

## Context

The brief lists three export formats — GIF, looping MP4/HEVC, and non-looping MP4/HEVC —
and asks how to make the looping variant actually loop in destinations like iMessage.

Research found **no supported mechanism**. Specifically:

**MP4/ISO-BMFF has no loop flag.** The container defines no such field. Looping on Apple
platforms is a player concern, which is why the API is `AVPlayerLooper` — in-app only, and
travels with nothing you send.

**The QuickTime `LOOP` atom is real but out of scope for this.** Apple documents it under
user data atoms:

> `'LOOP'` — Long integer indicating looping style. This atom is not present unless the
> movie is set to loop. Values are 0 for normal looping, 1 for palindromic looping.

Two documented limits make it near-useless here: it is only interpreted when the `udta`'s
parent is `moov`, and it belongs to the group of atoms that control how **QuickTime**
displays a movie — classic QuickTime Player, not AVFoundation and not Messages. The
popular claim that writing this atom makes iMessage loop a video traces to a single 2017
developer-forum post where the asker never confirmed it worked, and the follow-ups are
people guessing at `AVMutableMetadataItem` because no `AVMetadataKey` constant for `LOOP`
exists. Treat as unverified-to-false.

**Animated HEIC is not an option.** `.heics` decodes on iOS but encoding frame timing is
broken: `kCGImagePropertyHEICSDelayTime` is silently dropped on write, so frame duration —
let alone loop count — cannot be controlled. Nothing indicates Messages animates it
inline either.

**GIF loops in iMessage.** This is the one behaviour with consistent long-standing
evidence, and gifski exposes it as a single field: `GifskiSettings.repeat`, where `0`
means loop forever. The ecosystem's own tell is that WhatsApp and Viber convert Live
Photo Loop/Bounce to GIF in their share extensions.

**A testing trap worth recording.** iOS 18+ Photos has a **Loop Videos** setting, on by
default. A plain MOV therefore appears to loop in Photos while doing nothing of the sort
in Messages. This is almost certainly the origin of the "my video loops, why not in
iMessage" confusion, and it will mislead on-device verification unless the tester knows
about it. The phase-5 verification issue must call it out explicitly.

## Decision

**Loop becomes a property of the content, not a container flag.** Loop mode means the clip
is trimmed to the best loop points and crossfaded, so it is seamless whenever any player
repeats it. Nothing is written into the file to request looping, because nothing would
honour it.

Export formats reduce from three to two, and modes are per-format:

| Mode | GIF | MP4/HEVC |
| --- | --- | --- |
| Loop | yes (`repeat = 0`) | **no** |
| Bounce | yes | yes |
| Once | yes | yes |

Bounce is offered for MP4 because a forward-then-reversed clip is a **palindrome in the
content itself** — it plays through once and needs no player cooperation. Loop is the only
mode that genuinely requires the player to repeat, so it is GIF-only.

The editor shows all three modes and disables MP4 when Loop is selected, with a one-line
reason rather than a silently greyed control.

A `human` issue in phase 5 runs the empirical check: write the `LOOP` atom into a `.mov`,
send it via iMessage and AirDrop, and record what happens — with **Loop Videos turned off
in Photos settings first**, so the observation is real. If it turns out to work, this
record gets amended and a looping-MP4 export can be added. Until then the record cites
evidence rather than folklore.

## Consequences

- One fewer export format, one fewer encoder path, and a smaller export UI.
- The GIF is the shareable looping artifact. That is the correct emphasis anyway, since
  the brief already makes GIF quality the top encoding priority.
- MP4 remains valuable for quality and file size, and loops in-app via `AVPlayerLooper`
  and in Photos via the system setting. It is simply not a looping artifact when sent.
- Loop-point selection and crossfading remain fully in scope — they are what make the
  GIF seamless, and they also make an MP4 look intentional if a player does repeat it.
- The editor needs a mode/format compatibility rule, which is one small piece of state
  rather than a hidden constraint discovered at export time.

## Rejected alternatives

**Keep a separate "looping MP4" format and write the `LOOP` atom best-effort.** Faithful
to the brief's wording. Rejected because it would almost certainly ship a menu item that
differs from plain MP4 in metadata only — a control that does nothing, which is worse than
its absence.

**Animated HEIC as the looping format.** Rejected: frame timing cannot be set, and inline
animation in Messages is unverified.

**Animated WebP.** iOS 14+ decodes it, but there is no first-party encoder and Messages
inline behaviour is unverified. More risk than GIF for no clear gain.

**Export as a Live Photo with the Loop effect applied.** This is Apple's genuinely
looping artifact (`PHAsset.playbackStyle == .videoLooping`). Rejected as an interchange
format: it is an adjustment on a Live Photo asset rather than a file you can author,
exporting or sharing collapses the effect, Photos offers no "save as video" for it, and
third-party recipients receive a still or a plain MOV.

**All three modes for both formats,** treating MP4 loop mode as "seamless content that
loops if the player repeats it." Internally honest and the most flexible. Rejected
because it puts a Loop option in front of the user that does nothing in most destinations,
which is the same problem as the best-effort atom with extra steps.

## What would change this

- The `LOOP` atom experiment succeeding in iMessage: amend this record, add the format.
- Apple fixing HEICS frame-timing encoding *and* Messages animating `.heics` inline:
  would offer a genuinely better-quality looping format than GIF.
- Messages gaining autoloop for short videos: makes the whole question moot.
