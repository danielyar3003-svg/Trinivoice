import fs from 'node:fs';
import path from 'node:path';

const DAY = 24 * 3600 * 1000;

/**
 * Who has ever connected with TriniVoice: nick, version, first and last seen.
 * IP addresses are deliberately not stored. Nicks are compared case-insensitively.
 * Saved to `file` at most every `saveEveryMs` and on save(); writes are atomic.
 */
export class Stats {
  constructor({ file = null, now = () => Date.now(), saveEveryMs = 60000 } = {}) {
    this.file = file;
    this.now = now;
    this.saveEveryMs = saveEveryMs;
    this.players = new Map(); // lower nick -> { nick, first, last, version, room }
    this.dirty = false;
    this.savedAt = 0;
    this.online = 0;
    const data = this.#read();
    for (const p of data?.players ?? []) {
      if (p && typeof p.nick === 'string') this.players.set(p.nick.toLowerCase(), { ...p });
    }
  }

  #read() {
    if (!this.file || !fs.existsSync(this.file)) return null;
    try { return JSON.parse(fs.readFileSync(this.file, 'utf8')); } catch { return null; }
  }

  /** Called for every accepted STATE (5 times a second per player) — cheap. */
  record(nick, version, room) {
    const key = nick.toLowerCase();
    const t = this.now();
    const p = this.players.get(key);
    if (!p) {
      this.players.set(key, { nick, first: t, last: t, version, room, markedAt: t });
      this.dirty = true;
    } else {
      // «последний раз» с точностью до минуты: не помечаем на запись 5 раз в секунду
      if (t - (p.markedAt ?? 0) >= 60000 || p.version !== version || p.nick !== nick || p.room !== room) {
        this.dirty = true;
        p.markedAt = t;
      }
      Object.assign(p, { nick, last: t, version, room });
    }
  }

  setOnline(n) { if (n !== this.online) { this.online = n; this.dirty = true; } }

  summary(onlineByRoom = null) {
    const t = this.now();
    let day = 0, week = 0, month = 0;
    const versions = new Map();
    for (const p of this.players.values()) {
      const age = t - p.last;
      if (age <= DAY) day++;
      if (age <= 7 * DAY) week++;
      if (age <= 30 * DAY) {
        month++;
        versions.set(p.version || '?', (versions.get(p.version || '?') ?? 0) + 1);
      }
    }
    return {
      total: this.players.size, day, week, month, online: this.online,
      onlineByRoom,
      versions: [...versions].sort((a, b) => b[1] - a[1]),
    };
  }

  /** Lines for the in-game chat (short, so they are not cut). */
  summaryLines(myRoom = null, onlineInMyRoom = null) {
    const s = this.summary();
    const lines = [
      `Установили всего: ${s.total} · за сутки: ${s.day} · 7 дней: ${s.week} · 30 дней: ${s.month}`,
      `Сейчас онлайн: ${s.online}` + (myRoom && onlineInMyRoom !== null ? ` (на вашем сервере SA-MP: ${onlineInMyRoom})` : ''),
    ];
    if (s.versions.length) {
      lines.push('Версии за 30 дней: ' + s.versions.slice(0, 5).map(([v, n]) => `${v} — ${n}`).join(', '));
    }
    return lines;
  }

  maybeSave() {
    if (this.dirty && this.now() - this.savedAt >= this.saveEveryMs) this.save();
  }

  save() {
    this.savedAt = this.now();
    if (!this.file) { this.dirty = false; return; }
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const data = {
      savedAt: new Date(this.savedAt).toISOString(),
      online: this.online,
      players: [...this.players.values()]
        .sort((a, b) => b.last - a.last)
        .map(({ nick, first, last, version, room }) => ({ nick, first, last, version, room })),
    };
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(data, null, 1));
    fs.renameSync(tmp, this.file);
    this.dirty = false;
  }
}
