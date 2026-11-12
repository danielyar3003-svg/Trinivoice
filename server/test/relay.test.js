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
  const s = P.decodeClient(P.encodeState({ playerId: 7, x: 1.5, y: -2, z: 3, interior: 4, room: ROOM, nick: 'A_B', version: '0.3.1', radioFreq: 9115, radioPass: 'пароль' }));
  assert.deepEqual(s, { type: P.C_STATE, playerId: 7, x: 1.5, y: -2, z: 3, interior: 4, room: ROOM, nick: 'A_B', version: '0.3.1', radioFreq: 9115, radioPass: 'пароль' });
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
  assert.equal(ack.status, P.ACK_OK); assert.equal(ack.online, 3); assert.equal(ack.latestVersion, '0.3.0');
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
  const { relay, sent } = setup({ minClientVersion: '0.3.0', allowedRooms: [ROOM], bannedNicks: ['bad_guy'] });
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
