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
  "latestClientVersion": "9.9.9", "minClientVersion": "0.4.0" }
JSON
node server/src/index.js "$CFG" > "$DATA/relay.log" 2>&1 &
RELAY=$!
trap 'kill $RELAY 2>/dev/null; rm -rf "$DATA"' EXIT
sleep 0.5
luajit client/test/e2e_test.lua "$PORT"
echo "--- relay log"; tail -n 5 "$DATA/relay.log"; echo "--- reports"; cat "$DATA/reports.jsonl" 2>/dev/null || true
