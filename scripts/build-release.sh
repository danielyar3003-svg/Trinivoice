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

rm -rf dist && mkdir -p dist/client/moonloader dist/relay
cp -r client/moonloader/trinivoice.lua client/moonloader/lib client/moonloader/resource dist/client/moonloader/
cat > dist/client/УСТАНОВКА.txt <<TXT
TriniVoice $VERSION — голосовой чат для SA-MP

1. Нужны MoonLoader и SAMPFUNCS.
2. Скопируйте папку moonloader из архива в папку игры (с заменой).
3. Для меню установите mimgui (BlastHack, автор FYP).
   Для иконок — fAwesome6 для mimgui (BlastHack), файл moonloader/lib/fAwesome6.lua.
   Для автозвонков по сообщениям сервера — SAMP.Lua (lib/samp/events).
4. В игре: /tv — меню, вкладка «Сервер» — адрес ретранслятора.
   Без mimgui: /tv server АДРЕС ПОРТ, /tv help — все команды.

Клавиши по умолчанию: X — говорить, B — дальность, Z — рация.
Звук качественнее с Opus: положите 32-битный opus.dll в moonloader/lib
(он нужен всем, кто хочет вас слышать) и выберите Opus во вкладке «Звук».

Шрифты Montserrat — лицензия SIL OFL (moonloader/resource/trinivoice/Montserrat-OFL.txt).
TXT
cp -r server/src server/package.json server/config.example.json server/Dockerfile dist/relay/
cat > dist/relay/README.txt <<TXT
TriniVoice relay $VERSION

Нужен Node.js 18+ и открытый UDP-порт (по умолчанию 7790).
  cp config.example.json config.json   # впишите admins, radioPasswords, allowedRooms
  node src/index.js config.json
Жалобы: data/reports.jsonl, муты и баны: data/moderation.json.
TXT
(cd dist/client && zip -qr "../TriniVoice-$VERSION-client.zip" .)
(cd dist/relay && zip -qr "../TriniVoice-$VERSION-relay.zip" .)
rm -rf dist/client dist/relay
ls -la dist
