#!/usr/bin/env bash
# Установка ретранслятора TriniVoice на Ubuntu 24.04 (в том числе Oracle Cloud Always Free).
# Запуск из папки распакованного архива ретранслятора:  sudo bash deploy/install-ubuntu.sh
# Повторный запуск обновляет программу и не трогает config.json и данные.
set -euo pipefail

PORT="${PORT:-7790}"
[[ $EUID -eq 0 ]] || { echo "Запустите через sudo: sudo bash deploy/install-ubuntu.sh"; exit 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$SRC/src/index.js" ]] || { echo "Не найден $SRC/src/index.js: запускайте из папки ретранслятора"; exit 1; }

echo "== 1/6 Пакеты (Node.js из репозитория Ubuntu, без сторонних источников)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q nodejs iptables-persistent unattended-upgrades
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if (( NODE_MAJOR < 18 )); then
  echo "Нужен Node.js 18+, в системе $(node -v). Создайте сервер на образе Ubuntu 24.04."
  exit 1
fi
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

echo "== 2/6 Пользователь без прав входа"
id trinivoice >/dev/null 2>&1 || useradd --system --home-dir /opt/trinivoice --shell /usr/sbin/nologin trinivoice

echo "== 3/6 Файлы программы"
install -d -o root -g root -m 755 /opt/trinivoice /opt/trinivoice/app
rm -rf /opt/trinivoice/app/src
cp -r "$SRC/src" "$SRC/package.json" /opt/trinivoice/app/
chown -R root:root /opt/trinivoice/app
chmod -R a+rX,go-w /opt/trinivoice/app
install -d -o trinivoice -g trinivoice -m 700 /var/lib/trinivoice
install -d -o root -g trinivoice -m 750 /etc/trinivoice

echo "== 4/6 Настройки"
if [[ ! -f /etc/trinivoice/config.json ]]; then
  KEY="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  node -e '
    const fs = require("fs");
    const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    c.host = "0.0.0.0"; c.port = Number(process.argv[3]);
    c.admins = [{ name: "Admin", key: process.argv[2] }];
    c.radioPasswords = {};
    delete c.dataDir;
    fs.writeFileSync("/etc/trinivoice/config.json", JSON.stringify(c, null, 2) + "\n");
  ' "$SRC/config.example.json" "$KEY" "$PORT"
  chown root:trinivoice /etc/trinivoice/config.json
  chmod 640 /etc/trinivoice/config.json
  echo
  echo "  Ключ администратора (сохраните, в игре: /tv adminkey КЛЮЧ):"
  echo "  $KEY"
  echo
else
  echo "  /etc/trinivoice/config.json уже есть — оставляю как есть"
fi

echo "== 5/6 Брандмауэр: открыть UDP $PORT"
if ! iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null; then
  iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
fi
if command -v ip6tables >/dev/null && ! ip6tables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null; then
  ip6tables -I INPUT -p udp --dport "$PORT" -j ACCEPT || true
fi
netfilter-persistent save >/dev/null

echo "== 6/6 Служба systemd"
install -m 644 "$SRC/deploy/trinivoice.service" /etc/systemd/system/trinivoice.service
systemctl daemon-reload
systemctl enable trinivoice >/dev/null
systemctl restart trinivoice
sleep 1
systemctl --no-pager --lines=5 status trinivoice || true

IP="$(curl -s -m 5 https://ifconfig.me || true)"
echo
echo "Готово. Адрес для игроков: ${IP:-<публичный IP сервера>}:$PORT"
echo "Не забудьте открыть UDP $PORT в Security List сети Oracle (см. УСТАНОВКА.md)."
echo "Настройки: sudo nano /etc/trinivoice/config.json, затем sudo systemctl restart trinivoice"
echo "Журнал:    sudo journalctl -u trinivoice -f"
