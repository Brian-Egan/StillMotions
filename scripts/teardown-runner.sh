#!/usr/bin/env bash
# Undo everything the build setup did to this Mac: remove the GitHub Actions runner and put
# the power settings back.
#
#   ./scripts/teardown-runner.sh            # ask before each destructive step
#   ./scripts/teardown-runner.sh --yes      # no prompts
#   ./scripts/teardown-runner.sh --dry-run  # print what it would do
#
# Run this when the build is finished, or any time you want your Mac to behave normally
# again. It is safe to run twice; anything already gone is skipped.
#
# It does NOT change the repo's visibility or touch branch protection. Those are deliberate
# decisions, not cleanup. See "Making the repo public at the end" in docs/RUNBOOK.md.

set -uo pipefail

REPO="Brian-Egan/StillMotions"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
POWER_SNAPSHOT="${POWER_SNAPSHOT:-$HOME/.stillmotions-power-settings}"

ASSUME_YES=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)     ASSUME_YES=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    --runner-dir) RUNNER_DIR="$2"; shift ;;
    --repo)       REPO="$2"; shift ;;
    -h|--help)
      # Print the header comment, stopping at the first line that is not a comment.
      awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

step()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
info()  { printf '    %s\n' "$1"; }
ok()    { printf '\033[32m    done\033[0m  %s\n' "$1"; }
warn()  { printf '\033[33m    note\033[0m  %s\n' "$1"; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    would run: %s\n' "$*"
    return 0
  fi
  "$@"
}

confirm() {
  [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] && return 0
  local reply
  read -r -p "    $1 [y/N] " reply
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

[[ $DRY_RUN -eq 1 ]] && warn "dry run: nothing will actually change"

# ---------------------------------------------------------------------------
step "1/5  Stop the runner service"

if [[ -x "$RUNNER_DIR/svc.sh" ]]; then
  ( cd "$RUNNER_DIR" && run ./svc.sh stop )      || warn "svc.sh stop reported an error, continuing"
  ( cd "$RUNNER_DIR" && run ./svc.sh uninstall ) || warn "svc.sh uninstall reported an error, continuing"
  ok "service stopped and uninstalled"
else
  info "no svc.sh at $RUNNER_DIR, skipping"
fi

# ---------------------------------------------------------------------------
step "2/5  Deregister the runner from GitHub"

# A removal token is short-lived and can be minted through the API, so you do not have to
# fetch one from the web UI by hand.
if command -v gh >/dev/null 2>&1; then
  RUNNER_IDS="$(gh api "repos/$REPO/actions/runners" --jq '.runners[].id' 2>/dev/null)"

  if [[ -z "$RUNNER_IDS" ]]; then
    info "no runners registered on $REPO"
  else
    for id in $RUNNER_IDS; do
      name="$(gh api "repos/$REPO/actions/runners/$id" --jq '.name' 2>/dev/null || echo "id $id")"
      if confirm "remove runner '$name' from $REPO?"; then
        # Checked explicitly rather than through run(), because suppressing this call's
        # output would also suppress run()'s dry-run notice.
        if [[ $DRY_RUN -eq 1 ]]; then
          info "would remove runner '$name' (id $id)"
        elif gh api --method DELETE "repos/$REPO/actions/runners/$id" >/dev/null 2>&1; then
          ok "removed '$name'"
        else
          warn "could not remove '$name' via the API; it may be mid-job"
          warn "retry with: gh api --method DELETE repos/$REPO/actions/runners/$id"
        fi
      else
        info "left '$name' registered"
      fi
    done
  fi

  # config.sh also holds local credentials in .runner and .credentials. Clear them so a
  # stale registration cannot come back on next login.
  if [[ -f "$RUNNER_DIR/.runner" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      info "would clear the local registration in $RUNNER_DIR"
    else
      TOKEN="$(gh api --method POST "repos/$REPO/actions/runners/remove-token" --jq '.token' 2>/dev/null)"
      if [[ -n "${TOKEN:-}" ]]; then
        if ( cd "$RUNNER_DIR" && ./config.sh remove --token "$TOKEN" ) >/dev/null 2>&1; then
          ok "local runner registration cleared"
        else
          warn "config.sh remove failed; deleting local credentials instead"
        fi
      fi
      if [[ -f "$RUNNER_DIR/.runner" ]]; then
        rm -f "$RUNNER_DIR/.runner" "$RUNNER_DIR/.credentials" "$RUNNER_DIR/.credentials_rsaparams"
        ok "local credential files removed"
      fi
    fi
  fi
else
  warn "gh not found; remove the runner by hand under Settings > Actions > Runners"
fi

# ---------------------------------------------------------------------------
step "3/5  Remove launchd jobs and stray processes"

# svc.sh normally handles this, but a partly-failed install, a manually copied plist, or an
# older runner version can leave a job behind that starts again at login.
FOUND_PLIST=0
for dir in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r plist; do
    [[ -z "$plist" ]] && continue
    FOUND_PLIST=1
    label="$(basename "$plist" .plist)"
    info "found $plist"
    if confirm "unload and delete $label?"; then
      if [[ "$dir" == /Library/* ]]; then
        run sudo launchctl bootout system "$plist" 2>/dev/null
        run sudo rm -f "$plist"
      else
        run launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null
        run rm -f "$plist"
      fi
      ok "$label removed"
    fi
  done < <(find "$dir" -maxdepth 1 -name 'actions.runner.*.plist' 2>/dev/null)
done
[[ $FOUND_PLIST -eq 0 ]] && info "no actions.runner launchd jobs found"

# Anything still listening after the plists are gone.
LEFTOVER="$(pgrep -f 'Runner\.Listener|actions-runner/bin/Runner|actions-runner/run\.sh' 2>/dev/null)"
if [[ -n "$LEFTOVER" ]]; then
  info "still-running runner processes: $(echo "$LEFTOVER" | tr '\n' ' ')"
  if confirm "terminate them?"; then
    # shellcheck disable=SC2086
    run kill $LEFTOVER 2>/dev/null
    sleep 2
    STILL="$(pgrep -f 'Runner\.Listener|actions-runner/bin/Runner|actions-runner/run\.sh' 2>/dev/null)"
    if [[ -n "$STILL" ]]; then
      # shellcheck disable=SC2086
      run kill -9 $STILL 2>/dev/null
    fi
    ok "runner processes terminated"
  fi
else
  info "no runner processes running"
fi

if ! launchctl list 2>/dev/null | grep -q 'actions\.runner'; then
  ok "launchctl shows no actions.runner jobs"
else
  warn "launchctl still lists an actions.runner job:"
  launchctl list | grep 'actions\.runner' | sed 's/^/          /'
fi

# ---------------------------------------------------------------------------
step "4/5  Restore power settings"

# Setup set sleep and disksleep to 0 so overnight jobs were not left queued. Put back
# whatever was there before, or Apple's defaults if no snapshot was taken.
if [[ -f "$POWER_SNAPSHOT" ]]; then
  info "restoring from $POWER_SNAPSHOT"
  # The snapshot is `pmset -g custom` output: an AC Power and a Battery Power block of
  # "key value" lines. Replay the two settings we changed, per power source.
  if [[ $DRY_RUN -eq 0 ]]; then
    awk '
      /^AC Power:/      { src="-c"; next }
      /^Battery Power:/ { src="-b"; next }
      src && ($1=="sleep" || $1=="disksleep") { print src, $1, $2 }
    ' "$POWER_SNAPSHOT" | while read -r flag key value; do
      sudo pmset "$flag" "$key" "$value" && info "pmset $flag $key $value"
    done
    ok "power settings restored from snapshot"
  else
    info "would replay sleep and disksleep from the snapshot"
  fi
else
  warn "no snapshot at $POWER_SNAPSHOT"
  info "falling back to Apple's defaults, which may not match what you had"
  if confirm "run 'sudo pmset restoredefaults'?"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      info "would run: sudo pmset restoredefaults"
    elif sudo pmset restoredefaults; then
      ok "defaults restored"
    else
      warn "pmset restoredefaults failed; set them yourself with: sudo pmset -a sleep 10 disksleep 10"
    fi
  else
    info "left power settings as they are"
    info "set them yourself with: sudo pmset -a sleep 10 disksleep 10"
  fi
fi

# ---------------------------------------------------------------------------
step "5/5  Where things stand"

printf '\n'
info "power settings now:"
pmset -g custom 2>/dev/null | grep -E '^(AC|Battery) Power:|^ (sleep|disksleep) ' | sed 's/^/      /'

printf '\n'
if command -v gh >/dev/null 2>&1; then
  COUNT="$(gh api "repos/$REPO/actions/runners" --jq '.total_count' 2>/dev/null || echo '?')"
  info "runners registered on $REPO: $COUNT"
fi
info "launchd actions.runner jobs: $(launchctl list 2>/dev/null | grep -c 'actions\.runner')"
info "runner processes: $(pgrep -cf 'Runner\.Listener|actions-runner/run\.sh' 2>/dev/null || echo 0)"

if [[ -d "$RUNNER_DIR" ]]; then
  printf '\n'
  info "$RUNNER_DIR is still on disk (about $(du -sh "$RUNNER_DIR" 2>/dev/null | cut -f1))."
  info "delete it with: rm -rf $RUNNER_DIR"
fi

cat <<'EOF'

The runner is gone and your Mac will sleep normally again. Pull requests will now sit with a
pending `verify` check, so until you remove the required check in Settings > Branches, nothing
can merge.
EOF
