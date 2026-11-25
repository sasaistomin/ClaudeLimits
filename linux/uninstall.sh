#!/bin/bash
# Удаление ClaudeLimits для Linux:  bash ~/.local/share/claude-limits/uninstall.sh
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-limits"
CORE="$INSTALL_DIR/claude_limits_core.py"
[ -f "$CORE" ] || CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude_limits_core.py"

[ -z "${CLAUDE_LIMITS_NO_LAUNCH:-}" ] && pkill -f "claude-limits/claude_limits.py" 2>/dev/null
[ -f "$CORE" ] && python3 "$CORE" uninstall
rm -f "$HOME/.claude/limits.json" "$HOME/.claude/limits-history.jsonl" "$HOME/.claude/limits-phone.json"
rm -rf "$INSTALL_DIR" "${XDG_CONFIG_HOME:-$HOME/.config}/claude-limits" "${XDG_CACHE_HOME:-$HOME/.cache}/claude-limits"
echo "ClaudeLimits удалён."
