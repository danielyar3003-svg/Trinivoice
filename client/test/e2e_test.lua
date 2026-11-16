-- Сквозной тест: три экземпляра настоящего trinivoice.lua в эмуляции MoonLoader/SAMPFUNCS
-- с поддельным bass.dll говорят друг с другом через настоящий ретранслятор по UDP.
-- Запуск: client/test/e2e.sh (поднимает ретранслятор и запускает этот файл).
local ffi = require 'ffi'
local socket = require 'socket'
local here = arg[0]:match('^(.*)[/\\]') or '.'
local PORT = tonumber(arg[1]) or 7795
package.path = here .. '/../moonloader/lib/?.lua;' .. package.path
local A = require 'trinivoice.audio'
local SCRIPT = here .. '/../moonloader/trinivoice.lua'
local TMP = os.tmpname(); os.remove(TMP)

local world = { players = {}, wall = false }

local function deepcopy(t)
  if type(t) ~= 'table' then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = deepcopy(v) end
  return r
end

local function newClient(id, nick, x, y, iniData)
  local ped = 1000 + id
  world.players[id] = { nick = nick, x = x, y = y, z = 10, ped = ped, car = nil }
  local me = world.players[id]
  local st = { chat = {}, cmds = {}, keys = {}, pressed = {}, put = {}, attr = {}, fx = nil, t = 0 }

  -- поддельный bass.dll
  local recOn, recAvail, recRate, phase = false, 0, 8000, 0
  local nextH = 200
  local bass = {
    BASS_GetDevice = function() return 0 end,
    BASS_Init = function() return 1 end,
    BASS_ErrorGetCode = function() return 0 end,
    BASS_RecordInit = function() return 1 end,
    BASS_RecordStart = function(freq) recRate = freq; recOn = false; recAvail = 0; return 100 end,
    BASS_ChannelGetData = function(h, buf, len)
      if h ~= 100 then return 0 end
      if buf == nil and len == 0 then return recAvail end
      local n = math.min(len, recAvail)
      local p = ffi.cast('int16_t*', buf)
      for i = 0, n / 2 - 1 do p[i] = math.floor(math.sin(phase) * 9000); phase = phase + 0.2 end
      recAvail = recAvail - n
      return n
    end,
    BASS_ChannelPlay = function(h) if h == 100 then recOn = true; st.recStarts = (st.recStarts or 0) + 1 end return 1 end,
    BASS_ChannelPause = function(h) if h == 100 then recOn = false; st.recStops = (st.recStops or 0) + 1 end return 1 end,
    BASS_ChannelStop = function(h) if h == 100 then recOn = false end return 1 end,
    BASS_StreamCreate = function() nextH = nextH + 1; st.put[nextH] = 0; st.fx = st.fx or nextH; return nextH end,
    BASS_StreamPutData = function(h, buf, len) if buf ~= nil then st.put[h] = (st.put[h] or 0) + len end return 0 end,
    BASS_StreamFree = function(h) return 1 end,
    BASS_ChannelSetAttribute = function(h, a, v) st.attr[h .. ':' .. a] = v; return 1 end,
  }
  local ffiProxy = setmetatable({
    cdef = function(s) pcall(ffi.cdef, s) end,
    load = function(name) if name == 'bass' then return bass end error('no ' .. name) end,
  }, { __index = ffi })
  -- iniData: содержимое trinivoice.ini, как его прочитал бы inicfg (без подмешивания значений по умолчанию)
  local inicfgStub = { load = function(def) return iniData and deepcopy(iniData) or deepcopy(def) end, save = function() return true end }
  local vkeysStub = { id_to_name = function(k) return ({ [0x58] = 'X', [0x42] = 'B', [0x5A] = 'Z' })[k] or tostring(k) end }
  local sampevStub = {}

  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.os = setmetatable({ clock = function() return st.t end }, { __index = os })
  env.require = function(name)
    if name == 'ffi' then return ffiProxy
    elseif name == 'inicfg' then return inicfgStub
    elseif name == 'vkeys' then return vkeysStub
    elseif name == 'lib.samp.events' then return sampevStub
    elseif name == 'trinivoice.ui' then error('mimgui not installed')
    elseif name == 'socket' then
      -- обёртка UDP: тест может «убить» текущие сокеты, как роутер, забывший UDP-сессию
      st.sockets = st.sockets or {}
      return setmetatable({ udp = function()
        local real, dead = socket.udp(), false
        st.sockets[#st.sockets + 1] = function() dead = true end
        return {
          settimeout = function(_, ...) return real:settimeout(...) end,
          setpeername = function(_, ...) return real:setpeername(...) end,
          send = function(_, d) if dead then return #d end return real:send(d) end,
          receive = function() if dead then real:receive(); return nil end return real:receive() end,
          close = function() return real:close() end,
        }
      end }, { __index = socket })
    elseif name == 'trinivoice.protocol' then
      -- в MoonLoader у каждого скрипта свой Lua-state: свой модуль и свой токен
      st.protocol = st.protocol or dofile(here .. '/../moonloader/lib/trinivoice/protocol.lua')
      return st.protocol
    end
    return require(name)
  end
  for _, f in ipairs({ 'script_name', 'script_author', 'script_version', 'script_description', 'renderFontDrawText',
    'consumeWindowMessage', 'createDirectory' }) do env[f] = function() end end
  env.wait = function() coroutine.yield() end
  env.PLAYER_PED = ped
  env.isSampLoaded = function() return true end
  env.isSampfuncsLoaded = function() return true end
  env.isSampAvailable = function() return true end
  env.sampIsLocalPlayerSpawned = function() return true end
  env.isCharDead = function() return false end
  env.sampAddChatMessage = function(text) st.chat[#st.chat + 1] = text end
  env.sampRegisterChatCommand = function(name, fn) st.cmds[name] = fn end
  env.sampGetPlayerIdByCharHandle = function(p) if p == ped then return true, id end return false, -1 end
  env.sampGetCurrentServerAddress = function() return '1.2.3.4', 7777 end
  local function byPed(p) for _, pl in pairs(world.players) do if pl.ped == p then return pl end end end
  env.getCharCoordinates = function(p) local pl = byPed(p); return pl.x, pl.y, pl.z end
  env.getActiveInterior = function() return 0 end
  env.sampIsPlayerConnected = function(i) return world.players[i] ~= nil end
  env.sampGetPlayerNickname = function(i) return world.players[i].nick end
  env.sampGetMaxPlayerId = function() return 1000 end
  env.sampGetCharHandleBySampPlayerId = function(i)
    local pl = world.players[i]
    if pl and i ~= id and math.abs(pl.x - me.x) + math.abs(pl.y - me.y) < 300 then return true, pl.ped end
    return false, -1
  end
  env.doesCharExist = function() return true end
  env.isCharInAnyCar = function(p) return byPed(p).car ~= nil end
  env.storeCarCharIsInNoSave = function(p) return byPed(p).car.handle end
  env.getCarModel = function(car) for _, pl in pairs(world.players) do if pl.car and pl.car.handle == car then return pl.car.model end end end
  env.isLineOfSightClear = function() return not world.wall end
  env.getActiveCameraCoordinates = function() return me.x, me.y, me.z end
  env.getActiveCameraPointAt = function() return me.x, me.y + 1, me.z end
  env.isCharOnScreen = function() return true end
  env.convert3DCoordsToScreen = function() return 100, 100 end
  env.renderCreateFont = function() return 1 end
  env.renderGetFontDrawTextLength = function() return 50 end
  env.getScreenResolution = function() return 1920, 1080 end
  env.isKeyDown = function(k) return st.keys[k] == true end
  env.wasKeyPressed = function(k) return st.pressed[k] == true end
  env.sampIsChatInputActive = function() return false end
  env.sampIsDialogActive = function() return false end
  env.isSampfuncsConsoleActive = function() return false end
  env.getWorkingDirectory = function() return TMP end
  env.doesDirectoryExist = function() return true end
  env.doesFileExist = function(path) local f = io.open(path, 'rb'); if f then f:close(); return true end return false end
  env.thisScript = function() return env end
  env.setClipboardText = function(t) st.clipboard = t end

  local chunk = assert(loadfile(SCRIPT))
  setfenv(chunk, env)
  chunk()
  -- адрес ретранслятора задаём командой, как игрок
  local co = coroutine.create(env.main)

  local c = { id = id, nick = nick, st = st, me = me, sampev = sampevStub }
  function c.step()
    st.t = st.t + 0.02
    if recOn then recAvail = recAvail + recRate * 0.02 * 2 end
    local ok, err = coroutine.resume(co)
    if not ok then error(nick .. ': ' .. tostring(err) .. '\n' .. debug.traceback(co)) end
    st.pressed = {}
  end
  function c.cmd(text) st.cmds.tv(A.cp(text)) end
  function c.received()
    local n = 0
    for h, b in pairs(st.put) do if h ~= st.fx then n = n + b end end
    return n
  end
  function c.saw(needle)
    local cpNeedle = A.cp(needle)
    for _, m in ipairs(st.chat) do if m:find(cpNeedle, 1, true) then return true end end
    return false
  end
  function c.chatDump() for _, m in ipairs(st.chat) do print('   ', A.u8(m)) end end
  return c
end

local clients = {}
local function run(steps)
  for _ = 1, steps do
    for _, c in ipairs(clients) do c.step() end
    socket.sleep(0.002)
  end
end

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print('ok   ' .. name)
  else
    failed = failed + 1; print('FAIL ' .. name .. ': ' .. tostring(err))
    for _, c in ipairs(clients) do print('  chat of ' .. c.nick); c.chatDump() end
  end
end

-- Свои звуки, как их положил бы админ в moonloader/resource/trinivoice/sounds/
-- (getWorkingDirectory() в эмуляции = TMP, разделители путей как в Windows).
local function soundPath(name) return TMP .. '\\resource\\trinivoice\\sounds\\' .. name end
do
  local function le(n, k) local t = {} for _ = 1, k do t[#t + 1] = string.char(n % 256); n = math.floor(n / 256) end return table.concat(t) end
  local rate, frames = 16000, 8000 -- 0.5 сек
  local body = {}
  for i = 0, frames - 1 do local v = math.floor(math.sin(i / 3) * 8000); body[#body + 1] = le(v < 0 and v + 65536 or v, 2) end
  local data = table.concat(body)
  local wav = 'RIFF' .. le(36 + #data, 4) .. 'WAVE' .. 'fmt ' .. le(16, 4) .. le(1, 2) .. le(1, 2) .. le(rate, 4) ..
    le(rate * 2, 4) .. le(2, 2) .. le(16, 2) .. 'data' .. le(#data, 4) .. data
  local f = assert(io.open(soundPath('ring.wav'), 'wb')); f:write(wav); f:close()
  f = assert(io.open(soundPath('radio_on.wav'), 'wb')); f:write('ID3 это mp3, а не wav'); f:close()
end

local a = newClient(1, 'Ivan_Petrov', 0, 0)
local b = newClient(2, 'Anna_Smirnova', 5, 0)
-- C получил архив от админа: в ini вписан только адрес ретранслятора
local c = newClient(3, 'Sergey_Orlov', 2000, 0, { main = { host = '127.0.0.1', port = PORT } })
clients = { a, b, c }
run(1)
a.cmd('server 127.0.0.1 ' .. PORT)
b.cmd('server 127.0.0.1 ' .. PORT)
-- TV_E2E_CODEC=opus — тот же прогон с кодеком Opus (нужен libopus в LD_LIBRARY_PATH)
if os.getenv('TV_E2E_CODEC') == 'opus' then
  for _, cl in ipairs(clients) do cl.cmd('codec opus') end
  assert(a.saw('кодек: Opus'), 'opus library not found for the e2e run')
end

local X, Z = 0x58, 0x5A
local function eq2(x, y) if x ~= y then error(('expected %s, got %s'):format(tostring(y), tostring(x)), 2) end end
-- ждать сообщения в чате до 2 сек реального времени (ответ ретранслятора приходит по UDP)
local function waitFor(cl, text)
  for _ = 1, 200 do
    if cl.saw(text) then return true end
    run(1); socket.sleep(0.008)
  end
  return cl.saw(text)
end
local function hold(cl, key, steps) cl.st.keys[key] = true; run(steps); cl.st.keys[key] = nil; run(15) end

test('all clients connect to the relay', function()
  run(30)
  for _, cl in ipairs(clients) do assert(cl.saw('подключено к голосовому серверу'), cl.nick .. ' not connected') end
  updateSeen = b.saw('доступна новая версия 9.9.9') and c.saw('доступна новая версия 9.9.9')
  updateTg = b.saw('Скачать в Telegram: https://t.me/trinicode')
end)

test('B and other keys do nothing: only the talk and radio keys are bound', function()
  a.st.chat = {}
  for _, k in ipairs({ 0x42, 0x4D, 0x4E }) do a.st.pressed[k] = true; a.step() end -- B, M, N
  run(3)
  assert(not a.saw('режим:'), 'B must not switch the voice range any more')
  assert(not a.saw('загружен'), 'nothing else happened')
end)

test('pressing the talk key does not restart the microphone (no micro-freeze)', function()
  run(5)
  local starts, stops = a.st.recStarts or 0, a.st.recStops or 0
  local b0 = b.received()
  run(50) -- микрофон открыт, но клавиша не нажата
  assert(b.received() == b0, 'open microphone sends nothing until the key is pressed')
  for _ = 1, 5 do hold(a, X, 3) end
  eq2(a.st.recStarts or 0, starts) -- устройство записи не перезапускалось
  eq2(a.st.recStops or 0, stops)
  assert(b.received() > b0, 'but the presses were heard')
  -- старое поведение по желанию: запись только на время нажатия
  a.cmd('micready off')
  run(3)
  local s2 = a.st.recStarts or 0
  for _ = 1, 3 do hold(a, X, 3) end
  assert((a.st.recStarts or 0) - s2 == 3, 'micready off: the device starts on each press')
  a.cmd('micready on')
  run(3)
end)

test('proximity: neighbour hears, far player does not', function()
  local b0, c0 = b.received(), c.received()
  hold(a, X, 25)
  assert(b.received() - b0 > 3000, 'B heard too little: ' .. (b.received() - b0))
  assert(c.received() == c0, 'C is 2 km away and must not hear')
end)

test('walls muffle and lower volume', function()
  world.wall = true
  hold(a, X, 25)
  local vol
  for k, v in pairs(b.st.attr) do if k:match(':2$') and tonumber(k:match('^(%d+)')) ~= b.st.fx then vol = v end end
  world.wall = false
  assert(vol and vol <= 0.56, 'volume behind wall should be <= 0.55, got ' .. tostring(vol))
end)

test('radio: same frequency hears across the map', function()
  a.cmd('radio 100.0'); c.cmd('radio 100.0')
  run(20)
  local c0 = c.received()
  hold(a, Z, 25)
  assert(c.received() - c0 > 3000, 'C on the same frequency should hear A')
  assert(a.saw('рация включена, частота 100.0'))
end)

test('radio: password protected frequency is refused', function()
  b.cmd('radio 911.0')
  run(20)
  assert(b.saw('закрыта паролем'), 'B should be told the frequency is locked')
  b.cmd('radio off')
end)

test('megaphone in a police car reaches 58 m', function()
  a.cmd('radio off'); c.cmd('radio off')
  a.cmd('mode 3')
  a.me.car = { handle = 77, model = 596 }
  b.me.x = 58
  run(20)
  local b0 = b.received()
  hold(a, X, 25)
  assert(b.received() - b0 > 3000, 'megaphone should reach 58 m')
  a.me.car = nil
  run(20)
  b0 = b.received()
  hold(a, X, 25)
  assert(b.received() == b0, 'plain shout must not reach 58 m')
  b.me.x = 5
  a.cmd('mode 2')
  run(10)
end)

test('phone call across the map: ring, accept, talk, hang up', function()
  a.cmd('call 3')
  run(10)
  assert(c.saw('входящий звонок: Ivan_Petrov [1]'), 'C must see the incoming call')
  assert(a.saw('звоним Sergey_Orlov [3]'))
  local ringBytes = c.st.put[c.st.fx]
  run(10)
  assert(c.st.put[c.st.fx] > 0 and ringBytes ~= nil, 'ringtone should play locally')
  c.cmd('accept')
  run(10)
  assert(a.saw('разговор с Sergey_Orlov') and c.saw('разговор с Ivan_Petrov'))
  local c0 = c.received()
  hold(a, X, 25)
  assert(c.received() - c0 > 3000, 'C should hear A over the phone')
  c.cmd('hangup')
  run(10)
  assert(a.saw('звонок завершён'), 'A should be told the call ended')
end)

test('automatic call from server chat messages (both sides dial at once)', function()
  a.cmd('autocall on'); c.cmd('autocall on')
  a.cmd('autocall start Входящий звонок от (%S+)')
  c.cmd('autocall start Вы звоните (%S+)')
  a.cmd('autocall end Звонок завершен')
  c.cmd('autocall end Звонок завершен')
  -- сервер сообщает обоим о звонке в одном кадре
  a.sampev.onServerMessage(-1, A.cp('Входящий звонок от Sergey_Orlov'))
  c.sampev.onServerMessage(-1, A.cp('Вы звоните Ivan_Petrov'))
  run(15)
  assert(a.saw('разговор с Sergey_Orlov') or c.saw('разговор с Ivan_Petrov'), 'call should connect automatically')
  assert(not a.saw('занято') and not c.saw('занято'), 'simultaneous dial must not show "busy"')
  local c0 = c.received()
  hold(a, X, 25)
  assert(c.received() - c0 > 3000, 'voice goes over the automatic call')
  a.st.chat = {}
  a.sampev.onServerMessage(-1, A.cp('Звонок завершен'))
  run(10)
  assert(a.saw('звонок завершён'), 'end pattern hangs up')
  a.cmd('autocall off'); c.cmd('autocall off')
end)

test('player list: everyone with TriniVoice on this SA-MP server', function()
  a.st.chat = {}
  a.cmd('players')
  assert(waitFor(a, 'с TriniVoice на сервере: 3'), 'count')
  assert(a.saw('Anna_Smirnova [2]') and a.saw('Ivan_Petrov [1]') and a.saw('Sergey_Orlov [3]'), 'names')
end)

test('frequency list: who is on my frequency', function()
  a.cmd('radio 123.4'); c.cmd('radio 123.4')
  run(15)
  a.cmd('freqlist')
  assert(waitFor(a, 'на частоте 123.4: 2'), 'count on frequency')
  b.st.chat = {}
  b.cmd('freqlist')
  assert(b.saw('рация выключена'), 'no radio — no list')
  a.cmd('radio off'); c.cmd('radio off')
  run(5)
end)

test('do not disturb: nobody can call, list shows it', function()
  c.cmd('dnd on')
  run(15)
  a.cmd('call 3')
  run(10)
  assert(a.saw('Sergey_Orlov [3] не принимает звонки'), 'caller is told')
  a.st.chat = {}
  socket.sleep(1.6) -- ретранслятор отдаёт список не чаще раза в 1.5 сек (реального времени)
  a.cmd('players')
  assert(waitFor(a, 'Sergey_Orlov [3] (без звонков)'), 'list marks the player')
  c.cmd('dnd off')
  run(15)
end)

test('custom sounds: a good WAV replaces the ringtone, a bad file is reported', function()
  local before = c.st.put[c.st.fx]
  a.cmd('call 3')
  run(5)
  local played = c.st.put[c.st.fx] - before
  assert(played == 8000 * 2, 'custom 0.5 s ring at 16 kHz = 16000 bytes, got ' .. played)
  a.cmd('hangup'); run(10)
  assert(c.saw('звук radio_on.wav: это не WAV-файл, играет стандартный'), 'bad file is reported')
end)

test('mic test: you hear yourself, nobody else hears anything', function()
  local before = a.st.put[a.st.fx]
  local b0 = b.received()
  a.st.chat = {}
  a.cmd('mictest')
  assert(a.saw('проверка микрофона: говорите 4 секунды'), 'started')
  a.st.keys[X] = true -- даже если держать клавишу разговора, в эфир ничего не уходит
  run(4 / 0.02 + 10)
  a.st.keys[X] = nil
  local played = a.st.put[a.st.fx] - before
  -- 4 сек записи u-law 8 кГц, пересчитанные в 16 кГц для воспроизведения
  assert(played > 4 * 16000 * 2 * 0.9 and played < 5 * 16000 * 2, 'played back ' .. played .. ' bytes')
  assert(b.received() == b0, 'neighbour must not hear the test')
  run(250) -- воспроизведение закончилось — снова можно говорить
  b0 = b.received()
  hold(a, X, 25)
  assert(b.received() - b0 > 3000, 'talking works again after the test')
end)

test('report saves the last seconds of voice and reaches the relay', function()
  b.cmd('report 1 тестовая жалоба')
  run(10)
  assert(b.saw('запись голоса Ivan_Petrov'), 'report should save a recording')
  assert(b.saw('Жалоба отправлена'), 'relay should confirm the report')
  local found
  local p = io.popen('ls ' .. TMP:gsub('[^/]+$', '') .. ' 2>/dev/null')
  for f in p:lines() do if f:find('Ivan_Petrov.wav', 1, true) then found = f end end
  p:close()
  assert(found, 'wav file not found')
  local fh = io.open(TMP:gsub('[^/]+$', '') .. found, 'rb')
  local data = fh:read('*a'); fh:close()
  os.remove(TMP:gsub('[^/]+$', '') .. found)
  assert(data:sub(1, 4) == 'RIFF' and #data > 44 + 8000, 'wav too small: ' .. #data)
end)

test('admin mutes a player; muted player is not relayed', function()
  b.cmd('adminkey wrong-key-123')
  b.cmd('admin mute Ivan_Petrov 5')
  run(10)
  assert(b.saw('Неверный ключ администратора'))
  b.cmd('adminkey e2e-admin-key-123')
  b.cmd('admin mute Ivan_Petrov 5')
  run(20)
  assert(b.saw('Ivan_Petrov: голос выключен на 5 мин'), 'admin should get confirmation')
  assert(a.saw('администратор выключил вам голос на 5 мин'), 'A should be told about the mute')
  local b0 = b.received()
  hold(a, X, 25)
  assert(b.received() == b0, 'muted player must not be heard')
  b.cmd('admin unmute Ivan_Petrov')
  run(20)
  assert(a.saw('голос снова включён'))
  b0 = b.received()
  hold(a, X, 25)
  assert(b.received() - b0 > 3000, 'unmuted player is heard again')
end)

test('router forgets the UDP session: script notices, reconnects and keeps working', function()
  a.st.chat = {}
  for _, kill in ipairs(a.st.sockets) do kill() end
  run(400) -- 8 секунд игрового времени без ответов
  assert(a.saw('связь с голосовым сервером потеряна'), 'loss reported')
  assert(waitFor(a, 'подключено к голосовому серверу'), 'reconnected through a new socket')
  assert(not a.saw('ваш ID уже занят'), 'relay moved the session to the new port at once')
  a.cmd('diag')
  assert(a.saw('переподключений 1'), 'diag shows the reconnect')
  assert(a.saw('связь: есть'), 'diag shows the link is up')
  local b0 = b.received()
  hold(a, X, 25)
  assert(b.received() - b0 > 3000, 'neighbour hears the player again')
end)

test('admin stats: how many players use TriniVoice', function()
  b.st.chat = {}
  b.cmd('admin stats')
  assert(waitFor(b, 'Установили всего: 3'), 'total')
  assert(b.saw('Сейчас онлайн: 3 (на вашем сервере SA-MP: 3)'), 'online')
  assert(b.saw('Версии за 30 дней: ') and b.saw(' — 3'), 'versions: all 3 players on the same version')
end)

test('Telegram: /tv tg copies the link (browser opening needs Windows)', function()
  a.st.chat = {}
  a.cmd('tg')
  eq2(a.st.clipboard, 'https://t.me/trinicode')
  assert(a.saw('https://t.me/trinicode'), 'link shown in chat')
  assert(updateTg, 'update notice points to Telegram')
end)

test('update notice when relay advertises a newer version', function()
  assert(updateSeen, 'relay config advertises 9.9.9') -- запомнено в первом тесте: чаты потом очищаются
end)

for _, cl in ipairs(clients) do cl.cmd('off') end
run(5)
print(('%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
