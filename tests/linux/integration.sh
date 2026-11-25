#!/bin/bash
# Интеграционные тесты Linux: настоящая установка в изолированный HOME (ваши настройки не трогаются).
# Значок в трее проверяется, если есть GTK/AppIndicator и дисплей (в CI — через xvfb-run).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB" CLAUDE_LIMITS_NO_LAUNCH=1 CLAUDE_LIMITS_NO_DEPS=1
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
DIR="$SB/.local/share/claude-limits"
SETTINGS="$SB/.claude/settings.json"; LIMITS="$SB/.claude/limits.json"; HIST="$SB/.claude/limits-history.jsonl"
AUTOSTART="$SB/.config/autostart/claude-limits.desktop"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "❌ $1"; }
check()     { if eval "$1"; then ok; else bad "$2"; fi; }
check_eq()  { if [ "$1" == "$2" ]; then ok; else bad "$3: ожидалось «$2», получено «$1»"; fi; }
has()       { case "$1" in *"$2"*) ok;; *) bad "$3: нет «$2» в «$1»";; esac; }
json()      { python3 -c "import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'): d=d.get(k) if isinstance(d,dict) else None
print('' if d is None else d)" "$1" "$2" 2>/dev/null; }
lines()     { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
payload()   { local r=$(( $(date +%s) + 3600 ))
  echo "{\"model\":{\"display_name\":\"$3\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":$1,\"resets_at\":$r},\"seven_day\":{\"used_percentage\":$2,\"resets_at\":$((r+86400))}}}"; }

echo "== Установка"
mkdir -p "$SB/.claude"
echo '{"model":"opus","statusLine":{"type":"command","command":"~/old.sh"}}' > "$SETTINGS"
out=$(bash "$REPO/linux/install.sh" 2>&1); code=$?
check_eq "$code" 0 "install.sh завершился успешно"
check_eq "$(cat "$DIR/VERSION")" "$(tr -d '[:space:]' < "$REPO/VERSION")" "версия записана"
for f in claude_limits_core.py claude_limits_parsers.py claude_limits_monitor.py claude_limits_phone.py claude_limits.py statusline.py uninstall.sh; do check "[ -f '$DIR/$f' ]" "установлен $f"; done
check_eq "$(json "$SETTINGS" statusLine.command)" "python3 \"$DIR/statusline.py\"" "statusLine прописан"
check_eq "$(json "$SETTINGS" model)" "opus" "остальные настройки сохранены"
check_eq "$(json "$SETTINGS.bak" statusLine.command)" "~/old.sh" "резервная копия"
has "$out" "будет заменён" "предупреждение о замене чужого statusLine"
check "grep -q 'Exec=python3 \"$DIR/claude_limits.py\"' '$AUTOSTART'" "автозапуск создан"

echo "== Statusline (как его запускает Claude Code)"
cmd="$(json "$SETTINGS" statusLine.command)"
check_eq "$(payload 23.5 41 Opus | sh -c "$cmd")" "[Opus] 5h: 24% 7d: 41%" "строка статуса"
check_eq "$(payload 23.5 41 'Опус' | sh -c "$cmd")" "[Опус] 5h: 24% 7d: 41%" "кириллица в имени модели"
check_eq "$(json "$LIMITS" rate_limits.five_hour.used_percentage)" "23.5" "limits.json записан"
check_eq "$(lines "$HIST")" 1 "одинаковые значения не дублируются в истории"
payload 30 42 Opus | sh -c "$cmd" >/dev/null
check_eq "$(lines "$HIST")" 2 "изменение записано в историю"
check_eq "$(echo 'не json' | sh -c "$cmd"; echo "|$?")" "[Claude]
|0" "битый ввод не ломает statusline"
check_eq "$(sh -c "$cmd" < /dev/null)" "[Claude]" "пустой ввод"
start=$(python3 -c 'import time;print(time.time())')
payload 31 42 Opus | sh -c "$cmd" >/dev/null
ms=$(python3 -c "import time;print(int((time.time()-$start)*1000))")
check "[ $ms -lt 1000 ]" "statusline быстрый (${ms} мс)"
check "[ ! -e '$LIMITS.tmp' ]" "временный файл не остаётся"

echo "== Повторная установка и битый settings.json"
out=$(bash "$REPO/linux/install.sh" 2>&1); code=$?
check_eq "$code" 0 "повторная установка"
case "$out" in *"будет заменён"*) bad "повторная установка не должна предупреждать о своём statusLine";; *) ok;; esac
cp "$SETTINGS" "$SB/good.json"; echo '{сломано' > "$SETTINGS"
bash "$REPO/linux/install.sh" >/dev/null 2>&1; code=$?
check "[ $code -ne 0 ]" "установка отказывается при битом settings.json"
check_eq "$(cat "$SETTINGS")" "{сломано" "битый settings.json не перезаписан"
cp "$SB/good.json" "$SETTINGS"

echo "== Установка «одной командой» (файлы скачиваются)"
lone="$(mktemp -d)"; cp "$REPO/linux/install.sh" "$lone/"
out=$(cd "$lone" && CLAUDE_LIMITS_REPO_RAW="file://$REPO" bash install.sh 2>&1); code=$?
check_eq "$code" 0 "установка со скачиванием"; has "$out" "скачиваю claude_limits_core.py" "файлы скачаны"
out=$(cd "$lone" && CLAUDE_LIMITS_REPO_RAW="file://$REPO" bash < install.sh 2>&1); code=$?
check_eq "$code" 0 "установка через «| bash»"
rm -rf "$lone"

echo "== Значок в трее"
if python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" 2>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  now=$(date +%s)
  echo "{\"updated_at\":$now,\"model\":\"Opus\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":85,\"resets_at\":$((now+7200))},\"seven_day\":{\"used_percentage\":20,\"resets_at\":$((now+200000))}}}" > "$LIMITS"
  echo "{\"t\":$((now-3600)),\"f\":40,\"w\":15}" > "$HIST"
  for case_ in data nodata; do
    [ $case_ = nodata ] && rm -f "$LIMITS" "$HIST"
    out=$(CLAUDE_LIMITS_SELFTEST=1 CLAUDE_LIMITS_SELFTEST_OUT="$SB" timeout 60 python3 "$DIR/claude_limits.py" 2>&1)
    has "$out" "SELFTEST OK" "самопроверка значка ($case_)"
    echo "   $out" | grep SELFTEST
  done
  check "[ \$(wc -c < '$SB/chart-five_hour.png') -gt 3000 ]" "график 5 часов нарисован"
  check "[ -n \"\$(ls '$SB/.cache/claude-limits/icons/' 2>/dev/null)\" ]" "иконки созданы"
else
  echo "   (пропущено: нет GTK для Python или дисплея)"
fi

echo "== Виджет на телефоне (поддельный GitHub)"
GH="$SB/fake-github"; mkdir -p "$GH"
python3 "$REPO/tests/fake_github.py" "$GH" & ghpid=$!
for _ in $(seq 50); do [ -f "$GH/port" ] && break; sleep 0.1; done
export CLAUDE_LIMITS_GITHUB_API="http://127.0.0.1:$(cat "$GH/port")"
out=$(CLAUDE_LIMITS_GITHUB_TOKEN=bad python3 "$DIR/claude_limits_phone.py" setup 2>&1); code=$?
check_eq "$code" 1 "setup с неверным токеном"
has "$out" "401" "понятная ошибка про токен"
out=$(CLAUDE_LIMITS_GITHUB_TOKEN=good python3 "$DIR/claude_limits_phone.py" setup 2>&1); code=$?
check_eq "$code" 0 "setup"
has "$out" "ID для виджета:  g1" "напечатан ID gist"
check_eq "$(stat -c %a "$SB/.claude/limits-phone.json" 2>/dev/null || stat -f %Lp "$SB/.claude/limits-phone.json")" "600" "файл с токеном доступен только владельцу"
check_eq "$(json "$GH/g1.json" public)" "False" "gist секретный"
payload 61 17 Opus | python3 "$DIR/statusline.py" >/dev/null
( cd "$DIR" && python3 -c "
import claude_limits_phone as p, claude_limits_parsers as parsers
s = p.PhoneSync(); s.offer({'code': parsers.new_parser('code').parse_limits()})
assert s.tick(background=False) and s.error is None, s.error" ) 2>&1; check_eq "$?" 0 "PhoneSync выгружает данные"
content=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['files']['claude-limits.json']['content'])" "$GH/g1.json" 2>/dev/null)
has "$content" '"used": 61' "цифры в gist"
has "$(python3 "$DIR/claude_limits_phone.py" status)" "g1" "status"
kill $ghpid 2>/dev/null; wait $ghpid 2>/dev/null
unset CLAUDE_LIMITS_GITHUB_API

echo "== Удаление"
bash "$DIR/uninstall.sh" >/dev/null 2>&1; code=$?
check_eq "$code" 0 "uninstall.sh"
check "[ ! -e '$DIR' ] && [ ! -e '$AUTOSTART' ]" "программа и автозапуск удалены"
check "[ ! -e '$LIMITS' ] && [ ! -e '$HIST' ] && [ ! -e '$SB/.claude/limits-phone.json' ]" "данные и токен для виджета удалены"
check_eq "$(json "$SETTINGS" statusLine)" "" "statusLine убран"
check_eq "$(json "$SETTINGS" model)" "opus" "остальные настройки сохранены"
bash "$REPO/linux/install.sh" >/dev/null 2>&1
echo '{"statusLine":{"type":"command","command":"~/mine.sh"}}' > "$SETTINGS"
bash "$DIR/uninstall.sh" >/dev/null 2>&1
check_eq "$(json "$SETTINGS" statusLine.command)" "~/mine.sh" "чужой statusLine не трогается"

echo ""
if [ $FAIL -eq 0 ]; then echo "✅ Linux integration: все $PASS проверок прошли"; exit 0
else echo "Linux integration: $FAIL провалено, $PASS прошло"; exit 1; fi
