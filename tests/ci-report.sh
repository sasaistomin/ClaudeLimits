#!/bin/bash
# Запускает команду в CI и при неудаче публикует найденные ошибки как аннотацию GitHub
# (аннотации видны без авторизации, в отличие от логов). Использование: bash tests/ci-report.sh <команда> [аргументы]
out="$(mktemp)"
"$@" 2>&1 | tee "$out"
code=${PIPESTATUS[0]}
if [ "$code" -ne 0 ]; then
  {
    grep -E 'FAIL|❌|исключение|Exception|error|Error|ошибк|провален' "$out" | head -60
    echo '--- последние строки ---'
    tail -25 "$out"
  } | cut -c1-400 | "$(command -v python3 || command -v python)" -c 'import sys; t=sys.stdin.read().replace("%","%25").replace("\r","").replace("\n","%0A"); print("::error title=" + sys.argv[1][-90:].replace(":", " ").replace(",", " ") + "::" + t[:60000])' "$*"
fi
rm -f "$out"
exit "$code"
