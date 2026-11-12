import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Relay } from '../src/relay.js';
import {
  encodeState, encodeClientVoice, S_ACK, S_VOICE,
  ACK_OK, ACK_ID_TAKEN, ACK_ROOM_NOT_ALLOWED, ACK_BANNED, CODEC_ULAW,
} from '../src/protocol.js';

function setup(config = {}) {
  let t = 0;
  const sent = [];
  const relay = new Relay({ config, now: () => t, send: (buf, address, port) => sent.push({ buf, to: `${address}:${port}` }) });
  return { relay, sent, tick: (ms) => { t += ms; } };
}
const ROOM = '1.2.3.4:7777';
const state = (id, x, y, z = 10, extra = {}) =>
  encodeState({ playerId: id, x, y, z, room: ROOM, nick: `Nick_${id}`, ...extra });
const voice = (mode = 2) => encodeClientVoice(1, mode, CODEC_ULAW, Buffer.alloc(160, 0x7f));
const voiceTo = (sent) => sent.filter((s) => s.buf[3] === S_VOICE).map((s) => s.to);

test('acks state and forwards voice only to nearby players', () => {
  const { relay, sent } = setup();
  relay.handle(state(1, 0, 0), '10.0.0.1', 1000);
  relay.handle(state(2, 10, 0), '10.0.0.2', 1000);  // 10 m: hears normal
  relay.handle(state(3, 200, 0), '10.0.0.3', 1000); // far away
  const acks = sent.filter((s) => s.buf[3] === S_ACK);
  assert.equal(acks.length, 3);
  assert.equal(acks[0].buf[4], ACK_OK);
  assert.equal(acks[2].buf.readUInt16LE(5), 3);
  sent.length = 0;
  relay.handle(voice(2), '10.0.0.1', 1000);
  assert.deepEqual(voiceTo(sent), ['10.0.0.2:1000']);
  const pkt = sent[0].buf;
  assert.equal(pkt.readUInt16LE(4), 1); // speaker id
  assert.equal(pkt[8], 2);              // mode
  assert.equal(pkt.length, 10 + 160);
});

test('whisper range is short, different interiors are isolated', () => {
  const { relay, sent } = setup();
  relay.handle(state(1, 0, 0), 'a', 1);
  relay.handle(state(2, 10, 0), 'b', 1);
  relay.handle(state(3, 1, 0, 10, { interior: 5 }), 'c', 1);
  sent.length = 0;
  relay.handle(voice(1), 'a', 1);
  assert.deepEqual(voiceTo(sent), []);
  relay.handle(voice(3), 'a', 1);
  assert.deepEqual(voiceTo(sent), ['b:1']);
});

test('voice from unknown endpoint or invalid mode is dropped', () => {
  const { relay, sent } = setup();
  relay.handle(state(1, 0, 0), 'a', 1);
  relay.handle(state(2, 1, 0), 'b', 1);
  sent.length = 0;
  relay.handle(voice(2), 'x', 9);
  relay.handle(voice(9), 'a', 1);
  relay.handle(Buffer.from('garbage'), 'a', 1);
  assert.equal(sent.length, 0);
});

test('player id cannot be claimed twice in one room', () => {
  const { relay, sent } = setup();
  relay.handle(state(1, 0, 0), 'a', 1);
  relay.handle(state(1, 0, 0), 'evil', 1);
  assert.equal(sent.at(-1).buf[4], ACK_ID_TAKEN);
});

test('allowed rooms and banned nicks', () => {
  const { relay, sent } = setup({ allowedRooms: ['9.9.9.9:7777'], bannedNicks: ['bad_guy'] });
  relay.handle(state(1, 0, 0), 'a', 1);
  assert.equal(sent.at(-1).buf[4], ACK_ROOM_NOT_ALLOWED);
  relay.handle(encodeState({ playerId: 2, x: 0, y: 0, z: 0, room: '9.9.9.9:7777', nick: 'Bad_Guy' }), 'b', 1);
  assert.equal(sent.at(-1).buf[4], ACK_BANNED);
});

test('stale clients are swept and free their id', () => {
  const { relay, sent, tick } = setup({ clientTimeoutMs: 1000 });
  relay.handle(state(1, 0, 0), 'a', 1);
  tick(1500);
  relay.sweep();
  relay.handle(state(1, 0, 0), 'b', 1);
  assert.equal(sent.at(-1).buf[4], ACK_OK);
});

test('voice rate limit', () => {
  const { relay, sent } = setup({ maxVoicePacketsPerSec: 10 });
  relay.handle(state(1, 0, 0), 'a', 1);
  relay.handle(state(2, 1, 0), 'b', 1);
  sent.length = 0;
  for (let i = 0; i < 50; i++) relay.handle(voice(), 'a', 1);
  assert.equal(voiceTo(sent).length, 10);
});
