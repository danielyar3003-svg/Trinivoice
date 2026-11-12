#!/usr/bin/env bash
# Собирает архив для игроков, в который уже вписан адрес ретранслятора:
# игроку остаётся распаковать его в папку с игрой.
# Использование: bash deploy/make-player-zip.sh АДРЕС ПОРТ ФАЙЛ.zip
set -euo pipefail
HOST="${1:?адрес}"; PORT="${2:?порт}"; OUT="${3:?файл}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$SRC/client/moonloader/trinivoice.lua" ]] || { echo "Нет папки client/moonloader рядом с deploy"; exit 1; }
[[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Странный адрес: $HOST"; exit 1; }
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || { echo "Странный порт: $PORT"; exit 1; }
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cp -r "$SRC/client/moonloader" "$T/"
mkdir -p "$T/moonloader/config"
# Остальные настройки скрипт возьмёт по умолчанию.
printf '[main]\r\nhost=%s\r\nport=%s\r\n' "$HOST" "$PORT" > "$T/moonloader/config/trinivoice.ini"
cp "$SRC/client/ПРОЧИТАЙ_МЕНЯ.txt" "$T/"
rm -f "$OUT"
(cd "$T" && zip -qr "$OUT" .)
echo "$OUT"
