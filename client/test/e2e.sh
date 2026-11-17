#!/usr/bin/env bash
# Сквозной тест: ретранслятор + три клиента trinivoice.lua (нужны node, luajit, lua-socket).
set -euo pipefail
cd "$(dirname "$0")/../.."
PORT=${PORT:-7795}
DATA=$(mktemp -d)
CFG="$DATA/config.json"
cat > "$CFG" <<JSON
{ "host": "127.0.0.1", "port": $PORT, "dataDir": "$DATA",
  "maxVoicePacketsPerSec": 5000,
  "radioPasswords": { "911.0": "lspd" },
  "admins": [ { "name": "e2e", "key": "e2e-admin-key-123" } ],
  "bridges": [ { "name": "e2e", "key": "e2e-bridge-key-0123456789" } ], "bridgeCert": "$DATA/none.pem",
  "latestClientVersion": "9.9.9", "minClientVersion": "0.4.0" }
JSON
node server/src/index.js "$CFG" > "$DATA/relay.log" 2>&1 &
RELAY=$!
# мост: игроки, которым основной адрес недоступен, заходят через него
BPORT=$((PORT + 1))
cat > "$DATA/bridge.json" <<JSON
{ "listenHost": "127.0.0.1", "listenPort": $BPORT,
  "upstream": { "host": "127.0.0.1", "port": $PORT, "tlsPort": 0, "name": "e2e", "key": "e2e-bridge-key-0123456789" } }
JSON
node server/src/bridge.js "$DATA/bridge.json" > "$DATA/bridge.log" 2>&1 &
BRIDGE=$!
trap 'kill $RELAY $BRIDGE 2>/dev/null; rm -rf "$DATA"' EXIT
sleep 0.7
luajit client/test/e2e_test.lua "$PORT" "$BPORT"
echo "--- relay log"; tail -n 5 "$DATA/relay.log"; echo "--- bridge log"; tail -n 3 "$DATA/bridge.log"; echo "--- reports"; cat "$DATA/reports.jsonl" 2>/dev/null || true
