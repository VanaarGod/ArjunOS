#!/usr/bin/env bash
# Runs every available check. Uses $PYTHON, else the app venv created by setup.sh, else python3.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SUPPORT="${JARVIS_HOME:-$HOME/Library/Application Support/JarvisOS}"
[ "$(uname -s)" = "Darwin" ] || APP_SUPPORT="${JARVIS_HOME:-$HOME/.local/share/JarvisOS}"
PY="${PYTHON:-}"
[ -z "$PY" ] && [ -x "$APP_SUPPORT/venv/bin/python3" ] && PY="$APP_SUPPORT/venv/bin/python3"
PY="${PY:-python3}"
"$PY" -c "import pytest, jarvis_bridge" 2>/dev/null || { echo "ERROR: $PY lacks pytest/jarvis_bridge. Run scripts/setup.sh first (or set PYTHON=...)." >&2; exit 1; }
echo "== Python bridge tests ($PY) =="; ( cd "$ROOT/services/python" && "$PY" -m pytest -q )
echo "== API contract fixtures up to date? =="; "$PY" "$ROOT/scripts/gen_fixtures.py" --check
if command -v npm >/dev/null; then
  echo "== Markdown/math renderer tests (node) =="
  ( cd "$ROOT/apps/macos/Web" && { [ -d node_modules ] || npm install --no-audit --no-fund >/dev/null; } && npm test 2>&1 | grep -E "^(not ok|# (tests|pass|fail))" )
  echo "== Browser page-reading script tests (node + jsdom) =="
  ( cd "$ROOT/apps/macos/Tests/PageScripts" && { [ -d node_modules ] || npm install --no-audit --no-fund >/dev/null; } && npm test 2>&1 | grep -E "^(not ok|# (tests|pass|fail))" )
else echo "SKIPPED: npm not installed (renderer and page-script tests need Node: https://nodejs.org)"; fi
if command -v swift >/dev/null; then echo "== Swift tests =="; ( cd "$ROOT/apps/macos" && swift test )
else echo "SKIPPED: swift not installed (Swift code remains uncompiled/untested)"; fi
