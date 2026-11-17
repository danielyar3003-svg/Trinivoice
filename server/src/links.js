// Сторона главного ретранслятора: принимает мосты (UDP и TLS), передаёт пакеты
// игроков в Relay с их настоящими адресами и отправляет ответы обратно через мост.
import tls from 'node:tls';
import * as L from './link.js';

const ROUTE_TTL_MS = 60000;   // игрок за мостом без пакетов дольше — маршрут забываем
const UDP_FRESH_MS = 5000;    // UDP-адрес моста считается живым столько после его пакета
const AUTH_TIMEOUT_MS = 5000;
const MAX_PENDING_TLS = 16;   // неавторизованных TLS-соединений одновременно

export class LinkHub {
  /**
   * bridges: [{ name, key }]; onUp(payload, address, port) — пакет игрока;
   * sendUdp(buf, address, port) — отправка через UDP-сокет ретранслятора.
   */
  constructor({ bridges = [], onUp, sendUdp, now = () => Date.now(), log = () => {} }) {
    this.now = now;
    this.log = log;
    this.onUp = onUp;
    this.sendUdp = sendUdp;
    this.bridges = new Map();
    for (const b of bridges) {
      if (!L.validName(b.name) || typeof b.key !== 'string' || b.key.length < 16) {
        log(`bridge config ignored: name must be 1-16 of A-Z a-z 0-9 _ -, key >= 16 chars`);
        continue;
      }
      this.bridges.set(b.name, { name: b.name, key: b.key, udp: null, udpAt: -Infinity, tls: null, via: 'udp', up: 0, down: 0 });
    }
    this.routes = new Map(); // "ip:port" -> { bridge, at }
    this.pendingTls = 0;
  }

  get size() { return this.bridges.size; }

  /** UDP-датаграмма с 'TVL' пришла на порт ретранслятора. */
  handleUdp(buf, address, port) {
    const name = L.peekName(buf);
    const b = name !== null && this.bridges.get(name);
    if (!b) return;
    const frame = L.open(buf, b.key);
    if (!frame) return;
    b.udp = { address, port };
    b.udpAt = this.now();
    this.#onFrame(b, L.decodeFrame(frame), 'udp');
  }

  #onFrame(b, f, via) {
    if (!f) return;
    if (f.type === L.F_PING) {
      this.#send(b, L.encodePing(L.F_PONG, f.n), via);
    } else if (f.type === L.F_UP) {
      if (f.payload.length === 0 || f.payload.length > L.MAX_FRAME) return;
      b.via = via; // отвечаем тем же путём, которым мост сейчас шлёт данные
      b.up++;
      const key = `${f.address}:${f.port}`;
      const r = this.routes.get(key);
      if (r && r.bridge === b) r.at = this.now(); else this.routes.set(key, { bridge: b, at: this.now() });
      this.onUp(f.payload, f.address, f.port);
    }
  }

  #send(b, frame, via) {
    if (via === 'tls' && b.tls) { b.tls.write(L.lengthPrefixed(frame)); return true; }
    if (b.udp && this.now() - b.udpAt < UDP_FRESH_MS) { this.sendUdp(L.seal(b.name, b.key, frame), b.udp.address, b.udp.port); return true; }
    if (b.tls) { b.tls.write(L.lengthPrefixed(frame)); return true; }
    return false;
  }

  /** Если игрок пришёл через мост — отправить ответ через мост и вернуть true. */
  sendTo(buf, address, port) {
    const r = this.routes.get(`${address}:${port}`);
    if (!r || this.now() - r.at > ROUTE_TTL_MS) return false;
    const frame = L.encodeAddrFrame(L.F_DOWN, address, port, buf);
    if (!frame) return false;
    r.bridge.down++;
    this.#send(r.bridge, frame, r.bridge.via);
    return true;
  }

  sweep() {
    const t = this.now();
    for (const [k, r] of this.routes) if (t - r.at > ROUTE_TTL_MS) this.routes.delete(k);
  }

  summary() {
    return [...this.bridges.values()].map((b) => {
      const players = [...this.routes.values()].filter((r) => r.bridge === b).length;
      const link = b.tls ? (this.now() - b.udpAt < UDP_FRESH_MS ? 'udp+tls' : 'tls') : (this.now() - b.udpAt < UDP_FRESH_MS ? 'udp' : 'down');
      return `bridge ${b.name}: ${link} via=${b.via} players=${players} up=${b.up} down=${b.down}`;
    }).join('; ');
  }

  /** TLS-сервер для запасного канала (TCP 443). */
  listenTls({ cert, key, port, host = '0.0.0.0' }) {
    const server = tls.createServer({ cert, key, minVersion: 'TLSv1.2' }, (sock) => this.#onTls(sock));
    server.on('error', (e) => this.log(`bridge tls error: ${e.message}`));
    server.listen(port, host, () => this.log(`bridge links listening on tls://${host}:${port}`));
    return server;
  }

  #onTls(sock) {
    if (this.pendingTls >= MAX_PENDING_TLS) { sock.destroy(); return; }
    this.pendingTls++;
    let b = null;
    let pending = true;
    const done = () => { if (pending) { pending = false; this.pendingTls--; } };
    const timer = setTimeout(() => { if (!b) sock.destroy(); }, AUTH_TIMEOUT_MS);
    sock.setNoDelay(true);
    sock.setKeepAlive(true, 10000);
    const reader = new L.FrameReader((frame) => {
      if (!b) {
        // первый кадр — подписанная датаграмма HELLO
        const name = L.peekName(frame);
        const cand = name !== null && this.bridges.get(name);
        const inner = cand && L.open(frame, cand.key);
        if (!inner || inner[0] !== L.F_HELLO) { sock.destroy(); return; }
        clearTimeout(timer);
        done();
        b = cand;
        if (b.tls && b.tls !== sock) b.tls.destroy(); // новое соединение заменяет старое
        b.tls = sock;
        this.log(`bridge ${b.name} connected over tls from ${sock.remoteAddress}`);
        return;
      }
      this.#onFrame(b, L.decodeFrame(frame), 'tls');
    });
    sock.on('data', (chunk) => { if (!reader.push(chunk)) sock.destroy(); });
    const close = () => {
      clearTimeout(timer);
      done();
      if (b && b.tls === sock) { b.tls = null; if (b.via === 'tls') b.via = 'udp'; this.log(`bridge ${b.name} tls closed`); }
    };
    sock.on('close', close);
    sock.on('error', () => {});
  }
}
