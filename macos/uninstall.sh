#!/bin/bash
# Удаление ClaudeLimits для macOS.
set -euo pipefail
APP="$HOME/Applications/ClaudeLimits.app"

pkill -x ClaudeLimits 2>/dev/null || true
if [ -x "$APP/Contents/MacOS/ClaudeLimits" ]; then
  "$APP/Contents/MacOS/ClaudeLimits" --uninstall || true
fi
rm -rf "$APP"
rm -f "$HOME/.claude/limits.json" "$HOME/.claude/limits-history.jsonl"
echo "ClaudeLimits удалён."
