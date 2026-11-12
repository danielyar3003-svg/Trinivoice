-- TriniVoice: протокол v3 (см. docs/PROTOCOL.md). Чистый Lua + ffi, без игры.
local ffi = require 'ffi'
local bit = require 'bit'

local P = {}

P.VERSION = 3
local HDR = 'TV' .. string.char(P.VERSION)
-- Токен сессии (8 байт) идёт в каждом пакете клиента. Его выдаёт ретранслятор
-- (S_TOKEN) в ответ на первый STATE; до этого шлём нули.
P.TOKEN_LEN = 8
P.token = string.rep('\0', P.TOKEN_LEN)
function P.setToken(t) if #t == P.TOKEN_LEN then P.token = t end end

P.C_STATE, P.C_VOICE, P.C_BYE, P.C_CALL, P.C_REPORT, P.C_ADMIN = 0x01, 0x02, 0x03, 0x04, 0x05, 0x06
P.S_ACK, P.S_VOICE, P.S_CALL, P.S_NOTICE, P.S_TOKEN = 0x81, 0x82, 0x83, 0x84, 0x85

P.ACK_OK, P.ACK_ROOM, P.ACK_ID_TAKEN, P.ACK_BANNED, P.ACK_MUTED, P.ACK_OUTDATED, P.ACK_FULL = 0, 1, 2, 3, 4, 5, 6

P.MODE_WHISPER, P.MODE_NORMAL, P.MODE_SHOUT, P.MODE_MEGAPHONE, P.MODE_RADIO, P.MODE_PHONE = 1, 2, 3, 4, 5, 6
P.MODE_RANGE = { 3, 15, 40, 60, 8, 5 }
P.ROUTE_NEAR, P.ROUTE_RADIO, P.ROUTE_PHONE = 0, 1, 2

P.CODEC_ULAW, P.CODEC_OPUS = 1, 2

P.CALL_INVITE, P.CALL_ACCEPT, P.CALL_HANGUP = 1, 2, 3
P.EV_INCOMING, P.EV_STARTED, P.EV_ENDED, P.EV_UNAVAILABLE, P.EV_BUSY, P.EV_RINGING = 1, 2, 3, 4, 5, 6

P.ADMIN_MUTE, P.ADMIN_UNMUTE, P.ADMIN_BAN, P.ADMIN_UNBAN, P.ADMIN_KICK = 1, 2, 3, 4, 5

local function u8(n) return string.char(bit.band(n, 0xFF)) end
local function u16(n)
  n = math.max(0, math.min(math.floor(n), 0xFFFF))
  return string.char(bit.band(n, 0xFF), bit.band(bit.rshift(n, 8), 0xFF))
end
local function u32(n)
  n = math.max(0, math.min(math.floor(n), 0xFFFFFFFF))
  local s = ''
  for _ = 1, 4 do s = s .. string.char(n % 256); n = math.floor(n / 256) end
  return s
end
local f32buf = ffi.new('float[1]')
local function f32(x) f32buf[0] = x; return ffi.string(f32buf, 4) end
local function str(s)
  s = tostring(s or '')
  if #s > 255 then s = s:sub(1, 255) end
  return string.char(#s) .. s
end

local function head(t) return HDR .. u8(t) .. P.token end

function P.packState(t)
  return head(P.C_STATE) .. u16(t.id) .. f32(t.x) .. f32(t.y) .. f32(t.z) .. u8(t.interior or 0) ..
    str(t.room) .. str(t.nick) .. str(t.version) .. u16(t.radioFreq or 0) .. str(t.radioPass)
end
function P.packVoice(seq, mode, codec, payload) return head(P.C_VOICE) .. u16(seq) .. u8(mode) .. u8(codec) .. payload end
function P.packBye() return head(P.C_BYE) end
function P.packCall(action, target) return head(P.C_CALL) .. u8(action) .. u16(target or 0) end
function P.packReport(target, reason) return head(P.C_REPORT) .. u16(target) .. str(reason) end
function P.packAdmin(key, action, nick, minutes)
  return head(P.C_ADMIN) .. str(key) .. u8(action) .. str(nick) .. u32(minutes or 0)
end

-- чтение
local Reader = {}
Reader.__index = Reader
local function reader(s, pos) return setmetatable({ s = s, pos = pos, ok = true }, Reader) end
function Reader:need(n) if self.pos + n - 1 > #self.s then self.ok = false end return self.ok end
function Reader:u8() if not self:need(1) then return 0 end local v = self.s:byte(self.pos); self.pos = self.pos + 1; return v end
function Reader:u16() if not self:need(2) then return 0 end local a, b = self.s:byte(self.pos, self.pos + 1); self.pos = self.pos + 2; return a + b * 256 end
function Reader:u32()
  if not self:need(4) then return 0 end
  local a, b, c, d = self.s:byte(self.pos, self.pos + 3); self.pos = self.pos + 4
  return a + b * 256 + c * 65536 + d * 16777216
end
function Reader:str()
  local n = self:u8()
  if not self:need(n) then return '' end
  local v = self.s:sub(self.pos, self.pos + n - 1); self.pos = self.pos + n
  return v
end

function P.parseServer(s)
  if #s < 4 or s:sub(1, 3) ~= HDR then return nil end
  local t = s:byte(4)
  local r = reader(s, 5)
  local p
  if t == P.S_ACK then
    p = { type = t, status = r:u8(), online = r:u16(), radioListeners = r:u16(), mutedSec = r:u32(), latestVersion = r:str() }
  elseif t == P.S_VOICE then
    p = { type = t, speaker = r:u16(), seq = r:u16(), mode = r:u8(), codec = r:u8(), route = r:u8() }
    if r.ok and r.pos <= #s then p.payload = s:sub(r.pos) else return nil end
  elseif t == P.S_CALL then
    p = { type = t, event = r:u8(), peerId = r:u16(), peerNick = r:str() }
  elseif t == P.S_NOTICE then
    p = { type = t, code = r:u8(), text = r:str() }
  elseif t == P.S_TOKEN then
    if not r:need(P.TOKEN_LEN) then return nil end
    p = { type = t, token = s:sub(r.pos, r.pos + P.TOKEN_LEN - 1) }
  else
    return nil
  end
  return r.ok and p or nil
end

-- Частота в эфире: МГц * 10 (911.5 -> 9115). Допустимо 1.0 .. 6553.5.
function P.freqToWire(f)
  f = tonumber(f)
  if not f or f < 1 or f > 6553.5 then return 0 end
  return math.floor(f * 10 + 0.5)
end
function P.freqLabel(w) return ('%.1f'):format((w or 0) / 10) end

-- Текст от ретранслятора в чат: без цветовых кодов SA-MP {RRGGBB}, управляющих
-- символов и не длиннее limit байт — ретранслятор не может подделать сообщения в чате.
function P.cleanText(s, limit)
  s = tostring(s or ''):gsub('{%x%x%x%x%x%x}', ''):gsub('[{}]', ''):gsub('[%z\1-\31\127]', '')
  limit = limit or 160
  if #s > limit then
    s = s:sub(1, limit)
    -- не резать UTF-8 символ посередине
    while #s > 0 and s:byte(#s) >= 0x80 and s:byte(#s) < 0xC0 do s = s:sub(1, -2) end
    if #s > 0 and s:byte(#s) >= 0xC0 then s = s:sub(1, -2) end
  end
  return s
end

-- Ник SA-MP: только разрешённые сервером символы (и безопасно для имени файла).
function P.cleanNick(s)
  return (tostring(s or ''):gsub('[^%w%[%]%(%)%$@%._=]', '')):sub(1, 24)
end

function P.compareVersions(a, b)
  local pa, pb = {}, {}
  for n in tostring(a):gmatch('%d+') do pa[#pa + 1] = tonumber(n) end
  for n in tostring(b):gmatch('%d+') do pb[#pb + 1] = tonumber(n) end
  for i = 1, math.max(#pa, #pb) do
    local d = (pa[i] or 0) - (pb[i] or 0)
    if d ~= 0 then return d < 0 and -1 or 1 end
  end
  return 0
end

return P
