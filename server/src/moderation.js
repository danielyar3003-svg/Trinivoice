import fs from 'node:fs';
import path from 'node:path';

/**
 * Mutes and bans. Nicks are compared case-insensitively. A ban may also carry
 * the IP address the nick was using, so changing the nick does not help.
 * `until` is a unix time in ms, 0 means permanent.
 */
export class Moderation {
  constructor({ file = null, now = () => Date.now(), initial = null } = {}) {
    this.file = file;
    this.now = now;
    this.mutes = new Map(); // nick -> until
    this.bans = [];         // { nick, ip, until, by, reason }
    const data = initial ?? this.#read();
    for (const [nick, until] of Object.entries(data?.mutes ?? {})) this.mutes.set(nick.toLowerCase(), until);
    this.bans = (data?.bans ?? []).map((b) => ({ ...b, nick: b.nick?.toLowerCase() ?? null }));
  }

  #read() {
    if (!this.file || !fs.existsSync(this.file)) return null;
    try { return JSON.parse(fs.readFileSync(this.file, 'utf8')); } catch { return null; }
  }

  #save() {
    if (!this.file) return;
    this.#prune();
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const data = { mutes: Object.fromEntries(this.mutes), bans: this.bans };
    fs.writeFileSync(this.file, JSON.stringify(data, null, 2));
  }

  #alive(until) { return until === 0 || until > this.now(); }

  #prune() {
    for (const [nick, until] of this.mutes) if (!this.#alive(until)) this.mutes.delete(nick);
    this.bans = this.bans.filter((b) => this.#alive(b.until));
  }

  #until(minutes) { return minutes > 0 ? this.now() + minutes * 60000 : 0; }

  mute(nick, minutes) { this.mutes.set(nick.toLowerCase(), this.#until(minutes)); this.#save(); }
  unmute(nick) { const had = this.mutes.delete(nick.toLowerCase()); this.#save(); return had; }

  /** Seconds of mute left (Infinity-ish 0xffffffff for permanent), 0 if not muted. */
  mutedFor(nick) {
    const until = this.mutes.get(nick.toLowerCase());
    if (until === undefined || !this.#alive(until)) return 0;
    return until === 0 ? 0xffffffff : Math.ceil((until - this.now()) / 1000);
  }

  ban(nick, ip, minutes, by = '', reason = '') {
    this.bans.push({ nick: nick ? nick.toLowerCase() : null, ip: ip ?? null, until: this.#until(minutes), by, reason });
    this.#save();
  }

  unban(nick) {
    const n = nick.toLowerCase();
    const before = this.bans.length;
    this.bans = this.bans.filter((b) => b.nick !== n);
    this.#save();
    return this.bans.length !== before;
  }

  isBanned(nick, ip) {
    const n = nick.toLowerCase();
    return this.bans.some((b) => this.#alive(b.until) && ((b.nick && b.nick === n) || (b.ip && b.ip === ip)));
  }
}
