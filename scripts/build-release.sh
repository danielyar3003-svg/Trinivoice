#!/usr/bin/env bash
# Собирает архивы для раздачи: dist/TriniVoice-<версия>-client.zip и -relay.zip
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(grep -oP "SCRIPT_VERSION = '\K[^']+" client/moonloader/trinivoice.lua)
SERVER_VERSION=$(node -p "require('./server/package.json').version")
LATEST=$(grep -oP "latestClientVersion: '\K[^']+" server/src/relay.js)
if [[ "$VERSION" != "$SERVER_VERSION" || "$VERSION" != "$LATEST" ]]; then
  echo "версии не совпадают: клиент $VERSION, server/package.json $SERVER_VERSION, latestClientVersion $LATEST" >&2
  exit 1
fi

echo "== тесты"
(cd server && npm test --silent >/dev/null)
luajit client/test/run.lua >/dev/null
luajit client/test/ui_test.lua >/dev/null
echo "ok"

# UTF-8 с BOM и переводами строк Windows: Блокнот покажет русский текст правильно
notepad() { printf '\xEF\xBB\xBF' > "$2"; sed 's/$/\r/' "$1" >> "$2"; }

rm -rf dist && mkdir -p dist/client/moonloader dist/relay/client
# для игроков: папка moonloader + простая инструкция
cp -r client/moonloader/trinivoice.lua client/moonloader/lib client/moonloader/resource dist/client/moonloader/
notepad client/ПРОЧИТАЙ_МЕНЯ.txt dist/client/ПРОЧИТАЙ_МЕНЯ.txt
# для админа: ретранслятор + установщик + файлы игроков (из них установщик соберёт
# архив с адресом сервера)
cp -r server/src server/deploy server/package.json server/config.example.json server/Dockerfile dist/relay/
cp -r dist/client/moonloader dist/client/ПРОЧИТАЙ_МЕНЯ.txt dist/relay/client/
notepad ИНСТРУКЦИЯ_АДМИНУ.txt dist/relay/ИНСТРУКЦИЯ_АДМИНУ.txt
cp УСТАНОВКА.md dist/relay/
(cd dist/client && zip -qr "../TriniVoice-$VERSION-client.zip" .)
(cd dist/relay && zip -qr "../TriniVoice-$VERSION-relay.zip" .)
rm -rf dist/client dist/relay
ls -la dist
