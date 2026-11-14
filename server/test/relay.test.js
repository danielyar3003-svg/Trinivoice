import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Relay } from '../src/relay.js';
import { Moderation } from '../src/moderation.js';
import * as P from '../src/protocol.js';

function setup(config = {}) {
  let t = 1_000_000;
  const sent = [];
  const reports = [];
  const now = () => t;
  const relay = new Relay({
    config, now, moderation: new Moderation({ now }),
    send: (buf, address, port) => sent.push({ to: `${address}:${port}`, pkt: P.decodeServer(buf) }),
    onReport: (r) => reports.push(r),
  });
  // Тесты ниже собирают пакеты без токена: подставляем правильный токен адреса,
  // как сделал бы честный клиент. Проверки самих токенов — через relay.raw().
  relay.raw = relay.handle.bind(relay);
  relay.handle = (buf, address, port) => {
    const b = Buffer.from(buf);
    if (b.length >= 12) relay.tokenFor(address, port).copy(b, 4);
    relay.raw(b, address, port);
  };
  return { relay, sent, reports, tick: (ms) => { t += ms; }, clear: () => { sent.length = 0; } };
}
const ROOM = '1.2.3.4:7777';
const join = (relay, addr, id, x, y, extra = {}) =>
  relay.handle(P.encodeState({ playerId: id, x, y, z: 10, room: ROOM, nick: `Nick_${id}`, ...extra }), addr, 1);
const speak = (relay, addr, mode = P.MODE_NORMAL) =>
  relay.handle(P.encodeClientVoice(1, mode, P.CODEC_ULAW, Buffer.alloc(160, 0x7f)), addr, 1);
const of = (sent, type) => sent.filter((s) => s.pkt?.type === type);
const voiceTo = (sent) => of(sent, P.S_VOICE).map((s) => `${s.to}/${s.pkt.route}`).sort();

test('protocol round trip', () => {
  const token = Buffer.from('12345678');
  const s = P.decodeClient(P.encodeState({ playerId: 7, x: 1.5, y: -2, z: 3, interior: 4, room: ROOM, nick: 'A_B', version: '0.3.1', radioFreq: 9115, radioPass: 'пароль', token }));
  assert.deepEqual({ ...s, token: s.token.toString() }, { type: P.C_STATE, playerId: 7, x: 1.5, y: -2, z: 3, interior: 4, room: ROOM, nick: 'A_B', version: '0.3.1', radioFreq: 9115, radioPass: 'пароль', flags: 0, token: '12345678' });
  assert.equal(P.decodeClient(Buffer.from('TV\x03\x03abc')), null, 'packet shorter than a token');
  assert.equal(P.decodeClient(P.encodeClientVoice(1, 2, 1, Buffer.alloc(0))), null);
  assert.equal(P.decodeClient(Buffer.from('TV\x01\x01')), null, 'v1 packets rejected');
  const ack = P.decodeServer(P.encodeAck({ status: 4, online: 3, radioListeners: 2, mutedSec: 60, latestVersion: '0.4.0' }));
  assert.equal(ack.mutedSec, 60); assert.equal(ack.latestVersion, '0.4.0');
  assert.equal(P.compareVersions('0.3.0', '0.3.0'), 0);
  assert.equal(P.compareVersions('0.2.9', '0.3'), -1);
  assert.equal(P.compareVersions('1.0', '0.9.9'), 1);
});

test('proximity voice goes only to nearby players, ack carries online count and version', () => {
  const { relay, sent, clear } = setup();
  join(relay, 'a', 1, 0, 0);
  join(relay, 'b', 2, 10, 0);
  join(relay, 'c', 3, 200, 0);
  const ack = of(sent, P.S_ACK).at(-1).pkt;
  assert.equal(ack.status, P.ACK_OK); assert.equal(ack.online, 3); assert.equal(ack.latestVersion, '0.5.2');
  clear();
  speak(relay, 'a');
  assert.deepEqual(voiceTo(sent), ['b:1/0']);
  assert.equal(of(sent, P.S_VOICE)[0].pkt.speaker, 1);
});

test('whisper is short, megaphone is long, interiors are isolated', () => {
  const { relay, sent, clear } = setup();
  join(relay, 'a', 1, 0, 0);
  join(relay, 'b', 2, 10, 0);
  join(relay, 'c', 3, 70, 0);
  join(relay, 'd', 4, 1, 0, { interior: 5 });
  clear();
  speak(relay, 'a', P.MODE_WHISPER);
  assert.deepEqual(voiceTo(sent), []);
  speak(relay, 'a', P.MODE_MEGAPHONE);
  assert.deepEqual(voiceTo(sent), ['b:1/0', 'c:1/0']);
});

test('radio reaches the whole frequency and people standing next to the speaker', () => {
  const { relay, sent, clear } = setup();
  join(relay, 'a', 1, 0, 0, { radioFreq: 1000 });
  join(relay, 'b', 2, 3000, 0, { radioFreq: 1000 });   // far, same freq
  join(relay, 'c', 3, 3000, 0, { radioFreq: 1005 });   // far, other freq
  join(relay, 'd', 4, 5, 0);                           // near, no radio
  join(relay, 'e', 5, 4, 0, { radioFreq: 1000 });      // near and same freq: radio only
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.radioListeners, 2);
  clear();
  speak(relay, 'a', P.MODE_RADIO);
  assert.deepEqual(voiceTo(sent), ['b:1/1', 'd:1/0', 'e:1/1']);
  clear();
  speak(relay, 'd', P.MODE_RADIO); // no frequency set
  assert.deepEqual(voiceTo(sent), []);
});

test('password protected frequency', () => {
  const { relay, sent, clear } = setup({ radioPasswords: { '911.0': 'secret' } });
  join(relay, 'a', 1, 0, 0, { radioFreq: 9110, radioPass: 'wrong' });
  join(relay, 'b', 2, 900, 0, { radioFreq: 9110, radioPass: 'secret' });
  assert.equal(of(sent, P.S_NOTICE).length, 1);
  assert.equal(of(sent, P.S_NOTICE)[0].pkt.code, P.NOTICE_RADIO_DENIED);
  join(relay, 'a', 1, 0, 0, { radioFreq: 9110, radioPass: 'wrong' });
  assert.equal(of(sent, P.S_NOTICE).length, 1, 'denial is not repeated every state');
  clear();
  speak(relay, 'a', P.MODE_RADIO);
  assert.deepEqual(voiceTo(sent), []);
  speak(relay, 'b', P.MODE_RADIO);
  assert.deepEqual(voiceTo(sent), []);
  join(relay, 'a', 1, 0, 0, { radioFreq: 9110, radioPass: 'secret' });
  clear();
  speak(relay, 'b', P.MODE_RADIO);
  assert.deepEqual(voiceTo(sent), ['a:1/1']);
});

test('phone call: invite, accept, voice at any distance, hang up', () => {
  const { relay, sent, clear } = setup();
  join(relay, 'a', 1, 0, 0);
  join(relay, 'b', 2, 5000, 0);
  join(relay, 'c', 3, 2, 0);
  clear();
  speak(relay, 'a', P.MODE_PHONE);
  assert.deepEqual(voiceTo(sent), [], 'no call yet');
  relay.handle(P.encodeClientCall(P.CALL_INVITE, 2), 'a', 1);
  assert.deepEqual(of(sent, P.S_CALL).map((s) => [s.to, s.pkt.event, s.pkt.peerId]), [['b:1', P.EV_INCOMING, 1], ['a:1', P.EV_RINGING, 2]]);
  relay.handle(P.encodeClientCall(P.CALL_INVITE, 2), 'c', 1);
  assert.equal(of(sent, P.S_CALL).at(-1).pkt.event, P.EV_BUSY);
  clear();
  relay.handle(P.encodeClientCall(P.CALL_ACCEPT, 0), 'b', 1);
  assert.deepEqual(of(sent, P.S_CALL).map((s) => s.pkt.event), [P.EV_STARTED, P.EV_STARTED]);
  clear();
  speak(relay, 'a', P.MODE_PHONE);
  assert.deepEqual(voiceTo(sent), ['b:1/2', 'c:1/0'], 'partner over phone, bystander nearby');
  clear();
  relay.handle(P.encodeClientCall(P.CALL_HANGUP, 0), 'b', 1);
  assert.deepEqual(of(sent, P.S_CALL).map((s) => [s.to, s.pkt.event]).sort(), [['a:1', P.EV_ENDED], ['b:1', P.EV_ENDED]]);
  clear();
  speak(relay, 'a', P.MODE_PHONE);
  assert.deepEqual(voiceTo(sent), [], 'phone voice is dropped after the call ends');
});

test('unanswered call times out, call to missing player is unavailable, leaving ends call', () => {
  const { relay, sent, clear, tick } = setup({ callRingTimeoutMs: 1000 });
  join(relay, 'a', 1, 0, 0);
  join(relay, 'b', 2, 0, 0);
  relay.handle(P.encodeClientCall(P.CALL_INVITE, 99), 'a', 1);
  assert.equal(of(sent, P.S_CALL).at(-1).pkt.event, P.EV_UNAVAILABLE);
  relay.handle(P.encodeClientCall(P.CALL_INVITE, 2), 'a', 1);
  clear();
  tick(1500);
  join(relay, 'a', 1, 0, 0); join(relay, 'b', 2, 0, 0);
  relay.sweep();
  assert.deepEqual(of(sent, P.S_CALL).map((s) => [s.to, s.pkt.event]).sort(), [['a:1', P.EV_UNAVAILABLE], ['b:1', P.EV_ENDED]]);
  relay.handle(P.encodeClientCall(P.CALL_INVITE, 2), 'a', 1);
  relay.handle(P.encodeClientCall(P.CALL_ACCEPT, 0), 'b', 1);
  clear();
  relay.handle(P.encodeBye(), 'b', 1);
  assert.deepEqual(of(sent, P.S_CALL).map((s) => [s.to, s.pkt.event]), [['a:1', P.EV_ENDED]]);
});

test('admin mute, ban by nick and IP, kick, wrong key', () => {
  const { relay, sent, clear } = setup({ admins: [{ name: 'Boss', key: 'super-secret-key' }] });
  join(relay, 'a', 1, 0, 0);
  join(relay, 'b', 2, 1, 0);
  clear();
  relay.handle(P.encodeAdmin('nope-nope-nope', P.ADMIN_MUTE, 'Nick_1', 5), 'adm', 9);
  assert.equal(of(sent, P.S_NOTICE)[0].pkt.code, P.NOTICE_ADMIN_DENIED);
  relay.handle(P.encodeAdmin('super-secret-key', P.ADMIN_MUTE, 'nick_1', 5), 'adm', 9);
  assert.equal(of(sent, P.S_NOTICE).at(-1).pkt.code, P.NOTICE_ADMIN_OK);
  clear();
  speak(relay, 'a');
  assert.deepEqual(voiceTo(sent), [], 'muted player is not relayed');
  join(relay, 'a', 1, 0, 0);
  const ack = of(sent, P.S_ACK).at(-1).pkt;
  assert.equal(ack.status, P.ACK_MUTED); assert.ok(ack.mutedSec > 0 && ack.mutedSec <= 300);
  relay.handle(P.encodeAdmin('super-secret-key', P.ADMIN_UNMUTE, 'Nick_1'), 'adm', 9);
  clear();
  speak(relay, 'a');
  assert.deepEqual(voiceTo(sent), ['b:1/0']);

  relay.handle(P.encodeAdmin('super-secret-key', P.ADMIN_BAN, 'Nick_2', 0), 'adm', 9);
  assert.ok(of(sent, P.S_NOTICE).some((s) => s.to === 'b:1' && s.pkt.code === P.NOTICE_KICKED));
  clear();
  relay.handle(P.encodeState({ playerId: 5, x: 0, y: 0, z: 0, room: ROOM, nick: 'Other_Name' }), 'b', 2);
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.status, P.ACK_BANNED, 'banned by IP under another nick');
  relay.handle(P.encodeAdmin('super-secret-key', P.ADMIN_UNBAN, 'Nick_2'), 'adm', 9);
  join(relay, 'b', 2, 1, 0);
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.status, P.ACK_OK);

  relay.handle(P.encodeAdmin('super-secret-key', P.ADMIN_KICK, 'Nick_2'), 'adm', 9);
  clear();
  speak(relay, 'b');
  assert.equal(sent.length, 0, 'kicked client must rejoin first');
});

test('reports are recorded with cooldown', () => {
  const { relay, sent, reports, tick } = setup();
  join(relay, 'a', 1, 0, 0);
  join(relay, 'b', 2, 1, 0);
  relay.handle(P.encodeReport(2, 'оскорбления'), 'a', 1);
  relay.handle(P.encodeReport(2, 'ещё раз'), 'a', 1);
  assert.equal(reports.length, 1);
  assert.equal(reports[0].target, 'Nick_2'); assert.equal(reports[0].reason, 'оскорбления');
  assert.equal(of(sent, P.S_NOTICE).at(-1).pkt.code, P.NOTICE_REPORT_OK);
  tick(31000);
  relay.handle(P.encodeReport(2, 'снова'), 'a', 1);
  assert.equal(reports.length, 2);
});

test('outdated client, allowed rooms, static bans, id ownership', () => {
  const { relay, sent } = setup({ minClientVersion: '0.4.0', allowedRooms: [ROOM], bannedNicks: ['bad_guy'] });
  join(relay, 'a', 1, 0, 0, { version: '0.2.0' });
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.status, P.ACK_OUTDATED);
  join(relay, 'a', 1, 0, 0, { room: '9.9.9.9:1' });
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.status, P.ACK_ROOM_NOT_ALLOWED);
  join(relay, 'a', 1, 0, 0, { nick: 'Bad_Guy' });
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.status, P.ACK_BANNED);
  join(relay, 'a', 1, 0, 0);
  join(relay, 'evil', 1, 0, 0);
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.status, P.ACK_ID_TAKEN);
});

test('stale clients are swept and voice rate limit holds', () => {
  const { relay, sent, clear, tick } = setup({ clientTimeoutMs: 1000, maxVoicePacketsPerSec: 10 });
  join(relay, 'a', 1, 0, 0);
  join(relay, 'b', 2, 1, 0);
  clear();
  for (let i = 0; i < 50; i++) speak(relay, 'a');
  assert.equal(of(sent, P.S_VOICE).length, 10);
  tick(1500);
  relay.sweep();
  join(relay, 'c', 1, 0, 0);
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.status, P.ACK_OK, 'id freed after timeout');
});

test('moderation persists to file', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tv-'));
  const file = path.join(dir, 'mod.json');
  const m1 = new Moderation({ file });
  m1.mute('Some_One', 10);
  m1.ban('Bad_One', '5.5.5.5', 0);
  const m2 = new Moderation({ file });
  assert.ok(m2.mutedFor('some_one') > 500);
  assert.ok(m2.isBanned('x', '5.5.5.5'));
  assert.ok(m2.isBanned('BAD_ONE', '1.1.1.1'));
  fs.rmSync(dir, { recursive: true });
});

test('session token: spoofed source gets nothing, real source gets a small token reply', () => {
  const { relay, sent, clear } = setup();
  join(relay, 'a', 1, 0, 0);
  clear();
  // злоумышленник подделывает адрес жертвы 'victim' и шлёт STATE без токена
  relay.raw(P.encodeState({ playerId: 9, x: 0, y: 0, z: 0, room: ROOM, nick: 'Fake' }), 'victim', 5);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].to, 'victim:5');
  assert.equal(sent[0].pkt.type, P.S_TOKEN);
  const reply = P.encodeToken(relay.tokenFor('victim', 5));
  assert.ok(reply.length < P.encodeState({ playerId: 9, x: 0, y: 0, z: 0, room: 'r', nick: 'n' }).length, 'no amplification');
  assert.equal(relay.clients.size, 1, 'spoofed address is not registered');
  // голос/звонок/жалоба/админ с неверным токеном молча отбрасываются
  clear();
  relay.raw(P.encodeClientVoice(1, 2, 1, Buffer.alloc(160), Buffer.alloc(8)), 'a', 1);
  relay.raw(P.encodeAdmin('whatever-key', P.ADMIN_BAN, 'Nick_1', 0, Buffer.alloc(8)), 'x', 1);
  assert.equal(sent.length, 0);
  // чужой токен не подходит к другому адресу
  relay.raw(P.encodeClientVoice(1, 2, 1, Buffer.alloc(160), relay.tokenFor('a', 1)), 'a', 2);
  assert.equal(sent.length, 0);
  // с правильным токеном клиент регистрируется
  relay.raw(P.encodeState({ playerId: 9, x: 0, y: 0, z: 0, room: ROOM, nick: 'Real', token: relay.tokenFor('victim', 5) }), 'victim', 5);
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.status, P.ACK_OK);
});

test('session limits per IP and in total', () => {
  const { relay, sent } = setup({ maxClientsPerIp: 2, maxClients: 3 });
  join(relay, 'ip1', 1, 0, 0);
  relay.handle(P.encodeState({ playerId: 2, x: 0, y: 0, z: 0, room: ROOM, nick: 'B' }), 'ip1', 2);
  relay.handle(P.encodeState({ playerId: 3, x: 0, y: 0, z: 0, room: ROOM, nick: 'C' }), 'ip1', 3);
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.status, P.ACK_FULL, 'third session from one IP');
  join(relay, 'ip2', 4, 0, 0);
  join(relay, 'ip3', 5, 0, 0);
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.status, P.ACK_FULL, 'relay is full');
  relay.handle(P.encodeBye(), 'ip1', 1);
  relay.handle(P.encodeState({ playerId: 3, x: 0, y: 0, z: 0, room: ROOM, nick: 'C' }), 'ip1', 3);
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.status, P.ACK_OK, 'slot freed after bye');
});

test('admin key brute force is locked out; admin IP allowlist', () => {
  const { relay, sent, clear, tick } = setup({ admins: [{ name: 'Boss', key: 'super-secret-key' }], adminMaxFailures: 3, adminLockMs: 60000 });
  join(relay, 'b', 2, 0, 0);
  for (let i = 0; i < 3; i++) relay.handle(P.encodeAdmin('guess-' + i + '-xxxx', P.ADMIN_MUTE, 'Nick_2', 1), 'evil', 1);
  clear();
  relay.handle(P.encodeAdmin('super-secret-key', P.ADMIN_MUTE, 'Nick_2', 1), 'evil', 1);
  assert.equal(sent.length, 0, 'locked out even with the right key');
  assert.equal(relay.mod.mutedFor('Nick_2'), 0);
  tick(61000);
  relay.sweep();
  relay.handle(P.encodeAdmin('super-secret-key', P.ADMIN_MUTE, 'Nick_2', 1), 'evil', 1);
  assert.equal(of(sent, P.S_NOTICE).at(-1).pkt.code, P.NOTICE_ADMIN_OK, 'lock expires');

  const r2 = setup({ admins: [{ name: 'Boss', key: 'super-secret-key' }], adminIps: ['10.0.0.1'] });
  r2.relay.handle(P.encodeAdmin('super-secret-key', P.ADMIN_KICK, 'X', 0), '6.6.6.6', 1);
  assert.equal(of(r2.sent, P.S_NOTICE).at(-1).pkt.code, P.NOTICE_ADMIN_DENIED);
  r2.relay.handle(P.encodeAdmin('super-secret-key', P.ADMIN_KICK, 'X', 0), '10.0.0.1', 1);
  assert.equal(of(r2.sent, P.S_NOTICE).at(-1).pkt.code, P.NOTICE_ADMIN_OK);
});

test('do-not-disturb: calls to a player with calls disabled are refused', () => {
  const { relay, sent, clear } = setup();
  join(relay, 'a', 1, 0, 0);
  join(relay, 'b', 2, 900, 0, { flags: P.FLAG_DND });
  clear();
  relay.handle(P.encodeClientCall(P.CALL_INVITE, 2), 'a', 1);
  assert.deepEqual(of(sent, P.S_CALL).map((s) => [s.to, s.pkt.event, s.pkt.peerNick]), [['a:1', P.EV_DND, 'Nick_2']]);
  join(relay, 'b', 2, 900, 0, { flags: 0 }); // включил звонки обратно
  clear();
  relay.handle(P.encodeClientCall(P.CALL_INVITE, 2), 'a', 1);
  assert.equal(of(sent, P.S_CALL)[0].pkt.event, P.EV_INCOMING);
});

test('old 0.4.x clients (no flags byte) still work', () => {
  const { relay, sent } = setup();
  join(relay, 'a', 1, 0, 0, { version: '0.4.1' }); // encodeState без flags
  assert.equal(of(sent, P.S_ACK).at(-1).pkt.status, P.ACK_OK);
  assert.equal(relay.clients.get('a:1').dnd, false);
});

test('room list: everyone on this SA-MP server with flags, paged, rate limited', () => {
  const { relay, sent, clear, tick } = setup({ listCooldownMs: 1000 });
  join(relay, 'a', 1, 0, 0);
  join(relay, 'b', 2, 900, 0, { flags: P.FLAG_DND });
  join(relay, 'c', 3, 50, 0);
  relay.handle(P.encodeState({ playerId: 4, x: 0, y: 0, z: 0, room: 'other:7777', nick: 'Elsewhere' }), 'd', 1);
  relay.handle(P.encodeClientCall(P.CALL_INVITE, 3), 'a', 1);
  relay.handle(P.encodeClientCall(P.CALL_ACCEPT, 0), 'c', 1);
  clear();
  relay.handle(P.encodeListRequest(P.LIST_ROOM), 'a', 1);
  const lists = of(sent, P.S_LIST);
  assert.equal(lists.length, 1);
  const l = lists[0].pkt;
  assert.equal(l.kind, P.LIST_ROOM); assert.equal(l.pages, 1); assert.equal(l.total, 3);
  assert.deepEqual(l.entries, [
    { id: 1, nick: 'Nick_1', flags: P.FLAG_IN_CALL },
    { id: 2, nick: 'Nick_2', flags: P.FLAG_DND },
    { id: 3, nick: 'Nick_3', flags: P.FLAG_IN_CALL },
  ], 'other SA-MP servers are not listed');
  clear();
  relay.handle(P.encodeListRequest(P.LIST_ROOM), 'a', 1);
  assert.equal(sent.length, 0, 'rate limited');
  tick(1100);
  relay.handle(P.encodeListRequest(P.LIST_ROOM), 'a', 1);
  assert.equal(of(sent, P.S_LIST).length, 1);
});

test('room list is split into pages', () => {
  const { relay, sent, clear } = setup({ maxClientsPerIp: 1000 });
  for (let i = 0; i < 95; i++) {
    relay.handle(P.encodeState({ playerId: i, x: 0, y: 0, z: 0, room: ROOM, nick: 'P' + String(i).padStart(3, '0') }), 'ip', 1000 + i);
  }
  clear();
  relay.handle(P.encodeListRequest(P.LIST_ROOM), 'ip', 1000);
  const pages = of(sent, P.S_LIST).map((s) => s.pkt);
  assert.equal(pages.length, 3);
  assert.deepEqual(pages.map((p) => [p.page, p.pages, p.total, p.entries.length]), [[0, 3, 95, 40], [1, 3, 95, 40], [2, 3, 95, 15]]);
  const raw = P.encodeList(P.LIST_ROOM, Array.from({ length: 40 }, (_, i) => ({ id: i, nick: 'X'.repeat(24), flags: 0 })));
  assert.ok(raw[0].length < 1300, 'a full page fits in a safe UDP packet: ' + raw[0].length);
});

test('radio list: only players on my frequency, only if I am on it', () => {
  const { relay, sent, clear } = setup({ radioPasswords: { '911.0': 'pw' } });
  join(relay, 'a', 1, 0, 0, { radioFreq: 1000 });
  join(relay, 'b', 2, 900, 0, { radioFreq: 1000 });
  join(relay, 'c', 3, 0, 0, { radioFreq: 1005 });
  join(relay, 'd', 4, 0, 0);
  join(relay, 'e', 5, 0, 0, { radioFreq: 9110, radioPass: 'wrong' });
  clear();
  relay.handle(P.encodeListRequest(P.LIST_RADIO), 'a', 1);
  assert.deepEqual(of(sent, P.S_LIST)[0].pkt.entries.map((e) => e.nick), ['Nick_1', 'Nick_2']);
  clear();
  relay.handle(P.encodeListRequest(P.LIST_RADIO), 'd', 1);
  assert.equal(of(sent, P.S_LIST)[0].pkt.total, 0, 'no radio — empty list');
  clear();
  relay.handle(P.encodeListRequest(P.LIST_RADIO), 'e', 1);
  assert.equal(of(sent, P.S_LIST)[0].pkt.total, 0, 'wrong password — cannot see who is on a locked frequency');
});
