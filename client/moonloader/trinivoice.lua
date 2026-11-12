-- TriniVoice: голосовой чат для SA-MP (Trinity RP).
-- Клиентский скрипт MoonLoader. Звук пишется и играется через bass.dll
-- клиента SA-MP и передаётся через внешний UDP-ретранслятор (папка server/).
-- Файл в UTF-8: русский текст переводится в CP1251 при выводе в чат.
--
-- Модули (moonloader/lib/trinivoice/):
--   protocol.lua  протокол обмена с ретранслятором
--   audio.lua     кодеки, эффекты (рация, телефон, мегафон, стены), служебные звуки, WAV
--   ui.lua        меню /tv на mimgui (необязательно)

local SCRIPT_VERSION = '0.4.0'
script_name('TriniVoice')
script_author('TriniVoice')
script_version(SCRIPT_VERSION)
script_description('Voice chat for SA-MP via external relay: proximity, radio, phone')

local ffi = require 'ffi'
local P = require 'trinivoice.protocol'
local A = require 'trinivoice.audio'
local inicfg = require 'inicfg'
local socket = require 'socket'
local vkeys = require 'vkeys'

-- Меню на mimgui. Если mimgui не установлен, работают только команды /tv.
local okUi, ui = pcall(require, 'trinivoice.ui')
if not okUi then
  print('[TriniVoice] меню недоступно: ' .. tostring(ui))
  ui = nil
end
-- SAMP.Lua нужен только для автозвонков по сообщениям сервера.
local okEv, sampev = pcall(require, 'lib.samp.events')
if not okEv then sampev = nil end

local cp, clamp = A.cp, A.clamp

local MODE_NAME = { 'шёпот', 'обычный', 'крик', 'мегафон', 'рация', 'телефон' }
local MODE_COLOR = { 0xFFC8C8C8, 0xFF5BD75B, 0xFFFF9A3C, 0xFFFF6B6B, 0xFF6E8BFF, 0xFF6E8BFF }
local ACK_TEXT = {
  [P.ACK_ROOM] = 'этот SA-MP сервер не разрешён на ретрансляторе',
  [P.ACK_ID_TAKEN] = 'ваш ID уже занят другим клиентом',
  [P.ACK_BANNED] = 'вам запрещён голосовой чат на этом ретрансляторе',
  [P.ACK_OUTDATED] = 'версия скрипта устарела: обновите TriniVoice',
  [P.ACK_FULL] = 'ретранслятор переполнен или слишком много подключений с вашего IP',
}
-- служебный транспорт, в котором крик становится мегафоном
local SERVICE_VEHICLES = {}
for _, m in ipairs({ 596, 597, 598, 599, 523, 427, 490, 528, 601, 497, 430, 416, 407, 544 }) do SERVICE_VEHICLES[m] = true end

local STATE_INTERVAL = 0.2   -- сек между отправками позиции
local SPEAKER_IDLE = 5.0     -- сек тишины, после которых поток собеседника освобождается
local MAX_QUEUE_SEC = 0.4    -- больше этого в очереди воспроизведения не копим
local KNOWN_TTL = 300        -- сек: столько игрок остаётся в списке «Игроки рядом»
local REPORT_SECONDS = 30
local LOCAL_RATE = 16000     -- служебные звуки

local INI = 'trinivoice.ini'
local DEFAULTS = {
  main = {
    enabled = true,
    host = '127.0.0.1',
    port = 7790,
    activation = 'ptt',      -- ptt | vad
    ptt_key = 0x58,          -- X
    mode_key = 0x42,         -- B: шёпот / обычный / крик
    mode = 2,
    vad_threshold = 700,
    mic_gain = 100,          -- %
    master_volume = 100,     -- %
    codec = 'ulaw',          -- ulaw | opus
    opus_bitrate = 24000,
    show_icons = true,
    show_hud = true,
    accent = '#6E8BFF',
    -- рация
    radio_on = false,
    radio_freq = 100.0,
    radio_pass = '',
    radio_key = 0x5A,        -- Z
    radio_volume = 100,
    -- звук
    fx_radio = true,         -- эффект рации и телефона
    occlusion = true,        -- приглушение через стены и в машинах
    megaphone = true,        -- крик в служебной машине = мегафон 60 м
    ptt_sound = true,        -- щелчок / шипение при нажатии
    ring_volume = 80,
    -- автозвонки по сообщениям сервера (Lua-шаблоны в CP1251, захват = ник или ID)
    phone_auto = false,
    phone_start = '',
    phone_end = '',
    admin_key = '',
  },
  muted = {},
  volume = {},
  radio_presets = {},
}

-- Ini может быть неполным (например, админ раздал архив только с адресом
-- ретранслятора): всё, чего в нём нет, берём из DEFAULTS.
local function loadConfig()
  local function copy(t)
    local r = {}
    for k, v in pairs(t) do r[k] = type(v) == 'table' and copy(v) or v end
    return r
  end
  local c = inicfg.load(copy(DEFAULTS), INI) or {}
  for sec, keys in pairs(DEFAULTS) do
    if type(c[sec]) ~= 'table' then c[sec] = {} end
    for k, v in pairs(keys) do
      if c[sec][k] == nil then c[sec][k] = v end
    end
  end
  return c
end
local cfg = loadConfig()

local function save() inicfg.save(cfg, INI) end
local function msg(text) sampAddChatMessage('[TriniVoice] {FFFFFF}' .. cp(text), 0x5BD75B) end

local bass, rec, pushProc, fxStream
local codec, codecs = nil, {}
local udp
local net = { seq = 0, lastState = 0, lastAck = -100, status = 0, online = 0, room = nil, ping = 0,
  stateAt = nil, radioListeners = 0, mutedSec = 0, latest = '', updateNotified = false }
local speakers = {}
local tx = { active = false, mode = nil, vadUntil = 0, level = 0, monitor = false, recording = false }
local call                  -- { state = 'in'|'out'|'active', peerId, peerNick, since }
local nextRing = 0
local autoCall = {}         -- ник -> время, когда сервер сообщил о звонке (автозвонки)
local known = {}            -- id -> { nick, heard, mode }: кого мы слышали рядом
local rings = {}            -- ник -> последние 30 сек его голоса (для жалоб)
local bindTarget            -- 'ptt' | 'mode' | 'radio', пока ждём новую клавишу из меню
local dirtyAt
local font
local sounds = {}

local function isConnected(now) return now - net.lastAck < 3 and (net.status == P.ACK_OK or net.status == P.ACK_MUTED) end
local function markDirty() dirtyAt = dirtyAt or os.clock() end
local function radioWire() return cfg.main.radio_on and P.freqToWire(cfg.main.radio_freq) or 0 end

local function keyName(k)
  local ok, name = pcall(vkeys.id_to_name, k)
  if ok and name then return name end
  return ('0x%02X'):format(k or 0)
end

---------------------------------------------------------------------------
-- BASS
---------------------------------------------------------------------------

local function initBass()
  ffi.cdef [[
    typedef uint32_t DWORD;
    typedef int BOOL;
    BOOL __stdcall BASS_Init(int device, DWORD freq, DWORD flags, void *win, void *dsguid);
    DWORD __stdcall BASS_GetDevice(void);
    int __stdcall BASS_ErrorGetCode(void);
    BOOL __stdcall BASS_RecordInit(int device);
    DWORD __stdcall BASS_RecordStart(DWORD freq, DWORD chans, DWORD flags, void *proc, void *user);
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
  if bass.BASS_GetDevice() == 0xFFFFFFFF then bass.BASS_Init(-1, 44100, 0, nil, nil) end
  pushProc = ffi.cast('void *', ffi.cast('intptr_t', -1)) -- STREAMPROC_PUSH
  fxStream = bass.BASS_StreamCreate(LOCAL_RATE, 1, 0, pushProc, nil)
  if fxStream ~= 0 then bass.BASS_ChannelPlay(fxStream, 0) end
  return true
end

local function soundsFor(rate)
  if not sounds[rate] then
    local s = {}
    s.click = { A.genClick(rate) }
    s.sqOpen = { A.genSquelch(rate, 70, 0.6) }
    s.sqClose = { A.genSquelch(rate, 160, 0.8) }
    s.ring = { A.genTones(rate, A.RINGTONE, 7000) }
    s.ringback = { A.genTones(rate, A.RINGBACK, 5000) }
    sounds[rate] = s
  end
  return sounds[rate]
end

-- Служебный звук только для себя.
local function playLocal(name, volume)
  if not fxStream or fxStream == 0 then return end
  local s = soundsFor(LOCAL_RATE)[name]
  bass.BASS_ChannelSetAttribute(fxStream, 2, (volume or 1) * cfg.main.master_volume / 100)
  bass.BASS_StreamPutData(fxStream, s[1], s[2] * 2)
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
  codecs[P.CODEC_ULAW] = codecs[P.CODEC_ULAW] or A.makeUlaw()
  local lib = A.loadOpus(getWorkingDirectory())
  if lib and not codecs[P.CODEC_OPUS] then codecs[P.CODEC_OPUS] = A.makeOpus(lib, cfg.main.opus_bitrate) end
  if cfg.main.codec == 'opus' and not codecs[P.CODEC_OPUS] then
    msg('opus.dll не найден в moonloader/lib, используется u-law')
  end
  codec = (cfg.main.codec == 'opus' and codecs[P.CODEC_OPUS]) or codecs[P.CODEC_ULAW]
end

---------------------------------------------------------------------------
-- Сеть
---------------------------------------------------------------------------

local function openSocket()
  if udp then udp:close() end
  P.setToken(string.rep('\0', P.TOKEN_LEN)) -- новый ретранслятор — новый токен
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
-- Игровые проверки
---------------------------------------------------------------------------

local function speakerPed(id)
  local ok, ped = sampGetCharHandleBySampPlayerId(id)
  if ok and doesCharExist(ped) then return ped end
  return nil
end

local function carOf(ped)
  if isCharInAnyCar(ped) then return storeCarCharIsInNoSave(ped) end
  return nil
end

local function inServiceVehicle(ped)
  local car = carOf(ped)
  return car ~= nil and SERVICE_VEHICLES[getCarModel(car)] == true
end

local function dist3(x1, y1, z1, x2, y2, z2) return math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2 + (z2 - z1) ^ 2) end

-- Насколько глухо слышно собеседника: (частота среза или nil, множитель громкости).
local function occlusion(ped)
  if not cfg.main.occlusion then return nil, 1 end
  local mx, my, mz = getCharCoordinates(PLAYER_PED)
  local sx, sy, sz = getCharCoordinates(ped)
  if not isLineOfSightClear(mx, my, mz + 0.6, sx, sy, sz + 0.6, true, false, false, true, false) then
    return 700, 0.55 -- стена
  end
  if carOf(PLAYER_PED) ~= carOf(ped) then return 1800, 0.8 end -- один из нас в машине
  return nil, 1
end

local function findPlayerId(nick)
  local lower = nick:lower()
  for id = 0, sampGetMaxPlayerId(false) do
    if sampIsPlayerConnected(id) and sampGetPlayerNickname(id):lower() == lower then return id end
  end
  return nil
end

---------------------------------------------------------------------------
-- Передача
---------------------------------------------------------------------------

local function canTalk()
  if not cfg.main.enabled or not sampIsLocalPlayerSpawned() then return false end
  if isCharDead(PLAYER_PED) or net.status == P.ACK_MUTED then return false end
  return true
end

local function inputBusy()
  return sampIsChatInputActive() or sampIsDialogActive() or isSampfuncsConsoleActive()
    or bindTarget ~= nil or (ui ~= nil and ui.wantsText())
end

-- Каким режимом сейчас говорим (nil = молчим) и открыт ли канал без активации голосом.
local function wantedMode()
  if not canTalk() then return nil end
  local m = cfg.main
  local busy = inputBusy()
  if radioWire() > 0 and not busy and isKeyDown(m.radio_key) then return P.MODE_RADIO, true end
  local keyed = m.activation == 'ptt' and not busy and isKeyDown(m.ptt_key)
  if not keyed and m.activation ~= 'vad' then return nil end
  if call and call.state == 'active' then return P.MODE_PHONE, keyed end
  if m.mode == P.MODE_SHOUT and m.megaphone and inServiceVehicle(PLAYER_PED) then return P.MODE_MEGAPHONE, keyed end
  return m.mode, keyed
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
  local mode, forced = wantedMode()

  -- звук нажатия: шипение для рации, щелчок для клавиши разговора
  if mode ~= tx.mode and cfg.main.ptt_sound then
    if mode == P.MODE_RADIO then playLocal('sqOpen', 0.6)
    elseif tx.mode == P.MODE_RADIO then playLocal('sqClose', 0.6)
    elseif mode and forced then playLocal('click', 0.5) end
  end
  tx.mode = mode

  -- пока открыто меню, микрофон пишется для индикатора, но в эфир не идёт
  local wantRecord = mode ~= nil or tx.monitor
  if wantRecord and not tx.recording then
    drainRecording()
    bass.BASS_ChannelPlay(rec, 0)
    tx.recording = true
  elseif not wantRecord and tx.recording then
    bass.BASS_ChannelPause(rec)
    drainRecording()
    tx.recording, tx.active, tx.level = false, false, 0
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
    local rms = A.applyGainAndRms(pcmIn, codec.frame, gain)
    tx.level = math.max(A.levelFromRms(rms), tx.level * 0.8)
    local open = mode ~= nil
    if open and not forced then
      if rms >= cfg.main.vad_threshold then tx.vadUntil = now + 0.35 end
      open = now < tx.vadUntil
    end
    if open then
      local payload = codec.encode(pcmIn, codec.frame)
      if payload then
        net.seq = (net.seq + 1) % 65536
        sendPacket(P.packVoice(net.seq, mode, codec.id, payload))
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

local function ringFor(nick, rate)
  local r = rings[nick]
  if not r or r.rate ~= rate then
    r = A.newRing(rate, REPORT_SECONDS)
    rings[nick] = r
  end
  r.heard = os.clock()
  return r
end

-- Обработка и отправка кадра в поток собеседника.
local function putFrame(sp, pcm, n)
  if not pcm or n <= 0 then return end
  local rate = sp.codec.rate
  if sp.route == P.ROUTE_RADIO then
    if cfg.main.fx_radio then A.bandFx(pcm, n, rate, 'radio', sp.fx) end
  elseif sp.route == P.ROUTE_PHONE then
    if cfg.main.fx_radio then A.bandFx(pcm, n, rate, 'phone', sp.fx) end
  elseif sp.mode == P.MODE_MEGAPHONE then
    A.bandFx(pcm, n, rate, 'megaphone', sp.fx)
  else
    A.muffle(pcm, n, rate, sp.cutoff, sp.fx)
  end
  bass.BASS_StreamPutData(sp.stream, pcm, n * 2)
end

local warnedOpus = false
local function onVoice(p, now)
  local c = codecs[p.codec]
  if not c then
    if p.codec == P.CODEC_OPUS and not warnedOpus then
      warnedOpus = true
      msg('кто-то говорит через Opus: положите opus.dll в moonloader/lib')
    end
    return
  end
  if not P.MODE_RANGE[p.mode] or not sampIsPlayerConnected(p.speaker) then return end
  local nick = sampGetPlayerNickname(p.speaker)
  local mode = p.mode

  if p.route == P.ROUTE_NEAR then
    -- проверка на месте: говорящий должен реально стоять рядом в игре
    local ped = speakerPed(p.speaker)
    if not ped then return end
    if mode == P.MODE_MEGAPHONE and not inServiceVehicle(ped) then mode = P.MODE_SHOUT end
    local mx, my, mz = getCharCoordinates(PLAYER_PED)
    local sx, sy, sz = getCharCoordinates(ped)
    if dist3(mx, my, mz, sx, sy, sz) > P.MODE_RANGE[mode] * 1.3 + 3 then return end
    known[p.speaker] = { nick = nick, heard = now, mode = mode }
  elseif p.route == P.ROUTE_RADIO then
    if radioWire() == 0 then return end
  elseif p.route == P.ROUTE_PHONE then
    if not (call and call.state == 'active' and call.peerId == p.speaker) then return end
  else
    return
  end
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
    sp = { stream = h, codec = c, dec = dec, nick = nick, last = 0, fx = A.newFxState(), occVol = 1, occAt = 0 }
    speakers[p.speaker] = sp
  end
  sp.route, sp.mode = p.route, mode

  local ring = ringFor(nick, c.rate)
  if sp.lastSeq then
    local diff = (p.seq - sp.lastSeq) % 65536
    if diff == 0 or diff > 32768 then return end -- дубликат или опоздавший пакет
    for _ = 1, math.min(diff - 1, 2) do          -- маскировка потерь
      putFrame(sp, sp.dec:conceal())
    end
  end
  sp.lastSeq = p.seq

  local queued = bass.BASS_StreamPutData(sp.stream, nil, 0)
  if queued ~= 0xFFFFFFFF and queued > c.rate * 2 * MAX_QUEUE_SEC then return end
  if now - sp.last > 0.3 then
    -- начало фразы: буфер против рывков (у рации — шипение открытия канала)
    ring:gap(250)
    if sp.route == P.ROUTE_RADIO and cfg.main.fx_radio then
      local s = soundsFor(c.rate).sqOpen
      bass.BASS_StreamPutData(sp.stream, s[1], s[2] * 2)
    else
      local pad = ffi.new('int16_t[?]', c.frame * 3)
      bass.BASS_StreamPutData(sp.stream, pad, c.frame * 3 * 2)
    end
  end
  local pcm, n = sp.dec:decode(p.payload)
  if pcm and n > 0 then
    ring:push(pcm, n)
    putFrame(sp, pcm, n)
  end
  sp.last = now
  sp.closed = false
end

local function updateSpeakers(now)
  local mx, my, mz = getCharCoordinates(PLAYER_PED)
  local cx, cy = getActiveCameraCoordinates()
  local px, py = getActiveCameraPointAt()
  local master = cfg.main.master_volume / 100
  for id, sp in pairs(speakers) do
    local personal = (tonumber(cfg.volume[sp.nick]) or 100) / 100
    if sp.route == P.ROUTE_RADIO and not sp.closed and now - sp.last > 0.25 then
      sp.closed = true
      if cfg.main.fx_radio then
        local s = soundsFor(sp.codec.rate).sqClose
        bass.BASS_StreamPutData(sp.stream, s[1], s[2] * 2)
      end
    end
    local ped = speakerPed(id)
    if now - sp.last > SPEAKER_IDLE or (sp.route == P.ROUTE_NEAR and not ped) then
      freeSpeaker(id)
    elseif sp.route == P.ROUTE_NEAR then
      local sx, sy, sz = getCharCoordinates(ped)
      if now - sp.occAt > 0.25 then
        sp.occAt = now
        sp.cutoff, sp.occVol = occlusion(ped)
      end
      local vol = A.distanceVolume(dist3(mx, my, mz, sx, sy, sz), P.MODE_RANGE[sp.mode or 2]) * master * personal * sp.occVol
      bass.BASS_ChannelSetAttribute(sp.stream, 2 --[[VOL]], vol)
      bass.BASS_ChannelSetAttribute(sp.stream, 3 --[[PAN]], A.stereoPan(mx, my, sx, sy, px - cx, py - cy))
    else
      local vol = master * personal * (sp.route == P.ROUTE_RADIO and cfg.main.radio_volume / 100 or 1)
      bass.BASS_ChannelSetAttribute(sp.stream, 2, vol)
      bass.BASS_ChannelSetAttribute(sp.stream, 3, 0)
    end
  end
  -- старые записи для жалоб не держим
  for nick, r in pairs(rings) do
    if now - (r.heard or 0) > KNOWN_TTL then rings[nick] = nil end
  end
end

---------------------------------------------------------------------------
-- Звонки
---------------------------------------------------------------------------

local function callPlayer(id)
  if call then msg('сначала завершите текущий звонок: /tv hangup'); return end
  if not sampIsPlayerConnected(id) then msg('игрок с таким ID не найден'); return end
  sendPacket(P.packCall(P.CALL_INVITE, id))
end

local function acceptCall()
  if call and call.state == 'in' then sendPacket(P.packCall(P.CALL_ACCEPT, call.peerId)) end
end

local function hangup(quiet)
  if call then
    sendPacket(P.packCall(P.CALL_HANGUP, call.peerId))
    call = nil
    if not quiet then msg('звонок завершён') end
  end
end

local function onCall(p, now)
  p.peerNick = P.cleanNick(p.peerNick)
  local who = ('%s [%d]'):format(p.peerNick, p.peerId)
  if p.event == P.EV_INCOMING then
    call = { state = 'in', peerId = p.peerId, peerNick = p.peerNick, since = now }
    nextRing = now
    local auto = autoCall[p.peerNick:lower()]
    if auto and now - auto < 15 then acceptCall()
    else msg('входящий звонок: ' .. who .. '. /tv accept - ответить, /tv decline - сбросить') end
  elseif p.event == P.EV_RINGING then
    call = { state = 'out', peerId = p.peerId, peerNick = p.peerNick, since = now }
    nextRing = now
    msg('звоним ' .. who .. '...')
  elseif p.event == P.EV_STARTED then
    call = { state = 'active', peerId = p.peerId, peerNick = p.peerNick, since = now }
    msg('разговор с ' .. who .. '. Говорите клавишей разговора, /tv hangup - положить трубку')
  elseif p.event == P.EV_ENDED then
    if call then msg('звонок завершён') end
    call = nil
  elseif p.event == P.EV_UNAVAILABLE then
    msg('абонент недоступен: нет TriniVoice рядом с сервером или не ответил')
    if call and call.state == 'out' then call = nil end
  elseif p.event == P.EV_BUSY then
    -- при автозвонке оба набирают друг друга одновременно: «занято» тут ожидаемо
    local auto = autoCall[p.peerNick:lower()]
    if auto and now - auto < 15 then return end
    msg('занято: ' .. (p.peerNick ~= '' and p.peerNick or ('ID ' .. p.peerId)) .. ' уже разговаривает')
  end
end

local function processRinging(now)
  if not call or call.state == 'active' or now < nextRing then return end
  nextRing = now + 2
  playLocal(call.state == 'in' and 'ring' or 'ringback', cfg.main.ring_volume / 100)
end

-- Автозвонки: сервер пишет в чат о звонке, мы сами соединяем голос.
if sampev then
  function sampev.onServerMessage(_, text)
    local m = cfg.main
    if not m.phone_auto or not text then return end
    local start, stop = tostring(m.phone_start), tostring(m.phone_end)
    if start ~= '' then
      local ok, cap = pcall(string.match, text, start)
      if ok and cap then
        local id = tonumber(cap) or findPlayerId(cap)
        if id and sampIsPlayerConnected(id) then
          local nick = sampGetPlayerNickname(id)
          autoCall[nick:lower()] = os.clock()
          if call and call.state == 'in' and call.peerId == id then acceptCall()
          elseif not call then sendPacket(P.packCall(P.CALL_INVITE, id)) end
        end
        return
      end
    end
    if stop ~= '' and call then
      local ok, hit = pcall(string.find, text, stop)
      if ok and hit then hangup() end
    end
  end
end

---------------------------------------------------------------------------
-- Жалобы и администрирование
---------------------------------------------------------------------------

-- reason в UTF-8
local function report(id, reason)
  if not sampIsPlayerConnected(id) then msg('игрок с таким ID не найден'); return end
  local nick = sampGetPlayerNickname(id)
  local r = rings[nick]
  if r and r.filled > 0 then
    local dir = getWorkingDirectory() .. '\\config\\trinivoice\\reports'
    if not doesDirectoryExist(dir) then createDirectory(dir) end
    local path = ('%s\\%s_%s.wav'):format(dir, os.date('%Y%m%d_%H%M%S'), P.cleanNick(nick))
    local f = io.open(path, 'wb')
    if f then
      f:write(r:wav()); f:close()
      msg(('запись голоса %s (%d сек) сохранена: moonloader\\config\\trinivoice\\reports'):format(nick, math.floor(r.filled / r.rate)))
    end
  else
    msg('записи голоса ' .. nick .. ' нет: вы его не слышали последние 5 минут')
  end
  sendPacket(P.packReport(id, reason ~= '' and reason or 'без причины'))
end

local ADMIN_ACTIONS = { mute = P.ADMIN_MUTE, unmute = P.ADMIN_UNMUTE, ban = P.ADMIN_BAN, unban = P.ADMIN_UNBAN, kick = P.ADMIN_KICK }

local function admin(action, nick, minutes)
  local key = tostring(cfg.main.admin_key or '')
  if key == '' then msg('сначала укажите ключ администратора: /tv adminkey КЛЮЧ'); return end
  sendPacket(P.packAdmin(key, ADMIN_ACTIONS[action], nick, minutes or 0))
end

---------------------------------------------------------------------------
-- Сетевой цикл
---------------------------------------------------------------------------

local function onAck(p, now)
  if p.status ~= net.status then
    if ACK_TEXT[p.status] then msg(ACK_TEXT[p.status]) end
    if p.status == P.ACK_MUTED then
      msg(p.mutedSec >= 0xFFFFFFFF and 'администратор выключил вам голос навсегда'
        or ('администратор выключил вам голос на %d мин'):format(math.ceil(p.mutedSec / 60)))
    elseif net.status == P.ACK_MUTED and p.status == P.ACK_OK then
      msg('голос снова включён')
    end
  end
  if (p.status == P.ACK_OK or p.status == P.ACK_MUTED) and now - net.lastAck > 5 then msg('подключено к голосовому серверу') end
  net.status, net.online, net.radioListeners, net.mutedSec = p.status, p.online, p.radioListeners, p.mutedSec
  net.lastAck = now
  if net.stateAt and now - net.stateAt < 1 then net.ping = math.floor((now - net.stateAt) * 1000 + 0.5) end
  net.stateAt = nil
  if p.latestVersion ~= '' then
    net.latest = p.latestVersion
    if not net.updateNotified and P.compareVersions(p.latestVersion, SCRIPT_VERSION) > 0 then
      net.updateNotified = true
      msg(('доступна новая версия %s (у вас %s)'):format(p.latestVersion, SCRIPT_VERSION))
    end
  end
end

local function processNetwork(now)
  if not udp then return end
  for _ = 1, 300 do
    local data = udp:receive()
    if not data then break end
    local p = P.parseServer(data)
    if p then
      if p.type == P.S_ACK then onAck(p, now)
      elseif p.type == P.S_VOICE then if cfg.main.enabled then onVoice(p, now) end
      elseif p.type == P.S_CALL then onCall(p, now)
      elseif p.type == P.S_NOTICE then msg(P.cleanText(p.text))
      elseif p.type == P.S_TOKEN then
        P.setToken(p.token)
        net.lastState = 0 -- сразу повторить STATE уже с токеном
      end
    end
  end

  if now - net.lastState >= STATE_INTERVAL and cfg.main.enabled and sampIsLocalPlayerSpawned() then
    net.lastState = now
    local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if ok then
      local ip, port = sampGetCurrentServerAddress()
      net.room = roomFor(ip, port)
      local x, y, z = getCharCoordinates(PLAYER_PED)
      sendPacket(P.packState({
        id = id, x = x, y = y, z = z, interior = getActiveInterior(), room = net.room,
        nick = sampGetPlayerNickname(id), version = SCRIPT_VERSION,
        radioFreq = radioWire(), radioPass = tostring(cfg.main.radio_pass or ''),
      }))
      net.stateAt = net.stateAt or now
    end
  end
end

---------------------------------------------------------------------------
-- Отрисовка в игре
---------------------------------------------------------------------------

local function fmtTime(sec) sec = math.floor(sec); return ('%02d:%02d'):format(math.floor(sec / 60), sec % 60) end

local function render(now)
  if cfg.main.show_icons then
    for id, sp in pairs(speakers) do
      if sp.route == P.ROUTE_NEAR and now - sp.last < 0.3 then
        local ped = speakerPed(id)
        if ped and isCharOnScreen(ped) then
          local x, y, z = getCharCoordinates(ped)
          local sx, sy = convert3DCoordsToScreen(x, y, z + 1.15)
          local text = cp(sp.mode == P.MODE_MEGAPHONE and '(( мегафон ))' or '(( голос ))')
          local w = renderGetFontDrawTextLength(font, text)
          renderFontDrawText(font, text, sx - w / 2, sy, MODE_COLOR[sp.mode or 2])
        end
      end
    end
  end
  if not (cfg.main.show_hud and cfg.main.enabled) then return end
  local _, h = getScreenResolution()
  local lines = {}
  local connected = isConnected(now)
  local state, color
  if not connected then state, color = 'нет связи с сервером', 0xFF909090
  elseif net.status == P.ACK_MUTED then state, color = 'голос выключен администратором', 0xFFFF7070
  elseif tx.active then state, color = 'В ЭФИРЕ' .. (tx.mode and tx.mode > 3 and (' (' .. MODE_NAME[tx.mode] .. ')') or ''), 0xFFFF5050
  elseif cfg.main.activation == 'vad' then state, color = 'голосовая активация', 0xFFE0E0E0
  else state, color = ('%s - говорить'):format(keyName(cfg.main.ptt_key)), 0xFFE0E0E0 end
  lines[#lines + 1] = { ('TriniVoice | %s | %s'):format(MODE_NAME[cfg.main.mode], state), color }
  if radioWire() > 0 then
    lines[#lines + 1] = { ('Рация %s | %s - говорить | на частоте: %d'):format(
      P.freqLabel(radioWire()), keyName(cfg.main.radio_key), net.radioListeners), 0xFF9DB2FF }
  end
  if call then
    local t = call.state == 'active' and ('разговор ' .. fmtTime(now - call.since))
      or (call.state == 'in' and 'входящий звонок (/tv accept)' or 'вызов...')
    lines[#lines + 1] = { ('Телефон: %s | %s'):format(call.peerNick, t), 0xFF7BE495 }
  end
  for i, l in ipairs(lines) do
    renderFontDrawText(font, cp(l[1]), 20, h * 0.72 + (i - 1) * 16, l[2])
  end
end

---------------------------------------------------------------------------
-- Настройки (общие для команд и меню)
---------------------------------------------------------------------------

local function setEnabled(on)
  cfg.main.enabled = on
  if not on then
    sendPacket(P.packBye())
    for id in pairs(speakers) do freeSpeaker(id) end
    hangup()
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

local function setRadio(on, freq)
  if freq then
    if P.freqToWire(freq) == 0 then msg('частота должна быть от 1.0 до 6553.5'); return false end
    cfg.main.radio_freq = math.floor(tonumber(freq) * 10 + 0.5) / 10
  end
  if on ~= nil then cfg.main.radio_on = on end
  for id, sp in pairs(speakers) do if sp.route == P.ROUTE_RADIO then freeSpeaker(id) end end
  markDirty()
  return true
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
            dist = dist3(mx, my, mz, sx, sy, sz),
            talking = sp ~= nil and sp.route == P.ROUTE_NEAR and now - sp.last < 0.3,
            muted = cfg.muted[k.nick] == true,
            volume = tonumber(cfg.volume[k.nick]) or 100,
            recorded = rings[k.nick] ~= nil,
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

local function radioPresets()
  local list = {}
  for name, f in pairs(cfg.radio_presets) do
    if P.freqToWire(f) > 0 then list[#list + 1] = { name = A.u8(tostring(name)), freq = tonumber(f) } end
  end
  table.sort(list, function(a, b) return a.freq < b.freq end)
  return list
end

-- Всё, что видит и меняет меню (lib/trinivoice/ui.lua).
local uiContext = {
  cfg = cfg,
  version = SCRIPT_VERSION,
  status = function()
    local now = os.clock()
    return {
      connected = isConnected(now), ping = net.ping, online = net.online, room = net.room,
      micOk = rec ~= nil, micLevel = tx.level, vadLevel = A.levelFromRms(cfg.main.vad_threshold),
      codec = codec and codec.name or 'u-law', opusAvailable = codecs[P.CODEC_OPUS] ~= nil,
      muted = net.status == P.ACK_MUTED, mutedSec = net.mutedSec,
      latest = net.latest, updateAvailable = net.latest ~= '' and P.compareVersions(net.latest, SCRIPT_VERSION) > 0,
      transmitting = tx.active, txMode = tx.mode,
      radioWire = radioWire(), radioListeners = net.radioListeners,
      inServiceVehicle = sampIsLocalPlayerSpawned() and inServiceVehicle(PLAYER_PED) or false,
    }
  end,
  players = nearbyPlayers,
  call = function()
    if not call then return nil end
    return { state = call.state, peerId = call.peerId, peerNick = call.peerNick, duration = os.clock() - call.since }
  end,
  set = function(key, value) cfg.main[key] = value; markDirty() end,
  setEnabled = setEnabled,
  setMode = function(m) cfg.main.mode = m; markDirty() end,
  setActivation = function(a) cfg.main.activation = a; markDirty() end,
  setCodec = setCodec,
  setServer = setServer,
  setRadio = setRadio,
  radioPresets = radioPresets,
  toggleMute = function(nick) cfg.muted[nick] = (not cfg.muted[nick]) or nil; markDirty() end,
  setVolume = function(nick, v) cfg.volume[nick] = v; markDirty() end,
  callPlayer = callPlayer,
  acceptCall = acceptCall,
  hangup = hangup,
  report = report,
  binding = function() return bindTarget end,
  startBinding = function(which) bindTarget = which end,
  keyName = keyName,
}

---------------------------------------------------------------------------
-- Команды
---------------------------------------------------------------------------

local HELP = {
  '/tv - меню (без mimgui: состояние и справка), /tv help - справка',
  '/tv on | off - включить или выключить голосовой чат',
  '/tv mode 1-3 - шёпот, обычный, крик; /tv ptt | vad - клавиша или голос',
  '/tv radio on | off | ЧАСТОТА - рация (например /tv radio 911.0), /tv radiopass ПАРОЛЬ',
  '/tv call ID - позвонить, /tv accept - ответить, /tv decline | hangup - сбросить',
  '/tv mute ID | unmute ID, /tv vol ID 0-100, /tv master 0-100, /tv gain 50-400',
  '/tv report ID причина - жалоба (сохраняет запись голоса)',
  '/tv codec ulaw | opus, /tv icons, /tv hud, /tv server HOST PORT',
  '/tv autocall on | off, /tv autocall start|end ШАБЛОН - звонки по сообщениям сервера',
  '/tv adminkey КЛЮЧ, /tv admin mute|unmute|ban|unban|kick НИК [минуты]',
}

local function nickById(arg)
  local id = tonumber(arg)
  if not id or not sampIsPlayerConnected(id) then msg('игрок с таким ID не найден'); return nil end
  return sampGetPlayerNickname(id), id
end

local function onCommand(args)
  local a = {}
  for w in args:gmatch('%S+') do a[#a + 1] = w end
  local c = (a[1] or ''):lower()
  local m = cfg.main
  if c == '' and ui then ui.toggle(); return end
  if c == '' or c == 'help' then
    msg(('v%s, %s, сервер %s:%d, %s, игроков с голосом: %d'):format(SCRIPT_VERSION,
      m.enabled and 'включён' or 'выключен', m.host, m.port,
      isConnected(os.clock()) and 'на связи' or 'нет связи', net.online))
    for _, line in ipairs(HELP) do msg(line) end
    return
  elseif c == 'on' or c == 'off' then
    setEnabled(c == 'on'); msg(m.enabled and 'включён' or 'выключен')
  elseif c == 'mode' and tonumber(a[2]) and tonumber(a[2]) >= 1 and tonumber(a[2]) <= 3 then
    m.mode = tonumber(a[2]); msg('режим: ' .. MODE_NAME[m.mode])
  elseif c == 'ptt' or c == 'vad' then
    m.activation = c; msg(c == 'ptt' and 'режим: нажми и говори' or 'режим: активация голосом')
  elseif c == 'threshold' and tonumber(a[2]) then
    m.vad_threshold = clamp(tonumber(a[2]), 50, 20000); msg('порог: ' .. m.vad_threshold)
  elseif c == 'radio' and a[2] then
    if a[2] == 'on' or a[2] == 'off' then setRadio(a[2] == 'on')
    elseif not setRadio(true, a[2]) then return end
    msg(m.radio_on and ('рация включена, частота ' .. P.freqLabel(radioWire()) .. ', клавиша ' .. keyName(m.radio_key)) or 'рация выключена')
  elseif c == 'radiopass' then
    m.radio_pass = a[2] and A.u8(a[2]) or ''; msg(a[2] and 'пароль частоты задан' or 'пароль частоты сброшен')
  elseif c == 'call' and tonumber(a[2]) then
    callPlayer(tonumber(a[2])); return
  elseif c == 'accept' then
    acceptCall(); return
  elseif c == 'decline' or c == 'hangup' then
    hangup(); return
  elseif c == 'report' and tonumber(a[2]) then
    report(tonumber(a[2]), A.u8(table.concat(a, ' ', 3))); return
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
    setCodec(a[2]); msg('кодек: ' .. codec.name)
  elseif c == 'icons' then
    m.show_icons = not m.show_icons
  elseif c == 'hud' then
    m.show_hud = not m.show_hud
  elseif c == 'server' and a[2] and tonumber(a[3]) then
    setServer(a[2], tonumber(a[3])); msg('ретранслятор: ' .. m.host .. ':' .. m.port)
  elseif c == 'autocall' and (a[2] == 'on' or a[2] == 'off') then
    if a[2] == 'on' and not sampev then msg('для автозвонков нужен SAMP.Lua (lib/samp/events)'); return end
    m.phone_auto = a[2] == 'on'
    msg(m.phone_auto and 'автозвонки включены' or 'автозвонки выключены')
  elseif c == 'autocall' and (a[2] == 'start' or a[2] == 'end') and a[3] then
    -- шаблон хранится как есть (CP1251), чтобы сравнивать с сообщениями сервера
    local pattern = args:match('^%s*%S+%s+%S+%s+(.-)%s*$')
    if not pcall(string.find, '', pattern) then msg('ошибка в шаблоне'); return end
    m['phone_' .. a[2]] = pattern
    msg((a[2] == 'start' and 'шаблон начала звонка: ' or 'шаблон конца звонка: ') .. A.u8(pattern))
  elseif c == 'adminkey' then
    m.admin_key = a[2] or ''; msg(a[2] and 'ключ администратора сохранён' or 'ключ администратора удалён')
  elseif c == 'admin' and ADMIN_ACTIONS[a[2] or ''] and a[3] then
    admin(a[2], a[3], tonumber(a[4])); return
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
  msg(('v%s загружен. %s - говорить, %s - дальность, /tv - %s'):format(SCRIPT_VERSION,
    keyName(cfg.main.ptt_key), keyName(cfg.main.mode_key), ui and 'меню' or 'настройки'))

  while true do
    wait(0)
    local now = os.clock()
    processKeys()
    tx.monitor = ui ~= nil and ui.isOpen()
    if not tx.monitor then bindTarget = nil end
    processNetwork(now)
    processCapture(now)
    processRinging(now)
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
    hangup(true)
    sendPacket(P.packBye())
    if bass then
      for id in pairs(speakers) do freeSpeaker(id) end
      stopRecording()
      if fxStream and fxStream ~= 0 then bass.BASS_StreamFree(fxStream) end
    end
    if udp then udp:close() end
  end)
end
