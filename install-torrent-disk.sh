#!/bin/bash
# Установщик "Torrent Disk" для macOS.
# Создаёт приложение ~/Applications/Torrent Disk.app: перетащите на него .torrent —
# и содержимое торрента (включая ZIP-архивы как папки) откроется в Finder как диск.
# Работает поверх distribyted через WebDAV, расширение ядра macFUSE не требуется.
#
# Запуск:  bash install-torrent-disk.sh [путь/к/файлу distribyted]
# Без аргумента берёт distribyted-*-darwin-* из Загрузок или скачивает его с GitHub.

set -euo pipefail

DIR="$HOME/TorrentDisk"
APP="$HOME/Applications/Torrent Disk.app"

DISTRIBYTED_VERSION="v0.15.0"
DISTRIBYTED_URL="https://github.com/distribyted/distribyted/releases/download/$DISTRIBYTED_VERSION/distribyted-$DISTRIBYTED_VERSION-darwin-arm64"

mkdir -p "$DIR/torrents" "$DIR/data/logs" "$HOME/Applications"

BIN_SRC="${1:-}"
if [ -z "$BIN_SRC" ]; then
  BIN_SRC=$(ls -t "$HOME"/Downloads/distribyted-*-darwin-* 2>/dev/null | head -n 1 || true)
fi
if [ -z "$BIN_SRC" ]; then
  if [ "$(uname -m)" != "arm64" ]; then
    echo "Готовая сборка distribyted есть только для Mac на Apple Silicon (M1 и новее)."
    echo "Соберите её сами: brew install go && go install github.com/distribyted/distribyted/cmd/distribyted@latest"
    echo "и запустите: bash install-torrent-disk.sh ~/go/bin/distribyted"
    exit 1
  fi
  echo "Скачиваю distribyted $DISTRIBYTED_VERSION..."
  BIN_SRC="$DIR/distribyted.download"
  curl -fL --progress-bar -o "$BIN_SRC" "$DISTRIBYTED_URL"
fi
if [ ! -f "$BIN_SRC" ]; then
  echo "Не найден файл: $BIN_SRC"
  exit 1
fi

# Если уже запущен — останавливаем, чтобы заменить файл программы.
pkill -f "$DIR/distribyted --config" 2>/dev/null || true
sleep 1

cp "$BIN_SRC" "$DIR/distribyted"
rm -f "$DIR/distribyted.download"
chmod +x "$DIR/distribyted"
xattr -c "$DIR/distribyted" 2>/dev/null || true

# WebDAV в distribyted слушает все сетевые интерфейсы, поэтому пароль случайный.
if [ ! -f "$DIR/.password" ]; then
  openssl rand -hex 12 > "$DIR/.password"
  chmod 600 "$DIR/.password"
fi
PASS=$(cat "$DIR/.password")

cat > "$DIR/config.yaml" <<EOF
http:
  port: 4444
  ip: "127.0.0.1"
  httpfs: true

webdav:
  port: 36911
  user: admin
  pass: "$PASS"

torrent:
  # Сколько МБ скачанных кусков хранить на диске (старые удаляются).
  global_cache_size: 2048
  metadata_folder: "$DIR/data/metadata"
  continue_when_add_timeout: true
  add_timeout: 60
  read_timeout: 120

log:
  path: "$DIR/data/logs"
  max_backups: 2
  max_size: 50

routes:
  - name: torrents
    torrent_folder: "$DIR/torrents"
EOF

# Вспомогательный скрипт: add / open / stop.
cat > "$DIR/tdisk.sh" <<'EOF'
#!/bin/bash
set -uo pipefail

DIR="$HOME/TorrentDisk"
BIN="$DIR/distribyted"
CONF="$DIR/config.yaml"
PASS=$(cat "$DIR/.password")
URL="http://127.0.0.1:36911/"

is_running() { pgrep -f "$BIN --config" >/dev/null 2>&1; }

mount_point() { mount | grep -F "127.0.0.1:36911" | sed -E 's/^.* on (.*) \(webdav.*$/\1/' | head -n 1; }

start() {
  is_running && return 0
  nohup "$BIN" --config "$CONF" </dev/null >"$DIR/data/logs/stdout.log" 2>&1 &
  # Ждём, пока поднимется WebDAV (торренты загружаются до его старта).
  for _ in $(seq 1 180); do
    if curl -s -o /dev/null -u "admin:$PASS" "$URL"; then return 0; fi
    if ! is_running; then
      echo "distribyted завершился с ошибкой:" >&2
      tail -n 15 "$DIR/data/logs/stdout.log" >&2
      exit 1
    fi
    sleep 1
  done
  echo "distribyted не запустился за 3 минуты. Лог: $DIR/data/logs/stdout.log" >&2
  exit 1
}

unmount_disk() {
  local mp
  mp=$(mount_point)
  if [ -n "$mp" ]; then
    umount "$mp" 2>/dev/null || diskutil unmount force "$mp" >/dev/null 2>&1 || true
  fi
}

stop() {
  unmount_disk
  pkill -INT -f "$BIN --config" 2>/dev/null || true
  for _ in $(seq 1 15); do
    is_running || return 0
    sleep 1
  done
  pkill -9 -f "$BIN --config" 2>/dev/null || true
}

open_disk() {
  start
  local mp
  mp=$(mount_point)
  if [ -z "$mp" ]; then
    osascript -e "mount volume \"$URL\" as user name \"admin\" with password \"$PASS\"" >/dev/null
    mp=$(mount_point)
  fi
  [ -n "$mp" ] && open "$mp"
}

case "${1:-open}" in
  add)
    shift
    for f in "$@"; do cp -f "$f" "$DIR/torrents/"; done
    # distribyted читает папку с торрентами только при старте — перезапускаем.
    stop
    open_disk
    ;;
  open) open_disk ;;
  stop) stop ;;
  *) echo "usage: tdisk.sh add FILE... | open | stop" >&2; exit 2 ;;
esac
EOF
chmod +x "$DIR/tdisk.sh"

# Приложение-"капля" на AppleScript.
TMPD=$(mktemp -d)
APPLESCRIPT="$TMPD/TorrentDisk.applescript"
cat > "$APPLESCRIPT" <<'EOF'
on run
	set r to button returned of (display dialog "Перетащите .torrent-файл на значок Torrent Disk, чтобы открыть его как диск." & return & return & "Все добавленные торренты лежат в папке ~/TorrentDisk/torrents." buttons {"Остановить", "Открыть диск"} default button "Открыть диск" with title "Torrent Disk")
	if r is "Открыть диск" then
		runHelper("open")
	else
		runHelper("stop")
	end if
end run

on open theFiles
	set args to ""
	repeat with f in theFiles
		set p to POSIX path of f
		if p ends with ".torrent" then set args to args & " " & quoted form of p
	end repeat
	if args is "" then
		display alert "Torrent Disk" message "Нужен файл с расширением .torrent."
		return
	end if
	display notification "Подключаю торрент…" with title "Torrent Disk"
	runHelper("add" & args)
end open

on runHelper(cmd)
	try
		do shell script quoted form of (POSIX path of (path to home folder) & "TorrentDisk/tdisk.sh") & " " & cmd
	on error errMsg
		display alert "Torrent Disk: ошибка" message errMsg
	end try
end runHelper
EOF

rm -rf "$APP"
osacompile -o "$APP" "$APPLESCRIPT"
rm -rf "$TMPD"

echo
echo "Готово: $APP"
echo "Перетащите .torrent-файл на значок Torrent Disk (можно закрепить его в Dock)."
open -R "$APP"
