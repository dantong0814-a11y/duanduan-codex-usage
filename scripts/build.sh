#!/bin/zsh
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Duanduan Codex Usage requires macOS." >&2
  exit 1
fi

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="${PROJECT_DIR}/build"
APP_PATH="${BUILD_DIR}/Duanduan Usage.app"
CONTENTS="${APP_PATH}/Contents"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Run: xcode-select --install" >&2
  exit 1
fi

rm -rf "${APP_PATH}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${PROJECT_DIR}/Info.plist" "${CONTENTS}/Info.plist"
cp "${PROJECT_DIR}"/Resources/*.png "${CONTENTS}/Resources/"

xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework SwiftUI \
  -framework UserNotifications \
  -lsqlite3 \
  "${PROJECT_DIR}"/Sources/*.swift \
  -o "${CONTENTS}/MacOS/DuanduanUsage"

codesign --force --deep --sign - "${APP_PATH}"
echo "Built: ${APP_PATH}"
