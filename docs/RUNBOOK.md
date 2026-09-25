# Runbook

How to set up the build, kick off a session, and keep an eye on it. Written for you, not for
the build agent. The agent reads [CLAUDE.md](../CLAUDE.md).

The short version: you do four setup tasks once, start Claude Code with a prompt, and it works
through the GitHub issues on its own until it hits something only you can do.

CI runs on GitHub's own macOS runners, which are free and unmetered because this repo is public,
and a ruleset requires the `verify` check before anything merges to `main`. There is nothing to
install and nothing on your Mac to keep running.

## What you need

- A Mac on Apple silicon, with admin rights
- Xcode 27 from the App Store
- An iPhone 14 Pro or newer, and a cable
- An Apple ID. **A free one is enough** — no $99 Apple Developer Program membership needed. See
  "Free account limits" below for what that costs you.
- 30 to 50 of your own Live Photos
- Claude Code, and `gh` already authenticated

Set aside about an hour. Most of it is waiting for Xcode to download.

## Setup, once

Four steps, in order. They are GitHub issues #1, #3 and #4, so tick the boxes there as you go.

### 1. Install the tooling

Xcode first, because it takes longest. Install it from the App Store, then open it once and let
it finish installing components.

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version        # want: Xcode 27.x

cd ~/path/to/StillMotions
brew bundle install        # XcodeGen, pinned in the Brewfile

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
```

Rust builds the GIF encoder from source. Install it with rustup rather than Homebrew, because
the build script needs to add cross-compilation targets.

Add cargo to your shell profile so future sessions find it:

```bash
echo 'source "$HOME/.cargo/env"' >> ~/.zprofile
```

Check all four:

```bash
xcodebuild -version && swift --version && xcodegen --version && cargo --version
```

### 2. Confirm the ruleset is in place

The repo is public, so rulesets are free and CI on GitHub-hosted runners is unmetered. A ruleset
named "verification check" should require the `verify` status check on `main`.

```bash
gh api repos/Brian-Egan/StillMotions/rulesets --jq '.[] | {name, enforcement}'
```

Expect one entry with `"enforcement": "active"`. If it is missing, add it under Settings, Rules,
Rulesets: target `main`, tick "Require status checks to pass", and add `verify`.

The check name must stay exactly `verify`. Renaming the workflow job renames the check and the
ruleset then blocks every merge, because it is waiting for a context nothing produces.

The repository also needs auto-merge enabled, otherwise the agent's `gh pr merge --auto` fails and
it has no correct way to land work:

```bash
gh api repos/Brian-Egan/StillMotions \
  --jq '{allow_auto_merge, allow_squash_merge, allow_merge_commit, delete_branch_on_merge}'
```

Expect auto-merge and squash true, merge commits false, delete-on-merge true. To set them:

```bash
gh api --method PATCH repos/Brian-Egan/StillMotions \
  -F allow_auto_merge=true -F delete_branch_on_merge=true \
  -F allow_merge_commit=false -F allow_rebase_merge=false
```

Squash-only is deliberate: it keeps one commit per issue on `main`, which is what makes
`git revert <sha>` a clean undo when something does slip through.

**Do not attach a self-hosted runner to this repo.** It is public, so a fork's pull request could
propose workflow changes that run on your machine. GitHub-hosted runners cost nothing here. If you
set one up under an earlier version of this runbook, see "Removing a self-hosted runner" below.

### 3. Export your Live Photos

The agent measures stabilization quality against real photos. Synthetic test clips prove the
maths is right; only your own photos show whether the output looks good.

In Photos on the Mac, select 30 to 50 Live Photos, then choose File, Export, **Export Unmodified
Original**. The wording matters. A plain Export re-encodes and can drop the paired video, which
leaves you with stills the pipeline cannot use.

Drop the resulting HEIC and MOV pairs into `tests/fixtures/personal/`.

Cover the cases that break stabilizers in different ways: standing still with normal hand shake,
walking while shooting, kids, pets, low light, a shot with something close and something far
away, and a few you would expect to defeat any stabilizer. The failures matter as much as the
successes, because they are what proves the failure warning works.

```bash
ls tests/fixtures/personal/*.HEIC | wc -l    # 30 to 50
ls tests/fixtures/personal/*.MOV  | wc -l    # the same number
./scripts/check-no-private-assets.sh         # want: no private assets detected
git status --short tests/fixtures/personal/  # want: nothing, the folder is gitignored
```

These photos must never be committed. If you make the repo public later, that exposes the whole
history, so a photo committed now is a photo published then. `check-no-private-assets.sh` runs
first in every verification pass to stop that happening.

### 4. Set up signing

On a free personal team there is **no developer-portal step**. Xcode registers the App IDs and
the App Group for you when it signs. You only need to tell it which team to use.

The identifiers, already in `project.yml`:

- App: `com.began.Still-Motions`
- Extension: `com.began.Still-Motions.Share`
- App Group: `group.com.began.Still-Motions`

The hyphen is deliberate and load-bearing. An explicit App ID claimed by a personal team cannot
be released without an Apple Developer Support ticket, so `com.began.StillMotions` is being kept
free for a future paid team. Do not "tidy" these.

Find your Team ID under Xcode, Settings, Accounts: select your Apple ID, then your personal team.
It is the ten-character string, or click Manage Certificates if it is not shown.

```bash
# edit project.yml, set DEVELOPMENT_TEAM under settings.base
xcodegen generate
open StillMotions.xcodeproj
```

In Xcode, select each of the two targets in turn and open Signing & Capabilities. Automatically
manage signing should be on, your personal team selected, and App Groups should list
`group.com.began.Still-Motions`. If App Groups shows an error mentioning personal teams, tell me —
that would contradict what Apple support currently says and would change the share extension design.

Xcode will probably warn that you have no registered devices. **Ignore it for now.** A development
profile embeds a device list, so that warning is expected until you plug the phone in, and none of
the agent's work needs it cleared.

```bash
xcodebuild -scheme StillMotions -destination 'generic/platform=iOS Simulator' build
git add project.yml && git commit -m "Set development team for signing (#4)" && git push
```

That is the whole of step 4. **No phone required.** Registering the device, installing, trusting
the certificate, and confirming App Groups against a real profile are issue #44, which you can do
whenever the phone is to hand — nothing the agent does is waiting on it.

### Free account limits

What the free tier costs you, from Apple's membership comparison:

| | Free personal team | Paid, $99/year |
| --- | --- | --- |
| Provisioning profile validity | **7 days** | 1 year |
| App IDs | 10, each expiring after 7 days | unlimited |
| Devices | 3, expiring after 7 days | 100 per type |
| Apps per device | 3 | unlimited |
| TestFlight | no | yes |

Two of these will actually affect you.

**The app stops launching every 7 days.** It stays on the home screen, then simply refuses to
open. There is no warning and nothing on the phone can extend it. Rebuild from Xcode and you get
a fresh 7 days. This is the main reason to eventually pay.

**Do not churn the bundle identifiers.** The app and the extension consume one App ID each, and
adding App Groups forces explicit rather than wildcard IDs. That gives you roughly five clean
identifier changes per week before `'10' App ID limit in '7' days`. Free accounts cannot see the
portal's Identifiers list to delete them, so the only remedy is waiting out the week.

### Upgrading to a paid account later

When the weekly rebuild gets old, enrol in the Apple Developer Program and switch the
identifiers to the unhyphenated ones being held in reserve:

1. In `project.yml`, change `DEVELOPMENT_TEAM` to the new team ID and replace all three
   identifiers: `com.began.StillMotions`, `com.began.StillMotions.Share`,
   `group.com.began.StillMotions`.
2. `xcodegen generate`, then in Xcode confirm both targets sign against the new team.
3. Register the two App IDs and the App Group in the developer portal, since a paid team manages
   identifiers there rather than implicitly.
4. Rebuild to the device. iOS treats this as a **different app**, so the old one stays installed
   until you delete it and its settings do not carry over. Nothing else is lost; there is no
   persistent data beyond preferences.
5. TestFlight becomes available at this point if you want it.

### Before you walk away

```bash
./scripts/verify.sh        # must exit 0 on main
```

If that passes, the agent has a working baseline to build on.

**Keep the Mac awake.** Nothing else does this any more — the self-hosted runner used to change the
sleep settings, and it has been removed. If the Mac sleeps, Claude Code stops mid-session.

```bash
caffeinate -dimsu
```

Leave that running in its own terminal tab. Unlike `pmset` it changes no saved settings, so it
reverts the moment you press Ctrl-C or reboot and there is nothing to undo afterwards.

**You do not need the phone connected.** Every issue the agent can work is completable without it:
app builds target the simulator, which needs no provisioning profile and no codesign pass, so an
overnight run cannot stall waiting for hardware or block on a keychain prompt. The device checks
(#44, #26, #30, #35, #38) are yours to do afterwards.

How far it gets unattended depends only on which setup issues are done:

| Done | Agent can reach | Why |
| --- | --- | --- |
| #1, #5 | phase 1 (#7–#17) | Pure package work on synthetic fixtures it generates itself |
| plus #3 | phase 2 (#18–#21) | Quality baseline needs your real Live Photos |
| plus #4, #6 | phase 3 onward | App code needs a project that builds |

Phase 1 alone is twelve substantial issues, so it is a reasonable night's work on its own. If you
only have a few minutes, do #4 — it takes five and unblocks everything downstream.

## Starting a build session

Open a terminal in the repo and start Claude Code. Give it permission to run `bash` and `gh`
without asking each time, or it will stop on its first tool call and wait for you.

Paste this:

```
You are the build agent for this repo. Read CLAUDE.md first, then docs/PRD.md and
docs/ARCHITECTURE.md, and follow the task loop in CLAUDE.md exactly.

Setup issues #1, #3 and #4 are done. Start with the lowest-numbered open issue in the
earliest open milestone whose blockers are all closed and which is not labeled `human`,
and keep going: one issue per branch, one pull request each.

I am away and the iPhone is not connected. Build the app for the simulator only, never for a
device. If an issue seems to need hardware, it is mis-scoped: the device checks live in #44,
#26, #30, #35 and #38, so skip to the next available issue and say so rather than stalling.

CI runs `scripts/verify.sh` on a GitHub-hosted macOS runner for every pull request, and a
ruleset requires the `verify` check before anything merges. Merge with
`gh pr merge --auto --squash --delete-branch`, which queues the merge so GitHub lands it
only once the check is green.

Before opening each pull request, also run verification locally against a clean checkout of
the pushed branch, so a trivial failure costs you seconds rather than a CI round trip:

    git push -u origin issue-N-slug
    git worktree add /tmp/verify-N issue-N-slug
    ( cd /tmp/verify-N && ./scripts/verify.sh )     # expect exit 0
    git worktree remove /tmp/verify-N

Run it there, not in your working directory, because your working directory has uncommitted
files and stale build products and will pass when the branch would not. Paste that output
into the pull request.

Work through as many issues as you can without me. Stop and tell me only if:
- the next issue is blocked by an open issue labeled `human`
- the `verify` check will not run, stays queued, or reports nothing
- verification fails in a way you cannot fix inside the issue's scope
- an issue's scope turns out to be wrong, in which case comment on the issue proposing a
  split rather than expanding it yourself

Do not relax a test or a threshold to make a build pass. For anything touching the pipeline,
run the harness against tests/fixtures/personal and look at the contact sheets before you
open the pull request.

Start now and give me a one-line note each time you merge something.
```

The first unblocked issue is #5, which confirms the scaffolding builds. From there it should run
through #25 without needing you, which is about twenty issues and covers the whole processing
pipeline, the test harness, quality tuning, and the app's main screens.

It stops at #26, the first thing that needs a phone in your hand.

## Checking on progress

```bash
gh pr list --state merged --limit 20         # what has landed
gh run list --limit 20                       # verification runs and their results
gh issue list --state closed --limit 20
gh issue list --label human --state open     # what is waiting on you
git log --oneline main -20
```

`gh run list` is the trustworthy record: those results come from GitHub, not from the agent's
account of its own work. Anything merged had a green `verify`, because the ruleset requires it.
The pull request bodies add the detail, including the harness metrics diff on pipeline changes.

## How verification works

`scripts/verify.sh` runs four things and stops at the first failure: the private-asset check,
`swift build`, `swift test`, and the test harness against the synthetic fixtures. Exit code 0
means all four passed. It does not build the iOS app; see "What is not covered" below.

```bash
./scripts/verify.sh
```

While iterating you will more often want a piece of it:

```bash
swift build
swift test
swift test --filter CameraPathTests

# quality against your own photos, which is the number that actually matters
swift run stillmotions-harness --fixtures tests/fixtures/personal --out /tmp/hp
open /tmp/hp/*/contact-sheet.png
```

Open the contact sheets. The metrics catch a broken tracker, but a clip can pass every threshold
and still look wrong, and the only way to know is to look.

The agent also runs verification from a **clean worktree** of the pushed branch before opening the
pull request, rather than in place. That is not redundant with CI, it is faster feedback on the
same class of bug: the most common way "tests pass" turns out false is a source file that exists
on the agent's disk and was never committed. In place it passes; from a fresh checkout it fails at
once, seconds instead of a CI round trip.

### What is not covered

CI is a real gate, but it does not cover everything:

- **The app is never built**, only the pipeline package. Signing needs a keychain and a
  free-personal-team provisioning profile, which a hosted runner cannot reproduce. Whether the iOS
  app compiles and runs is established by the on-device checks at the end of each app milestone
  (#26, #30, #35, #38).
- **Quality is not gated.** The harness compares against a committed baseline for the synthetic
  fixtures, but real stabilization quality on your own photos is a judgement you make by looking
  at contact sheets.

If you later want CI to build the app too, that needs signing material in the runner's keychain
(an exported certificate and profile as encrypted secrets). It is doable and it is more moving
parts than a personal project needs, which is why the on-device checks exist instead.

## When something goes wrong

**`swift build` fails on `CGifski`.** The GIF encoder is a build artifact and is not in git.

```bash
./scripts/build-gifski.sh
```

**`xcodebuild` cannot find the scheme.** The Xcode project is generated, not committed.

```bash
xcodegen generate
```

**Odd duplicate-file or missing-test errors.** Something created a `Tests/` directory. The
filesystem is case-insensitive, so `Tests/` and the `tests/` folder holding the fixtures are the
same place. Only lowercase `tests/` is used here.

**`verify` is stuck queued, or a pull request has no check.** Look at the Actions tab. If the
workflow did not trigger, check that `.github/workflows/verify.yml` exists on the branch. If the
check name no longer matches what the ruleset requires, every merge blocks — the context must be
exactly `verify`.

**A merged change broke main.** The ruleset makes this much less likely, but CI does not build the
app or judge quality, so it can still happen.

```bash
git log --oneline -10
git revert <sha>              # squash merges revert cleanly
./scripts/verify.sh
```

Then reopen the issue with what went wrong, so the agent picks it up again rather than moving on.

## Removing a self-hosted runner

If you set up a self-hosted runner under an earlier version of this runbook, **remove it.** CI now
uses GitHub-hosted runners, which are free here, and this repo is public, so a fork's pull request
could propose workflow changes that execute on your machine.

```bash
./scripts/teardown-runner.sh --dry-run   # see what it would do first
./scripts/teardown-runner.sh
```

It stops and uninstalls the launchd service, deregisters the runner from GitHub, deletes any
`actions.runner.*` launchd job in `~/Library/LaunchAgents`, `/Library/LaunchAgents` and
`/Library/LaunchDaemons`, kills any listener still running, and restores sleep and disksleep. It
asks before each destructive step.

If you disabled sleep without snapshotting the original settings first, it falls back to
`sudo pmset restoredefaults`. Afterwards:

```bash
rm -rf ~/actions-runner
gh api repos/Brian-Egan/StillMotions/actions/runners --jq '.total_count'   # expect 0
```

## Keeping private things out of a public repo

The repo is already public, so this is a standing rule rather than a one-off step. Every commit
you make is visible, and the whole history is visible, so anything committed by mistake stays
visible even after you delete it.

`scripts/check-no-private-assets.sh` runs first in every verification pass and refuses personal
fixtures, signing material, stray media, and anything over 10 MB. To audit the history yourself:

```bash
git log --all --name-only --pretty=format: \
  | sort -u \
  | grep -Ei 'fixtures/personal|\.p12$|\.mobileprovision$|\.cer$|\.p8$|\.heic$|\.mov$' \
  | grep -v 'fixtures/synthetic' \
  || echo "clean"
```

This was clean as of the switch to public: the only match is the intentional
`tests/fixtures/personal/.gitkeep`, and the largest tracked file is 17 KB of Markdown. If it ever
finds something real, removing it means rewriting history with `git filter-repo` and force-pushing,
so it is much cheaper to not commit it.
