#!/usr/bin/env bash
# Creates the Python environment the macOS app launches for its bridge. Touches only the app-support directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SUPPORT="${JARVIS_HOME:-$HOME/Library/Application Support/JarvisOS}"
case "$(uname -s)" in Darwin) ;; *) APP_SUPPORT="${JARVIS_HOME:-$HOME/.local/share/JarvisOS}";; esac
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  for c in python3.15 python3.14 python3.13 python3.12 python3.11 python3; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys;sys.exit(0 if sys.version_info>=(3,11) else 1)'; then PY="$c"; break; fi
  done
fi
[ -n "$PY" ] || { echo "ERROR: Python >= 3.11 not found. Install it (e.g. 'brew install python@3.12') or set PYTHON=/path/to/python." >&2; exit 1; }
echo "Using $($PY --version) at $(command -v "$PY")"
mkdir -p "$APP_SUPPORT"
"$PY" -m venv "$APP_SUPPORT/venv"
"$APP_SUPPORT/venv/bin/pip" install --quiet --upgrade pip
"$APP_SUPPORT/venv/bin/pip" install --quiet -e "$ROOT/services/python[dev]"
if ! "$APP_SUPPORT/venv/bin/python" -c "import jarvis_bridge, httpx, fastapi, uvicorn, pypdf; print('jarvis_bridge', jarvis_bridge.__version__, '+ pypdf', pypdf.__version__, 'OK')"; then
  echo "ERROR: the Python environment is missing packages (see the error above)." >&2
  echo "Try:  \"$APP_SUPPORT/venv/bin/pip\" install -e \"$ROOT/services/python[dev]\"" >&2
  exit 1
fi
echo "Done. Bridge python: $APP_SUPPORT/venv/bin/python3"
