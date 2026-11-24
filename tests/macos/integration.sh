#!/bin/bash
# Интеграционные тесты macOS: настоящая установка в изолированный HOME (ваши настройки не трогаются).
# Запуск: bash tests/macos/run.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="$(mktemp -d)"            # «домашняя папка» для теста
trap 'pkill -f "$SB/Applications/ClaudeLimits.app" 2>/dev/null; rm -rf "$SB"' EXIT
export HOME="$SB" CLAUDE_LIMITS_NO_LAUNCH=1
APP="$SB/Applications/ClaudeLimits.app"
BIN="$APP/Contents/MacOS/ClaudeLimits"
SETTINGS="$SB/.claude/settings.json"
LIMITS="$SB/.claude/limits.json"
HIST="$SB/.claude/limits-history.jsonl"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "❌ $1"; }
assert()          { if eval "$1"; then ok; else bad "$2"; fi; }
assert_eq()       { if [ "$1" == "$2" ]; then ok; else bad "$3: ожидалось «$2», получено «$1»"; fi; }
assert_contains() { case "$1" in *"$2"*) ok;; *) bad "$3: «$1» не содержит «$2»";; esac; }
json()            { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }   # json <file> <key.path>
lines()           { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
payload()         { # payload <5h %> <7d %>
  local r=$(( $(date +%s) + 3600 ))
  echo "{\"model\":{\"display_name\":\"Opus\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":$1,\"resets_at\":$r},\"seven_day\":{\"used_percentage\":$2,\"resets_at\":$((r+86400))}}}"
}

echo "== Установка (install.sh из папки проекта)"
mkdir -p "$SB/.claude"
cat > "$SETTINGS" <<'EOF'
{"model":"opus","theme":"dark","statusLine":{"type":"command","command":"~/old-statusline.sh"}}
EOF
cp "$SETTINGS" "$SB/original-settings.json"
out=$(bash "$REPO/macos/install.sh" 2>&1); code=$?
assert_eq "$code" 0 "install.sh завершился успешно"
assert "[ -x '$BIN' ]" "бинарник установлен"
assert "plutil -lint '$APP/Contents/Info.plist' >/dev/null" "Info.plist корректен"
assert_eq "$(plutil -extract LSUIElement raw -o - "$APP/Contents/Info.plist")" "true" "приложение без иконки в Dock"
assert "codesign -v '$APP' 2>/dev/null" "подпись (ad-hoc) валидна"
assert_eq "$(json "$SETTINGS" statusLine.command)" "\"$BIN\" --statusline" "statusLine указывает на установленный бинарник"
assert_eq "$(json "$SETTINGS" model)" "opus" "остальные настройки сохранены (model)"
assert_eq "$(json "$SETTINGS" theme)" "dark" "остальные настройки сохранены (theme)"
assert "cmp -s '$SB/.claude/settings.json.bak' '$SB/original-settings.json'" "резервная копия settings.json.bak"
assert_contains "$out" "будет заменён" "предупреждение о замене чужого statusLine"

echo "== Statusline"
out=$(payload 23.5 41 | "$BIN" --statusline)
assert_eq "$out" "[Opus] 5h: 24% 7d: 41%" "строка статуса"
assert "awk -v v=\"$(json "$LIMITS" rate_limits.five_hour.used_percentage)\" 'BEGIN{exit !(v+0==23.5)}'" "limits.json записан (23.5)"
assert "[ -n \"\$(json '$LIMITS' updated_at)\" ]" "limits.json содержит updated_at"
assert_eq "$(lines "$HIST")" 1 "первая строка истории"

payload 23.5 41 | "$BIN" --statusline >/dev/null
assert_eq "$(lines "$HIST")" 1 "одинаковые значения не дублируются в истории"
payload 30 42 | "$BIN" --statusline >/dev/null
assert_eq "$(lines "$HIST")" 2 "изменение записано в историю"
assert_contains "$(tail -1 "$HIST")" '"f":30' "в истории новое значение 5ч"

cp "$LIMITS" "$SB/limits-before.json"
out=$(echo '{"model":{"display_name":"Opus"}}' | "$BIN" --statusline)
assert_eq "$out" "[Opus]" "без rate_limits — только модель"
assert "cmp -s '$LIMITS' '$SB/limits-before.json'" "без rate_limits limits.json не перезаписывается"
out=$(echo 'не json' | "$BIN" --statusline); code=$?
assert_eq "$out|$code" "[Claude]|0" "битый ввод не ломает statusline"
out=$("$BIN" --statusline < /dev/null)
assert_eq "$out" "[Claude]" "пустой ввод"
out=$(echo '{"model":{"display_name":"Sonnet"},"rate_limits":{"seven_day":{"used_percentage":5,"resets_at":1}}}' | "$BIN" --statusline)
assert_eq "$out" "[Sonnet] 7d: 5%" "только недельное окно"

# Ровно так, как Claude Code запускает команду из settings.json (через shell, с кавычками)
cmd="$(json "$SETTINGS" statusLine.command)"
out=$(payload 50 60 | sh -c "$cmd")
assert_eq "$out" "[Opus] 5h: 50% 7d: 60%" "команда из settings.json работает через sh -c"

start=$(perl -MTime::HiRes=time -e 'print time')
payload 51 60 | "$BIN" --statusline >/dev/null
dur=$(perl -MTime::HiRes=time -e "printf '%.0f', (time - $start) * 1000")
assert "[ $dur -lt 1000 ]" "statusline быстрый (${dur} мс < 1000 мс)"

echo "== Очистка старой истории"
old=$(( $(date +%s) - 20 * 86400 ))
{ for i in $(seq 1 15000); do echo "{\"t\":$old,\"f\":1,\"fr\":1,\"w\":1,\"wr\":1}"; done; } > "$HIST"
payload 70 80 | "$BIN" --statusline >/dev/null
assert_eq "$(lines "$HIST")" 1 "файл > 512 КБ: старше 8 дней удалено, новое осталось"
assert_contains "$(cat "$HIST")" '"f":70' "осталась именно новая запись"

echo "== Повторная установка"
out=$(bash "$REPO/macos/install.sh" 2>&1); code=$?
assert_eq "$code" 0 "повторная установка"
case "$out" in *"будет заменён"*) bad "повторная установка не должна предупреждать о замене своего statusLine";; *) ok;; esac
assert_eq "$(json "$SETTINGS" model)" "opus" "настройки целы после повторной установки"

echo "== Битый settings.json"
echo '{сломано' > "$SETTINGS"
"$BIN" --install >/dev/null 2>&1; code=$?
assert_eq "$code" 1 "--install отказывается при битом JSON"
assert_eq "$(cat "$SETTINGS")" '{сломано' "битый settings.json не перезаписан"
rm "$SETTINGS"
"$BIN" --install >/dev/null; code=$?
assert_eq "$code|$(json "$SETTINGS" statusLine.type)" "0|command" "settings.json создаётся, если его не было"

echo "== Установка «одной командой» (исходники скачиваются)"
lone="$(mktemp -d)"; cp "$REPO/macos/install.sh" "$lone/"
out=$(cd "$lone" && CLAUDE_LIMITS_REPO_RAW="file://$REPO" bash install.sh 2>&1); code=$?
assert_eq "$code" 0 "установка со скачиванием исходников"
assert_contains "$out" "Скачиваю Core.swift" "исходники скачаны"
out=$(cd "$lone" && CLAUDE_LIMITS_REPO_RAW="file://$REPO" bash < install.sh 2>&1); code=$?
assert_eq "$code" 0 "установка через «| bash» (скрипт из stdin)"
rm -rf "$lone"
assert "[ -x '$BIN' ]" "бинарник на месте"

echo "== Интерфейс"
now=$(date +%s)
cat > "$LIMITS" <<EOF
{"updated_at":$now,"model":"Opus","rate_limits":{"five_hour":{"used_percentage":30,"resets_at":$((now+7200))},"seven_day":{"used_percentage":20,"resets_at":$((now+200000))}}}
EOF
echo "{\"t\":$((now-3600)),\"f\":10,\"fr\":$((now+7200)),\"w\":15,\"wr\":$((now+200000))}" > "$HIST"
for mode in "" "week dark"; do
  "$BIN" --snapshot "$SB/shot.png" $mode >/dev/null 2>&1
  size=$(stat -f %z "$SB/shot.png" 2>/dev/null || echo 0)
  assert "[ $size -gt 20000 ]" "окно рисуется (--snapshot $mode: $size байт)"
  rm -f "$SB/shot.png"
done
"$BIN" >/dev/null 2>&1 &
pid=$!
sleep 3
assert "kill -0 $pid 2>/dev/null" "приложение запускается и работает"
kill $pid 2>/dev/null; wait $pid 2>/dev/null

echo "== Удаление"
echo '{"model":"opus","statusLine":{"type":"command","command":"\"'"$BIN"'\" --statusline"}}' > "$SETTINGS"
bash "$REPO/macos/uninstall.sh" >/dev/null 2>&1; code=$?
assert_eq "$code" 0 "uninstall.sh"
assert "[ ! -e '$APP' ]" "приложение удалено"
assert "[ ! -e '$LIMITS' ] && [ ! -e '$HIST' ]" "данные удалены"
assert_eq "$(json "$SETTINGS" statusLine.command)" "" "statusLine убран"
assert_eq "$(json "$SETTINGS" model)" "opus" "остальные настройки сохранены"

bash "$REPO/macos/install.sh" >/dev/null 2>&1
echo '{"statusLine":{"type":"command","command":"~/mine.sh"}}' > "$SETTINGS"
bash "$REPO/macos/uninstall.sh" >/dev/null 2>&1
assert_eq "$(json "$SETTINGS" statusLine.command)" "~/mine.sh" "чужой statusLine при удалении не трогается"

echo ""
if [ $FAIL -eq 0 ]; then echo "✅ macOS integration: все $PASS проверок прошли"; exit 0
else echo "macOS integration: $FAIL провалено, $PASS прошло"; exit 1; fi
