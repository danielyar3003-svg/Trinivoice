// TriniVoice-мост: принимает игроков на своём UDP-порту и передаёт их пакеты
// главному ретранслятору (UDP, а если UDP режут — TLS через TCP 443).
// Запуск: node src/bridge.js /etc/trinivoice-bridge/config.json
//
// config.json:
// { "listenPort": 7790,
//   "upstream": { "host": "138.2.157.133", "port": 7790, "tlsPort": 443,
//                 "name": "ru", "key": "...", "fingerprint": "AA:BB:..." } }
import dgram from 'node:dgram';
import tls from 'node:tls';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as L from './link.js';

const SEEN_TTL_MS = 60000;   // ответы шлём только тем, кто писал нам за последнюю минуту
const MAX_SEEN = 20000;
const PONG_OK_MS = 3500;     // канал жив, если ответ на пинг был не раньше
const BACK_TO_UDP_MS = 10000; // вернуться с TLS на UDP, когда UDP стабилен столько

export class Bridge {
  constructor(config, { log = (t) => console.log(`[${new Date().toISOString()}] ${t}`), now = () => Date.now() } = {}) {
    const u = config.upstream ?? {};
    if (!u.host || !L.validName(u.name) || typeof u.key !== 'string' || u.key.length < 16) {
      throw new Error('upstream.host, upstream.name и upstream.key (>= 16 символов) обязательны');
    }
    this.cfg = { listenHost: config.listenHost ?? '0.0.0.0', listenPort: Number(config.listenPort ?? 7790),
      host: u.host, port: Number(u.port ?? 7790), tlsPort: u.tlsPort === 0 ? 0 : Number(u.tlsPort ?? 443),
      name: u.name, key: u.key, fingerprint: (u.fingerprint ?? '').toUpperCase() };
    this.log = log;
    this.now = now;
    this.seen = new Map();
    this.via = 'udp';
    this.udpPongAt = -Infinity;
    this.udpOkSince = null;
    this.tlsPongAt = -Infinity;
    this.tls = null;
    this.tlsReady = false;
    this.pingN = 0;
    this.stats = { up: 0, down: 0, dropped: 0 };
    this.lastState = '';
  }

  start() {
    return new Promise((resolve) => {
      this.players = dgram.createSocket('udp4');
      this.upstream = dgram.createSocket('udp4');
      this.players.on('message', (m, r) => this.#fromPlayer(m, r.address, r.port));
      this.upstream.on('message', (m) => this.#fromUpstreamUdp(m));
      this.players.on('error', (e) => this.log(`players socket: ${e.message}`));
      this.upstream.on('error', (e) => this.log(`upstream socket: ${e.message}`));
      this.timers = [
        setInterval(() => this.#tick(), 1000),
        setInterval(() => this.log(this.summary()), 60000),
      ];
      for (const t of this.timers) t.unref?.();
      if (this.cfg.tlsPort) this.#connectTls();
      this.upstream.bind(0, () => this.players.bind(this.cfg.listenPort, this.cfg.listenHost, () => {
        this.log(`bridge "${this.cfg.name}" listening on udp://${this.cfg.listenHost}:${this.players.address().port} -> ${this.cfg.host}:${this.cfg.port}` +
          (this.cfg.tlsPort ? ` (tls fallback :${this.cfg.tlsPort})` : ''));
        this.#tick();
        resolve(this);
      }));
    });
  }

  stop() {
    if (this.stopped) return;
    for (const t of this.timers ?? []) clearInterval(t);
    clearTimeout(this.tlsRetry);
    this.stopped = true;
    this.tls?.destroy();
    this.players?.close();
    this.upstream?.close();
  }

  get port() { return this.players.address().port; }

  // ---------------------------------------------------------------- игроки

  #fromPlayer(m, address, port) {
    // только пакеты TriniVoice-клиента ('TV' + версия), не больше обычного размера
    if (m.length < 4 || m.length > 1400 || m[0] !== 0x54 || m[1] !== 0x56 || m[2] === 0x4c) { this.stats.dropped++; return; }
    const key = `${address}:${port}`;
    if (!this.seen.has(key) && this.seen.size >= MAX_SEEN) { this.stats.dropped++; return; }
    this.seen.set(key, this.now());
    const frame = L.encodeAddrFrame(L.F_UP, address, port, m);
    if (!frame) return;
    this.stats.up++;
    this.#send(frame, this.via);
  }

  #toPlayer(f) {
    const at = this.seen.get(`${f.address}:${f.port}`);
    if (at === undefined || this.now() - at > SEEN_TTL_MS) { this.stats.dropped++; return; }
    this.stats.down++;
    this.players.send(f.payload, f.port, f.address);
  }

  // ---------------------------------------------------------------- главный

  #send(frame, via) {
    if (via === 'tls' && this.tlsReady) this.tls.write(L.lengthPrefixed(frame));
    else this.upstream.send(L.seal(this.cfg.name, this.cfg.key, frame), this.cfg.port, this.cfg.host);
  }

  #onFrame(f, via) {
    if (!f) return;
    if (f.type === L.F_PONG) {
      if (via === 'udp') this.udpPongAt = this.now(); else this.tlsPongAt = this.now();
    } else if (f.type === L.F_DOWN) {
      this.#toPlayer(f);
    }
  }

  #fromUpstreamUdp(m) {
    const frame = L.open(m, this.cfg.key);
    if (frame) this.#onFrame(L.decodeFrame(frame), 'udp');
  }

  #connectTls() {
    if (this.stopped) return;
    const sock = tls.connect({ host: this.cfg.host, port: this.cfg.tlsPort, rejectUnauthorized: false, checkServerIdentity: () => undefined });
    this.tls = sock;
    this.tlsReady = false;
    sock.setNoDelay(true);
    sock.setKeepAlive(true, 10000);
    sock.on('secureConnect', () => {
      // сертификат самоподписанный: проверяем его отпечаток, выданный при добавлении моста
      const fp = (sock.getPeerCertificate()?.fingerprint256 ?? '').toUpperCase();
      if (!this.cfg.fingerprint || fp !== this.cfg.fingerprint) {
        this.log(`TLS: чужой сертификат (${fp}), ожидался ${this.cfg.fingerprint || '(не задан)'} — соединение закрыто`);
        sock.destroy();
        return;
      }
      sock.write(L.lengthPrefixed(L.seal(this.cfg.name, this.cfg.key, Buffer.from([L.F_HELLO]))));
      this.tlsReady = true;
      this.#send(L.encodePing(L.F_PING, ++this.pingN), 'tls');
    });
    const reader = new L.FrameReader((frame) => this.#onFrame(L.decodeFrame(frame), 'tls'));
    sock.on('data', (c) => { if (!reader.push(c)) sock.destroy(); });
    sock.on('error', () => {});
    sock.on('close', () => {
      if (this.tls !== sock) return;
      this.tlsReady = false;
      this.tls = null;
      this.tlsRetry = setTimeout(() => this.#connectTls(), 3000);
      this.tlsRetry.unref?.();
    });
  }

  // ---------------------------------------------------------------- выбор канала

  #tick() {
    const t = this.now();
    this.#send(L.encodePing(L.F_PING, ++this.pingN), 'udp');
    if (this.tlsReady) this.#send(L.encodePing(L.F_PING, this.pingN), 'tls');

    const udpOk = t - this.udpPongAt < PONG_OK_MS;
    const tlsOk = this.tlsReady && t - this.tlsPongAt < PONG_OK_MS;
    if (udpOk) this.udpOkSince ??= t; else this.udpOkSince = null;
    if (this.via === 'udp' && !udpOk && tlsOk) this.via = 'tls';
    else if (this.via === 'tls' && (!tlsOk || (udpOk && t - this.udpOkSince >= BACK_TO_UDP_MS))) this.via = 'udp';

    const state = udpOk || tlsOk ? `канал до главного: ${this.via === 'tls' ? 'TLS 443 (UDP не проходит)' : 'UDP'}` : 'нет связи с главным ретранслятором';
    if (state !== this.lastState) { this.lastState = state; this.log(state); }

    for (const [k, at] of this.seen) if (t - at > SEEN_TTL_MS) this.seen.delete(k);
  }

  summary() {
    return `${this.lastState}; players=${this.seen.size} up=${this.stats.up} down=${this.stats.down} dropped=${this.stats.dropped}`;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const file = process.argv[2] ?? process.env.TRINIVOICE_BRIDGE_CONFIG ?? 'bridge.json';
  const bridge = new Bridge(JSON.parse(fs.readFileSync(file, 'utf8')));
  await bridge.start();
  const stop = () => { bridge.stop(); process.exit(0); };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}
