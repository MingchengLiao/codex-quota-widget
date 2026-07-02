#!/bin/zsh
set -euo pipefail

# Build a clean, shareable source archive of the project. The recipient unpacks
# it and runs ./scripts/install_launch_agent.sh, which builds the binary locally
# (so there are no code-signing / Gatekeeper / CPU-architecture problems).
#
# Only files tracked by git plus new, non-ignored files are included; build
# artifacts (bin/, .build*/) are excluded via .gitignore.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
NAME="codex-quota-widget"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$DIST_DIR/${NAME}-${STAMP}.tar.gz"

cd "$ROOT_DIR"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not a git repository; cannot determine which files to package." >&2
  exit 1
fi

STAGE="$(mktemp -d)/$NAME"
mkdir -p "$STAGE"

# Tracked files + untracked-but-not-ignored files (e.g. scripts you just added).
git ls-files --cached --others --exclude-standard -z | while IFS= read -r -d '' f; do
  mkdir -p "$STAGE/$(dirname "$f")"
  cp "$f" "$STAGE/$f"
done

mkdir -p "$DIST_DIR"
tar -czf "$ARCHIVE" -C "$(dirname "$STAGE")" "$NAME"
rm -rf "$(dirname "$STAGE")"

echo "Created $ARCHIVE"
echo
echo "Share that file. The recipient runs:"
echo "  tar -xzf $(basename "$ARCHIVE")"
echo "  cd $NAME"
echo "  ./scripts/install_launch_agent.sh"
