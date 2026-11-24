#!/bin/bash
# Установка ClaudeLimits для macOS.
# Запуск из папки проекта:   bash macos/install.sh
# Или одной командой:        curl -fsSL https://raw.githubusercontent.com/sasaistomin/ClaudeLimits/main/macos/install.sh | bash
#
# Переменные для тестов:
#   CLAUDE_LIMITS_REPO_RAW   откуда скачивать исходники (по умолчанию GitHub)
#   CLAUDE_LIMITS_NO_LAUNCH=1  не останавливать и не запускать приложение
set -euo pipefail

REPO_RAW="${CLAUDE_LIMITS_REPO_RAW:-https://raw.githubusercontent.com/sasaistomin/ClaudeLimits/main}"
APP="$HOME/Applications/ClaudeLimits.app"
BIN="$APP/Contents/MacOS/ClaudeLimits"
SOURCES=(Core.swift App.swift)

echo "==> ClaudeLimits: установка"

# 1. Компилятор Swift (Xcode Command Line Tools)
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Нужны Xcode Command Line Tools. Сейчас откроется окно установки."
  echo "После установки запустите этот скрипт ещё раз."
  xcode-select --install || true
  exit 1
fi

# 2. Исходники: из папки проекта или скачать (при запуске через curl | bash)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
for f in "${SOURCES[@]}"; do
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$f" ]; then
    cp "$SCRIPT_DIR/$f" "$WORK/"
  else
    echo "==> Скачиваю $f"
    curl -fsSL "$REPO_RAW/macos/$f" -o "$WORK/$f"
  fi
done

# 3. Сборка
echo "==> Собираю (это займёт ~30 секунд)"
( cd "$WORK" && xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" \
    -o "$WORK/ClaudeLimits" "${SOURCES[@]}" )

# 4. .app-бандл
[ -z "${CLAUDE_LIMITS_NO_LAUNCH:-}" ] && { pkill -x ClaudeLimits 2>/dev/null || true; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$WORK/ClaudeLimits" "$BIN"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeLimits</string>
  <key>CFBundleDisplayName</key><string>Claude Limits</string>
  <key>CFBundleIdentifier</key><string>io.github.claudelimits</string>
  <key>CFBundleExecutable</key><string>ClaudeLimits</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# 5. Подключение к Claude Code
"$BIN" --install

# 6. Запуск
if [ -z "${CLAUDE_LIMITS_NO_LAUNCH:-}" ]; then
  open "$APP"
  echo ""
  echo "Готово! Значок появился в меню-баре."
  echo "Отправьте любое сообщение в Claude Code, чтобы появились цифры."
else
  echo "Готово (без запуска)."
fi
