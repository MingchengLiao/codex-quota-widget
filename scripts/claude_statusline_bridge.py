#!/usr/bin/env python3
"""Claude Code statusLine bridge for Codex Quota Widget.

Claude Code invokes this script as its ``statusLine.command`` and feeds session
JSON on stdin.  For Claude.ai Pro/Max subscribers that JSON contains a
``rate_limits`` object with ``five_hour`` / ``seven_day`` usage windows (each with
``used_percentage`` 0-100 and ``resets_at`` Unix epoch seconds).  We translate
those into the widget's snapshot schema and write them atomically to
``~/.codex-quota-widget/claude-code-snapshot.json``, which the native helper
reads (see ClaudeCodeSnapshotService.swift).

Every run also drops a breadcrumb at
``~/.codex-quota-widget/claude-code-bridge-debug.json`` so the data interface can
be diagnosed.  Run ``claude_statusline_bridge.py --doctor`` for a health report.

Note: Claude Code only invokes a statusLine command from its interactive
terminal UI.  The VS Code extension / headless (`-p`) / SDK modes do not, so the
snapshot is only produced while Claude Code is running in a terminal.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import sys
import tempfile
from typing import Any


WIDGET_DIR = os.path.expanduser("~/.codex-quota-widget")
SNAPSHOT_PATH = os.path.join(WIDGET_DIR, "claude-code-snapshot.json")
DEBUG_PATH = os.path.join(WIDGET_DIR, "claude-code-bridge-debug.json")
SETTINGS_PATH = os.path.expanduser("~/.claude/settings.json")
# Keep in sync with ClaudeCodeSnapshotService(maxAge:) on the Swift side.
SNAPSHOT_MAX_AGE = 30
UTC = _dt.timezone.utc


# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------
def _find_rate_limits(value: Any) -> dict[str, Any] | None:
    """Locate a ``rate_limits`` dict anywhere in the payload (top level first)."""
    if isinstance(value, dict):
        rate_limits = value.get("rate_limits")
        if isinstance(rate_limits, dict):
            return rate_limits
        for child in value.values():
            found = _find_rate_limits(child)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = _find_rate_limits(child)
            if found is not None:
                return found
    return None


def _number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def _used_percent(payload: dict[str, Any]) -> float | None:
    for key in ("used_percentage", "used_percent", "usedPercent"):
        value = _number(payload.get(key))
        if value is not None:
            return max(0.0, min(100.0, value))

    for key in ("remaining_percentage", "remaining_percent", "remainingPercent"):
        value = _number(payload.get(key))
        if value is not None:
            return max(0.0, min(100.0, 100.0 - value))

    return None


def _iso_timestamp(value: Any) -> str | None:
    number = _number(value)
    if number is not None:
        if number > 10_000_000_000:  # milliseconds
            number = number / 1000
        return _dt.datetime.fromtimestamp(number, UTC).isoformat().replace("+00:00", "Z")

    if isinstance(value, str) and value:
        text = value.strip()
        if text.endswith("Z"):
            return text
        try:
            parsed = _dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return text
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return parsed.astimezone(UTC).isoformat().replace("+00:00", "Z")

    return None


def _window(label: str, payload: Any) -> dict[str, Any] | None:
    if not isinstance(payload, dict):
        return None

    used = _used_percent(payload)
    if used is None:
        return None

    resets_at = None
    for key in ("resets_at", "reset_at", "resetsAt"):
        resets_at = _iso_timestamp(payload.get(key))
        if resets_at is not None:
            break

    return {
        "label": label,
        "usedPercent": used,
        "remainingPercent": max(0.0, 100.0 - used),
        "resetsAt": resets_at,
    }


# ---------------------------------------------------------------------------
# Snapshot construction
# ---------------------------------------------------------------------------
def _now_iso() -> str:
    return _dt.datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def build_snapshot(payload: Any) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    """Return ``(snapshot_or_None, info)``.

    ``info`` is a small, JSON-serializable diagnostics record describing what was
    seen and decided; it is written verbatim to the debug breadcrumb.
    """
    info: dict[str, Any] = {
        "topLevelKeys": sorted(payload.keys()) if isinstance(payload, dict) else None,
        "version": payload.get("version") if isinstance(payload, dict) else None,
    }

    rate_limits = _find_rate_limits(payload)
    info["rateLimitsFound"] = isinstance(rate_limits, dict)
    if not isinstance(rate_limits, dict):
        info["status"] = "no-rate-limits"
        return None, info

    # The rate_limits subtree is tiny and the single most useful thing to inspect
    # when the schema does not match expectations, so record it verbatim.
    info["rateLimits"] = rate_limits

    five_hour = _window("5h", rate_limits.get("five_hour"))
    seven_day = _window("7d", rate_limits.get("seven_day"))
    info["fiveHour"] = five_hour
    info["sevenDay"] = seven_day
    info["windowsFound"] = [w["label"] for w in (five_hour, seven_day) if w is not None]

    # Each window may be independently absent. Show whatever we have, preferring
    # the 5-hour window as primary (the widget requires a non-optional primary).
    primary = five_hour or seven_day
    if primary is None:
        info["status"] = "no-windows"
        return None, info

    secondary = seven_day if primary is five_hour else None

    now = _now_iso()
    snapshot = {
        "providerName": "Claude",
        "sourceFileName": "Claude Code statusLine",
        "eventTimestamp": now,
        "detectedAt": now,
        "planType": None,  # not present in the statusLine payload
        "primary": primary,
        "secondary": secondary,
    }
    info["status"] = "ok"
    return snapshot, info


def _statusline_text(info: dict[str, Any]) -> str:
    parts = ["Claude"]
    for window in (info.get("fiveHour"), info.get("sevenDay")):
        if window is not None:
            parts.append(f"{window['label']} {int(round(window['remainingPercent']))}%")
    return " ".join(parts)


# ---------------------------------------------------------------------------
# IO helpers
# ---------------------------------------------------------------------------
def _write_json_atomic(path: str, obj: Any) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(obj, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def _write_debug(info: dict[str, Any]) -> None:
    record = {"ranAt": _now_iso()}
    record.update(info)
    try:
        _write_json_atomic(DEBUG_PATH, record)
    except Exception:
        pass


def _read_json(path: str) -> Any:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------
def run_bridge() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        _write_debug({"status": "empty-input"})
        print("Claude")
        return 0

    try:
        payload = json.loads(raw)
    except Exception as exc:
        _write_debug({"status": "parse-error", "error": str(exc)[:200]})
        print("Claude")
        return 0

    # The statusLine command must never hard-fail, so guard the whole pipeline.
    try:
        snapshot, info = build_snapshot(payload)
        info["wrote"] = False
        if snapshot is not None:
            try:
                _write_json_atomic(SNAPSHOT_PATH, snapshot)
                info["wrote"] = True
            except Exception as exc:
                info["status"] = "write-error"
                info["error"] = str(exc)[:200]
        _write_debug(info)
        print(_statusline_text(info))
    except Exception as exc:  # pragma: no cover - defensive
        _write_debug({"status": "bridge-error", "error": str(exc)[:200]})
        print("Claude")
    return 0


def _age_seconds(iso_text: Any) -> float | None:
    if not isinstance(iso_text, str):
        return None
    try:
        parsed = _dt.datetime.fromisoformat(iso_text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return (_dt.datetime.now(UTC) - parsed).total_seconds()


def doctor() -> int:
    self_path = os.path.realpath(__file__)
    ok = "  [ ok ]"
    warn = "  [warn]"
    bad = "  [fail]"

    print("Codex Quota Widget — Claude Code data interface doctor")
    print("=" * 56)

    # 1. statusLine wiring -------------------------------------------------
    print("\n1) Claude Code statusLine configuration")
    settings = _read_json(SETTINGS_PATH)
    status_line = settings.get("statusLine") if isinstance(settings, dict) else None
    if not isinstance(status_line, dict):
        print(f"{bad} No statusLine configured in {SETTINGS_PATH}")
        print("        Fix: scripts/widgetctl.sh claude on")
    else:
        command = status_line.get("command")
        if isinstance(command, str) and os.path.realpath(os.path.expanduser(command)) == self_path:
            print(f"{ok} statusLine.command -> this bridge")
        else:
            print(f"{warn} statusLine.command points elsewhere:")
            print(f"        {command!r}")
        refresh = status_line.get("refreshInterval")
        if isinstance(refresh, (int, float)) and refresh > 0:
            print(f"{ok} refreshInterval = {refresh}s (stays fresh while idle)")
        else:
            print(f"{warn} refreshInterval not set; snapshot can go stale when "
                  "Claude Code is idle")
            print("        Fix: scripts/widgetctl.sh claude on  (re-applies it)")

    # 2. last bridge run --------------------------------------------------
    print("\n2) Last bridge invocation (breadcrumb)")
    debug = _read_json(DEBUG_PATH)
    if not isinstance(debug, dict):
        print(f"{bad} Bridge has never run (no {DEBUG_PATH})")
        print("        Claude Code only runs statusLine from its TERMINAL UI.")
        print("        Open Claude Code in a terminal and send one message.")
    else:
        age = _age_seconds(debug.get("ranAt"))
        age_text = f"{int(age)}s ago" if age is not None else "unknown"
        print(f"{ok} Last ran: {debug.get('ranAt')} ({age_text})")
        status = debug.get("status")
        if status == "ok":
            print(f"{ok} Status: ok, windows={debug.get('windowsFound')}")
        elif status == "no-rate-limits":
            print(f"{warn} Status: no rate_limits in payload.")
            print(f"        Top-level keys seen: {debug.get('topLevelKeys')}")
            print("        rate_limits only appears for Pro/Max after the first")
            print("        API response in the session. Send a message, then retry.")
        else:
            print(f"{warn} Status: {status}")
            if debug.get("error"):
                print(f"        Error: {debug.get('error')}")

    # 3. snapshot freshness ----------------------------------------------
    print("\n3) Snapshot the widget reads")
    snapshot = _read_json(SNAPSHOT_PATH)
    if not isinstance(snapshot, dict):
        print(f"{bad} No snapshot at {SNAPSHOT_PATH}")
    else:
        age = _age_seconds(snapshot.get("detectedAt"))
        if age is None:
            print(f"{warn} Snapshot present but timestamp unreadable")
        elif age <= SNAPSHOT_MAX_AGE:
            print(f"{ok} Fresh ({int(age)}s old, widget shows data <= {SNAPSHOT_MAX_AGE}s)")
        else:
            print(f"{warn} Stale ({int(age)}s old > {SNAPSHOT_MAX_AGE}s); widget hides it")
        primary = snapshot.get("primary") or {}
        secondary = snapshot.get("secondary") or {}
        for window in (primary, secondary):
            if window:
                print(f"        {window.get('label')}: "
                      f"{round(window.get('remainingPercent', 0))}% remaining, "
                      f"resets {window.get('resetsAt')}")

    print("\nDone. Re-run after sending a message in a terminal Claude Code session.")
    return 0


def main(argv: list[str]) -> int:
    if argv:
        if argv[0] in {"--doctor", "doctor", "--check"}:
            return doctor()
        if argv[0] in {"-h", "--help"}:
            print(__doc__)
            return 0
        print(f"Unknown argument: {argv[0]} (use --doctor or no arguments)", file=sys.stderr)
        return 64
    return run_bridge()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
