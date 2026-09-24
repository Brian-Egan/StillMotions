# 0006. XcodeGen as the project generator

- Status: Accepted
- Date: 2026-09-24
- Relates to: PROJECT_BRIEF.md §7, §11 Q4; CLAUDE.md "Build commands"

## Context

The brief requires the Xcode project to be generated from a text definition and never
hand-edited, and asks for XcodeGen or Tuist with a reason.

Since the brief was written, the premise has partly expired. Xcode 16 introduced
**buildable file-system synchronized groups** (`PBXFileSystemSynchronizedRootGroup`), which
record a folder path instead of enumerating every file. That removes the original
justification for both tools — `.pbxproj` churn and merge conflicts on file
add/remove — and for a solo developer with two targets, a hand-maintained `.xcodeproj` with
buildable folders is now a legitimate answer.

It is nonetheless the wrong answer *for this project*, for a reason specific to the
workflow rather than to Xcode: **the project is maintained by an LLM build agent.** The
agent needs to add a target, change a build setting, add a capability, or adjust a
deployment target by editing a file it can read and diff. A text manifest makes that a
normal edit with a reviewable diff. A binary-ish `.pbxproj` makes it either a hand-patch of
a format not designed for it, or an instruction the agent cannot carry out at all. The
merge-conflict argument for generators is dead; the machine-editability argument is not.

Both tools are actively maintained, which settles the maintenance-risk question that
usually decides this:

- **XcodeGen** — 2.46.0 released 2026-07-16, with a steady 2.45.x series through spring
  2026. Recent work tracks current Xcode: Swift package `traits` support, Icon Composer
  `.icon` folders, synced-folder fixes.
- **Tuist** — releasing daily canaries; now a monorepo shipping the CLI plus a commercial
  server product.

The differentiators cut cleanly. Tuist's value is binary caching, selective testing, and
remote cache — features that amortise over many targets and many engineers. This project
has two targets and one developer, so there is nothing to amortise, and Tuist's own
migration guide pitches it at problems "organizations experience". Its release cadence also
means version pinning is mandatory rather than advisable.

## Decision

**XcodeGen**, driven by a single `project.yml` at the repo root.

- `.xcodeproj` is **gitignored**. It is a build artifact.
- `xcodegen generate` is a documented prerequisite of any Xcode build, stated in CLAUDE.md
  and README.
- XcodeGen is installed via Homebrew and **pinned in a Brewfile**, so the generator version
  is reproducible along with everything else.
- Sources use XcodeGen's synced-folder support where possible, so adding a Swift file needs
  no manifest edit — only structural changes touch `project.yml`.

Generated structure:

| Target | Type | Bundle ID |
| --- | --- | --- |
| `StillMotions` | iOS app | `com.began.StillMotions` |
| `StillMotionsShare` | Share extension | `com.began.StillMotions.Share` |

Both embed the local `StillMotionsPipeline` SwiftPM package. Both carry App Group
`group.com.began.StillMotions`. Deployment target iOS 27.0.

## Consequences

- The build agent can change project structure with an ordinary file edit, and the diff is
  reviewable in a PR. This is the whole point.
- `xcodegen generate` must run before any `xcodebuild`. Forgetting it produces a confusing
  "no such scheme" error, so `scripts/verify.sh` and CLAUDE.md both handle it explicitly.
- A new Xcode release can briefly outpace XcodeGen. The mitigation is that CI never builds
  the iOS app — it only builds and tests the package via `swift build`, which does not need
  the generator at all. A generator lag therefore blocks on-device verification, not the
  main loop.
- CI stays independent of the generator, which also keeps the unattended overnight path
  simpler: no `xcodebuild`, no signing, no keychain unlock.
- If gifski's build ends up driven from Xcode build phases, the manifest keeps that
  reproducible rather than hand-clicked. As decided in 0004, gifski is built by a script
  instead, so this does not arise.

## Rejected alternatives

**Tuist.** Stronger at scale, Swift manifests are more expressive than YAML, and its
caching is genuinely good. Rejected as disproportionate: its advantages are concentrated in
features a two-target solo project cannot use, and it adds version-pinning discipline plus a
heavier install for no benefit here.

**No generator: commit `.xcodeproj` with buildable folders.** Now defensible, and arguably
what a human-only project should do — it drops a tool, a manifest, and a build step.
Rejected on the machine-editability argument above, which is decisive given the brief's
explicit constraint that the project never be hand-edited and the fact that an agent does
the editing.

**Swift Package Manager alone, no Xcode project.** Attractive, and the package genuinely
needs no project. Rejected because an iOS app target and a share extension with App Group
entitlements are not expressible in SwiftPM.

**Bazel.** Reproducible and scales enormously. Rejected on setup cost, which exceeds the
entire rest of this project's build configuration.

## What would change this

- XcodeGen going unmaintained: Tuist becomes the fallback, and `project.yml` is small
  enough to port.
- A human taking over day-to-day project editing: the generator's main justification
  disappears and committing the project with buildable folders becomes reasonable.
- Growth to many targets, or CI build times becoming painful: Tuist's caching starts to pay.
