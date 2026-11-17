// Канал «мост ↔ главный ретранслятор».
//
// Мост (bridge.js) стоит в другой стране и принимает игроков, до которых главный
// ретранслятор не доходит. Каждый пакет игрока он передаёт главному вместе с
// настоящим адресом игрока, ответы идут обратно тем же путём. Вся логика
// (комнаты, звонки, баны, статистика) остаётся на главном ретрансляторе.
//
// Два транспорта, мост выбирает рабочий сам:
//   UDP — быстрый, через тот же порт, что и у игроков (7790);
//   TLS — запасной, TCP через порт 443, выглядит как обычный HTTPS.
//
// Кадр:  u8 тип, дальше по типу
//   F_UP   (мост → главный):  ipv4[4] u16 порт  пакет_игрока
//   F_DOWN (главный → мост):  ipv4[4] u16 порт  пакет_для_игрока
//   F_PING / F_PONG:           u32 номер
//
// UDP-датаграмма:  'TVL' u8 версия, u8 длина_имени, имя, u32 секунды, u32 счётчик,
//                  кадр, 16 байт HMAC-SHA256(ключ, всё перед подписью)
// TLS-поток:       первым — такая же подписанная датаграмма с кадром F_HELLO
//                  (сервер проверяет ключ), затем кадры с префиксом длины u16.
import crypto from 'node:crypto';

export const F_UP = 1;
export const F_DOWN = 2;
export const F_PING = 3;
export const F_PONG = 4;
export const F_HELLO = 5;

const MAGIC = Buffer.from('TVL');
const VERSION = 1;
const MAC_LEN = 16;
export const MAX_SKEW_SEC = 120; // часы моста и главного могут немного расходиться
export const MAX_FRAME = 2048;

export const isLinkDatagram = (buf) => buf.length > 4 && buf[0] === 0x54 && buf[1] === 0x56 && buf[2] === 0x4c;

export function validName(name) { return typeof name === 'string' && /^[A-Za-z0-9_-]{1,16}$/.test(name); }

export function encodeAddrFrame(type, address, port, payload) {
  const parts = String(address).split('.').map(Number);
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return null;
  const b = Buffer.alloc(7 + payload.length);
  b[0] = type;
  for (let i = 0; i < 4; i++) b[1 + i] = parts[i];
  b.writeUInt16LE(port, 5);
  payload.copy(b, 7);
  return b;
}

export function encodePing(type, n) {
  const b = Buffer.alloc(5);
  b[0] = type;
  b.writeUInt32LE(n >>> 0, 1);
  return b;
}

export function decodeFrame(f) {
  if (!f || f.length < 1) return null;
  const type = f[0];
  if (type === F_UP || type === F_DOWN) {
    if (f.length < 8) return null;
    return { type, address: `${f[1]}.${f[2]}.${f[3]}.${f[4]}`, port: f.readUInt16LE(5), payload: f.subarray(7) };
  }
  if (type === F_PING || type === F_PONG) {
    if (f.length !== 5) return null;
    return { type, n: f.readUInt32LE(1) };
  }
  if (type === F_HELLO) return { type };
  return null;
}

let counter = 0;
/** Подписанная датаграмма (и первый пакет TLS-соединения). */
export function seal(name, key, frame, nowSec = Math.floor(Date.now() / 1000)) {
  const nb = Buffer.from(name);
  const head = Buffer.alloc(4 + 1 + nb.length + 8);
  MAGIC.copy(head, 0);
  head[3] = VERSION;
  head[4] = nb.length;
  nb.copy(head, 5);
  head.writeUInt32LE(nowSec >>> 0, 5 + nb.length);
  counter = (counter + 1) >>> 0;
  head.writeUInt32LE(counter, 9 + nb.length);
  const body = Buffer.concat([head, frame]);
  const mac = crypto.createHmac('sha256', key).update(body).digest().subarray(0, MAC_LEN);
  return Buffer.concat([body, mac]);
}

/** Имя моста без проверки подписи (чтобы найти его ключ). */
export function peekName(buf) {
  if (!isLinkDatagram(buf) || buf[3] !== VERSION) return null;
  const n = buf[4];
  if (buf.length < 5 + n + 8 + 1 + MAC_LEN) return null;
  return buf.subarray(5, 5 + n).toString();
}

/** Проверяет подпись и время; возвращает кадр или null. */
export function open(buf, key, nowSec = Math.floor(Date.now() / 1000)) {
  const name = peekName(buf);
  if (name === null) return null;
  const n = buf[4];
  const body = buf.subarray(0, buf.length - MAC_LEN);
  const mac = buf.subarray(buf.length - MAC_LEN);
  const want = crypto.createHmac('sha256', key).update(body).digest().subarray(0, MAC_LEN);
  if (!crypto.timingSafeEqual(mac, want)) return null;
  const t = buf.readUInt32LE(5 + n);
  if (Math.abs(nowSec - t) > MAX_SKEW_SEC) return null;
  return body.subarray(5 + n + 8);
}

/** Разбор TCP-потока на кадры с префиксом длины. */
export class FrameReader {
  constructor(onFrame) { this.buf = Buffer.alloc(0); this.onFrame = onFrame; }
  push(chunk) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    while (this.buf.length >= 2) {
      const len = this.buf.readUInt16LE(0);
      if (len === 0 || len > MAX_FRAME + 64) return false; // мусор — закрыть соединение
      if (this.buf.length < 2 + len) break;
      const f = this.buf.subarray(2, 2 + len);
      this.buf = this.buf.subarray(2 + len);
      this.onFrame(f);
    }
    return true;
  }
}

export function lengthPrefixed(frame) {
  const b = Buffer.alloc(2 + frame.length);
  b.writeUInt16LE(frame.length, 0);
  frame.copy(b, 2);
  return b;
}

/** SHA-256 отпечаток сертификата в формате Node (AA:BB:...). */
export function fingerprintOf(pem) {
  return new crypto.X509Certificate(pem).fingerprint256;
}
