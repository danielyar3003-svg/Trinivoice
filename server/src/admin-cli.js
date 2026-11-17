// Команды админа на главном сервере (запуск через sudo):
//   sudo trinivoice add-bridge ИМЯ        — разрешить мост, выдать команду для его установки
//   sudo trinivoice remove-bridge ИМЯ     — убрать мост
//   sudo trinivoice set-backup IP [ПОРТ]  — вписать адрес моста в архив игроков как запасной
//   sudo trinivoice players-zip           — пересобрать ~/TriniVoice-players.zip
//   sudo trinivoice bridges               — список мостов
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fingerprintOf, validName } from './link.js';

const CONFIG = process.env.TRINIVOICE_CONFIG ?? '/etc/trinivoice/config.json';
const CERT = path.join(path.dirname(CONFIG), 'link-cert.pem');
const KEY = path.join(path.dirname(CONFIG), 'link-key.pem');
const APP = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');

const die = (text) => { console.error(text); process.exit(1); };
const readConfig = () => {
  try { return JSON.parse(fs.readFileSync(CONFIG, 'utf8')); } catch (e) {
    die(e.code === 'EACCES' ? 'Нет доступа к настройкам: запустите через sudo' : `Не прочитать ${CONFIG}: ${e.message}`);
  }
};
const writeConfig = (c) => {
  fs.writeFileSync(CONFIG + '.tmp', JSON.stringify(c, null, 2) + '\n', { mode: 0o640 });
  fs.renameSync(CONFIG + '.tmp', CONFIG);
  try { execFileSync('chown', ['root:trinivoice', CONFIG]); } catch { /* не на сервере */ }
};
const run = (cmd, args) => { try { execFileSync(cmd, args, { stdio: 'ignore' }); return true; } catch { return false; } };

function ensureCert() {
  if (!fs.existsSync(CERT) || !fs.existsSync(KEY)) {
    execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
      '-days', '3650', '-subj', '/CN=trinivoice', '-keyout', KEY, '-out', CERT], { stdio: 'ignore' });
    run('chown', ['root:trinivoice', CERT, KEY]);
    fs.chmodSync(CERT, 0o640);
    fs.chmodSync(KEY, 0o640);
  }
  return fingerprintOf(fs.readFileSync(CERT));
}

function openTcp(port) {
  const p = String(port);
  if (!run('iptables', ['-C', 'INPUT', '-p', 'tcp', '--dport', p, '-j', 'ACCEPT'])) run('iptables', ['-I', 'INPUT', '-p', 'tcp', '--dport', p, '-j', 'ACCEPT']);
  run('netfilter-persistent', ['save']);
}

function restart() {
  if (!run('systemctl', ['restart', 'trinivoice'])) console.log('  (не удалось перезапустить службу: sudo systemctl restart trinivoice)');
}

function playersZip(c) {
  const ip = c.publicIp;
  if (!ip) die('Не знаю публичный IP сервера: переустановите (sudo bash deploy/install-ubuntu.sh) или задайте "publicIp" в настройках');
  const owner = process.env.SUDO_USER || 'root';
  const home = execFileSync('getent', ['passwd', owner]).toString().split(':')[5];
  const out = path.join(home, 'TriniVoice-players.zip');
  const args = [path.join(APP, 'deploy/make-player-zip.sh'), ip, String(c.port ?? 7790), out];
  if (c.playersBackup) args.push(...c.playersBackup.split(':'));
  execFileSync('bash', args, { stdio: 'ignore' });
  run('chown', [`${owner}:${owner}`, out]);
  console.log(`Готов архив для игроков: ${out}`);
  console.log(`  основной адрес: ${ip}:${c.port ?? 7790}` + (c.playersBackup ? `, запасной (мост): ${c.playersBackup}` : ', запасного нет'));
}

const [cmd, ...args] = process.argv.slice(2);
const c = readConfig();
c.bridges ??= [];

if (cmd === 'add-bridge') {
  const name = args[0];
  if (!validName(name)) die('Имя моста: латиница/цифры/_/-, до 16 символов. Пример: sudo trinivoice add-bridge ru');
  const fp = ensureCert();
  const key = crypto.randomBytes(24).toString('hex');
  c.bridges = c.bridges.filter((b) => b.name !== name).concat([{ name, key }]);
  c.bridgeTlsPort ??= 443;
  writeConfig(c);
  openTcp(c.bridgeTlsPort);
  restart();
  const ip = c.publicIp ?? 'IP_ЭТОГО_СЕРВЕРА';
  console.log(`
Мост "${name}" разрешён. Запасной канал TLS: TCP ${c.bridgeTlsPort} (откройте его в Security List Oracle!).

На сервере моста выполните из папки распакованного архива (ОДНОЙ строкой):

sudo bash deploy/install-bridge.sh ${ip} ${name} ${key} ${fp}

Ключ секретный: не публикуйте его. Новый ключ: снова sudo trinivoice add-bridge ${name}
`);
} else if (cmd === 'remove-bridge') {
  const before = c.bridges.length;
  c.bridges = c.bridges.filter((b) => b.name !== args[0]);
  if (c.bridges.length === before) die(`Моста "${args[0]}" нет`);
  writeConfig(c);
  restart();
  console.log(`Мост "${args[0]}" убран`);
} else if (cmd === 'set-backup') {
  const ip = args[0];
  const port = Number(args[1] ?? 7790);
  if (!/^[A-Za-z0-9.-]+$/.test(ip ?? '') || !(port > 0 && port < 65536)) die('Пример: sudo trinivoice set-backup 1.2.3.4 7790');
  c.playersBackup = `${ip}:${port}`;
  writeConfig(c);
  playersZip(c);
} else if (cmd === 'players-zip') {
  playersZip(c);
} else if (cmd === 'bridges') {
  if (!c.bridges.length) console.log('Мостов нет. Добавить: sudo trinivoice add-bridge ru');
  for (const b of c.bridges) console.log(`  ${b.name}`);
  if (c.playersBackup) console.log(`Запасной адрес в архиве игроков: ${c.playersBackup}`);
  console.log('Состояние каналов: sudo journalctl -u trinivoice | grep bridge | tail');
} else {
  console.log(`Команды:
  sudo trinivoice add-bridge ИМЯ         разрешить мост и получить команду для его установки
  sudo trinivoice remove-bridge ИМЯ      убрать мост
  sudo trinivoice set-backup IP [ПОРТ]   вписать адрес моста в архив игроков (запасной сервер)
  sudo trinivoice players-zip            пересобрать ~/TriniVoice-players.zip
  sudo trinivoice bridges                список мостов
  sudo trinivoice-stats                  статистика игроков`);
}
