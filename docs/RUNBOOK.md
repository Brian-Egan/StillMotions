# Runbook

How to set up the build, kick off a session, and keep an eye on it. Written for you, not for
the build agent. The agent reads [CLAUDE.md](../CLAUDE.md).

The short version: you do four setup tasks once, start Claude Code with a prompt, and it works
through the GitHub issues on its own until it hits something only you can do.

There is no CI, no runner, and no status checks. Verification runs locally, and the agent is
instructed to run it against a clean checkout of each pushed branch before merging. See
"How verification works" below for what that does and does not buy you.

## What you need

- A Mac on Apple silicon, with admin rights
- Xcode 27 from the App Store
- An iPhone 14 Pro or newer, and a cable
- A paid Apple developer account
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

### 2. Make the repo private

Optional, and a preference rather than a requirement. The repo holds a tool built around your
personal photo library, and issue #39 makes it public at the end anyway.

```bash
gh repo edit Brian-Egan/StillMotions --visibility private --accept-visibility-change-consequences
```

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

Two identifiers and an App Group. The App Group is how the share extension passes a photo to
the app, so the share feature does not work without it.

On developer.apple.com, under Certificates, Identifiers & Profiles, register two App IDs:

- `com.began.StillMotions`
- `com.began.StillMotions.Share`

Enable the App Groups capability on both. Then register the group itself,
`group.com.began.StillMotions`, and go back to each App ID to tick it.

Now put your Team ID into the project definition. You will find it in the top right of the
developer portal, or under Xcode, Settings, Accounts.

```bash
# edit project.yml, set DEVELOPMENT_TEAM under settings.base
xcodegen generate
open StillMotions.xcodeproj
```

In Xcode, select each of the two targets in turn and open Signing & Capabilities. Automatically
manage signing should be on, your team selected, and App Groups should list
`group.com.began.StillMotions` with no warnings.

Plug in the iPhone, trust the Mac, and check it shows up as a run destination. Then confirm the
whole thing builds and commit the change:

```bash
xcodebuild -scheme StillMotions -destination 'generic/platform=iOS' build
git add project.yml && git commit -m "Set development team for signing (#4)" && git push
```

### Before you walk away

```bash
./scripts/verify.sh        # must exit 0 on main
```

If that passes, the agent has a working baseline to build on.

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

There is no CI on this repo. Nothing checks your work but you, and nothing will stop you
merging a broken branch. So for every issue, before you open the pull request, push the
branch and run verification against a clean checkout of it:

    git push -u origin issue-N-slug
    git worktree add /tmp/verify-N issue-N-slug
    ( cd /tmp/verify-N && ./scripts/verify.sh )     # must exit 0
    git worktree remove /tmp/verify-N

Run it there, not in your working directory, because your working directory has uncommitted
files and stale build products and will pass when the branch would not. Paste that output
into the pull request. Then merge with `gh pr merge --squash --delete-branch`.

Work through as many issues as you can without me. Stop and tell me only if:
- the next issue is blocked by an open issue labeled `human`
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
gh issue list --state closed --limit 20
gh issue list --label human --state open     # what is waiting on you
git log --oneline main -20
```

Because there is no CI, the pull request bodies are your only record of what was verified. Read
a few. You are looking for actual command output, not a claim that tests passed. A PR whose body
says "all tests pass" with nothing pasted is one to check by hand:

```bash
git checkout main && git pull
./scripts/verify.sh
```

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

The agent is told to run verification from a **clean worktree** of the pushed branch rather than
in place. That matters more than it sounds: the most common way "tests pass" turns out to be
false is a source file that exists on the agent's disk and was never committed. It passes in
place and fails for everyone else, permanently. Building a fresh checkout catches it immediately.

### What is not covered

Worth being clear about, since there is no second layer:

- **Nothing enforces any of this.** The agent could skip verification and merge anyway. The PR
  bodies are the audit trail, and they are written by the same agent doing the work.
- **The app is never built by verification**, only the pipeline package. Whether the iOS app
  compiles and runs is established by the on-device checks at the end of each app milestone
  (#26, #30, #35, #38).
- **Quality is not gated.** The harness compares against a committed baseline for the synthetic
  fixtures, but real stabilization quality on your own photos is a judgement you make by looking
  at contact sheets.

If you later want an independent check, the deleted GitHub Actions workflow is in git history at
`152d38d` under `.github/workflows/verify.yml`. On a public repo, branch protection is free on
any plan, so the strongest version of this setup is available after issue #39.

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

**A merged change broke main.** There is nothing preventing this, so it will eventually happen.

```bash
git log --oneline -10
git revert <sha>              # squash merges revert cleanly
./scripts/verify.sh
```

Then reopen the issue with what went wrong, so the agent picks it up again rather than moving on.

**The agent is merging without pasting verification output.** Stop the session and remind it of
the rule in CLAUDE.md. That output is the only evidence you get.

## Undoing a GitHub Actions runner

If you set up a self-hosted runner from an earlier version of this runbook, remove it:

```bash
./scripts/teardown-runner.sh
```

It stops and uninstalls the launchd service, deregisters the runner from GitHub, deletes any
`actions.runner.*` launchd job in `~/Library/LaunchAgents`, `/Library/LaunchAgents` and
`/Library/LaunchDaemons`, kills any listener still running, and restores sleep and disksleep.
It asks before each destructive step.

```bash
./scripts/teardown-runner.sh --dry-run   # see what it would do first
```

If you disabled sleep without snapshotting the original settings first, it falls back to
`sudo pmset restoredefaults`.

## Making the repo public at the end

Issue #39.

```bash
# 1. check the history, not just the working tree
git log --all --name-only --pretty=format: \
  | sort -u \
  | grep -Ei 'fixtures/personal|\.p12$|\.mobileprovision$|\.cer$|\.heic$|\.mov$' \
  | grep -v 'fixtures/synthetic' \
  || echo "clean"

# 2. only if step 1 printed clean
gh repo edit Brian-Egan/StillMotions --visibility public --accept-visibility-change-consequences
```

Step 1 is the one to take seriously. Going public exposes every commit ever made, so one personal
photo or one certificate from months ago becomes public too, and getting it out means rewriting
history. If that grep finds anything, deal with it before you flip the switch.
