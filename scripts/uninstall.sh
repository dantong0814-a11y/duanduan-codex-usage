#!/bin/zsh
set -euo pipefail

APP_DEST="${HOME}/Applications/Duanduan Usage.app"
LABEL="app.duanduan.codex-usage"
AGENT_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
USER_ID="$(id -u)"

launchctl bootout "gui/${USER_ID}" "${AGENT_PATH}" 2>/dev/null || true
pkill -x DuanduanUsage 2>/dev/null || true

if [[ -e "${APP_DEST}" ]]; then
  /usr/bin/osascript -e "tell application \"Finder\" to delete POSIX file \"${APP_DEST}\""
fi
if [[ -e "${AGENT_PATH}" ]]; then
  /usr/bin/osascript -e "tell application \"Finder\" to delete POSIX file \"${AGENT_PATH}\""
fi

echo "Duanduan Codex Usage was moved to Trash."
