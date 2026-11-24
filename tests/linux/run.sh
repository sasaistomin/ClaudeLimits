#!/bin/bash
# Все тесты Linux-версии: юнит-тесты логики + интеграционные тесты установки.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "### Linux: юнит-тесты"; python3 "$REPO/tests/linux/test_core.py"; u=$?
echo ""; echo "### Linux: интеграционные тесты"; bash "$REPO/tests/linux/integration.sh"; i=$?
[ $u -eq 0 ] && [ $i -eq 0 ]
