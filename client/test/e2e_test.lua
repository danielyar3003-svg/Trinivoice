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

local function newClient(id, nick, x, y)
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
    BASS_ChannelPlay = function(h) if h == 100 then recOn = true end return 1 end,
    BASS_ChannelPause = function(h) if h == 100 then recOn = false end return 1 end,
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
  local inicfgStub = { load = function(def) return deepcopy(def) end, save = function() return true end }
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
  env.thisScript = function() return env end

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

local a = newClient(1, 'Ivan_Petrov', 0, 0)
local b = newClient(2, 'Anna_Smirnova', 5, 0)
local c = newClient(3, 'Sergey_Orlov', 2000, 0)
clients = { a, b, c }
run(1)
for _, cl in ipairs(clients) do cl.cmd('server 127.0.0.1 ' .. PORT) end

local X, Z = 0x58, 0x5A
local function hold(cl, key, steps) cl.st.keys[key] = true; run(steps); cl.st.keys[key] = nil; run(15) end

test('all clients connect to the relay', function()
  run(30)
  for _, cl in ipairs(clients) do assert(cl.saw('подключено к голосовому серверу'), cl.nick .. ' not connected') end
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

test('update notice when relay advertises a newer version', function()
  assert(b.saw('доступна новая версия 9.9.9') and c.saw('доступна новая версия 9.9.9'), 'relay config advertises 9.9.9')
end)

for _, cl in ipairs(clients) do cl.cmd('off') end
run(5)
print(('%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
