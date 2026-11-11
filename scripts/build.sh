#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v swift >/dev/null || { echo "swift not found; install Xcode 15+" >&2; exit 1; }
( cd "$ROOT/apps/macos" && swift build -c release )
echo "Built: $ROOT/apps/macos/.build/release/JarvisOS   (dev run: cd apps/macos && swift run JarvisOS)"
