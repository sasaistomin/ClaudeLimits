#!/usr/bin/env python3
# ClaudeLimits — statusline-команда для Claude Code (Linux).
# Получает JSON сессии на stdin, сохраняет rate_limits в ~/.claude/limits.json и печатает строку статуса.
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from claude_limits_core import statusline
    data = sys.stdin.buffer.read().decode('utf-8', 'replace')
    line = statusline(data)
except Exception:
    line = '[Claude]'
sys.stdout.buffer.write((line + '\n').encode('utf-8'))
