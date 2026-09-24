# 0003. Share extension is a drop box, not a processor

- Status: Accepted
- Date: 2026-09-24
- Relates to: PROJECT_BRIEF.md §4.1, §11 Q2; docs/ARCHITECTURE.md "Extension memory strategy"

## Context

The brief proposed two options: process inside the extension at reduced resolution, or
"hand the asset to the main app (for example via an App Group container and a URL
scheme)".

**The URL-scheme half of the second option does not work.** Apple's current documentation
for `NSExtensionContext.open(_:completionHandler:)` states which extension points support
it:

> Each extension point determines whether to support this method, or under which
> conditions to support this method. In iOS, the Today and iMessage app extension points
> support this method.

Share extensions are not on that list. The widely-copied workaround — walking the
responder chain to find `openURL:` — is private-API-adjacent, has broken repeatedly
across releases, and returns failure on current iOS. So an extension **cannot launch the
containing app**. Any handoff design must assume the user switches to the app themselves.

The memory constraint is also real but undocumented. Extension jetsam kills report
`EXC_RESOURCE RESOURCE_TYPE_MEMORY (limit=120 MB)`, consistently across a decade of
crash reports, device classes, and iOS versions. Apple documents no number. Two
properties matter: it is a **high-water mark**, not an average, so a single transient
spike kills the process; and it is per-extension-type, so the figure is not
transferable. On the iPhone 14 Pro (6 GB RAM) there is no additional headroom versus
newer devices — the limit is not proportional to physical memory.

A single native-resolution frame from a recent iPhone as RGBA is roughly 50 MB before any
copies. Decode buffers, the warp destination, and the encoder's working set all coexist.
Processing at native resolution inside a 120 MB ceiling is not viable.

## Decision

The extension does the minimum and processes nothing:

1. Receive the item from `NSExtensionContext`.
2. Copy the paired photo and video into the App Group container using
   `loadFileRepresentation` and a filesystem copy. Never `loadDataRepresentation`,
   never `Data` in memory, never `UserDefaults` as a transport.
3. Write a small JSON manifest naming the copied files and recording a UUID and
   timestamp.
4. Show a brief confirmation telling the user to open StillMotions.
5. Call `completeRequest(returningItems:)` and exit.

The app drains the container on `didBecomeActive`: it reads pending manifests, ingests
them, and deletes the staged files on success. Ingestion is idempotent on the manifest
UUID so a crash mid-ingest cannot duplicate or lose work.

gifski is **not linked into the extension**. It is linked into the app target only. This
keeps the Rust static library out of the extension binary and confines the AGPL surface
to one target.

## Consequences

- **The share flow costs the user an extra deliberate step.** Share to StillMotions, then
  open StillMotions. This is the accepted cost, and it is honest: there is no supported
  way to remove it. The confirmation UI must say plainly what happens next, or the share
  will appear to have failed silently.
- The extension is small enough to be genuinely safe against the ceiling — a file copy
  has a memory profile measured in kilobytes, not tens of megabytes. Phase 6 still
  measures peak footprint on the 14 Pro against a 100 MB self-imposed budget, because
  the real limit is undocumented and unconfirmed on iOS 27.
- The extension needs no pipeline code at all, so phase 6 is small: one drop-box issue,
  one app-side drain issue, one on-device verification.
- Staged files accumulate if the user shares repeatedly and never opens the app. The
  drain must delete on successful ingest, and must discard manifests older than 7 days on
  launch, or the App Group container grows without bound.
- Editing happens only in the app, so there is exactly one editor implementation and one
  preview cache. Presets are not restricted by entry point.

## Rejected alternatives

**Process in the extension at reduced resolution (720 px cap), export directly.** The
best experience — never leaves Photos, no second step. Rejected on a combination of
risk and duplication: it needs the full pipeline, gifski, an editor UI, and a preview
cache all running inside an undocumented ~120 MB ceiling that we cannot test against
reliably, and it duplicates the app's editor. The failure mode is a jetsam kill with no
user-visible explanation, which is worse than an extra tap. Reconsider only if the
extra step proves genuinely annoying in daily use and phase 6 measurements show a large
memory margin.

**Process at native resolution in the extension.** Rejected on arithmetic: one native
RGBA frame is ~50 MB against a ~120 MB ceiling.

**Extension writes to a shared location and posts a local notification the user taps.**
Tapping a notification does launch the app, so this technically closes the loop.
Rejected because it requires notification permission for a purely mechanical purpose,
and a permission prompt on first share is a worse first impression than a sentence of
instruction.

**Skip the extension; use the in-app gallery only.** Defensible, and phases 1–5 deliver
a complete app without it. Rejected because sharing from Photos is where the app is
actually reached for in practice, and a file copy is cheap.

## What would change this

- Apple extending `NSExtensionContext.open(_:)` to share extensions: makes the handoff
  seamless and removes the only real objection to this design.
- Phase 6 measurements showing a large margin under the ceiling, plus the extra step
  proving annoying in use: would justify revisiting in-extension processing.
- A documented, raised extension memory limit: same.
