#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_ID="com.wendy.codex-quota-widget"
PLIST_PATH="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
LOCAL_BIN="$ROOT_DIR/bin/CodexQuotaWidget"
SERVICE="gui/$(id -u)/$AGENT_ID"

usage() {
  cat <<'EOF'
Usage:
  scripts/widgetctl.sh on
  scripts/widgetctl.sh off
  scripts/widgetctl.sh enable [--touchbar-only|--with-capsule]
  scripts/widgetctl.sh disable   # uninstall LaunchAgent
  scripts/widgetctl.sh restart
  scripts/widgetctl.sh status
  scripts/widgetctl.sh capsule on|off
  scripts/widgetctl.sh providers codex|claude|both
  scripts/widgetctl.sh claude on|off|status|doctor
  scripts/widgetctl.sh pin on|off
  scripts/widgetctl.sh touchbar-only
EOF
}

build_local() {
  "$SCRIPT_DIR/build.sh" >/dev/null
}

run_widget_cli() {
  build_local
  "$LOCAL_BIN" "$@"
}

restart_if_installed() {
  if [[ -f "$PLIST_PATH" ]]; then
    "$SCRIPT_DIR/restart_helper.sh"
  else
    echo "LaunchAgent is not installed. Run scripts/widgetctl.sh enable to start it."
  fi
}

command="${1:-}"
if [[ -z "$command" ]]; then
  usage
  exit 64
fi
shift

case "$command" in
  on)
    run_widget_cli --widget on
    restart_if_installed
    ;;

  off)
    run_widget_cli --widget off
    restart_if_installed
    ;;

  enable|start)
    capsule_mode=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --touchbar-only)
          capsule_mode="off"
          ;;
        --with-capsule)
          capsule_mode="on"
          ;;
        *)
          usage
          exit 64
          ;;
      esac
      shift
    done

    if [[ -n "$capsule_mode" ]]; then
      build_local
      "$LOCAL_BIN" --capsule "$capsule_mode"
    fi
    "$SCRIPT_DIR/install_launch_agent.sh"
    ;;

  disable|stop)
    "$SCRIPT_DIR/uninstall_launch_agent.sh"
    ;;

  restart)
    restart_if_installed
    ;;

  status)
    if launchctl print "$SERVICE" >/dev/null 2>&1; then
      echo "service: running"
    else
      echo "service: stopped"
    fi
    run_widget_cli --settings
    "$SCRIPT_DIR/configure_claude_statusline.py" status
    ;;

  capsule)
    if [[ $# -ne 1 ]]; then
      usage
      exit 64
    fi
    case "$1" in
      on|off)
        run_widget_cli --capsule "$1"
        restart_if_installed
        ;;
      *)
        usage
        exit 64
        ;;
    esac
    ;;

  providers)
    if [[ $# -ne 1 ]]; then
      usage
      exit 64
    fi
    case "$1" in
      codex|claude|both)
        run_widget_cli --providers "$1"
        restart_if_installed
        ;;
      *)
        usage
        exit 64
        ;;
    esac
    ;;

  touchbar-only)
    run_widget_cli --capsule off
    restart_if_installed
    ;;

  claude)
    if [[ $# -lt 1 ]]; then
      usage
      exit 64
    fi
    sub="$1"
    shift
    case "$sub" in
      on)
        "$SCRIPT_DIR/configure_claude_statusline.py" on
        ;;
      off)
        "$SCRIPT_DIR/configure_claude_statusline.py" off
        ;;
      status)
        "$SCRIPT_DIR/configure_claude_statusline.py" status
        ;;
      doctor)
        "$SCRIPT_DIR/configure_claude_statusline.py" doctor
        ;;
      *)
        usage
        exit 64
        ;;
    esac
    ;;

  pin)
    if [[ $# -ne 1 ]]; then
      usage
      exit 64
    fi
    case "$1" in
      on|off)
        run_widget_cli --touchbar-pin "$1"
        restart_if_installed
        ;;
      *)
        usage
        exit 64
        ;;
    esac
    ;;

  *)
    usage
    exit 64
    ;;
esac
