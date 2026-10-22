#!/bin/bash
# Помощник Torrent Disk: запускает distribyted и подключает его WebDAV как диск в Finder.
# Использование: tdisk.sh add FILE... | open | start | stop | folder
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$HOME/Library/Application Support/TorrentDisk"
TORRENTS="$DIR/torrents"
CONF="$DIR/config.yaml"
LOGS="$DIR/logs"
BIN="$DIR/distribyted"
URL="http://127.0.0.1:36911/"
MATCH="distribyted --config $CONF"

init() {
  mkdir -p "$TORRENTS" "$LOGS" "$DIR/metadata"

  # Копируем distribyted из приложения: так он не зависит от того,
  # где лежит Torrent Disk.app и не попадает под карантин Gatekeeper.
  if ! cmp -s "$HERE/distribyted" "$BIN"; then
    stop
    cp -f "$HERE/distribyted" "$BIN"
    chmod +x "$BIN"
    xattr -c "$BIN" 2>/dev/null || true
  fi

  # WebDAV в distribyted слушает все сетевые интерфейсы, поэтому пароль случайный.
  if [ ! -s "$DIR/.password" ]; then
    openssl rand -hex 12 > "$DIR/.password"
    chmod 600 "$DIR/.password"
  fi
  PASS=$(cat "$DIR/.password")

  cat > "$CONF" <<EOF
http:
  port: 4444
  ip: "127.0.0.1"
  httpfs: true

webdav:
  port: 36911
  user: admin
  pass: "$PASS"

torrent:
  global_cache_size: 2048
  metadata_folder: "$DIR/metadata"
  continue_when_add_timeout: true
  add_timeout: 60
  read_timeout: 120

log:
  path: "$LOGS"
  max_backups: 2
  max_size: 50

routes:
  - name: torrents
    torrent_folder: "$TORRENTS"
EOF
}

is_running() { pgrep -f "$MATCH" >/dev/null 2>&1; }

mount_point() { mount | grep -F "127.0.0.1:36911" | sed -E 's/^.* on (.*) \(webdav.*$/\1/' | head -n 1; }

start() {
  is_running && return 0
  nohup "$BIN" --config "$CONF" </dev/null >"$LOGS/stdout.log" 2>&1 &
  # Ждём, пока поднимется WebDAV (торренты загружаются до его старта).
  for _ in $(seq 1 180); do
    if curl -s -o /dev/null -u "admin:$PASS" "$URL"; then return 0; fi
    if ! is_running; then
      echo "distribyted завершился с ошибкой:" >&2
      tail -n 15 "$LOGS/stdout.log" >&2
      exit 1
    fi
    sleep 1
  done
  echo "distribyted не запустился за 3 минуты. Лог: $LOGS/stdout.log" >&2
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
  pkill -INT -f "$MATCH" 2>/dev/null || true
  for _ in $(seq 1 15); do
    is_running || return 0
    sleep 1
  done
  pkill -9 -f "$MATCH" 2>/dev/null || true
}

open_disk() {
  start
  local code mp
  code=$(curl -s -o /dev/null -w '%{http_code}' -X PROPFIND -H "Depth: 0" -u "admin:$PASS" "$URL")
  if [ "$code" != 207 ]; then
    echo "Пока не добавлено ни одного торрента. Перетащите .torrent-файл на значок Torrent Disk." >&2
    exit 1
  fi
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
    init
    for f in "$@"; do cp -f "$f" "$TORRENTS/"; done
    # distribyted читает папку с торрентами только при старте — перезапускаем.
    stop
    open_disk
    ;;
  open) init; open_disk ;;
  start) init; start ;;
  stop) stop ;;
  folder) mkdir -p "$TORRENTS"; open "$TORRENTS" ;;
  *) echo "usage: tdisk.sh add FILE... | open | start | stop | folder" >&2; exit 2 ;;
esac
