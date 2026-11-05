#!/usr/bin/env bash
# Keeps the share extension a drop box (docs/decisions/0003-extension-strategy.md).
#
# The extension runs under an undocumented ~120 MB memory ceiling and cannot launch the app, so it may only
# copy files. This fails the build if its source mentions the pipeline module, tries to open the containing
# app, or loads shared items as in-memory data, or if the project links the pipeline into it.
#
#   ./scripts/check-extension-clean.sh

set -euo pipefail
cd "$(dirname "$0")/.."

EXTENSION=App/StillMotionsShare
FAILED=0

# 1. Source: no pipeline, no launch attempt, no data-in-memory loading.
if grep -rnE "StillMotionsPipeline|extensionContext\??\.open|openURL|loadDataRepresentation" "$EXTENSION"; then
  echo "FAIL: the share extension must stay a drop box. See docs/decisions/0003-extension-strategy.md"
  FAILED=1
fi

# 2. Project: the extension target may link the drop box and nothing of ours beyond it.
BLOCK=$(awk '/^  StillMotionsShare:/{on=1; print; next} on && /^  [A-Za-z]/{exit} on{print}' project.yml)
if [[ -z "$BLOCK" ]]; then
  echo "FAIL: could not find the StillMotionsShare target in project.yml"
  FAILED=1
elif echo "$BLOCK" | grep -E "product: *StillMotionsPipeline|target: *StillMotions *$|product: *(Encoding|Rendering|Import|CameraPath|MotionEstimation|LoopSelection|PipelineCore)"; then
  echo "FAIL: the extension target links more than the DropBox product in project.yml"
  FAILED=1
fi

if [[ $FAILED -eq 0 ]]; then
  echo "extension clean"
fi
exit $FAILED
