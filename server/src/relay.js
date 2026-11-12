import {
  decodeClient, encodeAck, encodeVoice,
  C_STATE, C_VOICE, C_BYE,
  ACK_OK, ACK_ROOM_NOT_ALLOWED, ACK_ID_TAKEN, ACK_BANNED,
  MODE_RANGE, CODEC_ULAW, CODEC_OPUS,
} from './protocol.js';

export const DEFAULT_CONFIG = {
  allowedRooms: [],
  bannedNicks: [],
  clientTimeoutMs: 10000,
  maxVoicePacketsPerSec: 60,
  maxPayloadBytes: 512,
  rangeMargin: 1.25,
  rangeSlack: 5,
};

/**
 * Proximity voice relay. Transport-agnostic: feed it datagrams with handle(),
 * it calls send(buffer, address, port) for every outgoing datagram.
 */
export class Relay {
  constructor({ config = {}, send, now = () => Date.now() }) {
    this.config = { ...DEFAULT_CONFIG, ...config };
    this.send = send;
    this.now = now;
    this.clients = new Map(); // "addr:port" -> client
    this.rooms = new Map();   // room -> Map(playerId -> client)
    this.banned = new Set(this.config.bannedNicks.map((n) => n.toLowerCase()));
    this.allowed = new Set(this.config.allowedRooms);
    this.stats = { in: 0, out: 0, dropped: 0 };
  }

  handle(buf, address, port) {
    this.stats.in++;
    const pkt = decodeClient(buf);
    if (!pkt) { this.stats.dropped++; return; }
    const key = `${address}:${port}`;
    if (pkt.type === C_STATE) return this.#onState(key, address, port, pkt);
    const client = this.clients.get(key);
    if (!client) { this.stats.dropped++; return; }
    if (pkt.type === C_VOICE) return this.#onVoice(client, pkt);
    if (pkt.type === C_BYE) return this.#remove(client);
  }

  #reply(address, port, status, room) {
    const online = room ? (this.rooms.get(room)?.size ?? 0) : 0;
    this.#out(encodeAck(status, online), address, port);
  }

  #out(buf, address, port) {
    this.stats.out++;
    this.send(buf, address, port);
  }

  #onState(key, address, port, p) {
    if (this.allowed.size && !this.allowed.has(p.room)) {
      return this.#reply(address, port, ACK_ROOM_NOT_ALLOWED);
    }
    if (this.banned.has(p.nick.toLowerCase())) {
      return this.#reply(address, port, ACK_BANNED);
    }
    const t = this.now();
    let client = this.clients.get(key);
    const members = this.rooms.get(p.room);
    const holder = members?.get(p.playerId);
    if (holder && holder !== client) {
      // Another live endpoint already owns this id in this room.
      return this.#reply(address, port, ACK_ID_TAKEN, p.room);
    }
    if (client && (client.room !== p.room || client.playerId !== p.playerId)) {
      this.#detach(client);
    }
    if (!client) {
      client = { key, address, port, bucket: this.config.maxVoicePacketsPerSec, bucketAt: t };
      this.clients.set(key, client);
    }
    Object.assign(client, {
      room: p.room, playerId: p.playerId, nick: p.nick,
      x: p.x, y: p.y, z: p.z, interior: p.interior, seenAt: t,
    });
    if (!this.rooms.has(p.room)) this.rooms.set(p.room, new Map());
    this.rooms.get(p.room).set(p.playerId, client);
    this.#reply(address, port, ACK_OK, p.room);
  }

  #allowVoice(client) {
    const t = this.now();
    const rate = this.config.maxVoicePacketsPerSec;
    client.bucket = Math.min(rate, client.bucket + ((t - client.bucketAt) / 1000) * rate);
    client.bucketAt = t;
    if (client.bucket < 1) return false;
    client.bucket -= 1;
    return true;
  }

  #onVoice(client, p) {
    const range = MODE_RANGE[p.mode];
    if (!range || (p.codec !== CODEC_ULAW && p.codec !== CODEC_OPUS) ||
        p.payload.length > this.config.maxPayloadBytes || !this.#allowVoice(client)) {
      this.stats.dropped++;
      return;
    }
    const members = this.rooms.get(client.room);
    if (!members) return;
    const limit = range * this.config.rangeMargin + this.config.rangeSlack;
    const limit2 = limit * limit;
    let out = null;
    for (const other of members.values()) {
      if (other === client || other.interior !== client.interior) continue;
      const dx = other.x - client.x, dy = other.y - client.y, dz = other.z - client.z;
      if (dx * dx + dy * dy + dz * dz > limit2) continue;
      out ??= encodeVoice(client.playerId, p.seq, p.mode, p.codec, p.payload);
      this.#out(out, other.address, other.port);
    }
  }

  #detach(client) {
    const members = this.rooms.get(client.room);
    if (members?.get(client.playerId) === client) {
      members.delete(client.playerId);
      if (members.size === 0) this.rooms.delete(client.room);
    }
  }

  #remove(client) {
    this.#detach(client);
    this.clients.delete(client.key);
  }

  /** Drop clients that stopped sending state. Call periodically. */
  sweep() {
    const cutoff = this.now() - this.config.clientTimeoutMs;
    for (const c of this.clients.values()) if (c.seenAt < cutoff) this.#remove(c);
  }

  summary() {
    const rooms = [...this.rooms].map(([name, m]) => `${name}=${m.size}`).join(' ');
    return `clients=${this.clients.size} in=${this.stats.in} out=${this.stats.out} dropped=${this.stats.dropped} ${rooms}`;
  }
}
