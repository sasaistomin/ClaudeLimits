#!/bin/bash
# Smoke-тест: быстрая проверка, что главное работает (установка → данные → окно → удаление).
# Всё ставится во временную «домашнюю папку», ваши настройки не трогаются.
# Запуск: bash tests/smoke.sh          (macOS; плюс Windows-логика, если есть pwsh)
#         SMOKE_REMOTE=1 bash tests/smoke.sh   — ещё проверить, что файлы доступны на GitHub
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW="https://raw.githubusercontent.com/sasaistomin/ClaudeLimits/main"
FAIL=0
step() { LABEL="$1"; }
pass() { echo "  ✅ $LABEL"; }
fail() { echo "  ❌ $LABEL ${1:-}"; FAIL=$((FAIL+1)); }

if [ "$(uname)" = "Darwin" ]; then
  echo "### Smoke: macOS"
  SB="$(mktemp -d)"
  trap 'pkill -f "$SB/Applications" 2>/dev/null; rm -rf "$SB"' EXIT
  BIN="$SB/Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits"
  (
    export HOME="$SB" CLAUDE_LIMITS_NO_LAUNCH=1
    mkdir -p "$SB/.claude"; echo '{"model":"opus"}' > "$SB/.claude/settings.json"

    step "1. Установка (сборка + settings.json)"
    if out=$(bash "$REPO/macos/install.sh" 2>&1) && [ -x "$BIN" ]; then pass; else fail; echo "$out" | tail -5; exit 1; fi

    step "2. statusLine прописан, остальные настройки целы"
    cmd=$(plutil -extract statusLine.command raw -o - "$SB/.claude/settings.json" 2>/dev/null)
    model=$(plutil -extract model raw -o - "$SB/.claude/settings.json" 2>/dev/null)
    [ "$cmd" = "\"$BIN\" --statusline" ] && [ "$model" = opus ] && pass || fail "($cmd)"

    step "3. Команда Claude Code → строка статуса"
    r=$(( $(date +%s) + 3600 ))
    out=$(echo "{\"model\":{\"display_name\":\"Opus\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":42,\"resets_at\":$r},\"seven_day\":{\"used_percentage\":17,\"resets_at\":$((r+86400))}}}" | sh -c "$cmd")
    [ "$out" = "[Opus] 5h: 42% 7d: 17%" ] && pass || fail "($out)"

    step "4. Данные сохранены (limits.json + история)"
    [ -s "$SB/.claude/limits.json" ] && [ -s "$SB/.claude/limits-history.jsonl" ] && pass || fail

    step "5. Окно рисуется (5ч и неделя)"
    ok=1
    for m in "" "week dark"; do
      "$BIN" --snapshot "$SB/s.png" $m >/dev/null 2>&1
      [ "$(stat -f %z "$SB/s.png" 2>/dev/null || echo 0)" -gt 20000 ] || ok=0; rm -f "$SB/s.png"
    done
    [ $ok = 1 ] && pass || fail

    step "6. Приложение запускается и не падает (3 с)"
    "$BIN" >/dev/null 2>&1 & pid=$!; sleep 3
    if kill -0 $pid 2>/dev/null; then pass; kill $pid; wait $pid 2>/dev/null; else fail; fi

    step "7. Удаление"
    bash "$REPO/macos/uninstall.sh" >/dev/null 2>&1
    [ ! -e "$SB/Applications/ClaudeLimits.app" ] && \
      [ -z "$(plutil -extract statusLine raw -o - "$SB/.claude/settings.json" 2>/dev/null)" ] && pass || fail
    [ $FAIL -eq 0 ]
  ) || FAIL=$((FAIL+1))
fi

if command -v pwsh >/dev/null; then
  echo ""; echo "### Smoke: Windows-версия (через pwsh)"
  pwsh -NoProfile -File "$REPO/tests/windows/smoke.ps1" || FAIL=$((FAIL+1))
fi

if [ -n "${SMOKE_REMOTE:-}" ]; then
  echo ""; echo "### Smoke: файлы на GitHub (то, что скачивают пользователи)"
  for f in macos/install.sh macos/Core.swift macos/App.swift windows/install.ps1 windows/ClaudeLimits.Core.ps1 \
           windows/ClaudeLimits.ps1 windows/statusline.ps1 windows/uninstall.ps1; do
    step "$f"
    code=$(curl -s -o "$(mktemp)" -w '%{http_code}' "$RAW/$f")
    if [ "$code" = 200 ] && cmp -s <(curl -s "$RAW/$f" | tr -d '\r') <(tr -d '\r' < "$REPO/$f"); then pass
    elif [ "$code" = 200 ]; then fail "(на GitHub старая версия — сделайте push)"
    else fail "(HTTP $code)"; fi
  done
fi

echo ""
if [ $FAIL -eq 0 ]; then echo "✅ Smoke: всё работает"; else echo "❌ Smoke: есть проблемы ($FAIL)"; exit 1; fi
