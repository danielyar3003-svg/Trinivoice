import dgram from 'node:dgram';
import fs from 'node:fs';
import path from 'node:path';
import { Relay } from './relay.js';
import { Moderation } from './moderation.js';
import { Stats } from './stats.js';
import { LinkHub } from './links.js';
import { isLinkDatagram } from './link.js';

const configPath = process.argv[2] ?? process.env.TRINIVOICE_CONFIG ?? 'config.json';
let config = {};
if (fs.existsSync(configPath)) {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  console.log(`[trinivoice] config: ${configPath}`);
} else {
  console.log(`[trinivoice] ${configPath} not found, using defaults`);
}
const host = process.env.HOST ?? config.host ?? '0.0.0.0';
const port = Number(process.env.PORT ?? config.port ?? 7790);
const dataDir = process.env.DATA_DIR ?? config.dataDir ?? 'data';
fs.mkdirSync(dataDir, { recursive: true });

const log = (text) => console.log(`[${new Date().toISOString()}] ${text}`);
const reportsFile = path.join(dataDir, 'reports.jsonl');

const socket = dgram.createSocket('udp4');
// Мосты (bridges): игроки из стран, откуда главный сервер не виден, подключаются
// к мосту, а он передаёт их пакеты сюда. Ответы таким игрокам идут через мост.
let hub = null;
const relay = new Relay({
  config,
  send: (buf, address, p) => { if (!hub || !hub.sendTo(buf, address, p)) socket.send(buf, p, address); },
  moderation: new Moderation({ file: path.join(dataDir, 'moderation.json') }),
  usage: new Stats({ file: path.join(dataDir, 'stats.json') }),
  onReport: (record) => fs.appendFileSync(reportsFile, JSON.stringify(record) + '\n'),
  log,
});
if (!relay.adminKeys.size) log('no admins configured (config.admins, key >= 8 chars): moderation commands are disabled');

hub = new LinkHub({
  bridges: config.bridges ?? [],
  onUp: (payload, address, p) => relay.handle(payload, address, p),
  sendUdp: (buf, address, p) => socket.send(buf, p, address),
  log,
});
if (hub.size) {
  // сертификат лежит рядом с config.json (его создаёт «sudo trinivoice add-bridge»)
  const certFile = config.bridgeCert ?? path.join(path.dirname(configPath), 'link-cert.pem');
  const keyFile = config.bridgeKey ?? path.join(path.dirname(configPath), 'link-key.pem');
  try {
    hub.listenTls({ cert: fs.readFileSync(certFile), key: fs.readFileSync(keyFile), port: Number(config.bridgeTlsPort ?? 443), host });
  } catch (e) {
    log(`bridge tls disabled (${e.message}); bridges can still use udp`);
  }
  setInterval(() => hub.sweep(), 5000).unref();
  setInterval(() => log(hub.summary()), 60000).unref();
}

socket.on('message', (msg, rinfo) => {
  if (isLinkDatagram(msg)) hub.handleUdp(msg, rinfo.address, rinfo.port);
  else relay.handle(msg, rinfo.address, rinfo.port);
});
socket.on('error', (err) => log(`socket error: ${err.message}`));
socket.bind(port, host, () => log(`relay listening on udp://${host}:${port}, data in ${path.resolve(dataDir)}`));

setInterval(() => relay.sweep(), 1000).unref();
setInterval(() => log(relay.summary()), 60000).unref();

const shutdown = () => {
  try { relay.usage.save(); } catch (e) { log(`stats not saved: ${e.message}`); }
  socket.close();
  process.exit(0);
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
