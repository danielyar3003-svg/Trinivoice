// TriniVoice wire protocol (little endian). See docs/PROTOCOL.md.
export const MAGIC0 = 0x54; // 'T'
export const MAGIC1 = 0x56; // 'V'
export const VERSION = 1;

export const C_STATE = 0x01;
export const C_VOICE = 0x02;
export const C_BYE = 0x03;
export const S_ACK = 0x81;
export const S_VOICE = 0x82;

export const ACK_OK = 0;
export const ACK_ROOM_NOT_ALLOWED = 1;
export const ACK_ID_TAKEN = 2;
export const ACK_BANNED = 3;

// Voice modes and their hearing ranges in metres.
export const MODE_RANGE = { 1: 3, 2: 15, 3: 40 };

export const CODEC_ULAW = 1; // G.711 u-law, 8 kHz mono
export const CODEC_OPUS = 2; // Opus, 16 kHz mono

const HEADER = 4;

function readStr(buf, off) {
  if (off >= buf.length) return null;
  const len = buf[off];
  if (off + 1 + len > buf.length) return null;
  return { value: buf.toString('latin1', off + 1, off + 1 + len), next: off + 1 + len };
}

/** Decode a client packet. Returns null for anything malformed. */
export function decodeClient(buf) {
  if (buf.length < HEADER || buf[0] !== MAGIC0 || buf[1] !== MAGIC1 || buf[2] !== VERSION) return null;
  const type = buf[3];
  if (type === C_STATE) {
    if (buf.length < HEADER + 15) return null;
    const playerId = buf.readUInt16LE(4);
    const x = buf.readFloatLE(6);
    const y = buf.readFloatLE(10);
    const z = buf.readFloatLE(14);
    const interior = buf[18];
    const room = readStr(buf, 19);
    if (!room) return null;
    const nick = readStr(buf, room.next);
    if (!nick) return null;
    if (![x, y, z].every(Number.isFinite)) return null;
    if (!room.value || !nick.value) return null;
    return { type, playerId, x, y, z, interior, room: room.value, nick: nick.value };
  }
  if (type === C_VOICE) {
    if (buf.length < HEADER + 5) return null; // seq(2) mode(1) codec(1) + >=1 byte payload
    return {
      type,
      seq: buf.readUInt16LE(4),
      mode: buf[6],
      codec: buf[7],
      payload: buf.subarray(8),
    };
  }
  if (type === C_BYE) return { type };
  return null;
}

export function encodeAck(status, online) {
  const b = Buffer.alloc(HEADER + 3);
  b[0] = MAGIC0; b[1] = MAGIC1; b[2] = VERSION; b[3] = S_ACK;
  b[4] = status;
  b.writeUInt16LE(Math.min(online, 0xffff), 5);
  return b;
}

export function encodeVoice(speakerId, seq, mode, codec, payload) {
  const b = Buffer.alloc(HEADER + 6 + payload.length);
  b[0] = MAGIC0; b[1] = MAGIC1; b[2] = VERSION; b[3] = S_VOICE;
  b.writeUInt16LE(speakerId, 4);
  b.writeUInt16LE(seq, 6);
  b[8] = mode;
  b[9] = codec;
  payload.copy(b, 10);
  return b;
}

// Helpers used by tests / tools to build client packets.
export function encodeState({ playerId, x, y, z, interior = 0, room, nick }) {
  const r = Buffer.from(room, 'latin1');
  const n = Buffer.from(nick, 'latin1');
  const b = Buffer.alloc(HEADER + 15 + 1 + r.length + 1 + n.length);
  b[0] = MAGIC0; b[1] = MAGIC1; b[2] = VERSION; b[3] = C_STATE;
  b.writeUInt16LE(playerId, 4);
  b.writeFloatLE(x, 6); b.writeFloatLE(y, 10); b.writeFloatLE(z, 14);
  b[18] = interior;
  b[19] = r.length; r.copy(b, 20);
  b[20 + r.length] = n.length; n.copy(b, 21 + r.length);
  return b;
}

export function encodeClientVoice(seq, mode, codec, payload) {
  const b = Buffer.alloc(HEADER + 4 + payload.length);
  b[0] = MAGIC0; b[1] = MAGIC1; b[2] = VERSION; b[3] = C_VOICE;
  b.writeUInt16LE(seq, 4); b[6] = mode; b[7] = codec;
  payload.copy(b, 8);
  return b;
}
