import dgram from 'node:dgram';
import fs from 'node:fs';
import { Relay } from './relay.js';

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

const socket = dgram.createSocket('udp4');
const relay = new Relay({
  config,
  send: (buf, address, p) => socket.send(buf, p, address),
});

socket.on('message', (msg, rinfo) => relay.handle(msg, rinfo.address, rinfo.port));
socket.on('error', (err) => { console.error('[trinivoice] socket error:', err); });
socket.bind(port, host, () => console.log(`[trinivoice] relay listening on udp://${host}:${port}`));

setInterval(() => relay.sweep(), 2000).unref();
setInterval(() => console.log(`[trinivoice] ${relay.summary()}`), 60000).unref();

const shutdown = () => { socket.close(); process.exit(0); };
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
