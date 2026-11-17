#!/usr/bin/env bash
# Установка моста TriniVoice на Ubuntu 22.04/24.04 (например, VPS в России).
# Команду с ключом выдаёт главный сервер:  sudo trinivoice add-bridge ИМЯ
#   sudo bash deploy/install-bridge.sh ГЛАВНЫЙ_IP ИМЯ КЛЮЧ ОТПЕЧАТОК [ПОРТ]
# Повторный запуск обновляет программу и ключ.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Запустите через sudo"; exit 1; }
UP="${1:?адрес главного сервера}"; NAME="${2:?имя моста}"; KEY="${3:?ключ}"; FP="${4:?отпечаток сертификата}"
PORT="${5:-7790}"
[[ "$UP" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Странный адрес: $UP"; exit 1; }
[[ "$NAME" =~ ^[A-Za-z0-9_-]{1,16}$ ]] || { echo "Странное имя: $NAME"; exit 1; }
[[ "$KEY" =~ ^[0-9a-f]{32,}$ ]] || { echo "Странный ключ (скопируйте команду целиком)"; exit 1; }
[[ "$FP" =~ ^([0-9A-F]{2}:){31}[0-9A-F]{2}$ ]] || { echo "Странный отпечаток (скопируйте команду целиком)"; exit 1; }
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || { echo "Странный порт: $PORT"; exit 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$SRC/src/bridge.js" ]] || { echo "Не найден $SRC/src/bridge.js: запускайте из папки архива"; exit 1; }

echo "== 1/5 Пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q nodejs iptables-persistent unattended-upgrades curl
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if (( NODE_MAJOR < 18 )); then
  # в Ubuntu 22.04 Node.js 12 — ставим 20 LTS с официального сайта (с проверкой контрольной суммы)
  ARCH="$(uname -m)"; case "$ARCH" in x86_64) A=x64 ;; aarch64) A=arm64 ;; *) echo "Неизвестная архитектура $ARCH"; exit 1 ;; esac
  V=v20.18.1; F="node-$V-linux-$A.tar.xz"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  curl -fsSL -o "$T/$F" "https://nodejs.org/dist/$V/$F"
  curl -fsSL -o "$T/SHASUMS256.txt" "https://nodejs.org/dist/$V/SHASUMS256.txt"
  (cd "$T" && grep " $F\$" SHASUMS256.txt | sha256sum -c -)
  rm -rf /opt/node && mkdir -p /opt/node && tar -xJf "$T/$F" -C /opt/node --strip-components=1
  ln -sf /opt/node/bin/node /usr/bin/node
  echo "  Node.js $(node -v) установлен в /opt/node"
fi
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

echo "== 2/5 Пользователь и файлы"
id trinivoice-bridge >/dev/null 2>&1 || useradd --system --home-dir /opt/trinivoice-bridge --shell /usr/sbin/nologin trinivoice-bridge
install -d -o root -g root -m 755 /opt/trinivoice-bridge /opt/trinivoice-bridge/app
rm -rf /opt/trinivoice-bridge/app/src
cp -r "$SRC/src" "$SRC/package.json" /opt/trinivoice-bridge/app/
chmod -R a+rX,go-w /opt/trinivoice-bridge/app

echo "== 3/5 Настройки"
install -d -o root -g trinivoice-bridge -m 750 /etc/trinivoice-bridge
node -e '
  const [up, name, key, fp, port] = process.argv.slice(1);
  const c = { listenPort: Number(port), upstream: { host: up, port: 7790, tlsPort: 443, name, key, fingerprint: fp } };
  require("fs").writeFileSync("/etc/trinivoice-bridge/config.json", JSON.stringify(c, null, 2) + "\n");
' "$UP" "$NAME" "$KEY" "$FP" "$PORT"
chown root:trinivoice-bridge /etc/trinivoice-bridge/config.json
chmod 640 /etc/trinivoice-bridge/config.json

echo "== 4/5 Брандмауэр: открыть UDP $PORT"
iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
netfilter-persistent save >/dev/null

echo "== 5/5 Служба"
install -m 644 "$SRC/deploy/trinivoice-bridge.service" /etc/systemd/system/trinivoice-bridge.service
systemctl daemon-reload
systemctl enable trinivoice-bridge >/dev/null
systemctl restart trinivoice-bridge
echo "  Проверяю связь с главным сервером (до 15 секунд)..."
STATE=""
for _ in $(seq 1 15); do
  sleep 1
  STATE="$(journalctl -u trinivoice-bridge --since "20 seconds ago" --no-pager -o cat 2>/dev/null | grep -E 'канал до главного|нет связи' | tail -n 1 || true)"
  [[ "$STATE" == *"канал до главного"* ]] && break
done
IP="$(curl -s -m 5 https://ifconfig.me || true)"
echo
echo "================================================================"
if [[ "$STATE" == *"канал до главного"* ]]; then
  echo " ГОТОВО. Мост работает: $STATE"
else
  echo " Мост запущен, но связи с главным пока НЕТ."
  echo " Проверьте: на главном открыт TCP 443 (Security List Oracle),"
  echo " команда скопирована целиком. Журнал: sudo journalctl -u trinivoice-bridge -f"
fi
echo " Адрес моста для игроков: ${IP:-<IP этого сервера>}:$PORT"
echo " Откройте UDP $PORT во входящих правилах (группа безопасности) у хостинга."
echo
echo " Последний шаг — на ГЛАВНОМ сервере (Oracle):"
echo "   sudo trinivoice set-backup ${IP:-IP_МОСТА} $PORT"
echo " и раздайте игрокам новый ~/TriniVoice-players.zip"
echo "================================================================"
