#!/usr/bin/env python3
import datetime as _dt
import json
import os
import sys
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
BRIDGE_PATH = ROOT_DIR / "scripts" / "claude_statusline_bridge.py"
SETTINGS_PATH = Path.home() / ".claude" / "settings.json"
COMMAND = str(BRIDGE_PATH)
# Re-run the bridge on a timer so the snapshot stays fresh while Claude Code is
# idle (the widget treats snapshots older than 60s as stale). See statusLine docs.
REFRESH_INTERVAL = 10


def _load_settings() -> dict:
    if not SETTINGS_PATH.exists():
        return {}
    try:
        return json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {SETTINGS_PATH}: {exc}") from exc


def _save_settings(settings: dict) -> None:
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    if SETTINGS_PATH.exists():
        timestamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = SETTINGS_PATH.with_name(f"settings.json.codex-quota-widget-backup-{timestamp}")
        backup.write_text(SETTINGS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
    SETTINGS_PATH.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def _is_ours(status_line: object) -> bool:
    return isinstance(status_line, dict) and status_line.get("command") == COMMAND


def enable() -> None:
    settings = _load_settings()
    existing = settings.get("statusLine")
    if existing is not None and not _is_ours(existing):
        raise SystemExit(
            "Claude Code already has a custom statusLine. "
            "Refusing to overwrite it; remove or merge it manually first."
        )

    settings["statusLine"] = {
        "type": "command",
        "command": COMMAND,
        "padding": 0,
        "refreshInterval": REFRESH_INTERVAL,
    }
    _save_settings(settings)
    print(f"Claude statusLine enabled: {COMMAND}")
    print(f"refreshInterval set to {REFRESH_INTERVAL}s.")
    print("Note: Claude Code only runs statusLine from its terminal UI; the")
    print("VS Code extension / headless mode will not feed quota data.")


def disable() -> None:
    settings = _load_settings()
    if _is_ours(settings.get("statusLine")):
        settings.pop("statusLine", None)
        _save_settings(settings)
        print("Claude statusLine disabled.")
    else:
        print("Claude statusLine is not managed by codex-quota-widget.")


def status() -> None:
    settings = _load_settings()
    status_line = settings.get("statusLine")
    if _is_ours(status_line):
        refresh = status_line.get("refreshInterval") if isinstance(status_line, dict) else None
        suffix = f" (refreshInterval={refresh}s)" if refresh else " (refreshInterval not set)"
        print(f"claude statusLine: enabled{suffix}")
    elif status_line is None:
        print("claude statusLine: disabled")
    else:
        print("claude statusLine: custom")


def doctor() -> int:
    import subprocess

    return subprocess.call([sys.executable, str(BRIDGE_PATH), "--doctor"])


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"on", "off", "status", "doctor"}:
        print("Usage: configure_claude_statusline.py on|off|status|doctor", file=sys.stderr)
        return os.EX_USAGE

    if sys.argv[1] == "on":
        enable()
    elif sys.argv[1] == "off":
        disable()
    elif sys.argv[1] == "doctor":
        return doctor()
    else:
        status()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
