#!/bin/zsh
set -euo pipefail

AGENT_ID="com.wendy.codex-quota-widget"
PLIST_PATH="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
INSTALL_BIN="$HOME/.codex-quota-widget/bin/CodexQuotaWidget"

launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
rm -f "$INSTALL_BIN"

echo "Removed $PLIST_PATH"
