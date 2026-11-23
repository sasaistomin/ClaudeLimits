#!/bin/bash
# Установка ClaudeLimits для macOS.
# Запуск из папки проекта:   ./macos/install.sh
# Или одной командой:        curl -fsSL https://raw.githubusercontent.com/sasaistomin/claude-limits/main/macos/install.sh | bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/sasaistomin/claude-limits/main"
APP="$HOME/Applications/ClaudeLimits.app"
BIN="$APP/Contents/MacOS/ClaudeLimits"

echo "==> ClaudeLimits: установка"

# 1. Компилятор Swift (Xcode Command Line Tools)
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Нужны Xcode Command Line Tools. Сейчас откроется окно установки."
  echo "После установки запустите этот скрипт ещё раз."
  xcode-select --install || true
  exit 1
fi

# 2. Исходник: из папки проекта или скачать
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/ClaudeLimits.swift" ]; then
  cp "$SCRIPT_DIR/ClaudeLimits.swift" "$WORK/"
else
  echo "==> Скачиваю исходник"
  curl -fsSL "$REPO_RAW/macos/ClaudeLimits.swift" -o "$WORK/ClaudeLimits.swift"
fi

# 3. Сборка
echo "==> Собираю (это займёт ~30 секунд)"
xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -o "$WORK/ClaudeLimits" "$WORK/ClaudeLimits.swift"

# 4. .app-бандл
pkill -x ClaudeLimits 2>/dev/null || true
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
open "$APP"
echo ""
echo "Готово! Значок появился в меню-баре."
echo "Отправьте любое сообщение в Claude Code, чтобы появились цифры."
