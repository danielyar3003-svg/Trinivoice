// TriniVoice wire protocol v2 (little endian). See docs/PROTOCOL.md.
export const MAGIC0 = 0x54; // 'T'
export const MAGIC1 = 0x56; // 'V'
export const VERSION = 2;

// client -> relay
export const C_STATE = 0x01;
export const C_VOICE = 0x02;
export const C_BYE = 0x03;
export const C_CALL = 0x04;
export const C_REPORT = 0x05;
export const C_ADMIN = 0x06;
// relay -> client
export const S_ACK = 0x81;
export const S_VOICE = 0x82;
export const S_CALL = 0x83;
export const S_NOTICE = 0x84;

export const ACK_OK = 0;
export const ACK_ROOM_NOT_ALLOWED = 1;
export const ACK_ID_TAKEN = 2;
export const ACK_BANNED = 3;
export const ACK_MUTED = 4;
export const ACK_OUTDATED = 5;

export const MODE_WHISPER = 1;
export const MODE_NORMAL = 2;
export const MODE_SHOUT = 3;
export const MODE_MEGAPHONE = 4;
export const MODE_RADIO = 5;
export const MODE_PHONE = 6;
// Hearing range in metres. For radio/phone this is how far people standing
// next to the speaker hear them; the radio/phone partner hears at any distance.
export const MODE_RANGE = { 1: 3, 2: 15, 3: 40, 4: 60, 5: 8, 6: 5 };

export const ROUTE_NEAR = 0;
export const ROUTE_RADIO = 1;
export const ROUTE_PHONE = 2;

export const CODEC_ULAW = 1; // G.711 u-law, 8 kHz mono
export const CODEC_OPUS = 2; // Opus, 16 kHz mono

export const CALL_INVITE = 1;
export const CALL_ACCEPT = 2;
export const CALL_HANGUP = 3;

export const EV_INCOMING = 1;
export const EV_STARTED = 2;
export const EV_ENDED = 3;
export const EV_UNAVAILABLE = 4;
export const EV_BUSY = 5;
export const EV_RINGING = 6;

export const ADMIN_MUTE = 1;
export const ADMIN_UNMUTE = 2;
export const ADMIN_BAN = 3;
export const ADMIN_UNBAN = 4;
export const ADMIN_KICK = 5;

export const NOTICE_ADMIN_OK = 1;
export const NOTICE_ADMIN_DENIED = 2;
export const NOTICE_REPORT_OK = 3;
export const NOTICE_RADIO_DENIED = 4;
export const NOTICE_KICKED = 5;

const HEADER = 4;

class Reader {
  constructor(buf, off) { this.buf = buf; this.off = off; this.ok = true; }
  need(n) { if (this.off + n > this.buf.length) this.ok = false; return this.ok; }
  u8() { if (!this.need(1)) return 0; return this.buf[this.off++]; }
  u16() { if (!this.need(2)) return 0; const v = this.buf.readUInt16LE(this.off); this.off += 2; return v; }
  u32() { if (!this.need(4)) return 0; const v = this.buf.readUInt32LE(this.off); this.off += 4; return v; }
  f32() { if (!this.need(4)) return 0; const v = this.buf.readFloatLE(this.off); this.off += 4; return v; }
  str(enc = 'latin1') {
    const len = this.u8();
    if (!this.need(len)) return '';
    const v = this.buf.toString(enc, this.off, this.off + len);
    this.off += len;
    return v;
  }
}

class Writer {
  constructor(type) { this.parts = [Buffer.from([MAGIC0, MAGIC1, VERSION, type])]; }
  u8(v) { this.parts.push(Buffer.from([v & 0xff])); return this; }
  u16(v) { const b = Buffer.alloc(2); b.writeUInt16LE(Math.max(0, Math.min(v, 0xffff))); this.parts.push(b); return this; }
  u32(v) { const b = Buffer.alloc(4); b.writeUInt32LE(Math.max(0, Math.min(v, 0xffffffff)) >>> 0); this.parts.push(b); return this; }
  f32(v) { const b = Buffer.alloc(4); b.writeFloatLE(v); this.parts.push(b); return this; }
  str(s, enc = 'latin1') {
    let b = Buffer.from(String(s ?? ''), enc);
    if (b.length > 255) b = b.subarray(0, 255);
    this.parts.push(Buffer.from([b.length]), b);
    return this;
  }
  bytes(b) { this.parts.push(b); return this; }
  done() { return Buffer.concat(this.parts); }
}

/** Decode a client packet. Returns null for anything malformed. */
export function decodeClient(buf) {
  if (buf.length < HEADER || buf[0] !== MAGIC0 || buf[1] !== MAGIC1 || buf[2] !== VERSION) return null;
  const type = buf[3];
  const r = new Reader(buf, HEADER);
  let p;
  switch (type) {
    case C_STATE: {
      p = {
        type, playerId: r.u16(), x: r.f32(), y: r.f32(), z: r.f32(), interior: r.u8(),
        room: r.str(), nick: r.str(), version: r.str(), radioFreq: r.u16(), radioPass: r.str('utf8'),
      };
      if (![p.x, p.y, p.z].every(Number.isFinite) || !p.room || !p.nick) return null;
      break;
    }
    case C_VOICE: {
      p = { type, seq: r.u16(), mode: r.u8(), codec: r.u8() };
      if (!r.ok || r.off >= buf.length) return null; // payload must not be empty
      p.payload = buf.subarray(r.off);
      return p;
    }
    case C_BYE: return { type };
    case C_CALL: p = { type, action: r.u8(), target: r.u16() }; break;
    case C_REPORT: p = { type, target: r.u16(), reason: r.str('utf8') }; break;
    case C_ADMIN: p = { type, key: r.str('utf8'), action: r.u8(), nick: r.str(), minutes: r.u32() }; break;
    default: return null;
  }
  return r.ok ? p : null;
}

export function encodeAck({ status, online = 0, radioListeners = 0, mutedSec = 0, latestVersion = '' }) {
  return new Writer(S_ACK).u8(status).u16(online).u16(radioListeners).u32(mutedSec).str(latestVersion).done();
}

export function encodeVoice(speakerId, seq, mode, codec, route, payload) {
  return new Writer(S_VOICE).u16(speakerId).u16(seq).u8(mode).u8(codec).u8(route).bytes(payload).done();
}

export function encodeCall(event, peerId, peerNick) {
  return new Writer(S_CALL).u8(event).u16(peerId).str(peerNick).done();
}

export function encodeNotice(code, text) {
  return new Writer(S_NOTICE).u8(code).str(text, 'utf8').done();
}

// Client-side packet builders (tests and tools).
export function encodeState({ playerId, x, y, z, interior = 0, room, nick, version = '0.3.0', radioFreq = 0, radioPass = '' }) {
  return new Writer(C_STATE).u16(playerId).f32(x).f32(y).f32(z).u8(interior)
    .str(room).str(nick).str(version).u16(radioFreq).str(radioPass, 'utf8').done();
}
export function encodeClientVoice(seq, mode, codec, payload) {
  return new Writer(C_VOICE).u16(seq).u8(mode).u8(codec).bytes(payload).done();
}
export function encodeClientCall(action, target) { return new Writer(C_CALL).u8(action).u16(target).done(); }
export function encodeReport(target, reason) { return new Writer(C_REPORT).u16(target).str(reason, 'utf8').done(); }
export function encodeAdmin(key, action, nick, minutes = 0) {
  return new Writer(C_ADMIN).str(key, 'utf8').u8(action).str(nick).u32(minutes).done();
}
export function encodeBye() { return new Writer(C_BYE).done(); }

export function decodeServer(buf) {
  if (buf.length < HEADER || buf[0] !== MAGIC0 || buf[1] !== MAGIC1 || buf[2] !== VERSION) return null;
  const type = buf[3];
  const r = new Reader(buf, HEADER);
  let p;
  if (type === S_ACK) p = { type, status: r.u8(), online: r.u16(), radioListeners: r.u16(), mutedSec: r.u32(), latestVersion: r.str() };
  else if (type === S_VOICE) {
    p = { type, speaker: r.u16(), seq: r.u16(), mode: r.u8(), codec: r.u8(), route: r.u8() };
    p.payload = buf.subarray(r.off);
  } else if (type === S_CALL) p = { type, event: r.u8(), peerId: r.u16(), peerNick: r.str() };
  else if (type === S_NOTICE) p = { type, code: r.u8(), text: r.str('utf8') };
  else return null;
  return r.ok ? p : null;
}

/** Radio frequency on the wire is MHz * 10 (911.5 -> 9115). */
export function freqLabel(f) { return (f / 10).toFixed(1); }

/** Compare dotted versions: -1, 0, 1. */
export function compareVersions(a, b) {
  const pa = String(a).split('.').map((n) => parseInt(n, 10) || 0);
  const pb = String(b).split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d) return d < 0 ? -1 : 1;
  }
  return 0;
}
