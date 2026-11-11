#!/usr/bin/env bash
# Read-only environment report. Changes nothing.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok(){ printf "  [ok]   %s\n" "$1"; }; warn(){ printf "  [warn] %s\n" "$1"; }; bad(){ printf "  [FAIL] %s\n" "$1"; }
echo "System:"; uname -sm; command -v sw_vers >/dev/null && sw_vers -productVersion
echo "Toolchain:"
if command -v swift >/dev/null; then ok "$(swift --version 2>&1 | head -1)"; else bad "swift not found (install Xcode 15+ or the Swift toolchain)"; fi
command -v xcodebuild >/dev/null && ok "$(xcodebuild -version 2>/dev/null | head -1)" || warn "xcodebuild not found (only needed for signed .app packaging)"
for c in python3.15 python3.14 python3.13 python3.12 python3.11 python3; do
  if command -v $c >/dev/null && $c -c 'import sys;sys.exit(0 if sys.version_info>=(3,11) else 1)'; then ok "$($c --version) ($c)"; found=1; break; fi
done; [ -z "$found" ] && bad "Python >= 3.11 not found"
echo "Local AI services (probing loopback only, no prompts sent):"
for u in "http://127.0.0.1:11434/api/version:Ollama" "http://127.0.0.1:1234/v1/models:LM Studio"; do
  url="${u%:*}"; name="${u##*:}"
  if curl -fsS -m 2 "$url" >/dev/null 2>&1; then ok "$name answering at $url"; else warn "$name not answering at $url"; fi
done
command -v ollama >/dev/null && ok "ollama CLI: $(ollama --version 2>&1 | head -1)" || warn "ollama not installed (optional; any OpenAI-compatible server works)"
echo "Bridge venv:"; V="${JARVIS_HOME:-$HOME/Library/Application Support/JarvisOS}/venv/bin/python3"
if [ -x "$V" ]; then
  ok "$V"
  "$V" -c "import pypdf" 2>/dev/null && ok "PDF support (pypdf) installed" || bad "pypdf missing in the app's Python: run scripts/setup.sh (PDF attachments will fail)"
  "$V" -c "import jarvis_bridge, httpx, fastapi, uvicorn" 2>/dev/null && ok "bridge packages installed" || bad "bridge packages missing: run scripts/setup.sh"
else warn "not created yet: run scripts/setup.sh"; fi
