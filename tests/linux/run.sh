#!/bin/bash
# Все тесты Linux-версии: юнит-тесты логики, парсеров, фонового опроса и выгрузки для виджета + интеграционные тесты установки.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "### Linux: юнит-тесты"; python3 "$REPO/tests/linux/test_core.py"; u=$?
python3 "$REPO/tests/linux/test_sources.py"; s=$?
python3 "$REPO/tests/linux/test_phone.py"; p=$?
echo ""; echo "### Linux: интеграционные тесты"; bash "$REPO/tests/linux/integration.sh"; i=$?
[ $u -eq 0 ] && [ $s -eq 0 ] && [ $p -eq 0 ] && [ $i -eq 0 ]
