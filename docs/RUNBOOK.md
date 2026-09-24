# Runbook — verification, the self-hosted runner, and going public

Operational procedures for the human. Nothing here is optional reading before an overnight
build session: if the runner is not running or the Mac sleeps, the build agent stalls
waiting on a queued check that will never complete.

Architecture context in [ARCHITECTURE.md §9](ARCHITECTURE.md).

---

## 1. How verification works

`scripts/verify.sh` is the single entry point, run by both the build agent locally and the
self-hosted runner in CI. There is deliberately no second code path — local and CI
verification cannot drift.

```bash
./scripts/verify.sh
```

It runs, in order, stopping at the first failure:

1. `check-no-private-assets.sh` — refuses personal fixtures and signing material
2. `swift build`
3. `swift test`
4. Harness regression against `tests/fixtures/synthetic` vs `harness/baseline.json`

Exit code 0 means all four passed. It does **not** build the iOS app — see §5.

Run a subset while iterating:

```bash
swift build                                              # compile only
swift test                                               # unit tests only
swift test --filter CameraPathTests                      # one suite
swift run stillmotions-harness --fixtures tests/fixtures/synthetic --out /tmp/h
swift run stillmotions-harness --fixtures tests/fixtures/personal --out /tmp/hp   # quality
```

Personal fixtures are the real quality signal and are **not** in CI, because they are not
in git. Run them locally, and look at the contact sheets — the numbers alone will not tell
you that a clip looks wrong.

---

## 2. Self-hosted runner: one-time setup

Installs the runner as a launchd service so it starts at login and survives reboots.

```bash
# 1. Create a runner in the repo UI to get a registration token:
#    Settings > Actions > Runners > New self-hosted runner  (macOS / arm64)
#    Leave that page open; the token is short-lived.

mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o actions-runner-osx-arm64.tar.gz -L \
  https://github.com/actions/runner/releases/latest/download/actions-runner-osx-arm64.tar.gz
tar xzf actions-runner-osx-arm64.tar.gz

# 2. Register. Accept the defaults; label it macos-arm64 when prompted for extra labels.
./config.sh --url https://github.com/Brian-Egan/StillMotions --token <TOKEN>

# 3. Install and start as a launchd service.
./svc.sh install
./svc.sh start
./svc.sh status        # expect: active / running
```

Then confirm the runner shows **Idle** under Settings → Actions → Runners.

### Required system settings

```bash
sudo pmset -a sleep 0            # never sleep — a sleeping Mac leaves jobs queued
sudo pmset -a disksleep 0
pmset -g | grep -E ' sleep|disksleep'   # verify both are 0
```

Also: **stay logged in.** The runner is a launchd *user* agent, so it runs in your login
session. The screen may lock; the Mac may not be logged out. If you log out, jobs queue
silently and the agent waits forever.

### Branch protection

Settings → Branches → Add rule for `main`:

- Require status checks to pass before merging
- Select the **`verify`** check (it appears in the list only after the workflow has run at
  least once — push any branch to populate it)
- Leave "Require a pull request before merging" **off** or allow the agent as bypass; the
  agent opens PRs itself and does not need review

This is what makes `gh pr merge --auto --squash` safe: GitHub queues the merge and lands it
only when `verify` is green.

---

## 3. Day-to-day runner commands

```bash
cd ~/actions-runner
./svc.sh status                  # is it running
./svc.sh start
./svc.sh stop
tail -f _diag/Runner_*.log       # live runner log
```

Job logs are in the GitHub Actions UI per PR. The runner's own checkout lives in
`~/actions-runner/_work/StillMotions/` — **separate from your working copy**, so the runner
and the build agent never touch the same files.

### Before an overnight session

```bash
cd ~/actions-runner && ./svc.sh status   # must be running
pmset -g | grep ' sleep'                 # must be 0
cd /path/to/StillMotions && ./scripts/verify.sh   # must pass on main
```

If all three are good, the agent can work unattended: it opens a PR, the runner picks the
job up within seconds, and GitHub merges on green.

---

## 4. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| PR sits with a queued check, agent stalled | Runner stopped, or Mac asleep, or logged out | `./svc.sh start`; `sudo pmset -a sleep 0`; log back in |
| `verify` not offered in branch protection | Workflow has never run | Push any branch to trigger it once, then add the rule |
| Runner Offline in the UI but `svc.sh status` says running | Token expired or network change | `./svc.sh stop && ./config.sh remove --token <NEW>` then re-register |
| gifski step slow on every PR | Cache key changed | Expected after a gifski version bump or a `build-gifski.sh` edit; one slow run, then cached |
| `swift build` fails on `CGifski` | `Vendor/Gifski.xcframework` missing (it is gitignored) | `./scripts/build-gifski.sh` |
| `xcodebuild`: scheme not found | `.xcodeproj` not generated | `xcodegen generate` |
| Baffling duplicate-file or missing-test errors | A `Tests/` directory was created; APFS is case-insensitive so it merged with `tests/` | Use lowercase `tests/` only ([ARCHITECTURE §8](ARCHITECTURE.md)) |

### Emergency: unblock the agent with a broken runner

Temporarily drop the required check (Settings → Branches → edit rule → uncheck `verify`).
The agent falls back to merging on its own verification output. **Re-enable it** once the
runner is healthy — without it, nothing independently gates auto-merge.

---

## 5. Why CI does not build the app

CI runs `swift build`, `swift test`, and the synthetic harness only. It deliberately never
runs `xcodebuild`, because signing an iOS build unattended requires keychain unlock and
fails in exactly the conditions overnight runs depend on.

Consequences, stated plainly:

- A green `verify` means the **pipeline** is correct. It says nothing about whether the app
  compiles.
- App and extension builds are covered by the `human` on-device verification issues at the
  end of each app-facing milestone.
- CI checks correctness, not quality: personal fixtures are gitignored, so CI only sees
  synthetic clips. Real-world stabilization quality is gated locally.

---

## 6. Going public at the end of the build

**Order matters.** Deregister the runner *before* changing visibility, or there is a window
in which a pull request from a stranger's fork could execute code on your Mac.

```bash
# 1. Stop and deregister the runner
cd ~/actions-runner
./svc.sh stop
./svc.sh uninstall
./config.sh remove --token <TOKEN>        # new token from Settings > Actions > Runners

# 2. Remove the required status check
#    Settings > Branches > edit the main rule > uncheck verify  (or delete the rule)

# 3. Confirm nothing private is in history — not just in the working tree
git log --all --name-only --pretty=format: \
  | sort -u | grep -Ei 'fixtures/personal|\.p12$|\.mobileprovision$|\.cer$|\.heic$|\.mov$' \
  | grep -v 'fixtures/synthetic' || echo "clean"

# 4. Only if step 3 printed "clean":
gh repo edit Brian-Egan/StillMotions --visibility public --accept-visibility-change-consequences
```

Step 3 is not a formality. Making a repo public exposes the **entire history**, so a single
personal Live Photo or signing certificate committed months earlier becomes public — and
removing it requires rewriting history. If step 3 finds anything, stop and deal with it
before flipping visibility.

If you later want CI back on a public repo, switch the workflow to a GitHub-hosted macOS
runner (`runs-on: macos-latest`) and accept the billed minutes. Do not attach a self-hosted
runner to a public repo.
