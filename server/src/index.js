import dgram from 'node:dgram';
import fs from 'node:fs';
import path from 'node:path';
import { Relay } from './relay.js';
import { Moderation } from './moderation.js';

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
const relay = new Relay({
  config,
  send: (buf, address, p) => socket.send(buf, p, address),
  moderation: new Moderation({ file: path.join(dataDir, 'moderation.json') }),
  onReport: (record) => fs.appendFileSync(reportsFile, JSON.stringify(record) + '\n'),
  log,
});
if (!relay.adminKeys.size) log('no admins configured (config.admins, key >= 8 chars): moderation commands are disabled');

socket.on('message', (msg, rinfo) => relay.handle(msg, rinfo.address, rinfo.port));
socket.on('error', (err) => log(`socket error: ${err.message}`));
socket.bind(port, host, () => log(`relay listening on udp://${host}:${port}, data in ${path.resolve(dataDir)}`));

setInterval(() => relay.sweep(), 1000).unref();
setInterval(() => log(relay.summary()), 60000).unref();

const shutdown = () => { socket.close(); process.exit(0); };
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
