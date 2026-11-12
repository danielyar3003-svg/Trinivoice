import crypto from 'node:crypto';
import * as P from './protocol.js';
import { Moderation } from './moderation.js';

export const DEFAULT_CONFIG = {
  allowedRooms: [],
  bannedNicks: [],
  clientTimeoutMs: 10000,
  maxVoicePacketsPerSec: 60,
  maxPayloadBytes: 512,
  rangeMargin: 1.25,
  rangeSlack: 5,
  // радиочастоты с паролем: { "911.0": "пароль" }
  radioPasswords: {},
  callRingTimeoutMs: 30000,
  reportCooldownMs: 30000,
  // администраторы ретранслятора: [{ "name": "Admin", "key": "длинный-секрет" }]
  admins: [],
  latestClientVersion: '0.4.0',
  minClientVersion: '0.4.0',
  // защита от перегрузки
  maxClients: 2000,
  maxClientsPerIp: 4,
  // админ-команды: только с этих IP (пусто = с любого) и блокировка подбора ключа
  adminIps: [],
  adminMaxFailures: 5,
  adminLockMs: 15 * 60000,
};

/**
 * Voice relay. Transport-agnostic: feed it datagrams with handle(); it calls
 * send(buffer, address, port) for every outgoing datagram.
 *
 * Optional hooks: onReport(record), log(text).
 */
export class Relay {
  constructor({ config = {}, send, now = () => Date.now(), moderation, onReport = () => {}, log = () => {} }) {
    this.config = { ...DEFAULT_CONFIG, ...config };
    this.send = send;
    this.now = now;
    this.onReport = onReport;
    this.log = log;
    this.mod = moderation ?? new Moderation({ now });
    this.clients = new Map(); // "addr:port" -> client
    this.rooms = new Map();   // room -> Map(playerId -> client)
    this.staticBans = new Set(this.config.bannedNicks.map((n) => n.toLowerCase()));
    this.allowed = new Set(this.config.allowedRooms);
    this.radioPasswords = new Map(Object.entries(this.config.radioPasswords).map(([f, pw]) => [Math.round(parseFloat(f) * 10), String(pw)]));
    this.adminKeys = new Map(this.config.admins.filter((a) => a.key && a.key.length >= 8).map((a) => [a.key, a.name ?? 'admin']));
    this.adminIps = new Set(this.config.adminIps);
    this.adminFailures = new Map(); // ip -> { count, since, lockedUntil }
    this.perIp = new Map();         // ip -> number of sessions
    // Секрет для токенов сессий. Новый при каждом запуске: после перезапуска
    // клиенты просто получают новый токен в ответ на следующий STATE.
    this.secret = config.tokenSecret ?? crypto.randomBytes(32);
    this.stats = { in: 0, out: 0, dropped: 0 };
  }

  tokenFor(address, port) {
    return crypto.createHmac('sha256', this.secret).update(`${address}:${port}`).digest().subarray(0, P.TOKEN_LEN);
  }

  handle(buf, address, port) {
    this.stats.in++;
    const pkt = P.decodeClient(buf);
    if (!pkt) { this.stats.dropped++; return; }
    const expected = this.tokenFor(address, port);
    if (!crypto.timingSafeEqual(pkt.token, expected)) {
      // Токен уходит только на адрес отправителя, и ответ (12 байт) меньше STATE,
      // поэтому подделка IP не даёт ни сессии, ни усиления трафика.
      if (pkt.type === P.C_STATE) this.#out(P.encodeToken(expected), address, port);
      this.stats.dropped++;
      return;
    }
    const key = `${address}:${port}`;
    if (pkt.type === P.C_STATE) return this.#onState(key, address, port, pkt);
    const client = this.clients.get(key);
    if (!client) {
      // admin commands do not need a game session
      if (pkt.type === P.C_ADMIN) return this.#onAdmin(null, address, port, pkt);
      this.stats.dropped++;
      return;
    }
    switch (pkt.type) {
      case P.C_VOICE: return this.#onVoice(client, pkt);
      case P.C_BYE: return this.#remove(client);
      case P.C_CALL: return this.#onCall(client, pkt);
      case P.C_REPORT: return this.#onReport(client, pkt);
      case P.C_ADMIN: return this.#onAdmin(client, address, port, pkt);
    }
  }

  #out(buf, address, port) {
    this.stats.out++;
    this.send(buf, address, port);
  }
  #to(client, buf) { this.#out(buf, client.address, client.port); }

  #ack(address, port, status, extra = {}) {
    this.#out(P.encodeAck({ status, latestVersion: this.config.latestClientVersion, ...extra }), address, port);
  }

  // ---------------------------------------------------------------- state

  #onState(key, address, port, p) {
    if (this.allowed.size && !this.allowed.has(p.room)) return this.#ack(address, port, P.ACK_ROOM_NOT_ALLOWED);
    if (this.staticBans.has(p.nick.toLowerCase()) || this.mod.isBanned(p.nick, address)) {
      const c = this.clients.get(key);
      if (c) this.#remove(c);
      return this.#ack(address, port, P.ACK_BANNED);
    }
    if (P.compareVersions(p.version, this.config.minClientVersion) < 0) return this.#ack(address, port, P.ACK_OUTDATED);

    const t = this.now();
    let client = this.clients.get(key);
    const holder = this.rooms.get(p.room)?.get(p.playerId);
    if (holder && holder !== client) return this.#ack(address, port, P.ACK_ID_TAKEN, { online: this.rooms.get(p.room).size });
    if (client && (client.room !== p.room || client.playerId !== p.playerId)) this.#detach(client);
    if (!client) {
      if (this.clients.size >= this.config.maxClients || (this.perIp.get(address) ?? 0) >= this.config.maxClientsPerIp) {
        return this.#ack(address, port, P.ACK_FULL);
      }
      client = { key, address, port, bucket: this.config.maxVoicePacketsPerSec, bucketAt: t, call: null, reportAt: -Infinity };
      this.clients.set(key, client);
      this.perIp.set(address, (this.perIp.get(address) ?? 0) + 1);
      this.log(`join ${p.nick}[${p.playerId}] ${address} room=${p.room} v${p.version}`);
    }
    Object.assign(client, {
      room: p.room, playerId: p.playerId, nick: p.nick, version: p.version,
      x: p.x, y: p.y, z: p.z, interior: p.interior, seenAt: t,
    });
    this.#setRadio(client, p.radioFreq, p.radioPass);
    if (!this.rooms.has(p.room)) this.rooms.set(p.room, new Map());
    const members = this.rooms.get(p.room);
    members.set(p.playerId, client);

    let radioListeners = 0;
    if (client.radioFreq) for (const o of members.values()) if (o !== client && o.radioFreq === client.radioFreq) radioListeners++;
    const mutedSec = this.mod.mutedFor(client.nick);
    this.#ack(address, port, mutedSec ? P.ACK_MUTED : P.ACK_OK, { online: members.size, radioListeners, mutedSec });
  }

  #setRadio(client, freq, pass) {
    if (!freq) { client.radioFreq = 0; client.radioDenied = 0; return; }
    const need = this.radioPasswords.get(freq);
    if (need !== undefined && need !== pass) {
      client.radioFreq = 0;
      if (client.radioDenied !== freq) {
        client.radioDenied = freq;
        this.#to(client, P.encodeNotice(P.NOTICE_RADIO_DENIED, `Частота ${P.freqLabel(freq)} закрыта паролем`));
      }
      return;
    }
    client.radioDenied = 0;
    client.radioFreq = freq;
  }

  // ---------------------------------------------------------------- voice

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
    const range = P.MODE_RANGE[p.mode];
    if (!range || (p.codec !== P.CODEC_ULAW && p.codec !== P.CODEC_OPUS) ||
        p.payload.length > this.config.maxPayloadBytes || !this.#allowVoice(client) ||
        this.mod.mutedFor(client.nick)) {
      this.stats.dropped++;
      return;
    }
    const members = this.rooms.get(client.room);
    if (!members) return;

    let partners = null; // clients that get this over radio/phone, at any distance
    let route = P.ROUTE_NEAR;
    if (p.mode === P.MODE_RADIO) {
      if (!client.radioFreq) { this.stats.dropped++; return; }
      route = P.ROUTE_RADIO;
      partners = [...members.values()].filter((o) => o !== client && o.radioFreq === client.radioFreq);
    } else if (p.mode === P.MODE_PHONE) {
      if (client.call?.state !== 'active') { this.stats.dropped++; return; }
      route = P.ROUTE_PHONE;
      partners = [client.call.peer];
    }

    const cache = new Map();
    const packet = (r) => {
      if (!cache.has(r)) cache.set(r, P.encodeVoice(client.playerId, p.seq, p.mode, p.codec, r, p.payload));
      return cache.get(r);
    };
    const served = new Set();
    if (partners) {
      for (const o of partners) { served.add(o); this.#to(o, packet(route)); }
    }
    const limit = range * this.config.rangeMargin + this.config.rangeSlack;
    const limit2 = limit * limit;
    for (const o of members.values()) {
      if (o === client || served.has(o) || o.interior !== client.interior) continue;
      const dx = o.x - client.x, dy = o.y - client.y, dz = o.z - client.z;
      if (dx * dx + dy * dy + dz * dz > limit2) continue;
      this.#to(o, packet(P.ROUTE_NEAR));
    }
  }

  // ---------------------------------------------------------------- calls

  #endCall(client, notifyPeer = true) {
    const call = client.call;
    if (!call) return;
    client.call = null;
    if (call.peer.call?.peer === client) {
      call.peer.call = null;
      if (notifyPeer) this.#to(call.peer, P.encodeCall(P.EV_ENDED, client.playerId, client.nick));
    }
  }

  #onCall(client, p) {
    if (p.action === P.CALL_INVITE) {
      const target = this.rooms.get(client.room)?.get(p.target);
      if (!target || target === client) return this.#to(client, P.encodeCall(P.EV_UNAVAILABLE, p.target, ''));
      if (target.call || client.call) return this.#to(client, P.encodeCall(P.EV_BUSY, p.target, target.nick));
      const t = this.now();
      client.call = { peer: target, state: 'out', since: t };
      target.call = { peer: client, state: 'in', since: t };
      this.#to(target, P.encodeCall(P.EV_INCOMING, client.playerId, client.nick));
      this.#to(client, P.encodeCall(P.EV_RINGING, target.playerId, target.nick));
    } else if (p.action === P.CALL_ACCEPT) {
      const call = client.call;
      if (!call || call.state !== 'in') return;
      const t = this.now();
      call.state = 'active'; call.since = t;
      call.peer.call.state = 'active'; call.peer.call.since = t;
      this.#to(client, P.encodeCall(P.EV_STARTED, call.peer.playerId, call.peer.nick));
      this.#to(call.peer, P.encodeCall(P.EV_STARTED, client.playerId, client.nick));
    } else if (p.action === P.CALL_HANGUP) {
      const peer = client.call?.peer;
      this.#endCall(client);
      if (peer) this.#to(client, P.encodeCall(P.EV_ENDED, peer.playerId, peer.nick));
    }
  }

  // ---------------------------------------------------------------- reports & admin

  #onReport(client, p) {
    const t = this.now();
    if (t - client.reportAt < this.config.reportCooldownMs) return;
    const target = this.rooms.get(client.room)?.get(p.target);
    client.reportAt = t;
    const record = {
      time: new Date(t).toISOString(), room: client.room,
      reporter: client.nick, reporterId: client.playerId, reporterIp: client.address,
      target: target?.nick ?? null, targetId: p.target, targetIp: target?.address ?? null,
      reason: p.reason.slice(0, 200),
    };
    this.onReport(record);
    this.log(`report ${record.reporter} -> ${record.target ?? '#' + p.target}: ${record.reason}`);
    this.#to(client, P.encodeNotice(P.NOTICE_REPORT_OK, 'Жалоба отправлена администрации ретранслятора'));
  }

  #onAdmin(client, address, port, p) {
    const reply = (code, text) => this.#out(P.encodeNotice(code, text), address, port);
    if (this.adminIps.size && !this.adminIps.has(address)) {
      this.log(`admin: command from non-admin IP ${address} ignored`);
      return reply(P.NOTICE_ADMIN_DENIED, 'Команды администратора с этого IP запрещены');
    }
    const t = this.now();
    let fail = this.adminFailures.get(address);
    if (fail && fail.lockedUntil > t) return; // подбор ключа: молча игнорируем
    const admin = this.adminKeys.get(p.key);
    if (!admin) {
      if (!fail || t - fail.since > this.config.adminLockMs) fail = { count: 0, since: t, lockedUntil: 0 };
      fail.count++;
      if (fail.count >= this.config.adminMaxFailures) {
        fail.lockedUntil = t + this.config.adminLockMs;
        this.log(`admin: ${address} locked out after ${fail.count} wrong keys`);
      }
      this.adminFailures.set(address, fail);
      this.log(`admin: wrong key from ${address}`);
      return reply(P.NOTICE_ADMIN_DENIED, 'Неверный ключ администратора');
    }
    this.adminFailures.delete(address);
    const nick = p.nick.trim();
    if (!nick) return reply(P.NOTICE_ADMIN_DENIED, 'Не указан ник');
    const online = [...this.clients.values()].filter((c) => c.nick?.toLowerCase() === nick.toLowerCase());
    let text;
    switch (p.action) {
      case P.ADMIN_MUTE:
        this.mod.mute(nick, p.minutes);
        text = `${nick}: голос выключен ${p.minutes ? `на ${p.minutes} мин` : 'навсегда'}`;
        break;
      case P.ADMIN_UNMUTE:
        text = this.mod.unmute(nick) ? `${nick}: голос включён` : `${nick} не был заглушён`;
        break;
      case P.ADMIN_BAN:
        this.mod.ban(nick, online[0]?.address ?? null, p.minutes, admin);
        for (const c of online) { this.#to(c, P.encodeNotice(P.NOTICE_KICKED, 'Вы заблокированы на голосовом сервере')); this.#remove(c); }
        text = `${nick}: бан ${p.minutes ? `на ${p.minutes} мин` : 'навсегда'}${online.length ? ' (и по IP)' : ''}`;
        break;
      case P.ADMIN_UNBAN:
        text = this.mod.unban(nick) ? `${nick}: разбанен` : `${nick} не был забанен`;
        break;
      case P.ADMIN_KICK:
        for (const c of online) { this.#to(c, P.encodeNotice(P.NOTICE_KICKED, 'Вас отключили от голосового сервера')); this.#remove(c); }
        text = online.length ? `${nick}: отключён` : `${nick} не в сети`;
        break;
      default:
        return reply(P.NOTICE_ADMIN_DENIED, 'Неизвестное действие');
    }
    this.log(`admin ${admin}: ${text}`);
    reply(P.NOTICE_ADMIN_OK, text);
  }

  // ---------------------------------------------------------------- lifecycle

  #detach(client) {
    this.#endCall(client);
    const members = this.rooms.get(client.room);
    if (members?.get(client.playerId) === client) {
      members.delete(client.playerId);
      if (members.size === 0) this.rooms.delete(client.room);
    }
  }

  #remove(client) {
    this.#detach(client);
    if (this.clients.delete(client.key)) {
      const n = (this.perIp.get(client.address) ?? 1) - 1;
      if (n > 0) this.perIp.set(client.address, n); else this.perIp.delete(client.address);
    }
  }

  /** Drop silent clients and unanswered calls. Call periodically. */
  sweep() {
    const t = this.now();
    for (const [ip, f] of this.adminFailures) {
      if (f.lockedUntil < t && t - f.since > this.config.adminLockMs) this.adminFailures.delete(ip);
    }
    const cutoff = t - this.config.clientTimeoutMs;
    for (const c of this.clients.values()) {
      if (c.seenAt < cutoff) { this.#remove(c); continue; }
      if (c.call && c.call.state === 'out' && t - c.call.since > this.config.callRingTimeoutMs) {
        const peer = c.call.peer;
        this.#endCall(c);
        this.#to(c, P.encodeCall(P.EV_UNAVAILABLE, peer.playerId, peer.nick));
      }
    }
  }

  summary() {
    const rooms = [...this.rooms].map(([name, m]) => `${name}=${m.size}`).join(' ');
    return `clients=${this.clients.size} in=${this.stats.in} out=${this.stats.out} dropped=${this.stats.dropped} ${rooms}`;
  }
}
