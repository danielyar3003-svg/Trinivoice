-- Модульные тесты protocol.lua и audio.lua (запуск: luajit client/test/run.lua)
local here = arg[0]:match('^(.*)[/\\]') or '.'
package.path = here .. '/../moonloader/lib/?.lua;' .. package.path
local P = require 'trinivoice.protocol'
local A = require 'trinivoice.audio'
local ffi = require 'ffi'

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print('ok   ' .. name)
  else failed = failed + 1; print('FAIL ' .. name .. ': ' .. tostring(err)) end
end
local function eq(a, b, m) if a ~= b then error((m or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end

test('utf8 <-> cp1251', function()
  eq(A.cp('abc'), 'abc')
  eq(A.cp('Привет'), '\207\240\232\226\229\242')
  eq(A.cp('ёЁ№'), '\184\168\185')
  eq(A.cp('a—b'), 'a-b')
  eq(A.cp('a✓b'), 'a?b')
  local s = 'Съешь же ещё этих мягких французских булок, ЁЖ №5'
  eq(A.u8(A.cp(s)), s)
end)

test('u-law round trip stays close', function()
  for _, s in ipairs({ 0, 1, -1, 100, -100, 1000, -1000, 8000, -8000, 32767, -32768 }) do
    local d = A.ulawDec[A.ulawEnc[s + 32768]]
    assert(math.abs(d - s) <= math.max(8, math.abs(s) * 0.07), ('sample %d decoded as %d'):format(s, d))
  end
  local c = A.makeUlaw()
  local pcm = ffi.new('int16_t[160]')
  for i = 0, 159 do pcm[i] = math.floor(math.sin(i / 5) * 10000) end
  local out, n = c.newDecoder():decode(c.encode(pcm, 160))
  eq(n, 160)
  for i = 0, 159 do assert(math.abs(out[i] - pcm[i]) < 800) end
end)

test('state packet layout', function()
  local s = P.packState({ id = 513, x = 1.5, y = -2, z = 3, interior = 7, room = '1.2.3.4:7777', nick = 'Ivan_Ivanov',
    version = '0.3.0', radioFreq = 9115, radioPass = 'pw' })
  eq(s:sub(1, 4), 'TV\2\1')
  eq(s:byte(5) + s:byte(6) * 256, 513)
  local f = ffi.new('float[1]')
  ffi.copy(f, s:sub(7, 10), 4); eq(f[0], 1.5)
  eq(s:byte(19), 7)
  eq(s:sub(20, 32), '\12' .. '1.2.3.4:7777')
  eq(s:sub(33, 44), '\11' .. 'Ivan_Ivanov')
  eq(s:sub(45, 50), '\5' .. '0.3.0')
  eq(s:byte(51) + s:byte(52) * 256, 9115)
  eq(s:sub(53), '\2pw')
end)

test('client packets', function()
  eq(P.packVoice(65535, 5, 1, 'xyz'), 'TV\2\2\255\255\5\1xyz')
  eq(P.packCall(P.CALL_INVITE, 300), 'TV\2\4\1\44\1')
  eq(P.packReport(2, 'ab'), 'TV\2\5\2\0\2ab')
  eq(P.packAdmin('k', P.ADMIN_BAN, 'N', 70000), 'TV\2\6\1k\3\1N' .. '\112\17\1\0')
  eq(P.packBye(), 'TV\2\3')
end)

test('server packets', function()
  local v = P.parseServer('TV\2\130' .. '\5\1' .. '\9\0' .. '\5\1\1' .. 'payload')
  eq(v.speaker, 261); eq(v.seq, 9); eq(v.mode, 5); eq(v.codec, 1); eq(v.route, 1); eq(v.payload, 'payload')
  local a = P.parseServer('TV\2\129' .. '\4' .. '\3\0' .. '\2\0' .. '\60\0\0\0' .. '\5' .. '0.4.0')
  eq(a.status, 4); eq(a.online, 3); eq(a.radioListeners, 2); eq(a.mutedSec, 60); eq(a.latestVersion, '0.4.0')
  local c = P.parseServer('TV\2\131' .. '\1' .. '\7\0' .. '\3Bob')
  eq(c.event, 1); eq(c.peerId, 7); eq(c.peerNick, 'Bob')
  local n = P.parseServer('TV\2\132\3\4\208\150\208\176')
  eq(n.code, 3); eq(n.text, 'Жа')
  eq(P.parseServer('TV\1\129\0\3\0'), nil, 'old protocol')
  eq(P.parseServer('TV\2\130\1'), nil, 'truncated')
  eq(P.parseServer('TV\2\129\0'), nil, 'truncated ack')
end)

test('frequencies and versions', function()
  eq(P.freqToWire('911.5'), 9115); eq(P.freqToWire(100), 1000); eq(P.freqToWire(0.5), 0); eq(P.freqToWire('abc'), 0)
  eq(P.freqLabel(9115), '911.5')
  eq(P.compareVersions('0.3.0', '0.3'), 0); eq(P.compareVersions('0.10.0', '0.9.9'), 1); eq(P.compareVersions('0.2', '0.3.1'), -1)
end)

test('distance volume and stereo pan', function()
  eq(A.distanceVolume(0, 15), 1); eq(A.distanceVolume(3, 15), 1); eq(A.distanceVolume(15, 15), 0)
  assert(math.abs(A.distanceVolume(9.375, 15) - 0.5) < 1e-9)
  assert(A.stereoPan(0, 0, 10, 0, 0, 1) > 0.7)   -- смотрим на север, говорящий на востоке — справа
  assert(A.stereoPan(0, 0, -10, 0, 0, 1) < -0.7)
  eq(A.stereoPan(0, 0, 0.1, 0, 0, 1), 0)
end)

test('gain, rms, level', function()
  local b = ffi.new('int16_t[4]', { 1000, -1000, 30000, -30000 })
  local rms = A.applyGainAndRms(b, 4, 2)
  eq(b[0], 2000); eq(b[2], 32767); eq(b[3], -32768)
  assert(rms > 20000)
  eq(A.levelFromRms(0), 0); eq(A.levelFromRms(32768), 1)
  assert(math.abs(A.levelFromRms(32.768) - 0) < 1e-9)
end)

-- энергия высоких частот: сумма квадратов разностей соседних отсчётов
local function hfEnergy(buf, n) local e = 0 for i = 1, n - 1 do e = e + (buf[i] - buf[i - 1]) ^ 2 end return e end
local function tone(n, rate, f, amp)
  local b = ffi.new('int16_t[?]', n)
  for i = 0, n - 1 do b[i] = math.floor(math.sin(2 * math.pi * f * i / rate) * amp) end
  return b
end

test('muffle removes highs, keeps lows, no-op when disabled', function()
  local rate, n = 16000, 1600
  local hi = tone(n, rate, 5000, 10000)
  local before = hfEnergy(hi, n)
  A.muffle(hi, n, rate, 700, A.newFxState())
  assert(hfEnergy(hi, n) < before * 0.05, 'highs should drop >95%')
  local lo = tone(n, rate, 200, 10000)
  A.muffle(lo, n, rate, 700, A.newFxState())
  local peak = 0
  for i = 800, n - 1 do peak = math.max(peak, math.abs(lo[i])) end
  assert(peak > 7000, 'lows should pass, peak ' .. peak)
  local same = tone(n, rate, 3000, 10000)
  local ref = tone(n, rate, 3000, 10000)
  A.muffle(same, n, rate, nil, A.newFxState())
  for i = 0, n - 1 do eq(same[i], ref[i]) end
end)

test('radio/phone/megaphone effects stay in range and cut bass', function()
  for _, kind in ipairs({ 'radio', 'phone', 'megaphone' }) do
    local rate, n = 8000, 800
    local loud = tone(n, rate, 1000, 32000)
    A.bandFx(loud, n, rate, kind, A.newFxState())
    for i = 0, n - 1 do assert(loud[i] >= -32768 and loud[i] <= 32767 and loud[i] == loud[i]) end
    local bass = tone(n, rate, 60, 20000)
    A.bandFx(bass, n, rate, kind, A.newFxState())
    local peak = 0
    for i = 400, n - 1 do peak = math.max(peak, math.abs(bass[i])) end
    assert(peak < 9000, kind .. ': 60 Hz should be cut, peak ' .. peak)
  end
end)

test('generated sounds', function()
  local c, n = A.genClick(16000); assert(n == 400 and c[10] ~= 0)
  local s, sn = A.genSquelch(8000, 70, 1); eq(sn, 560)
  local peak = 0
  for i = 0, sn - 1 do peak = math.max(peak, math.abs(s[i])) end
  assert(peak > 1000 and peak <= 32767)
  local _, rn = A.genTones(16000, A.RINGTONE); eq(rn, 16000 * 2)
  local _, bn = A.genTones(8000, A.RINGBACK); eq(bn, 8000 * 2)
end)

test('report ring buffer keeps the last N seconds in order', function()
  local r = A.newRing(10, 1) -- 10 отсчётов
  local src = ffi.new('int16_t[15]')
  for i = 0, 14 do src[i] = i + 1 end
  r:push(src, 15)
  local out, n = r:samples()
  eq(n, 10)
  for i = 0, 9 do eq(out[i], i + 6) end
  r:gap(300) -- 3 отсчёта тишины
  out, n = r:samples()
  eq(out[9], 0); eq(out[6], 15)
end)

test('wav header', function()
  local r = A.newRing(8000, 1)
  r:push(tone(800, 8000, 440, 5000), 800)
  local w = r:wav()
  eq(#w, 44 + 1600)
  eq(w:sub(1, 4), 'RIFF'); eq(w:sub(9, 16), 'WAVEfmt ')
  local function le32(s, i) local a, b, c, d = s:byte(i, i + 3); return a + b * 256 + c * 65536 + d * 16777216 end
  eq(le32(w, 25), 8000); eq(le32(w, 41), 1600); eq(le32(w, 5), 36 + 1600)
end)

print(('%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
