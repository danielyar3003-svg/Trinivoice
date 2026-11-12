-- Тесты чистой логики trinivoice.lua (запуск: luajit client/test/run.lua)
TRINIVOICE_TEST = true
for _, f in ipairs({ 'script_name', 'script_author', 'script_version', 'script_description' }) do _G[f] = function() end end
local here = arg[0]:match('^(.*)[/\\]') or '.'
dofile(here .. '/../moonloader/trinivoice.lua')
local T = assert(TV_internal, 'TV_internal not exported')
local ffi = require 'ffi'

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print('ok   ' .. name)
  else failed = failed + 1; print('FAIL ' .. name .. ': ' .. tostring(err)) end
end
local function eq(a, b, m) if a ~= b then error((m or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end

test('cp1251 conversion', function()
  eq(T.cp('abc'), 'abc')
  eq(T.cp('Привет'), '\207\240\232\226\229\242')
  eq(T.cp('ёЁ'), '\184\168')
  eq(T.cp('a✓b'), 'a?b')
end)

test('u-law round trip stays close', function()
  local maxRel = 0
  for _, s in ipairs({ 0, 1, -1, 100, -100, 1000, -1000, 8000, -8000, 32767, -32768 }) do
    local d = T.ulawDec[T.ulawEnc[s + 32768]]
    local err = math.abs(d - s)
    assert(err <= math.max(8, math.abs(s) * 0.07), ('sample %d decoded as %d'):format(s, d))
  end
  eq(T.ulawEnc[0 + 32768], 0xFF, 'silence code')
end)

test('u-law codec frame encode/decode', function()
  local c = T.makeUlaw()
  eq(c.frame, 160)
  local pcm = ffi.new('int16_t[160]')
  for i = 0, 159 do pcm[i] = math.floor(math.sin(i / 5) * 10000) end
  local payload = c.encode(pcm, 160)
  eq(#payload, 160)
  local out, n = c.newDecoder():decode(payload)
  eq(n, 160)
  for i = 0, 159 do assert(math.abs(out[i] - pcm[i]) < 800, 'sample ' .. i) end
end)

test('state packet layout', function()
  local s = T.packState(513, 1.5, -2, 3, 7, '1.2.3.4:7777', 'Ivan_Ivanov')
  eq(s:sub(1, 4), 'TV\1\1')
  eq(s:byte(5) + s:byte(6) * 256, 513)
  local f = ffi.new('float[1]')
  ffi.copy(f, s:sub(7, 10), 4); eq(f[0], 1.5)
  ffi.copy(f, s:sub(11, 14), 4); eq(f[0], -2)
  eq(s:byte(19), 7)
  eq(s:byte(20), 12)
  eq(s:sub(21, 32), '1.2.3.4:7777')
  eq(s:byte(33), 11)
  eq(s:sub(34), 'Ivan_Ivanov')
end)

test('voice packet and server parse', function()
  local v = T.packVoice(65535, 3, 1, 'xyz')
  eq(v, 'TV\1\2\255\255\3\1xyz')
  local p = T.parseServer('TV\1\130' .. '\5\1' .. '\9\0' .. '\2\1' .. 'payload')
  eq(p.type, 0x82); eq(p.speaker, 261); eq(p.seq, 9); eq(p.mode, 2); eq(p.codec, 1); eq(p.payload, 'payload')
  local a = T.parseServer('TV\1\129\0\3\0')
  eq(a.status, 0); eq(a.online, 3)
  eq(T.parseServer('XX\1\129\0\3\0'), nil)
  eq(T.parseServer('TV\1\130\1'), nil)
end)

test('distance volume', function()
  eq(T.distanceVolume(0, 15), 1)
  eq(T.distanceVolume(3, 15), 1)
  eq(T.distanceVolume(15, 15), 0)
  eq(T.distanceVolume(40, 15), 0)
  local mid = T.distanceVolume(9.375, 15)
  assert(math.abs(mid - 0.5) < 1e-9, mid)
end)

test('stereo pan', function()
  -- смотрим на север (+y): говорящий на востоке (+x) справа
  assert(T.stereoPan(0, 0, 10, 0, 0, 1) > 0.7)
  assert(T.stereoPan(0, 0, -10, 0, 0, 1) < -0.7)
  eq(T.stereoPan(0, 0, 0, 10, 0, 1), 0)
  eq(T.stereoPan(0, 0, 0.1, 0, 0, 1), 0)
end)

test('gain and rms', function()
  local b = ffi.new('int16_t[4]', { 1000, -1000, 30000, -30000 })
  local rms = T.applyGainAndRms(b, 4, 2)
  eq(b[0], 2000); eq(b[2], 32767); eq(b[3], -32768)
  assert(rms > 20000)
end)

print(('%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
