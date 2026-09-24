#!/usr/bin/env bash
# Builds gifski from source into Vendor/Gifski.xcframework.
# See docs/decisions/0004-gifski-integration.md.
#
#   ./scripts/build-gifski.sh
#
# The resulting xcframework is a gitignored build artifact; THIS SCRIPT is the artifact of
# record. The version below is pinned deliberately: an unpinned encoder makes the harness
# regression baseline meaningless, because output size and dithering drift underneath it.

set -euo pipefail
cd "$(dirname "$0")/.."

# --- Pinned version. Bump deliberately, then re-run the harness and inspect size/quality
# --- drift before committing the new baseline.
GIFSKI_VERSION="1.34.0"

# Apple silicon only. The build machine and the reference device (iPhone 14 Pro) are both
# arm64. Add x86_64-apple-ios / x86_64-apple-darwin here if Intel support is ever needed.
TARGETS=(
  "aarch64-apple-darwin"    # macOS harness
  "aarch64-apple-ios"       # device
  "aarch64-apple-ios-sim"   # Apple silicon simulator
)

WORK_DIR="$(pwd)/.build/gifski"
OUT_XCFRAMEWORK="$(pwd)/Vendor/Gifski.xcframework"

# --- Preconditions ---------------------------------------------------------
if ! command -v cargo >/dev/null 2>&1; then
  cat <<'EOF'
ERROR: cargo not found. gifski is built from Rust source.

Install rustup, then re-run this script:
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  source "$HOME/.cargo/env"

Do not install Rust via Homebrew — rustup is needed to manage target toolchains.
EOF
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: xcodebuild not found. Xcode 27 is required to assemble an xcframework." >&2
  exit 1
fi

# --- Fetch -----------------------------------------------------------------
mkdir -p "$WORK_DIR"
SRC_DIR="$WORK_DIR/gifski-$GIFSKI_VERSION"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "==> fetching gifski $GIFSKI_VERSION"
  git clone --depth 1 --branch "$GIFSKI_VERSION" \
    https://github.com/ImageOptim/gifski.git "$SRC_DIR"
fi

# --- Build -----------------------------------------------------------------
# Default features only. The `video` feature needs ffmpeg 6.x plus libclang with system
# headers, drags in codec licensing, and is unnecessary: AVFoundation decodes, and gifski
# is fed raw RGBA frames.
#
# `cargo build` for iOS prints "dropping unsupported crate type cdylib". That warning is
# expected and documented upstream, not an error.
for target in "${TARGETS[@]}"; do
  echo "==> rustup target add $target"
  rustup target add "$target" >/dev/null

  echo "==> cargo build --release --lib --target $target"
  ( cd "$SRC_DIR" && cargo build --release --lib --target "$target" )
done

# --- Headers and module map ------------------------------------------------
# The module map makes the static library importable from Swift as `CGifski`.
HEADERS_DIR="$WORK_DIR/include"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp "$SRC_DIR/gifski.h" "$HEADERS_DIR/"

cat > "$HEADERS_DIR/module.modulemap" <<'EOF'
module CGifski {
    header "gifski.h"
    export *
}
EOF

# --- Assemble the xcframework ---------------------------------------------
rm -rf "$OUT_XCFRAMEWORK"
mkdir -p "$(dirname "$OUT_XCFRAMEWORK")"

XC_ARGS=()
for target in "${TARGETS[@]}"; do
  lib="$SRC_DIR/target/$target/release/libgifski.a"
  if [[ ! -f "$lib" ]]; then
    echo "ERROR: expected $lib but it was not produced" >&2
    exit 1
  fi
  XC_ARGS+=(-library "$lib" -headers "$HEADERS_DIR")
done

echo "==> xcodebuild -create-xcframework"
xcodebuild -create-xcframework "${XC_ARGS[@]}" -output "$OUT_XCFRAMEWORK"

# --- Report ---------------------------------------------------------------
echo
echo "built $OUT_XCFRAMEWORK from gifski $GIFSKI_VERSION"
echo "slices:"
/usr/libexec/PlistBuddy -c "Print :AvailableLibraries" \
  "$OUT_XCFRAMEWORK/Info.plist" 2>/dev/null \
  | grep -E 'LibraryIdentifier|SupportedArchitectures|SupportedPlatform' || true

cat <<'EOF'

Next: uncomment the CGifski binaryTarget and the Encoding dependency in Package.swift.
See docs/decisions/0004-gifski-integration.md.

Reminder: gifski is AGPL-3.0-or-later. Fine for TestFlight to yourself, which is not
conveying to a third party. Distributing further requires a commercial license from the
author.
EOF
