# Runbook

How to set up the build, kick off a session, and keep it running. Written for you, not for
the build agent. The agent reads [CLAUDE.md](../CLAUDE.md).

The short version: you do four setup tasks once, start Claude Code with a prompt, and it
works through the GitHub issues on its own until it hits something only you can do. Your Mac
runs the tests that gate each merge, so it needs to stay awake and logged in.

## What you need

- A Mac on Apple silicon, with admin rights
- Xcode 27 from the App Store
- An iPhone 14 Pro or newer, and a cable
- A paid Apple developer account
- 30 to 50 of your own Live Photos
- Claude Code, and `gh` already authenticated

Set aside about an hour for setup. Most of it is waiting for Xcode to download.

## Setup, once

Six steps. Do them in order. Steps 1 to 5 are GitHub issues #1 through #4, so tick the boxes
there as you go.

### 1. Install the tooling

Xcode first, because it takes longest. Install it from the App Store, then open it once and
let it finish installing components.

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

Add cargo to your shell profile, or the runner will not find it later:

```bash
echo 'source "$HOME/.cargo/env"' >> ~/.zprofile
```

Check all four:

```bash
xcodebuild -version && swift --version && xcodegen --version && cargo --version
```

### 2. Make the repo private

A self-hosted runner on a public repo can be reached by a pull request from a stranger's fork.
Keep it private until the build is finished.

```bash
gh repo edit Brian-Egan/StillMotions --visibility private --accept-visibility-change-consequences
gh repo view Brian-Egan/StillMotions --json visibility
```

### 3. Set up the runner

This is what runs the tests on every pull request the agent opens. Installed as a launchd
service, it starts at login and survives reboots.

Get a registration token first: in the repo on GitHub, go to Settings, Actions, Runners, and
click New self-hosted runner. Pick macOS and ARM64. Leave that page open, because the token
expires in about an hour.

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o actions-runner-osx-arm64.tar.gz -L \
  https://github.com/actions/runner/releases/latest/download/actions-runner-osx-arm64.tar.gz
tar xzf actions-runner-osx-arm64.tar.gz

./config.sh --url https://github.com/Brian-Egan/StillMotions --token PASTE_TOKEN_HERE
```

Accept every default it offers. You do not need to add custom labels: the runner labels itself
`self-hosted`, `macOS` and `ARM64`, which is exactly what the workflow asks for.

```bash
./svc.sh install
./svc.sh start
./svc.sh status        # want: active, running
```

Then stop the Mac sleeping, or jobs will sit in a queue overnight while the agent waits. Save
your current settings first, so the teardown script can put them back exactly rather than
guessing:

```bash
pmset -g custom > ~/.stillmotions-power-settings

sudo pmset -a sleep 0
sudo pmset -a disksleep 0
pmset -g | grep -E ' sleep|disksleep'      # both should read 0
```

One thing that catches people out: the runner is a launchd *user* agent, so it only runs while
you are logged in. Locking the screen is fine. Logging out is not.

### 4. Check that the runner actually runs a job

GitHub cannot enforce the test result for you on this setup. Branch protection on a private
repository needs GitHub Pro, and the newer rulesets need an organization on GitHub Team. This
repo is private under a Free personal account, so GitHub will happily let a red branch merge.

That is less of a loss than it sounds, and the reason is worth understanding, because it changes
what the runner is for. The runner's value was never the blocking. It is that the tests run on a
clean checkout of the branch, on hardware the agent does not control, and the result is recorded
on the pull request where you can read it later. That all still works. What you lose is the
mechanical inability to merge red, and the substitute is that the agent waits for the check and
merges only when it is green, which is written into CLAUDE.md as a hard rule.

So instead of configuring protection, confirm the runner picks up work:

```bash
git checkout -b runner-smoke-test
git commit --allow-empty -m "Check that the runner picks up a job"
git push -u origin runner-smoke-test
gh pr create --fill
gh pr checks --watch
```

You want that to end with `verify` passing, having run on your Mac. Watch it appear in the
Actions tab while it runs if you want to see the runner doing its thing.

Clean up:

```bash
gh pr close --delete-branch
git checkout main
```

If you would rather have real enforcement, two ways to get it. GitHub Pro is about $4 a month
for a personal account and includes branch protection on private repositories; once you have it,
add a rule on `main` requiring the `verify` check and switch the agent back to
`gh pr merge --auto --squash`. Or make the repo public, where protection is free on any plan,
though that means a self-hosted runner on a public repo, which is the configuration GitHub warns
against because a pull request from a stranger's fork can propose workflow changes that run on
your machine. Neither is necessary.

### 5. Export your Live Photos

The agent measures stabilization quality against real photos. Synthetic test clips prove the
maths is right; only your own photos show whether the output looks good.

In Photos on the Mac, select 30 to 50 Live Photos, then choose File, Export, **Export
Unmodified Original**. The wording matters. A plain Export re-encodes and can drop the paired
video, which leaves you with stills the pipeline cannot use.

Drop the resulting HEIC and MOV pairs into `tests/fixtures/personal/`.

Try to cover the cases that break stabilizers in different ways: standing still with normal
hand shake, walking while shooting, kids, pets, low light, a shot with something close and
something far away, and a few you would expect to defeat any stabilizer. The failures matter
as much as the successes, because they are what proves the failure warning works.

```bash
ls tests/fixtures/personal/*.HEIC | wc -l    # 30 to 50
ls tests/fixtures/personal/*.MOV  | wc -l    # the same number
./scripts/check-no-private-assets.sh         # want: no private assets detected
git status --short tests/fixtures/personal/  # want: nothing, the folder is gitignored
```

These photos must never be committed. The repo goes public at the end of the build, and that
exposes the whole history, so a photo committed now is a photo published later.
`check-no-private-assets.sh` runs first in every verification pass to stop that happening.

### 6. Set up signing

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

Three checks. If any fails the agent will stall waiting for a job that never runs.

```bash
cd ~/actions-runner && ./svc.sh status    # running
pmset -g | grep ' sleep'                  # 0
cd ~/path/to/StillMotions && ./scripts/verify.sh   # exits 0
```

## Starting a build session

Open a terminal in the repo and start Claude Code. Give it permission to run `bash` and `gh`
without asking each time, or it will stop on its first tool call and wait for you.

Paste this:

```
You are the build agent for this repo. Read CLAUDE.md first, then docs/PRD.md and
docs/ARCHITECTURE.md, and follow the task loop in CLAUDE.md exactly.

Setup issues #1 through #4 are done. Start with the lowest-numbered open issue in the
earliest open milestone whose blockers are all closed and which is not labeled `human`,
and keep going: one issue per branch, one pull request each.

There is no branch protection on this repo, so GitHub will not stop you merging a failed
build. You are the gate. For every pull request, wait for the check and merge only if it
passed:

    gh pr checks --watch --fail-fast
    gh pr merge --squash --delete-branch

Do not use `gh pr merge --auto`; with no required checks it merges immediately, before the
runner has even started. If `gh pr checks` reports no checks at all, stop and tell me, because
that means the runner is down and nothing is actually being verified.

Work through as many issues as you can without me. Stop and tell me only if:
- the next issue is blocked by an open issue labeled `human`
- the `verify` check will not run, reports nothing, or the runner looks offline
- an issue's scope turns out to be wrong, in which case comment on the issue proposing a
  split rather than expanding it yourself

Do not relax a test or a threshold to make a build pass. Do not merge on a failing or
pending check. For anything touching the pipeline, run the harness against
tests/fixtures/personal and look at the contact sheets before you open the pull request.

Start now and give me a one-line note each time you merge something.
```

The first unblocked issue is #5, which confirms the scaffolding builds. From there it should
run through #25 without needing you, which is about twenty issues and covers the whole
processing pipeline, the test harness, quality tuning, and the app's main screens.

It stops at #26, the first thing that needs a phone in your hand.

## Checking on progress

```bash
gh pr list                                   # open pull requests
gh issue list --state closed --limit 20      # what has landed
gh run list --limit 10                       # recent verification runs
gh issue list --label human --state open     # what is waiting on you
```

To see where it got to and why it stopped, read the last few pull requests. The agent puts its
verification output in each one.

## Running verification yourself

`scripts/verify.sh` is the single entry point, used by both you and CI, so there is no
second code path that could behave differently.

```bash
./scripts/verify.sh
```

It runs four things and stops at the first failure: the private-asset check, `swift build`,
`swift test`, and the test harness against the synthetic fixtures. Exit code 0 means all four
passed.

While iterating you will more often want a piece of it:

```bash
swift build
swift test
swift test --filter CameraPathTests

# quality against your own photos, which is the number that actually matters
swift run stillmotions-harness --fixtures tests/fixtures/personal --out /tmp/hp
open /tmp/hp/*/contact-sheet.png
```

Open the contact sheets. The metrics catch a broken tracker, but a clip can pass every
threshold and still look wrong, and the only way to know is to look.

## Starting and stopping the runner

```bash
cd ~/actions-runner
./svc.sh status
./svc.sh start
./svc.sh stop
tail -f _diag/Runner_*.log      # live log
```

Per-job logs live in the Actions tab on GitHub. The runner checks the code out into
`~/actions-runner/_work/StillMotions/`, which is separate from your working copy, so it and
the agent never fight over the same files.

## When something goes wrong

**A pull request sits with a pending check and the agent has gone quiet.** The runner is
stopped, or the Mac slept, or you logged out. Start the service, set sleep back to 0, log in.
The agent is doing the right thing by waiting.

**A pull request has no check on it at all.** The runner never picked the job up. Check
`./svc.sh status` and the Actions tab. This is the case to care about, because a missing check
looks like nothing is wrong: CLAUDE.md tells the agent to stop and report rather than treat it
as a pass, but if it merged anyway you would only notice later.

**The runner shows Offline on GitHub but `svc.sh status` says it is running.** The
registration has lapsed. Get a fresh token and re-register:

```bash
cd ~/actions-runner
./config.sh remove --token NEW_TOKEN
./config.sh --url https://github.com/Brian-Egan/StillMotions --token NEW_TOKEN
./svc.sh start
```

**`swift build` fails on `CGifski`.** The GIF encoder is a build artifact and is not in git.

```bash
./scripts/build-gifski.sh
```

**`xcodebuild` cannot find the scheme.** The Xcode project is generated, not committed.

```bash
xcodegen generate
```

**Odd duplicate-file or missing-test errors.** Something created a `Tests/` directory. The
filesystem is case-insensitive, so `Tests/` and the `tests/` folder holding the fixtures are
the same place. Only lowercase `tests/` is used here.

**The GIF build step is slow on every pull request.** It caches on the pinned gifski version
and the build script, so a change to either costs one slow run and then goes back to cached.

If the runner is broken and you want the agent to keep working anyway, tell it to run
`./scripts/verify.sh` locally and paste the output into each pull request instead of waiting
for the check. That loses the independent clean-checkout run, so it is a stopgap rather than a
mode to leave it in. Fix the runner.

## Why CI does not build the app

Verification runs `swift build`, `swift test`, and the harness. It never runs `xcodebuild`.
Signing an iOS build without someone present needs the keychain unlocked, which is exactly the
sort of thing that fails at 3am and leaves you with a stalled queue and a confusing log.

Two things follow from that. A green `verify` means the processing pipeline is correct, and
says nothing about whether the app compiles, which is why every app milestone ends with an
on-device check you do by hand. And because your photos are not in git, CI only ever sees the
synthetic clips, so it protects correctness while real quality stays your call.

## Shutting the build rig down

When you are finished, or any time you want your Mac to behave normally again:

```bash
./scripts/teardown-runner.sh
```

It stops and uninstalls the launchd service, deregisters the runner from GitHub, deletes any
`actions.runner.*` launchd job it finds in `~/Library/LaunchAgents`, `/Library/LaunchAgents`
and `/Library/LaunchDaemons`, kills any listener still running, and restores sleep and
disksleep from the snapshot you took during setup. It asks before each destructive step, so
you can decline any of them.

```bash
./scripts/teardown-runner.sh --dry-run   # see what it would do first
./scripts/teardown-runner.sh --yes       # no prompts
```

Safe to run twice. Anything already gone is skipped.

One thing it deliberately leaves alone: it does not delete `~/actions-runner` itself, in case
you want to register it again without downloading it. It tells you the command if you do want it
gone.

After teardown, pull requests get no `verify` check at all. That is the state CLAUDE.md tells
the agent to stop and report on, so if you tear the runner down mid-build, expect the agent to
halt rather than merge unverified.

If you never took the power snapshot it falls back to `sudo pmset restoredefaults`, which
restores Apple's defaults rather than whatever you personally had.

## Making the repo public at the end

Issue #39. Deregister the runner **before** you change visibility, not after, or you leave a
window where a fork's pull request could run code on your Mac.

```bash
# 1. runner off, power settings back
./scripts/teardown-runner.sh

# 2. check the history, not just the working tree
git log --all --name-only --pretty=format: \
  | sort -u \
  | grep -Ei 'fixtures/personal|\.p12$|\.mobileprovision$|\.cer$|\.heic$|\.mov$' \
  | grep -v 'fixtures/synthetic' \
  || echo "clean"

# 3. only if step 2 printed clean
gh repo edit Brian-Egan/StillMotions --visibility public --accept-visibility-change-consequences
```

Step 2 is the one to take seriously. Going public exposes every commit ever made, so one
personal photo or one certificate from months ago becomes public too, and getting it out means
rewriting history. If that grep finds anything, deal with it before you flip the switch.

If you want CI afterwards on a public repo, point the workflow at `macos-latest` and accept
the billed minutes. Do not attach a self-hosted runner to a public repo.
