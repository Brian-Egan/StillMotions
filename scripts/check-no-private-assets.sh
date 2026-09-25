#!/usr/bin/env bash
# Refuses to let personal photos or signing material enter git history.
#
# This exists because the repo is private during the build and PUBLIC afterwards, and
# making a repo public exposes the entire history. A single personal Live Photo committed
# months earlier becomes public, and removing it means rewriting history.
# See PRD R-26 and "Making the repo public at the end" in docs/RUNBOOK.md.
#
#   ./scripts/check-no-private-assets.sh
#
# Checks both the index (what is about to be committed) and tracked files (what already
# is committed). Exit non-zero on any hit.

set -euo pipefail
cd "$(dirname "$0")/.."

VIOLATIONS=0

report() {
  printf '\033[31mBLOCKED\033[0m  %s\n' "$1"
  VIOLATIONS=1
}

# Media extensions that could be a real photo or video. The synthetic fixture directory is
# the sole permitted location, since those are generated, not personal.
MEDIA_RE='\.(heic|heif|mov|mp4|m4v|jpg|jpeg|png|gif|dng|raw|avci)$'
SIGNING_RE='\.(p12|cer|certSigningRequest|mobileprovision|provisionprofile)$'

# --- Anything under the personal fixtures directory, ever -------------------
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ "$f" == *".gitkeep" ]] && continue
  report "personal fixture tracked or staged: $f"
done < <(git ls-files 'tests/fixtures/personal/*' 2>/dev/null || true)

# --- Signing material ------------------------------------------------------
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  report "signing material tracked or staged: $f"
done < <(git ls-files | grep -Ei "$SIGNING_RE" || true)

# --- Media outside the synthetic fixtures ----------------------------------
# Synthetic fixtures are committed deliberately (PRD R-21); everything else is suspect.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    tests/fixtures/synthetic/*) continue ;;
    App/*/Assets.xcassets/*)    continue ;;  # app icons and UI assets are fine
    docs/images/*)              continue ;;  # documentation diagrams are fine
  esac
  report "media file outside synthetic fixtures: $f"
done < <(git ls-files | grep -Ei "$MEDIA_RE" || true)

# --- Oversized files -------------------------------------------------------
# Catches a stray xcframework or a large binary that slipped past .gitignore.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  report "file over 10 MB (public history): $line"
done < <(git ls-files | while IFS= read -r f; do
           [[ -f "$f" ]] || continue
           sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
           if [[ "$sz" -gt 10485760 ]]; then echo "$f ($((sz / 1048576)) MB)"; fi
         done)

if [[ $VIOLATIONS -eq 0 ]]; then
  echo "no private assets detected"
  exit 0
fi

cat <<'EOF'

These files must not be in git. The repo becomes public at the end of the build and
history is exposed in full — a personal photo or certificate committed now is permanent.

To unstage without deleting from disk:
  git rm --cached <file>

If a file is already committed, it must be removed from history before the repo is made
public. See "Making the repo public at the end" in docs/RUNBOOK.md.
EOF
exit 1
