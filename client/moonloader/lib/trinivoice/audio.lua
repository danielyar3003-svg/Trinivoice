-- TriniVoice: кодеки, обработка звука и служебные звуки. Чистый Lua + ffi, без игры.
local ffi = require 'ffi'
local bit = require 'bit'

local A = {}

A.FRAME_MS = 20
A.CODEC_ULAW, A.CODEC_OPUS = 1, 2

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
A.clamp = clamp

---------------------------------------------------------------------------
-- Текст: UTF-8 <-> CP1251 (чат SA-MP работает в CP1251)
---------------------------------------------------------------------------

function A.cp(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    if c < 0x80 then
      out[#out + 1] = string.char(c); i = i + 1
    elseif c >= 0xC0 and c < 0xE0 and i < n then
      local u = bit.bor(bit.lshift(bit.band(c, 0x1F), 6), bit.band(s:byte(i + 1), 0x3F))
      if u >= 0x410 and u <= 0x44F then out[#out + 1] = string.char(u - 0x410 + 0xC0)
      elseif u == 0x401 then out[#out + 1] = '\168'
      elseif u == 0x451 then out[#out + 1] = '\184'
      elseif u == 0x2116 then out[#out + 1] = '\185'
      else out[#out + 1] = '?' end
      i = i + 2
    else
      local u
      if c >= 0xE0 and c < 0xF0 and i + 2 <= n then
        u = bit.bor(bit.lshift(bit.band(c, 0x0F), 12), bit.lshift(bit.band(s:byte(i + 1), 0x3F), 6), bit.band(s:byte(i + 2), 0x3F))
      end
      if u == 0x2014 or u == 0x2013 then out[#out + 1] = '-'
      elseif u == 0x2116 then out[#out + 1] = '\185'
      else out[#out + 1] = '?' end
      i = i + (c >= 0xF0 and 4 or (c >= 0xE0 and 3 or 1))
    end
  end
  return table.concat(out)
end

function A.u8(s)
  local out = {}
  for i = 1, #s do
    local c = s:byte(i)
    if c < 0x80 then out[#out + 1] = string.char(c)
    elseif c >= 0xC0 then
      local u = c - 0xC0 + 0x410
      out[#out + 1] = string.char(0xC0 + bit.rshift(u, 6), 0x80 + bit.band(u, 0x3F))
    elseif c == 0xA8 then out[#out + 1] = '\208\129'
    elseif c == 0xB8 then out[#out + 1] = '\209\145'
    elseif c == 0xB9 then out[#out + 1] = '\226\132\150'
    else out[#out + 1] = '?' end
  end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Кодеки
---------------------------------------------------------------------------

-- G.711 u-law, 8 кГц: работает без дополнительных библиотек.
A.ulawEnc = ffi.new('uint8_t[65536]')
A.ulawDec = ffi.new('int16_t[256]')
do
  local BIAS, CLIP = 0x84, 32635
  for s = -32768, 32767 do
    local v, sign = s, 0
    if v < 0 then v = -v; sign = 0x80 end
    if v > CLIP then v = CLIP end
    v = v + BIAS
    local exp, mask = 7, 0x4000
    while exp > 0 and bit.band(v, mask) == 0 do exp = exp - 1; mask = bit.rshift(mask, 1) end
    local mant = bit.band(bit.rshift(v, exp + 3), 0x0F)
    A.ulawEnc[s + 32768] = bit.band(bit.bnot(bit.bor(sign, bit.lshift(exp, 4), mant)), 0xFF)
  end
  for u = 0, 255 do
    local x = bit.band(bit.bnot(u), 0xFF)
    local exp, mant = bit.band(bit.rshift(x, 4), 7), bit.band(x, 0x0F)
    local v = bit.lshift(bit.lshift(mant, 3) + BIAS, exp) - BIAS
    A.ulawDec[u] = bit.band(x, 0x80) ~= 0 and -v or v
  end
end

function A.makeUlaw()
  local rate = 8000
  local n = rate * A.FRAME_MS / 1000
  local out = ffi.new('uint8_t[?]', n)
  local enc, dec = A.ulawEnc, A.ulawDec
  return {
    id = A.CODEC_ULAW, rate = rate, frame = n, name = 'u-law',
    encode = function(src, count)
      for i = 0, count - 1 do out[i] = enc[src[i] + 32768] end
      return ffi.string(out, count)
    end,
    newDecoder = function()
      local pcm = ffi.new('int16_t[?]', n)
      return {
        decode = function(_, data)
          local len = math.min(#data, n)
          for i = 0, len - 1 do pcm[i] = dec[data:byte(i + 1)] end
          return pcm, len
        end,
        conceal = function() return nil, 0 end,
      }
    end,
  }
end

-- Opus, 16 кГц: нужен 32-битный opus.dll в moonloader/lib (у всех собеседников).
local opusLib
function A.loadOpus(dir)
  if opusLib ~= nil then return opusLib or nil end
  opusLib = false
  pcall(ffi.cdef, [[
    typedef struct OpusEncoder OpusEncoder;
    typedef struct OpusDecoder OpusDecoder;
    OpusEncoder *opus_encoder_create(int32_t Fs, int channels, int application, int *error);
    int32_t opus_encode(OpusEncoder *st, const int16_t *pcm, int frame_size, unsigned char *data, int32_t max_data_bytes);
    int opus_encoder_ctl(OpusEncoder *st, int request, ...);
    void opus_encoder_destroy(OpusEncoder *st);
    OpusDecoder *opus_decoder_create(int32_t Fs, int channels, int *error);
    int opus_decode(OpusDecoder *st, const unsigned char *data, int32_t len, int16_t *pcm, int frame_size, int decode_fec);
    void opus_decoder_destroy(OpusDecoder *st);
  ]])
  for _, name in ipairs({ dir and (dir .. '\\lib\\opus.dll') or nil, 'opus' }) do
    local ok, lib = pcall(ffi.load, name)
    if ok then opusLib = lib; break end
  end
  return opusLib or nil
end

function A.makeOpus(lib, bitrate)
  local rate = 16000
  local n = rate * A.FRAME_MS / 1000
  local err = ffi.new('int[1]')
  local enc = lib.opus_encoder_create(rate, 1, 2048 --[[VOIP]], err)
  if enc == nil or err[0] ~= 0 then return nil end
  ffi.gc(enc, lib.opus_encoder_destroy)
  lib.opus_encoder_ctl(enc, 4002 --[[SET_BITRATE]], ffi.new('int32_t', bitrate))
  lib.opus_encoder_ctl(enc, 4012 --[[SET_INBAND_FEC]], ffi.new('int32_t', 1))
  lib.opus_encoder_ctl(enc, 4014 --[[SET_PACKET_LOSS_PERC]], ffi.new('int32_t', 10))
  local out = ffi.new('unsigned char[512]')
  return {
    id = A.CODEC_OPUS, rate = rate, frame = n, name = 'Opus',
    encode = function(src, count)
      local len = lib.opus_encode(enc, src, count, out, 512)
      if len <= 0 then return nil end
      return ffi.string(out, len)
    end,
    newDecoder = function()
      local derr = ffi.new('int[1]')
      local dec = lib.opus_decoder_create(rate, 1, derr)
      if dec == nil then return nil end
      ffi.gc(dec, lib.opus_decoder_destroy)
      local pcm = ffi.new('int16_t[?]', n)
      return {
        decode = function(_, data)
          local got = lib.opus_decode(dec, data, #data, pcm, n, 0)
          if got < 0 then return nil, 0 end
          return pcm, got
        end,
        conceal = function()
          local got = lib.opus_decode(dec, nil, 0, pcm, n, 0)
          if got < 0 then return nil, 0 end
          return pcm, got
        end,
      }
    end,
  }
end

---------------------------------------------------------------------------
-- Громкость, панорама, уровень микрофона
---------------------------------------------------------------------------

-- Полная громкость в первой четверти радиуса, дальше линейно до нуля на границе.
function A.distanceVolume(d, range)
  local full = range * 0.25
  if d <= full then return 1 end
  return clamp(1 - (d - full) / (range - full), 0, 1)
end

-- Панорама: -1 слева, 1 справа, относительно направления камеры (fx, fy).
function A.stereoPan(mx, my, sx, sy, fx, fy)
  local dx, dy = sx - mx, sy - my
  local dl = math.sqrt(dx * dx + dy * dy)
  local fl = math.sqrt(fx * fx + fy * fy)
  if dl < 0.5 or fl < 1e-3 then return 0 end
  local rx, ry = fy / fl, -fx / fl
  return clamp((dx * rx + dy * ry) / dl, -1, 1) * 0.75
end

function A.applyGainAndRms(buf, count, gain)
  local sum = 0
  for i = 0, count - 1 do
    local v = buf[i]
    if gain ~= 1 then
      v = clamp(math.floor(v * gain), -32768, 32767)
      buf[i] = v
    end
    sum = sum + v * v
  end
  return math.sqrt(sum / count)
end

-- RMS -> 0..1 по шкале -60..0 дБ.
function A.levelFromRms(rms)
  if rms < 1 then return 0 end
  return clamp((20 * math.log10(rms / 32768) + 60) / 60, 0, 1)
end

---------------------------------------------------------------------------
-- Фильтры и эффекты (in-place над int16)
---------------------------------------------------------------------------

local TWO_PI = 2 * math.pi
local function lpCoef(rate, fc) return 1 - math.exp(-TWO_PI * fc / rate) end
local function hpCoef(rate, fc) local rc = 1 / (TWO_PI * fc); local dt = 1 / rate; return rc / (rc + dt) end

-- Новое состояние фильтров для одного собеседника.
function A.newFxState() return { lp1 = 0, lp2 = 0, hp = 0, hpx = 0, seed = 12345 } end

-- Приглушение (стена, машина): НЧ-фильтр второго порядка. cutoff >= rate/2 = без эффекта.
function A.muffle(buf, n, rate, cutoff, st)
  if not cutoff or cutoff >= rate / 2 then
    if n > 0 then st.lp1, st.lp2 = buf[n - 1], buf[n - 1] end
    return
  end
  local a = lpCoef(rate, cutoff)
  local y1, y2 = st.lp1, st.lp2
  for i = 0, n - 1 do
    y1 = y1 + a * (buf[i] - y1)
    y2 = y2 + a * (y1 - y2)
    buf[i] = clamp(math.floor(y2 + 0.5), -32768, 32767)
  end
  st.lp1, st.lp2 = y1, y2
end

local function rand(st)
  st.seed = (st.seed * 1103515245 + 12345) % 2147483648
  return st.seed / 1073741824 - 1
end

-- Полоса пропускания + перегруз + шум: рация, телефон, мегафон.
local PRESETS = {
  radio = { hp = 380, lp = 2600, drive = 2.2, noise = 350, out = 0.9 },
  phone = { hp = 300, lp = 3400, drive = 1.3, noise = 60, out = 1.0 },
  megaphone = { hp = 550, lp = 3600, drive = 3.0, noise = 0, out = 1.0 },
}
A.PRESETS = PRESETS

function A.bandFx(buf, n, rate, kind, st)
  local p = PRESETS[kind]
  if not p then return end
  local ah, al = hpCoef(rate, p.hp), lpCoef(rate, math.min(p.lp, rate * 0.45))
  local hp, hpx, l1, l2 = st.hp, st.hpx, st.lp1, st.lp2
  for i = 0, n - 1 do
    local x = buf[i]
    hp = ah * (hp + x - hpx); hpx = x
    l1 = l1 + al * (hp - l1)
    l2 = l2 + al * (l1 - l2)
    local v = l2 / 32768 * p.drive
    v = v / (1 + math.abs(v)) -- мягкое ограничение
    v = v * 32768 * p.out + rand(st) * p.noise
    buf[i] = clamp(math.floor(v + 0.5), -32768, 32767)
  end
  st.hp, st.hpx, st.lp1, st.lp2 = hp, hpx, l1, l2
end

---------------------------------------------------------------------------
-- Служебные звуки (возвращают int16-буфер и длину)
---------------------------------------------------------------------------

-- Короткий щелчок нажатия клавиши.
function A.genClick(rate)
  local n = math.floor(rate * 0.025)
  local buf = ffi.new('int16_t[?]', n)
  for i = 0, n - 1 do
    local t = i / rate
    buf[i] = math.floor(math.sin(TWO_PI * 1900 * t) * math.exp(-t * 220) * 9000)
  end
  return buf, n
end

-- Шипение рации: открытие/закрытие канала.
function A.genSquelch(rate, ms, level)
  local n = math.floor(rate * ms / 1000)
  local buf = ffi.new('int16_t[?]', n)
  local st = A.newFxState()
  st.seed = 777
  local a = lpCoef(rate, 3000)
  local y = 0
  for i = 0, n - 1 do
    local env = math.min(1, i / (rate * 0.005)) * math.min(1, (n - i) / (rate * 0.02))
    y = y + a * (rand(st) - y)
    buf[i] = clamp(math.floor(y * 26000 * (level or 1) * env), -32768, 32767)
  end
  return buf, n
end

-- Последовательность тонов: { {частота, мс}, ... }; частота 0 = пауза.
function A.genTones(rate, seq, amp)
  local total = 0
  for _, s in ipairs(seq) do total = total + math.floor(rate * s[2] / 1000) end
  local buf = ffi.new('int16_t[?]', total)
  local pos = 0
  for _, s in ipairs(seq) do
    local n = math.floor(rate * s[2] / 1000)
    for i = 0, n - 1 do
      local env = math.min(1, i / (rate * 0.01)) * math.min(1, (n - i) / (rate * 0.01))
      buf[pos + i] = s[1] > 0 and math.floor(math.sin(TWO_PI * s[1] * i / rate) * (amp or 7000) * env) or 0
    end
    pos = pos + n
  end
  return buf, total
end

-- Входящий звонок и гудки исходящего.
A.RINGTONE = { { 880, 180 }, { 0, 60 }, { 1175, 180 }, { 0, 60 }, { 880, 180 }, { 0, 1340 } }
A.RINGBACK = { { 425, 800 }, { 0, 1200 } }

---------------------------------------------------------------------------
-- Запись последних N секунд (для жалоб) и WAV
---------------------------------------------------------------------------

local Ring = {}
Ring.__index = Ring

function A.newRing(rate, seconds)
  local size = math.floor(rate * seconds)
  return setmetatable({ rate = rate, size = size, buf = ffi.new('int16_t[?]', size), pos = 0, filled = 0 }, Ring)
end

function Ring:push(src, n)
  for i = 0, n - 1 do
    self.buf[self.pos] = src[i]
    self.pos = (self.pos + 1) % self.size
  end
  self.filled = math.min(self.size, self.filled + n)
end

-- Тишина между фразами, чтобы запись не склеивала их.
function Ring:gap(ms)
  local n = math.min(self.size, math.floor(self.rate * ms / 1000))
  for _ = 1, n do
    self.buf[self.pos] = 0
    self.pos = (self.pos + 1) % self.size
  end
  self.filled = math.min(self.size, self.filled + n)
end

function Ring:samples()
  local out = ffi.new('int16_t[?]', math.max(1, self.filled))
  local start = (self.pos - self.filled) % self.size
  for i = 0, self.filled - 1 do out[i] = self.buf[(start + i) % self.size] end
  return out, self.filled
end

local function le32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end

function A.wav(rate, buf, n)
  local bytes = n * 2
  return 'RIFF' .. le32(36 + bytes) .. 'WAVE' ..
    'fmt ' .. le32(16) .. le16(1) .. le16(1) .. le32(rate) .. le32(rate * 2) .. le16(2) .. le16(16) ..
    'data' .. le32(bytes) .. ffi.string(buf, bytes)
end

function Ring:wav()
  local buf, n = self:samples()
  return A.wav(self.rate, buf, n)
end


---------------------------------------------------------------------------
-- Громкость выше 100%: усиление с мягким ограничением (без хрипа на пиках)
---------------------------------------------------------------------------

local KNEE = 26000
function A.applyGain(buf, n, g)
  if g == 1 then return end
  for i = 0, n - 1 do
    local v = buf[i] * g
    local a = math.abs(v)
    if a > KNEE then
      a = KNEE + (32767 - KNEE) * math.tanh((a - KNEE) / (32767 - KNEE))
      v = v < 0 and -a or a
    end
    buf[i] = math.floor(v + 0.5)
  end
end

---------------------------------------------------------------------------
-- Свои звуки: WAV (PCM 8/16 бит, моно/стерео, любая частота)
---------------------------------------------------------------------------

local function rd16(s, i) local a, b = s:byte(i, i + 1); return a + b * 256 end
local function rd32(s, i) local a, b, c, d = s:byte(i, i + 3); return a + b * 256 + c * 65536 + d * 16777216 end

-- Разбирает WAV из строки. Возвращает { rate, n, buf (int16, моно) } или nil, причина.
function A.parseWav(data, maxSeconds)
  if type(data) ~= 'string' or #data < 44 or data:sub(1, 4) ~= 'RIFF' or data:sub(9, 12) ~= 'WAVE' then
    return nil, 'это не WAV-файл'
  end
  local pos, fmt, dataPos, dataLen = 13, nil, nil, nil
  while pos + 8 <= #data do
    local id, size = data:sub(pos, pos + 3), rd32(data, pos + 4)
    local body = pos + 8
    if id == 'fmt ' and size >= 16 then
      fmt = { format = rd16(data, body), channels = rd16(data, body + 2), rate = rd32(data, body + 4), bits = rd16(data, body + 14) }
    elseif id == 'data' then
      dataPos, dataLen = body, math.min(size, #data - body + 1)
      break
    end
    pos = body + size + (size % 2)
  end
  if not fmt or not dataPos then return nil, 'повреждённый WAV' end
  if fmt.format ~= 1 and fmt.format ~= 0xFFFE then return nil, 'нужен несжатый WAV (PCM)' end
  if fmt.bits ~= 16 and fmt.bits ~= 8 then return nil, 'нужен WAV 16 или 8 бит' end
  if fmt.channels < 1 or fmt.channels > 2 or fmt.rate < 4000 or fmt.rate > 96000 then
    return nil, 'нужен моно или стерео WAV 4000-96000 Гц'
  end
  local bytesPer = fmt.bits / 8 * fmt.channels
  local n = math.floor(dataLen / bytesPer)
  if maxSeconds and n > fmt.rate * maxSeconds then
    return nil, ('слишком длинный: больше %d сек'):format(maxSeconds)
  end
  if n < 1 then return nil, 'пустой WAV' end
  local buf = ffi.new('int16_t[?]', n)
  local p = ffi.cast('const uint8_t *', data) + (dataPos - 1)
  if fmt.bits == 16 then
    local s16 = ffi.cast('const int16_t *', p)
    for i = 0, n - 1 do
      if fmt.channels == 2 then buf[i] = math.floor((s16[2 * i] + s16[2 * i + 1]) / 2)
      else buf[i] = s16[i] end
    end
  else
    for i = 0, n - 1 do
      if fmt.channels == 2 then buf[i] = ((p[2 * i] + p[2 * i + 1]) / 2 - 128) * 256
      else buf[i] = (p[i] - 128) * 256 end
    end
  end
  return { rate = fmt.rate, n = n, buf = buf, data = data }
end

-- Пересчёт частоты (линейная интерполяция). Возвращает новый буфер и длину.
function A.resample(src, n, from, to)
  if from == to then
    local out = ffi.new('int16_t[?]', n)
    ffi.copy(out, src, n * 2)
    return out, n
  end
  local m = math.max(1, math.floor(n * to / from))
  local out = ffi.new('int16_t[?]', m)
  local step = from / to
  for i = 0, m - 1 do
    local x = i * step
    local j = math.floor(x)
    local f = x - j
    local a = src[math.min(j, n - 1)]
    local b = src[math.min(j + 1, n - 1)]
    out[i] = math.floor(a + (b - a) * f + 0.5)
  end
  return out, m
end

return A
