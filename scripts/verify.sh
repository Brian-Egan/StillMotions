#!/usr/bin/env bash
# Single verification entry point.
# Run it from a clean `git worktree` checkout of the pushed branch, not from a working
# directory: uncommitted files and stale build products make an in-place run pass when the
# branch would not.
# See docs/ARCHITECTURE.md §9 and "How verification works" in docs/RUNBOOK.md.
#
#   ./scripts/verify.sh
#
# Exit 0 means every stage passed. This does NOT build the iOS app: signing needs keychain
# unlock, so app correctness is established by the `human` on-device verification issues.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
FAILED=0

section() { printf '\n\033[1m=== %s\033[0m\n' "$1"; }
ok()      { printf '\033[32mPASS\033[0m  %s\n' "$1"; }
fail()    { printf '\033[31mFAIL\033[0m  %s\n' "$1"; FAILED=1; }

# ---------------------------------------------------------------------------
section "1/4  Private asset check"
# Runs first and cheapest. A personal photo or signing cert in history is permanent, and
# the repo goes public at the end of the build.
if ./scripts/check-no-private-assets.sh; then
  ok "no private assets staged or tracked"
else
  fail "private assets detected — see output above"
  # Hard stop: nothing else matters if this fails.
  exit 1
fi

# ---------------------------------------------------------------------------
section "2/4  swift build"
# Vendor/Gifski.xcframework is gitignored. If the Encoding target depends on CGifski and
# the artifact is missing, the build fails with a confusing manifest error — so say so.
if [[ ! -d "Vendor/Gifski.xcframework" ]] && grep -q '^\s*"CGifski"' Package.swift; then
  fail "Vendor/Gifski.xcframework missing but CGifski is an active dependency"
  echo "      run: ./scripts/build-gifski.sh"
  exit 1
fi

if swift build 2>&1 | tee /tmp/sm-build.log; then
  ok "swift build"
else
  fail "swift build — see /tmp/sm-build.log"
fi

# ---------------------------------------------------------------------------
section "3/4  swift test"
if swift test 2>&1 | tee /tmp/sm-test.log; then
  ok "swift test"
else
  fail "swift test — see /tmp/sm-test.log"
fi

# ---------------------------------------------------------------------------
section "4/4  Harness regression (synthetic fixtures)"
# Only synthetic fixtures have a committed baseline, because personal fixtures are gitignored.
# This guards correctness, not real-world quality — quality is judged locally against personal
# fixtures plus contact-sheet review. See PRD R-23.
SYNTH_DIR="tests/fixtures/synthetic"
BASELINE="harness/baseline.json"
OUT_DIR="harness/out/verify-$$"

if [[ -z "$(ls -A "$SYNTH_DIR" 2>/dev/null | grep -v '^\.gitkeep$' || true)" ]]; then
  echo "SKIP  no synthetic fixtures yet — expected until the fixture generator lands"
elif [[ ! -f "$BASELINE" ]]; then
  echo "SKIP  no $BASELINE yet — expected until the baseline is established"
else
  mkdir -p "$OUT_DIR"
  if swift run stillmotions-harness \
       --fixtures "$SYNTH_DIR" \
       --out "$OUT_DIR" \
       --baseline "$BASELINE" 2>&1 | tee /tmp/sm-harness.log; then
    ok "harness regression vs $BASELINE"
  else
    fail "harness regression — see /tmp/sm-harness.log and contact sheets in $OUT_DIR"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n'
if [[ $FAILED -eq 0 ]]; then
  printf '\033[32mVERIFY PASSED\033[0m  %s\n' "$REPO_ROOT"
  exit 0
else
  printf '\033[31mVERIFY FAILED\033[0m  do not merge\n'
  exit 1
fi
