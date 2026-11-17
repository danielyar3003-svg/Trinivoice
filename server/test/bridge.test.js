// Мост: игрок за мостом и игрок напрямую — в одной комнате, слышат друг друга.
// Проверяется UDP-канал, запасной TLS-канал (когда UDP не проходит) и защита.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import dgram from 'node:dgram';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as P from '../src/protocol.js';
import * as L from '../src/link.js';
import { Bridge } from '../src/bridge.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tv-bridge-'));
const KEY = 'bridge-test-key-0123456789';
const RELAY_PORT = 17791;
const TLS_PORT = 17443;
const ROOM = '1.2.3.4:7777';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', '-days', '30',
  '-subj', '/CN=trinivoice', '-keyout', path.join(dir, 'key.pem'), '-out', path.join(dir, 'cert.pem')], { stdio: 'ignore' });
const FP = L.fingerprintOf(fs.readFileSync(path.join(dir, 'cert.pem')));
fs.writeFileSync(path.join(dir, 'config.json'), JSON.stringify({
  host: '127.0.0.1', port: RELAY_PORT, dataDir: dir, maxVoicePacketsPerSec: 5000,
  bridges: [{ name: 'ru', key: KEY }], bridgeTlsPort: TLS_PORT,
  bridgeCert: path.join(dir, 'cert.pem'), bridgeKey: path.join(dir, 'key.pem'),
}));
const relayLog = [];
const relay = spawn(process.execPath, [path.join(here, '../src/index.js'), path.join(dir, 'config.json')]);
relay.stdout.on('data', (d) => relayLog.push(String(d)));
relay.stderr.on('data', (d) => relayLog.push(String(d)));
const bridges = [];
after(() => { for (const b of bridges) b.stop(); relay.kill(); fs.rmSync(dir, { recursive: true, force: true }); });

async function waitFor(fn, ms = 4000, what = 'condition') {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (fn()) return; await sleep(20); }
  throw new Error(`timeout: ${what}\n${relayLog.join('')}`);
}

/** Простой клиент TriniVoice: получает токен, входит в комнату, говорит. */
async function player(id, port) {
  const sock = dgram.createSocket('udp4');
  await new Promise((r) => sock.bind(0, '127.0.0.1', r));
  const p = { sock, token: Buffer.alloc(8), acks: [], voice: [] };
  sock.on('message', (m) => {
    const pkt = P.decodeServer(m);
    if (!pkt) return;
    if (pkt.type === P.S_TOKEN) p.token = pkt.token;
    if (pkt.type === P.S_ACK) p.acks.push(pkt);
    if (pkt.type === P.S_VOICE) p.voice.push(pkt);
  });
  p.state = () => sock.send(P.encodeState({ playerId: id, x: 0, y: id, z: 10, room: ROOM, nick: `Nick_${id}`, version: '0.5.9', token: p.token }), port, '127.0.0.1');
  p.speak = () => sock.send(P.encodeClientVoice(1, P.MODE_NORMAL, P.CODEC_ULAW, Buffer.alloc(160, 0x7f), p.token), port, '127.0.0.1');
  p.join = async () => {
    for (let i = 0; i < 100 && !p.acks.some((a) => a.status === P.ACK_OK); i++) { p.state(); await sleep(40); }
    assert.ok(p.acks.some((a) => a.status === P.ACK_OK), `player ${id} joined`);
  };
  p.close = () => sock.close();
  return p;
}

async function startBridge(upstream) {
  const b = new Bridge({ listenHost: '127.0.0.1', listenPort: 0, upstream: { host: '127.0.0.1', port: RELAY_PORT, tlsPort: TLS_PORT, name: 'ru', key: KEY, fingerprint: FP, ...upstream } }, { log: () => {} });
  bridges.push(b);
  await b.start();
  return b;
}

test('relay starts with bridge support', async () => {
  await waitFor(() => relayLog.join('').includes('bridge links listening'), 4000, 'relay tls listener');
});

test('player behind the bridge (udp link) and a direct player hear each other', async () => {
  const b = await startBridge({});
  await waitFor(() => b.lastState === 'канал до главного: UDP', 4000, 'udp link');
  const direct = await player(1, RELAY_PORT);
  const viaBridge = await player(2, b.port);
  await direct.join();
  await viaBridge.join();
  assert.equal(viaBridge.acks.at(-1).online, 2, 'same room for both');
  direct.speak();
  await waitFor(() => viaBridge.voice.length > 0, 2000, 'bridge player hears direct');
  viaBridge.speak();
  await waitFor(() => direct.voice.length > 0, 2000, 'direct player hears bridge');
  direct.close(); viaBridge.close(); b.stop();
});

test('when UDP to the relay is blocked the bridge switches to TLS 443', async () => {
  const b = await startBridge({ port: 9 }); // UDP уходит «в никуда», как при блокировке
  await waitFor(() => b.lastState === 'канал до главного: TLS 443 (UDP не проходит)', 6000, 'tls fallback');
  const direct = await player(3, RELAY_PORT);
  const viaBridge = await player(4, b.port);
  await direct.join();
  await viaBridge.join();
  direct.speak();
  await waitFor(() => viaBridge.voice.length > 0, 2000, 'heard over tls');
  viaBridge.speak();
  await waitFor(() => direct.voice.length > 0, 2000, 'spoke over tls');
  direct.close(); viaBridge.close(); b.stop();
});

test('wrong key or wrong certificate gets no link', async () => {
  const bad = await startBridge({ key: 'wrong-key-wrong-key-123' });
  const fake = await startBridge({ fingerprint: 'AA:BB', port: 9 });
  await sleep(2500);
  assert.equal(bad.lastState, 'нет связи с главным ретранслятором');
  assert.equal(fake.lastState, 'нет связи с главным ретранслятором');
  bad.stop(); fake.stop();
});

test('bridge forwards only TriniVoice packets', async () => {
  const b = await startBridge({});
  const s = dgram.createSocket('udp4');
  await new Promise((r) => s.bind(0, '127.0.0.1', r));
  s.send(Buffer.from('GET / HTTP/1.1\r\n\r\n'), b.port, '127.0.0.1');
  s.send(L.seal('ru', KEY, L.encodePing(L.F_PING, 1)), b.port, '127.0.0.1'); // кадр канала от игрока
  await sleep(200);
  assert.equal(b.stats.up, 0);
  assert.equal(b.stats.dropped, 2);
  s.close(); b.stop();
});

test('link frames: tampering and stale timestamps are rejected', () => {
  const frame = L.encodeAddrFrame(L.F_UP, '10.0.0.1', 5000, Buffer.from('TV\x03x'));
  const sealed = L.seal('ru', KEY, frame);
  assert.deepEqual(L.decodeFrame(L.open(sealed, KEY)), { type: L.F_UP, address: '10.0.0.1', port: 5000, payload: Buffer.from('TV\x03x') });
  const t = Buffer.from(sealed); t[t.length - 20] ^= 1;
  assert.equal(L.open(t, KEY), null, 'tampered');
  assert.equal(L.open(L.seal('ru', KEY, frame, 1000), KEY), null, 'old timestamp');
  assert.equal(L.encodeAddrFrame(L.F_UP, '::1', 1, Buffer.alloc(1)), null, 'ipv4 only');
});
