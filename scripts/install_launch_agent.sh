#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_ID="com.wendy.codex-quota-widget"
PLIST_PATH="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
APP_HOME="$HOME/.codex-quota-widget"
INSTALL_BIN="$APP_HOME/bin/CodexQuotaWidget"

"$SCRIPT_DIR/build.sh"
mkdir -p "$APP_HOME/bin"
cp "$ROOT_DIR/bin/CodexQuotaWidget" "$INSTALL_BIN"
chmod +x "$INSTALL_BIN"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$AGENT_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$APP_HOME/launch-agent.log</string>
  <key>StandardErrorPath</key>
  <string>$APP_HOME/launch-agent.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || true
"$SCRIPT_DIR/restart_helper.sh"

echo "Installed LaunchAgent at $PLIST_PATH"
echo "Installed binary at $INSTALL_BIN"
