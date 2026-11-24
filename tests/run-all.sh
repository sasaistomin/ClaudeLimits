#!/bin/bash
# Все тесты, которые можно запустить на этом компьютере.
#   macOS: юнит + интеграционные тесты macOS-версии.
#   Linux-версия (логика, установка, statusline) — везде, где есть python3; значок в трее — на Linux с дисплеем.
#   Windows-версия (логика) — если установлен PowerShell (pwsh).
#   Полная проверка Windows (установка, значок в трее) идёт в GitHub Actions: .github/workflows/tests.yml
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

if [ "$(uname)" = "Darwin" ]; then
  bash "$REPO/tests/macos/run.sh" || status=1
  echo ""
fi

if command -v python3 >/dev/null 2>&1; then
  bash "$REPO/tests/linux/run.sh" || status=1
  echo ""
fi

if command -v pwsh >/dev/null 2>&1; then
  echo "### Windows-версия: логика и statusline (pwsh)"
  pwsh -NoProfile -File "$REPO/tests/windows/run-tests.ps1" || status=1
else
  echo "### Windows-версия: пропущено — нет PowerShell (brew install --cask powershell)."
  echo "    Полностью Windows проверяется в GitHub Actions после git push."
fi

echo ""
[ $status -eq 0 ] && echo "✅ ВСЕ ТЕСТЫ ПРОШЛИ" || echo "❌ ЕСТЬ ОШИБКИ"
exit $status
