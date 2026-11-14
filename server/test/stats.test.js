import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Stats } from '../src/stats.js';
import { Relay } from '../src/relay.js';
import { Moderation } from '../src/moderation.js';
import * as P from '../src/protocol.js';

const DAY = 24 * 3600 * 1000;

test('counts unique players by nick (case-insensitive) and activity windows', () => {
  let t = 100 * DAY;
  const s = new Stats({ now: () => t });
  s.record('Ivan_Petrov', '0.5.1', 'r'); s.record('ivan_petrov', '0.5.1', 'r'); // тот же игрок
  t -= 40 * DAY; s.record('Old_Guy', '0.4.0', 'r');          // давно
  t += 40 * DAY - 3 * DAY; s.record('Week_Guy', '0.5.0', 'r'); // 3 дня назад
  t += 3 * DAY;
  s.record('Today_Guy', '0.5.1', 'r');
  s.setOnline(2);
  const sum = s.summary();
  assert.deepEqual([sum.total, sum.day, sum.week, sum.month, sum.online], [4, 2, 3, 3, 2]);
  assert.deepEqual(sum.versions, [['0.5.1', 2], ['0.5.0', 1]], 'versions of the last 30 days, most common first');
  const lines = s.summaryLines('r', 2);
  assert.match(lines[0], /всего: 4 · за сутки: 2 · 7 дней: 3 · 30 дней: 3/);
  assert.match(lines[1], /онлайн: 2 \(на вашем сервере SA-MP: 2\)/);
  assert.match(lines[2], /0\.5\.1 — 2, 0\.5\.0 — 1/);
  for (const l of lines) assert.ok(Buffer.byteLength(l) <= 160, 'fits in one chat line: ' + l);
});

test('saves at most once a minute, atomically, without IPs, and loads back', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tvs-'));
  const file = path.join(dir, 'stats.json');
  let t = 1000 * DAY;
  const s = new Stats({ file, now: () => t });
  s.record('A_B', '0.5.2', '1.2.3.4:7777');
  s.maybeSave();
  assert.ok(fs.existsSync(file));
  const m1 = fs.statSync(file).mtimeMs;
  for (let i = 0; i < 50; i++) { t += 200; s.record('A_B', '0.5.2', '1.2.3.4:7777'); s.maybeSave(); }
  assert.equal(fs.statSync(file).mtimeMs, m1, 'no rewrite 5 times a second');
  t += 61000; s.record('A_B', '0.5.2', '1.2.3.4:7777'); s.maybeSave();
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.deepEqual(Object.keys(data.players[0]).sort(), ['first', 'last', 'nick', 'room', 'version']);
  assert.equal(data.players[0].last, t, 'last seen saved after a minute');
  assert.ok(!fs.existsSync(file + '.tmp'));
  const again = new Stats({ file, now: () => t });
  assert.equal(again.summary().total, 1);
  fs.rmSync(dir, { recursive: true });
});

test('relay records players and answers /tv admin stats', () => {
  let t = 5 * DAY;
  const sent = [];
  const usage = new Stats({ now: () => t });
  const relay = new Relay({
    config: { admins: [{ name: 'Boss', key: 'super-secret-key' }] }, now: () => t, usage,
    moderation: new Moderation({ now: () => t }),
    send: (buf, a, port) => sent.push({ to: `${a}:${port}`, pkt: P.decodeServer(buf) }),
  });
  const join = (addr, id, nick, version) =>
    relay.handle(P.encodeState({ playerId: id, x: 0, y: 0, z: 0, room: 'R:1', nick, version, token: relay.tokenFor(addr, 1) }), addr, 1);
  join('a', 1, 'Admin_One', '0.5.2');
  join('b', 2, 'Player_Two', '0.4.1');
  join('c', 3, 'Player_Three', '0.5.2');
  relay.handle(P.encodeAdmin('wrong-key-xxxx', P.ADMIN_STATS, '', 0, relay.tokenFor('a', 1)), 'a', 1);
  assert.equal(sent.at(-1).pkt.code, P.NOTICE_ADMIN_DENIED, 'needs the admin key');
  sent.length = 0;
  relay.handle(P.encodeAdmin('super-secret-key', P.ADMIN_STATS, '', 0, relay.tokenFor('a', 1)), 'a', 1);
  const texts = sent.filter((s) => s.pkt.type === P.S_NOTICE).map((s) => s.pkt.text);
  assert.equal(texts.length, 3);
  assert.match(texts[0], /всего: 3/);
  assert.match(texts[1], /онлайн: 3 \(на вашем сервере SA-MP: 3\)/);
  assert.match(texts[2], /0\.5\.2 — 2, 0\.4\.1 — 1/);
});

test('trinivoice-stats prints a summary and the player list', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tvc-'));
  const file = path.join(dir, 'stats.json');
  const s = new Stats({ file });
  s.record('Ivan_Petrov', '0.5.2', 'r'); s.record('Anna_Smirnova', '0.5.1', 'r'); s.setOnline(1); s.save();
  const cli = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'src', 'stats-cli.js');
  const out = execFileSync(process.execPath, [cli, file], { encoding: 'utf8' });
  assert.match(out, /Установили всего: 2/);
  assert.match(out, /Сейчас онлайн: 1/);
  assert.match(out, /Ivan_Petrov\s+0\.5\.2/);
  assert.match(out, /Anna_Smirnova\s+0\.5\.1/);
  const missing = (() => { try { execFileSync(process.execPath, [cli, path.join(dir, 'nope.json')], { encoding: 'utf8' }); } catch (e) { return e.stdout; } })();
  assert.match(missing, /Статистики пока нет/);
  fs.rmSync(dir, { recursive: true });
});
