-- TriniVoice: голосовой чат по близости для SA-MP (Trinity RP).
-- Клиентский скрипт MoonLoader. Звук пишется и играется через bass.dll
-- клиента SA-MP и передаётся через внешний UDP-ретранслятор (папка server/).
-- Файл в UTF-8: русский текст переводится в CP1251 при выводе (функция cp).

script_name('TriniVoice')
script_author('TriniVoice')
script_version('0.1.0')
script_description('Proximity voice chat for SA-MP via external relay')

local ffi = require 'ffi'
local bit = require 'bit'

local VERSION = 1
local HDR = 'TV' .. string.char(VERSION)
local C_STATE, C_VOICE, C_BYE = 0x01, 0x02, 0x03
local S_ACK, S_VOICE = 0x81, 0x82

local MODE_RANGE = { 3, 15, 40 }                       -- шёпот, обычный, крик (метры)
local MODE_NAME = { 'шёпот', 'обычный', 'крик' }
local MODE_COLOR = { 0xFFB0B0B0, 0xFF5BD75B, 0xFFFF9A3C }
local ACK_TEXT = {
  [1] = 'этот SA-MP сервер не разрешён на ретрансляторе',
  [2] = 'ваш ID уже занят другим клиентом',
  [3] = 'вам запрещён голосовой чат',
}

local CODEC_ULAW, CODEC_OPUS = 1, 2
local FRAME_MS = 20
local STATE_INTERVAL = 0.2   -- сек между отправками позиции
local SPEAKER_IDLE = 5.0     -- сек тишины, после которых поток собеседника освобождается
local MAX_QUEUE_SEC = 0.4    -- больше этого в очереди воспроизведения не копим

---------------------------------------------------------------------------
-- Утилиты
---------------------------------------------------------------------------

-- UTF-8 -> CP1251 (кириллица + ASCII), остальное заменяется на '?'
local function cp(s)
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
      else out[#out + 1] = '?' end
      i = i + 2
    else
      out[#out + 1] = '?'
      i = i + (c >= 0xF0 and 4 or (c >= 0xE0 and 3 or 1))
    end
  end
  return table.concat(out)
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

local function u16(n) return string.char(bit.band(n, 0xFF), bit.band(bit.rshift(n, 8), 0xFF)) end
local function rd16(s, i) return s:byte(i) + s:byte(i + 1) * 256 end
local f32buf = ffi.new('float[1]')
local function f32(x) f32buf[0] = x; return ffi.string(f32buf, 4) end

---------------------------------------------------------------------------
-- Протокол (см. docs/PROTOCOL.md)
---------------------------------------------------------------------------

local function packState(id, x, y, z, interior, room, nick)
  return HDR .. string.char(C_STATE) .. u16(id) .. f32(x) .. f32(y) .. f32(z) ..
    string.char(bit.band(interior, 0xFF)) ..
    string.char(#room) .. room .. string.char(#nick) .. nick
end

local function packVoice(seq, mode, codec, payload)
  return HDR .. string.char(C_VOICE) .. u16(seq) .. string.char(mode, codec) .. payload
end

local function packBye() return HDR .. string.char(C_BYE) end

-- Разбор пакета сервера. Возвращает таблицу или nil.
local function parseServer(s)
  if #s < 4 or s:sub(1, 3) ~= HDR then return nil end
  local t = s:byte(4)
  if t == S_ACK and #s >= 7 then
    return { type = t, status = s:byte(5), online = rd16(s, 6) }
  elseif t == S_VOICE and #s > 10 then
    return { type = t, speaker = rd16(s, 5), seq = rd16(s, 7), mode = s:byte(9),
             codec = s:byte(10), payload = s:sub(11) }
  end
  return nil
end

---------------------------------------------------------------------------
-- Кодеки
---------------------------------------------------------------------------

-- G.711 u-law, 8 кГц: работает без дополнительных библиотек.
local ulawEnc = ffi.new('uint8_t[65536]')
local ulawDec = ffi.new('int16_t[256]')
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
    ulawEnc[s + 32768] = bit.band(bit.bnot(bit.bor(sign, bit.lshift(exp, 4), mant)), 0xFF)
  end
  for u = 0, 255 do
    local x = bit.band(bit.bnot(u), 0xFF)
    local exp, mant = bit.band(bit.rshift(x, 4), 7), bit.band(x, 0x0F)
    local v = bit.lshift(bit.lshift(mant, 3) + BIAS, exp) - BIAS
    ulawDec[u] = bit.band(x, 0x80) ~= 0 and -v or v
  end
end

local function makeUlaw()
  local rate = 8000
  local n = rate * FRAME_MS / 1000
  local out = ffi.new('uint8_t[?]', n)
  local pcm = ffi.new('int16_t[?]', n)
  return {
    id = CODEC_ULAW, rate = rate, frame = n,
    encode = function(src, count)
      for i = 0, count - 1 do out[i] = ulawEnc[src[i] + 32768] end
      return ffi.string(out, count)
    end,
    newDecoder = function()
      return {
        decode = function(_, data)
          local len = math.min(#data, n)
          for i = 0, len - 1 do pcm[i] = ulawDec[data:byte(i + 1)] end
          return pcm, len
        end,
        conceal = function() return nil, 0 end,
        free = function() end,
      }
    end,
  }
end

-- Opus, 16 кГц: нужен 32-битный opus.dll в moonloader/lib (у всех собеседников).
local opusLib
local function loadOpus(dir)
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

local function makeOpus(lib, bitrate)
  local rate = 16000
  local n = rate * FRAME_MS / 1000
  local err = ffi.new('int[1]')
  local enc = lib.opus_encoder_create(rate, 1, 2048 --[[VOIP]], err)
  if enc == nil or err[0] ~= 0 then return nil end
  ffi.gc(enc, lib.opus_encoder_destroy)
  lib.opus_encoder_ctl(enc, 4002 --[[SET_BITRATE]], ffi.new('int32_t', bitrate))
  lib.opus_encoder_ctl(enc, 4012 --[[SET_INBAND_FEC]], ffi.new('int32_t', 1))
  lib.opus_encoder_ctl(enc, 4014 --[[SET_PACKET_LOSS_PERC]], ffi.new('int32_t', 10))
  local out = ffi.new('unsigned char[512]')
  local pcm = ffi.new('int16_t[?]', n)
  return {
    id = CODEC_OPUS, rate = rate, frame = n,
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
        free = function() end,
      }
    end,
  }
end

---------------------------------------------------------------------------
-- Звук и громкость
---------------------------------------------------------------------------

-- Громкость в зависимости от расстояния: полная в первой четверти радиуса,
-- дальше линейно до нуля на границе.
local function distanceVolume(d, range)
  local full = range * 0.25
  if d <= full then return 1 end
  return clamp(1 - (d - full) / (range - full), 0, 1)
end

-- Панорама: -1 слева, 1 справа, относительно направления камеры.
local function stereoPan(mx, my, sx, sy, fx, fy)
  local dx, dy = sx - mx, sy - my
  local dl = math.sqrt(dx * dx + dy * dy)
  local fl = math.sqrt(fx * fx + fy * fy)
  if dl < 0.5 or fl < 1e-3 then return 0 end
  -- правый вектор для направления (fx, fy) в координатах GTA (z вверх)
  local rx, ry = fy / fl, -fx / fl
  return clamp((dx * rx + dy * ry) / dl, -1, 1) * 0.75
end

-- Громкость микрофона (усиление) и RMS кадра для активации голосом.
local function applyGainAndRms(buf, count, gain)
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

-- RMS кадра -> уровень 0..1 по шкале -60..0 дБ (для индикатора микрофона).
local function levelFromRms(rms)
  if rms < 1 then return 0 end
  return clamp((20 * math.log10(rms / 32768) + 60) / 60, 0, 1)
end

if TRINIVOICE_TEST then
  TV_internal = {
    cp = cp, packState = packState, packVoice = packVoice, packBye = packBye,
    parseServer = parseServer, makeUlaw = makeUlaw, ulawEnc = ulawEnc, ulawDec = ulawDec,
    distanceVolume = distanceVolume, stereoPan = stereoPan, applyGainAndRms = applyGainAndRms,
    levelFromRms = levelFromRms,
    MODE_RANGE = MODE_RANGE,
  }
  return
end

---------------------------------------------------------------------------
-- Всё, что ниже, работает только внутри игры
---------------------------------------------------------------------------

local inicfg = require 'inicfg'
local socket = require 'socket'
local vkeys = require 'vkeys'

-- Меню на mimgui. Если mimgui не установлен, работают только команды /tv.
local okUi, ui = pcall(require, 'trinivoice.ui')
if not okUi then
  print('[TriniVoice] меню недоступно: ' .. tostring(ui))
  ui = nil
end

local INI = 'trinivoice.ini'
local cfg = inicfg.load({
  main = {
    enabled = true,
    host = '127.0.0.1',
    port = 7790,
    activation = 'ptt',      -- ptt | vad
    ptt_key = 0x58,          -- X
    mode_key = 0x42,         -- B: переключить шёпот/обычный/крик
    mode = 2,
    vad_threshold = 700,
    mic_gain = 100,          -- %
    master_volume = 100,     -- %
    codec = 'ulaw',          -- ulaw | opus
    opus_bitrate = 24000,
    show_icons = true,
    show_hud = true,
    accent = '#6E8BFF',      -- цвет меню
  },
  muted = {},
  volume = {},
}, INI)

local function save() inicfg.save(cfg, INI) end
local function msg(text) sampAddChatMessage('[TriniVoice] {FFFFFF}' .. cp(text), 0x5BD75B) end

local bass
local rec, pushProc
local codec, codecs = nil, {}
local udp
local net = { seq = 0, lastState = 0, lastAck = -100, status = 0, online = 0, room = nil, ping = 0, stateAt = nil }
local speakers = {}
local tx = { active = false, vadUntil = 0, level = 0, monitor = false }
local known = {}          -- игроки, которых мы слышали: id -> { nick, heard, mode }
local KNOWN_TTL = 300     -- сек: столько игрок остаётся в списке «Игроки рядом»
local bindTarget          -- 'ptt' | 'mode', пока ждём новую клавишу из меню
local dirtyAt             -- когда настройки изменились (сохраняем с задержкой)
local font

local function initBass()
  ffi.cdef [[
    typedef uint32_t DWORD;
    typedef int BOOL;
    BOOL __stdcall BASS_Init(int device, DWORD freq, DWORD flags, void *win, void *dsguid);
    DWORD __stdcall BASS_GetDevice(void);
    int __stdcall BASS_ErrorGetCode(void);
    BOOL __stdcall BASS_RecordInit(int device);
    DWORD __stdcall BASS_RecordStart(DWORD freq, DWORD chans, DWORD flags, void *proc, void *user);
    BOOL __stdcall BASS_RecordFree(void);
    DWORD __stdcall BASS_ChannelGetData(DWORD handle, void *buffer, DWORD length);
    BOOL __stdcall BASS_ChannelPlay(DWORD handle, BOOL restart);
    BOOL __stdcall BASS_ChannelPause(DWORD handle);
    BOOL __stdcall BASS_ChannelStop(DWORD handle);
    DWORD __stdcall BASS_StreamCreate(DWORD freq, DWORD chans, DWORD flags, void *proc, void *user);
    DWORD __stdcall BASS_StreamPutData(DWORD handle, const void *buffer, DWORD length);
    BOOL __stdcall BASS_StreamFree(DWORD handle);
    BOOL __stdcall BASS_ChannelSetAttribute(DWORD handle, DWORD attrib, float value);
  ]]
  local ok, lib = pcall(ffi.load, 'bass')
  if not ok then return false, 'не найден bass.dll' end
  bass = lib
  if bass.BASS_GetDevice() == 0xFFFFFFFF then
    bass.BASS_Init(-1, 44100, 0, nil, nil)
  end
  pushProc = ffi.cast('void *', ffi.cast('intptr_t', -1)) -- STREAMPROC_PUSH
  return true
end

local function stopRecording()
  if rec then bass.BASS_ChannelStop(rec); rec = nil end
end

local function startRecording()
  stopRecording()
  -- BOOL из C: 0 = ошибка (в Lua 0 считается истиной, поэтому сравниваем явно)
  if bass.BASS_RecordInit(-1) == 0 and bass.BASS_ErrorGetCode() ~= 14 --[[ALREADY]] then
    return false, 'микрофон недоступен (код ' .. bass.BASS_ErrorGetCode() .. ')'
  end
  local h = bass.BASS_RecordStart(codec.rate, 1, 0x8000 --[[RECORD_PAUSE]], nil, nil)
  if h == 0 then return false, 'не удалось начать запись (код ' .. bass.BASS_ErrorGetCode() .. ')' end
  rec = h
  tx.recording = false
  return true
end

local function selectCodec()
  codecs[CODEC_ULAW] = codecs[CODEC_ULAW] or makeUlaw()
  local lib = loadOpus(getWorkingDirectory())
  if lib and not codecs[CODEC_OPUS] then codecs[CODEC_OPUS] = makeOpus(lib, cfg.main.opus_bitrate) end
  if cfg.main.codec == 'opus' then
    if codecs[CODEC_OPUS] then codec = codecs[CODEC_OPUS]
    else
      msg('opus.dll не найден в moonloader/lib, используется u-law')
      codec = codecs[CODEC_ULAW]
    end
  else
    codec = codecs[CODEC_ULAW]
  end
end

local function openSocket()
  if udp then udp:close() end
  udp = socket.udp()
  udp:settimeout(0)
  local ok, err = udp:setpeername(cfg.main.host, cfg.main.port)
  if not ok then msg('не удалось подключиться к ' .. cfg.main.host .. ': ' .. tostring(err)); udp = nil end
  net.lastAck = -100
end

local function sendPacket(data) if udp then udp:send(data) end end

-- Комната = адрес SA-MP сервера. Домен переводим в IP, чтобы игроки,
-- зашедшие по домену и по IP, попали в одну комнату.
local resolved = {}
local function roomFor(host, port)
  if not host:match('^%d+%.%d+%.%d+%.%d+$') then
    if resolved[host] == nil then resolved[host] = socket.dns.toip(host) or host end
    host = resolved[host]
  end
  return host .. ':' .. port
end

---------------------------------------------------------------------------
-- Передача
---------------------------------------------------------------------------

local function canTalk()
  if not cfg.main.enabled or not sampIsLocalPlayerSpawned() then return false end
  if isCharDead(PLAYER_PED) then return false end
  return true
end

local function inputBusy()
  return sampIsChatInputActive() or sampIsDialogActive() or isSampfuncsConsoleActive()
    or bindTarget ~= nil or (ui ~= nil and ui.wantsText())
end

local function drainRecording()
  if not rec then return end
  local avail = bass.BASS_ChannelGetData(rec, nil, 0)
  if avail > 0 and avail ~= 0xFFFFFFFF then
    local junk = ffi.new('uint8_t[?]', avail)
    bass.BASS_ChannelGetData(rec, junk, avail)
  end
end

local pcmIn
local function processCapture(now)
  if not rec then tx.level = 0; return end
  local talk = canTalk() and (cfg.main.activation == 'vad' or (not inputBusy() and isKeyDown(cfg.main.ptt_key)))
  -- пока открыто меню, микрофон пишется для индикатора, но в эфир не идёт
  local wantRecord = talk or tx.monitor
  if wantRecord and not tx.recording then
    drainRecording()
    bass.BASS_ChannelPlay(rec, 0)
    tx.recording = true
  elseif not wantRecord and tx.recording then
    bass.BASS_ChannelPause(rec)
    drainRecording()
    tx.recording = false
    tx.active = false
    tx.level = 0
    return
  end
  if not tx.recording then return end

  local frameBytes = codec.frame * 2
  if not pcmIn or ffi.sizeof(pcmIn) < frameBytes then pcmIn = ffi.new('int16_t[?]', codec.frame) end
  local avail = bass.BASS_ChannelGetData(rec, nil, 0)
  if avail == 0xFFFFFFFF then return end
  local frames = math.floor(avail / frameBytes)
  -- после подвисания игры не шлём старый звук пачкой
  while frames > 10 do bass.BASS_ChannelGetData(rec, pcmIn, frameBytes); frames = frames - 1 end

  local gain = cfg.main.mic_gain / 100
  local sent = false
  for _ = 1, frames do
    if bass.BASS_ChannelGetData(rec, pcmIn, frameBytes) ~= frameBytes then break end
    local rms = applyGainAndRms(pcmIn, codec.frame, gain)
    tx.level = math.max(levelFromRms(rms), tx.level * 0.8)
    local open = talk
    if talk and cfg.main.activation == 'vad' then
      if rms >= cfg.main.vad_threshold then tx.vadUntil = now + 0.35 end
      open = now < tx.vadUntil
    end
    if open then
      local payload = codec.encode(pcmIn, codec.frame)
      if payload then
        net.seq = (net.seq + 1) % 65536
        sendPacket(packVoice(net.seq, cfg.main.mode, codec.id, payload))
        sent = true
      end
    end
  end
  if frames > 0 then tx.active = sent end
end

---------------------------------------------------------------------------
-- Приём
---------------------------------------------------------------------------

local function freeSpeaker(id)
  local sp = speakers[id]
  if sp then
    if sp.stream then bass.BASS_StreamFree(sp.stream) end
    speakers[id] = nil
  end
end

local function speakerPed(id)
  local ok, ped = sampGetCharHandleBySampPlayerId(id)
  if ok and doesCharExist(ped) then return ped end
  return nil
end

local warnedOpus = false
local function onVoice(p, now)
  local c = codecs[p.codec]
  if not c then
    if p.codec == CODEC_OPUS and not warnedOpus then
      warnedOpus = true
      msg('кто-то рядом говорит через Opus: положите opus.dll в moonloader/lib')
    end
    return
  end
  if not MODE_RANGE[p.mode] or not sampIsPlayerConnected(p.speaker) then return end
  local nick = sampGetPlayerNickname(p.speaker)
  -- проверка на месте: говорящий должен реально стоять рядом в игре
  local ped = speakerPed(p.speaker)
  if not ped then return end
  local mx, my, mz = getCharCoordinates(PLAYER_PED)
  local sx, sy, sz = getCharCoordinates(ped)
  local d = math.sqrt((sx - mx) ^ 2 + (sy - my) ^ 2 + (sz - mz) ^ 2)
  if d > MODE_RANGE[p.mode] * 1.3 + 3 then return end
  known[p.speaker] = { nick = nick, heard = now, mode = p.mode }
  if cfg.muted[nick] then return end

  local sp = speakers[p.speaker]
  if sp and (sp.nick ~= nick or sp.codec ~= c) then freeSpeaker(p.speaker); sp = nil end
  if not sp then
    local dec = c.newDecoder()
    if not dec then return end
    local h = bass.BASS_StreamCreate(c.rate, 1, 0, pushProc, nil)
    if h == 0 then return end
    bass.BASS_ChannelSetAttribute(h, 2 --[[VOL]], 0)
    bass.BASS_ChannelPlay(h, 0)
    sp = { stream = h, codec = c, dec = dec, nick = nick, lastSeq = nil, last = 0 }
    speakers[p.speaker] = sp
  end

  if sp.lastSeq then
    local diff = (p.seq - sp.lastSeq) % 65536
    if diff == 0 or diff > 32768 then return end -- дубликат или опоздавший пакет
    for _ = 1, math.min(diff - 1, 2) do          -- маскировка потерь
      local pcm, n = sp.dec:conceal()
      if pcm and n > 0 then bass.BASS_StreamPutData(sp.stream, pcm, n * 2) end
    end
  end
  sp.lastSeq = p.seq

  local queued = bass.BASS_StreamPutData(sp.stream, nil, 0)
  if queued ~= 0xFFFFFFFF and queued > c.rate * 2 * MAX_QUEUE_SEC then return end
  if now - sp.last > 0.3 then
    -- начало фразы: небольшой буфер тишины против рывков
    local pad = ffi.new('int16_t[?]', c.frame * 3)
    bass.BASS_StreamPutData(sp.stream, pad, c.frame * 3 * 2)
  end
  local pcm, n = sp.dec:decode(p.payload)
  if pcm and n > 0 then bass.BASS_StreamPutData(sp.stream, pcm, n * 2) end
  sp.last = now
  sp.mode = p.mode
end

local function processNetwork(now)
  if not udp then return end
  for _ = 1, 300 do
    local data = udp:receive()
    if not data then break end
    local p = parseServer(data)
    if p and p.type == S_ACK then
      if p.status ~= net.status and ACK_TEXT[p.status] then msg(ACK_TEXT[p.status]) end
      if p.status == 0 and now - net.lastAck > 5 then msg('подключено к голосовому серверу') end
      net.status, net.online, net.lastAck = p.status, p.online, now
      if net.stateAt and now - net.stateAt < 1 then net.ping = math.floor((now - net.stateAt) * 1000 + 0.5) end
      net.stateAt = nil
    elseif p and p.type == S_VOICE and cfg.main.enabled then
      onVoice(p, now)
    end
  end

  if now - net.lastState >= STATE_INTERVAL and cfg.main.enabled and sampIsLocalPlayerSpawned() then
    net.lastState = now
    local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if ok then
      local ip, port = sampGetCurrentServerAddress()
      net.room = roomFor(ip, port)
      local x, y, z = getCharCoordinates(PLAYER_PED)
      sendPacket(packState(id, x, y, z, getActiveInterior(), net.room, sampGetPlayerNickname(id)))
      net.stateAt = net.stateAt or now
    end
  end
end

local function updateSpeakers(now)
  local mx, my, mz = getCharCoordinates(PLAYER_PED)
  local cx, cy = getActiveCameraCoordinates()
  local px, py = getActiveCameraPointAt()
  local master = cfg.main.master_volume / 100
  for id, sp in pairs(speakers) do
    local ped = speakerPed(id)
    if now - sp.last > SPEAKER_IDLE or not ped then
      freeSpeaker(id)
    else
      local sx, sy, sz = getCharCoordinates(ped)
      local d = math.sqrt((sx - mx) ^ 2 + (sy - my) ^ 2 + (sz - mz) ^ 2)
      local personal = (tonumber(cfg.volume[sp.nick]) or 100) / 100
      local vol = distanceVolume(d, MODE_RANGE[sp.mode or 2]) * master * personal
      if cfg.muted[sp.nick] then vol = 0 end
      bass.BASS_ChannelSetAttribute(sp.stream, 2 --[[VOL]], vol)
      bass.BASS_ChannelSetAttribute(sp.stream, 3 --[[PAN]], stereoPan(mx, my, sx, sy, px - cx, py - cy))
    end
  end
end

---------------------------------------------------------------------------
-- Отрисовка
---------------------------------------------------------------------------

local function render(now)
  if cfg.main.show_icons then
    for id, sp in pairs(speakers) do
      local ped = speakerPed(id)
      if ped and now - sp.last < 0.3 and isCharOnScreen(ped) then
        local x, y, z = getCharCoordinates(ped)
        local sx, sy = convert3DCoordsToScreen(x, y, z + 1.15)
        local text = cp('(( голос ))')
        local w = renderGetFontDrawTextLength(font, text)
        renderFontDrawText(font, text, sx - w / 2, sy, MODE_COLOR[sp.mode or 2])
      end
    end
  end
  if cfg.main.show_hud and cfg.main.enabled then
    local _, h = getScreenResolution()
    local connected = now - net.lastAck < 3 and net.status == 0
    local state
    if not connected then state = 'нет связи с сервером'
    elseif tx.active then state = 'В ЭФИРЕ'
    elseif cfg.main.activation == 'vad' then state = 'голосовая активация'
    else state = 'зажмите клавишу, чтобы говорить' end
    local text = cp(('TriniVoice | %s | %s'):format(MODE_NAME[cfg.main.mode], state))
    local color = tx.active and 0xFFFF5050 or (connected and 0xFFE0E0E0 or 0xFF909090)
    renderFontDrawText(font, text, 20, h * 0.72, color)
  end
end

---------------------------------------------------------------------------
-- Настройки (общие для команд /tv и меню)
---------------------------------------------------------------------------

local function isConnected(now) return now - net.lastAck < 3 and net.status == 0 end
local function markDirty() dirtyAt = dirtyAt or os.clock() end

local function setEnabled(on)
  cfg.main.enabled = on
  if not on then
    sendPacket(packBye())
    for id in pairs(speakers) do freeSpeaker(id) end
  end
  markDirty()
end

local function setCodec(name)
  cfg.main.codec = name
  selectCodec()
  local ok, err = startRecording()
  if not ok then msg(err) end
  markDirty()
end

local function setServer(host, port)
  cfg.main.host, cfg.main.port = host, port
  openSocket()
  markDirty()
end

local function keyName(k)
  local ok, name = pcall(vkeys.id_to_name, k)
  if ok and name then return name end
  return ('0x%02X'):format(k or 0)
end

local playersCache, playersAt = {}, -1
local function nearbyPlayers()
  local now = os.clock()
  if now - playersAt < 0.1 then return playersCache end
  playersAt = now
  local list = {}
  if sampIsLocalPlayerSpawned() then
    local mx, my, mz = getCharCoordinates(PLAYER_PED)
    for id, k in pairs(known) do
      if now - k.heard > KNOWN_TTL or not sampIsPlayerConnected(id) or sampGetPlayerNickname(id) ~= k.nick then
        known[id] = nil
      else
        local ped = speakerPed(id)
        if ped then
          local sx, sy, sz = getCharCoordinates(ped)
          local sp = speakers[id]
          list[#list + 1] = {
            id = id, nick = k.nick, mode = k.mode,
            dist = math.sqrt((sx - mx) ^ 2 + (sy - my) ^ 2 + (sz - mz) ^ 2),
            talking = sp ~= nil and now - sp.last < 0.3,
            muted = cfg.muted[k.nick] == true,
            volume = tonumber(cfg.volume[k.nick]) or 100,
          }
        end
      end
    end
    table.sort(list, function(a, b)
      if a.talking ~= b.talking then return a.talking end
      return a.dist < b.dist
    end)
  end
  playersCache = list
  return list
end

-- Всё, что видит и меняет меню (lib/trinivoice/ui.lua).
local uiContext = {
  cfg = cfg,
  status = function()
    local now = os.clock()
    return {
      connected = isConnected(now), ping = net.ping, online = net.online, room = net.room,
      micOk = rec ~= nil, micLevel = tx.level, vadLevel = levelFromRms(cfg.main.vad_threshold),
      codec = codec and codec.id == CODEC_OPUS and 'Opus' or 'u-law',
      opusAvailable = codecs[CODEC_OPUS] ~= nil,
    }
  end,
  players = nearbyPlayers,
  set = function(key, value) cfg.main[key] = value; markDirty() end,
  setEnabled = setEnabled,
  setMode = function(m) cfg.main.mode = m; markDirty() end,
  setActivation = function(a) cfg.main.activation = a; markDirty() end,
  setCodec = setCodec,
  setServer = setServer,
  toggleMute = function(nick) cfg.muted[nick] = (not cfg.muted[nick]) or nil; markDirty() end,
  setVolume = function(nick, v) cfg.volume[nick] = v; markDirty() end,
  binding = function() return bindTarget end,
  startBinding = function(which) bindTarget = which end,
  keyName = keyName,
}

---------------------------------------------------------------------------
-- Команды
---------------------------------------------------------------------------

local HELP = {
  '/tv - открыть меню (без mimgui: состояние и справка)',
  '/tv help - эта справка',
  '/tv on | off - включить или выключить голосовой чат',
  '/tv mode 1-3 - шёпот, обычный, крик (или клавиша режима)',
  '/tv ptt | vad - нажми и говори / активация голосом',
  '/tv threshold N - порог активации голосом (по умолчанию 700)',
  '/tv mute ID | unmute ID - выключить или вернуть звук игрока',
  '/tv vol ID 0-100 - громкость игрока, /tv master 0-100 - общая',
  '/tv gain 50-400 - усиление микрофона в процентах',
  '/tv codec ulaw | opus - кодек (opus.dll нужен всем)',
  '/tv icons | hud - показать или скрыть значки и строку состояния',
  '/tv server HOST PORT - адрес ретранслятора',
}

local function nickById(arg)
  local id = tonumber(arg)
  if not id or not sampIsPlayerConnected(id) then msg('игрок с таким ID не найден'); return nil end
  return sampGetPlayerNickname(id)
end

local function onCommand(args)
  local a = {}
  for w in args:gmatch('%S+') do a[#a + 1] = w end
  local c = (a[1] or ''):lower()
  local m = cfg.main
  if c == '' and ui then
    ui.toggle()
    return
  elseif c == '' or c == 'help' then
    msg(('%s, сервер %s:%d, %s, игроков с голосом на сервере: %d'):format(
      m.enabled and 'включён' or 'выключен', m.host, m.port,
      isConnected(os.clock()) and 'на связи' or 'нет связи', net.online))
    for _, line in ipairs(HELP) do msg(line) end
    return
  elseif c == 'on' or c == 'off' then
    setEnabled(c == 'on')
    msg(m.enabled and 'включён' or 'выключен')
  elseif c == 'mode' and tonumber(a[2]) and MODE_RANGE[tonumber(a[2])] then
    m.mode = tonumber(a[2]); msg('режим: ' .. MODE_NAME[m.mode])
  elseif c == 'ptt' or c == 'vad' then
    m.activation = c; msg(c == 'ptt' and 'режим: нажми и говори' or 'режим: активация голосом')
  elseif c == 'threshold' and tonumber(a[2]) then
    m.vad_threshold = clamp(tonumber(a[2]), 50, 20000); msg('порог: ' .. m.vad_threshold)
  elseif c == 'mute' or c == 'unmute' then
    local nick = nickById(a[2]); if not nick then return end
    cfg.muted[nick] = (c == 'mute') or nil
    msg((c == 'mute' and 'звук выключен: ' or 'звук включён: ') .. nick)
  elseif c == 'vol' and tonumber(a[3]) then
    local nick = nickById(a[2]); if not nick then return end
    cfg.volume[nick] = clamp(math.floor(tonumber(a[3])), 0, 100)
    msg(('громкость %s: %d%%'):format(nick, cfg.volume[nick]))
  elseif c == 'master' and tonumber(a[2]) then
    m.master_volume = clamp(math.floor(tonumber(a[2])), 0, 100); msg('общая громкость: ' .. m.master_volume .. '%')
  elseif c == 'gain' and tonumber(a[2]) then
    m.mic_gain = clamp(math.floor(tonumber(a[2])), 50, 400); msg('усиление микрофона: ' .. m.mic_gain .. '%')
  elseif c == 'codec' and (a[2] == 'ulaw' or a[2] == 'opus') then
    setCodec(a[2])
    msg('кодек: ' .. (codec.id == CODEC_OPUS and 'opus' or 'u-law'))
  elseif c == 'icons' then
    m.show_icons = not m.show_icons
  elseif c == 'hud' then
    m.show_hud = not m.show_hud
  elseif c == 'server' and a[2] and tonumber(a[3]) then
    setServer(a[2], tonumber(a[3]))
    msg('ретранслятор: ' .. m.host .. ':' .. m.port)
  else
    msg('неизвестная команда, введите /tv help'); return
  end
  save()
end

---------------------------------------------------------------------------
-- Точка входа
---------------------------------------------------------------------------

local function processKeys()
  if cfg.main.mode_key ~= 0 and wasKeyPressed(cfg.main.mode_key) and not inputBusy() then
    cfg.main.mode = cfg.main.mode % 3 + 1
    if not (ui and ui.isOpen()) then msg('режим: ' .. MODE_NAME[cfg.main.mode]) end
    markDirty()
  end
  -- переназначение клавиши из меню: ловим следующую нажатую (кроме ЛКМ/ПКМ и Esc)
  if bindTarget then
    for k = 3, 254 do
      if k ~= 0x1B and wasKeyPressed(k) then
        cfg.main[bindTarget .. '_key'] = k
        bindTarget = nil
        markDirty()
        break
      end
    end
  end
end

function main()
  if not isSampLoaded() or not isSampfuncsLoaded() then return end
  while not isSampAvailable() do wait(100) end

  local ok, err = initBass()
  if not ok then msg(err .. ', скрипт остановлен'); return end
  selectCodec()
  ok, err = startRecording()
  if not ok then msg(err .. ', вы будете только слышать других') end
  openSocket()
  font = renderCreateFont('Arial', 9, 5)
  sampRegisterChatCommand('tv', onCommand)
  if ui then ui.init(uiContext) end
  msg(('загружен. %s - говорить, %s - дальность, /tv - %s'):format(
    keyName(cfg.main.ptt_key), keyName(cfg.main.mode_key), ui and 'меню' or 'настройки'))

  while true do
    wait(0)
    local now = os.clock()
    processKeys()
    tx.monitor = ui ~= nil and ui.isOpen()
    if not tx.monitor then bindTarget = nil end
    processNetwork(now)
    processCapture(now)
    if cfg.main.enabled and sampIsLocalPlayerSpawned() then updateSpeakers(now) end
    render(now)
    if dirtyAt and now - dirtyAt > 1 then dirtyAt = nil; save() end
  end
end

-- Esc закрывает меню (или отменяет переназначение клавиши), а не открывает паузу.
function onWindowMessage(m, wparam)
  if m == 0x0100 and wparam == 0x1B and ui and ui.isOpen() then
    consumeWindowMessage(true, false)
    if bindTarget then bindTarget = nil else ui.close() end
  end
end

function onScriptTerminate(scr)
  if scr ~= thisScript() then return end
  pcall(function()
    if dirtyAt then save() end
    sendPacket(packBye())
    if bass then
      for id in pairs(speakers) do freeSpeaker(id) end
      stopRecording()
    end
    if udp then udp:close() end
  end)
end
