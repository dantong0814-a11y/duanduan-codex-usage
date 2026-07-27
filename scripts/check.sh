#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

"${SCRIPT_DIR}/build.sh"
plutil -lint "${PROJECT_DIR}/Info.plist"
codesign --verify --deep --strict --verbose=2 "${PROJECT_DIR}/build/Duanduan Usage.app"

if /usr/bin/grep -REn '/Users/[^/$ ]+' \
  "${PROJECT_DIR}/Sources" \
  "${PROJECT_DIR}/Info.plist" \
  "${PROJECT_DIR}/README.md" \
  "${PROJECT_DIR}/PRIVACY.md"; then
  echo "Found a machine-specific user path." >&2
  exit 1
fi

echo "Checks passed."
