#!/bin/bash
# Установка ClaudeLimits для Linux.
# Одной командой:
#   curl -fsSL https://raw.githubusercontent.com/sasaistomin/ClaudeLimits/main/linux/install.sh | bash
# Или из скачанной папки проекта:
#   bash linux/install.sh
#
# Переменные для тестов:
#   CLAUDE_LIMITS_REPO_RAW     откуда скачивать файлы (по умолчанию GitHub)
#   CLAUDE_LIMITS_NO_LAUNCH=1  не останавливать и не запускать значок
#   CLAUDE_LIMITS_NO_DEPS=1    не ставить системные пакеты
set -euo pipefail

REPO_RAW="${CLAUDE_LIMITS_REPO_RAW:-https://raw.githubusercontent.com/sasaistomin/ClaudeLimits/main}"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-limits"
FILES="claude_limits_core.py claude_limits_parsers.py claude_limits_monitor.py claude_limits_phone.py claude_limits.py statusline.py uninstall.sh"

echo "==> ClaudeLimits: установка"

if ! command -v python3 >/dev/null; then
  echo "Ошибка: нужен python3. Установите его (например: sudo apt install python3) и запустите снова." >&2
  exit 1
fi

# 1. Пакеты для значка в трее (GTK, AppIndicator, уведомления)
have_tray_deps() {
  python3 - <<'PY' 2>/dev/null
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk
import cairo
ok = False
for n in ('AyatanaAppIndicator3', 'AppIndicator3'):
    try:
        gi.require_version(n, '0.1'); ok = True; break
    except ValueError:
        pass
raise SystemExit(0 if ok else 1)
PY
}
if ! have_tray_deps && [ -z "${CLAUDE_LIMITS_NO_DEPS:-}" ]; then
  echo "==> Ставлю пакеты для значка в трее (может спросить пароль sudo)"
  SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  if command -v apt-get >/dev/null; then
    $SUDO apt-get install -y python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 libnotify-bin \
      || $SUDO apt-get install -y python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-appindicator3-0.1 libnotify-bin || true
  elif command -v dnf >/dev/null; then
    $SUDO dnf install -y python3-gobject python3-cairo gtk3 libayatana-appindicator-gtk3 libnotify || true
  elif command -v pacman >/dev/null; then
    $SUDO pacman -S --needed --noconfirm python-gobject python-cairo gtk3 libayatana-appindicator libnotify || true
  elif command -v zypper >/dev/null; then
    $SUDO zypper install -y python3-gobject python3-gobject-cairo typelib-1_0-AyatanaAppIndicator3-0_1 libnotify-tools || true
  fi
fi
if have_tray_deps; then TRAY=1; else
  TRAY=0
  echo "Внимание: не нашёл GTK/AppIndicator для Python — значок в трее не запустится."
  echo "          Строка статуса в Claude Code работать будет. Пакеты: python3-gi, gir1.2-ayatanaappindicator3-0.1, libnotify-bin"
fi

# 2. Остановить запущенный экземпляр
[ -z "${CLAUDE_LIMITS_NO_LAUNCH:-}" ] && pkill -f "claude-limits/claude_limits.py" 2>/dev/null || true

# 3. Скопировать или скачать файлы
SRC=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/claude_limits_core.py" ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
mkdir -p "$INSTALL_DIR"
for f in $FILES; do
  if [ -n "$SRC" ]; then cp "$SRC/$f" "$INSTALL_DIR/$f"
  else echo "    скачиваю $f"; curl -fsSL "$REPO_RAW/linux/$f" -o "$INSTALL_DIR/$f"; fi
done
chmod +x "$INSTALL_DIR"/*.py "$INSTALL_DIR/uninstall.sh"
# Версия (для пункта «Проверить обновления»): VERSION в корне проекта или на GitHub
if [ -n "$SRC" ] && [ -f "$SRC/../VERSION" ]; then VERSION="$(cat "$SRC/../VERSION")"
else VERSION="$(curl -fsSL "$REPO_RAW/VERSION" 2>/dev/null || true)"; fi
VERSION="$(printf '%s' "$VERSION" | head -1 | tr -cd '0-9.')"
printf '%s\n' "${VERSION:-0.0.0}" > "$INSTALL_DIR/VERSION"
echo "==> Версия ${VERSION:-0.0.0}"

# 4. statusLine в ~/.claude/settings.json + автозапуск
python3 "$INSTALL_DIR/claude_limits_core.py" install "$INSTALL_DIR"

# 5. Запуск
if [ -z "${CLAUDE_LIMITS_NO_LAUNCH:-}" ] && [ "$TRAY" = 1 ]; then
  setsid python3 "$INSTALL_DIR/claude_limits.py" >/dev/null 2>&1 < /dev/null &
  echo ""
  echo "Готово! Значок появился в трее (вверху справа или внизу, в зависимости от оболочки)."
  echo "Отправьте любое сообщение в Claude Code, чтобы появились цифры."
  echo "Виджет на iPhone (Scriptable): python3 \"$INSTALL_DIR/claude_limits_phone.py\" setup"
  case "${XDG_CURRENT_DESKTOP:-}" in
    *GNOME*) echo "В «чистом» GNOME (не Ubuntu) нужно расширение AppIndicator: https://extensions.gnome.org/extension/615/";;
  esac
else
  echo "Готово."
fi
