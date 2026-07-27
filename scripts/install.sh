#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="Duanduan Usage.app"
APP_SOURCE="${PROJECT_DIR}/build/${APP_NAME}"
APP_DEST="${HOME}/Applications/${APP_NAME}"
LABEL="app.duanduan.codex-usage"
AGENT_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/Duanduan Usage"
USER_ID="$(id -u)"

"${SCRIPT_DIR}/build.sh"

mkdir -p "${HOME}/Applications" "${HOME}/Library/LaunchAgents" "${LOG_DIR}"
rm -rf "${APP_DEST}"
ditto "${APP_SOURCE}" "${APP_DEST}"

cat > "${AGENT_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>${APP_DEST}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launch.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launch-error.log</string>
</dict>
</plist>
PLIST

plutil -lint "${AGENT_PATH}"
launchctl bootout "gui/${USER_ID}" "${AGENT_PATH}" 2>/dev/null || true
launchctl bootstrap "gui/${USER_ID}" "${AGENT_PATH}"
launchctl enable "gui/${USER_ID}/${LABEL}"

echo "Installed: ${APP_DEST}"
echo "Login item: ${AGENT_PATH}"
