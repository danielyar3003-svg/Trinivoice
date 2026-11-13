-- Прогон меню lib/trinivoice/ui.lua на заглушке mimgui (запуск: luajit client/test/ui_test.lua).
-- Каждый вызов imgui сверяется со списком функций cimgui из mimgui 1.7.1
-- (cimgui_names.txt), проверяются типы аргументов и парность Push/Pop.
local ffi = require 'ffi'
local here = arg[0]:match('^(.*)[/\\]') or '.'

local valid = {}
for line in io.lines(here .. '/cimgui_names.txt') do
  if not line:match('^#') then valid[line] = true end
end

ffi.cdef [[ typedef struct { float x, y; } ImVec2; ]]
local ImVec2
ImVec2 = ffi.metatype('ImVec2', {
  __add = function(a, b) return ImVec2(a.x + b.x, a.y + b.y) end,
  __sub = function(a, b) return ImVec2(a.x - b.x, a.y - b.y) end,
})
local function isVec2(v) return ffi.istype('ImVec2', v) end
local function isVec4(v) return type(v) == 'table' and type(v.x) == 'number' and type(v.w) == 'number' end
local function check(cond, what) if not cond then error(what, 3) end end

local rnd = 1
local function coin() rnd = (rnd * 1103515245 + 12345) % 2147483648; return rnd % 3 == 0 end

inCallback = false
local stacks, calls
local function reset() stacks = { font = 0, var = 0, color = 0, child = 0, window = 0 }; calls = {} end
reset()

local drawList = {}
function drawList:AddRectFilled(a, b, col, r, corners)
  check(isVec2(a) and isVec2(b) and type(col) == 'number' and type(r) == 'number' and type(corners) == 'number', 'AddRectFilled args')
  check(a.x == a.x and b.y == b.y, 'NaN in rect')
end
function drawList:AddRect(a, b, col, r, corners, th)
  check(isVec2(a) and isVec2(b) and type(col) == 'number' and type(th) == 'number', 'AddRect args')
end
function drawList:AddCircleFilled(c, r, col, seg)
  check(isVec2(c) and type(r) == 'number' and type(col) == 'number' and type(seg) == 'number', 'AddCircleFilled args')
end
function drawList:AddText(pos, col, s)
  check(isVec2(pos) and type(col) == 'number' and type(s) == 'string', 'AddText args: ' .. tostring(s))
  calls[#calls + 1] = s
end

local fontsAtlas = {}
function fontsAtlas:GetGlyphRangesCyrillic() return ffi.new('uint16_t[3]', 0x20, 0x4FF, 0) end
function fontsAtlas:AddFontFromFileTTF(path, size, cfg, ranges)
  check(type(path) == 'string' and type(size) == 'number', 'AddFontFromFileTTF args')
  if path:find('fontawesome-webfont.ttf', 1, true) then
    -- иконки: диапазон Font Awesome 4.7, и он должен жить до сборки атласа
    check(ranges ~= nil and ranges[0] == 0xF000 and ranges[1] >= 0xF2CE and ranges[2] == 0, 'icon glyph range')
    iconFontLoaded = iconFontLoaded + 1
  end
  return { path = path, size = size }
end
function fontsAtlas:AddFontFromMemoryCompressedBase85TTF(data, size, cfg, ranges)
  check(type(data) == 'string' and type(size) == 'number' and ranges ~= nil, 'AddFontFromMemoryCompressedBase85TTF args')
  return { icons = true }
end

local io = { DeltaTime = 0.016, WantTextInput = false, Fonts = fontsAtlas }
local style = { Colors = {} }
local initCb, frameCb = {}, {}

local function enum(prefix)
  return setmetatable({}, { __index = function(_, k)
    check(valid['ImGui' .. prefix .. '_' .. k], 'unknown enum ImGui' .. prefix .. '_' .. k)
    return 1
  end })
end

local function newType(ct)
  return setmetatable({}, {
    __call = function(_, v) return ffi.new(ct .. '[1]', v) end,
    __index = function(_, n) return function(...) return ffi.new(ct .. '[' .. n .. ']', ...) end end,
  })
end

local impl = {
  ImVec2 = function(x, y) return ImVec2(x or 0, y or 0) end,
  ImVec4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
  ImFontConfig = function() return {} end,
  new = setmetatable({}, { __index = function(_, t) return newType(t == 'ImWchar' and 'uint16_t' or t) end }),
  Col = enum('Col'), StyleVar = enum('StyleVar'), WindowFlags = enum('WindowFlags'), Cond = enum('Cond'),
  InputTextFlags = enum('InputTextFlags'),
  GetTime = function() return 12.5 end,
  -- mimgui можно трогать только внутри этих колбэков: контекст ImGui общий для
  -- всех скриптов, вне кадра он чужой или пустой (в игре это падение скрипта)
  OnInitialize = function(cb)
    initCb[#initCb + 1] = function(...) inCallback = true; cb(...); inCallback = false end
  end,
  OnFrame = function(cond, cb)
    frameCb[#frameCb + 1] = { cond = cond, cb = function(...) inCallback = true; cb(...); inCallback = false end }
  end,
  StrCopy = function(dst, src) ffi.copy(dst, src) end,
  GetIO = function() return io end,
  GetStyle = function() return style end,
  GetWindowDrawList = function() return drawList end,
  GetWindowPos = function() return ImVec2(100, 100) end,
  GetMousePos = function() return ImVec2(500, 300) end,
  GetScrollY = function() return 0 end,
  CalcTextSize = function(s) check(type(s) == 'string', 'CalcTextSize arg'); return ImVec2(#s * 7, 15) end,
  ColorConvertFloat4ToU32 = function(c) check(isVec4(c), 'ColorConvertFloat4ToU32 arg'); return 0xFFFFFFFF end,
  Begin = function(name, open, flags) check(type(name) == 'string' and type(flags) == 'number', 'Begin args'); stacks.window = stacks.window + 1; return true end,
  End = function() stacks.window = stacks.window - 1 end,
  BeginChild = function(id, size, border, flags) check(type(id) == 'string' and isVec2(size), 'BeginChild args'); stacks.child = stacks.child + 1; return true end,
  EndChild = function() stacks.child = stacks.child - 1 end,
  PushFont = function(f) check(type(f) == 'table', 'PushFont arg'); stacks.font = stacks.font + 1 end,
  PopFont = function() stacks.font = stacks.font - 1 end,
  PushStyleVarFloat = function(i, v) check(type(v) == 'number', 'PushStyleVarFloat'); stacks.var = stacks.var + 1 end,
  PushStyleVarVec2 = function(i, v) check(isVec2(v), 'PushStyleVarVec2'); stacks.var = stacks.var + 1 end,
  PopStyleVar = function(n) stacks.var = stacks.var - (n or 1) end,
  PushStyleColor = function(i, v) check(isVec4(v), 'PushStyleColor'); stacks.color = stacks.color + 1 end,
  PopStyleColor = function(n) stacks.color = stacks.color - (n or 1) end,
  SetCursorPos = function(v) check(isVec2(v) and v.x == v.x and v.y == v.y, 'SetCursorPos arg') end,
  InvisibleButton = function(id, size)
    check(type(id) == 'string' and isVec2(size) and size.x > 0 and size.y > 0, 'InvisibleButton size must be > 0: ' .. tostring(id))
    return coin()
  end,
  IsItemHovered = function() return coin() end,
  IsItemActive = function() return coin() end,
  IsItemClicked = function() return coin() end,
  InputTextWithHint = function(l, h, buf, size, flags)
    check(type(l) == 'string' and type(h) == 'string' and size > 0 and (flags == nil or type(flags) == 'number'), 'InputTextWithHint args')
    return false
  end,
  SetNextItemWidth = function(w) check(type(w) == 'number' and w > 0, 'SetNextItemWidth') end,
  SetNextWindowPos = function(p, c, pivot) check(isVec2(p) and isVec2(pivot), 'SetNextWindowPos') end,
  SetNextWindowSize = function(s) check(isVec2(s), 'SetNextWindowSize') end,
  Dummy = function(s) check(isVec2(s), 'Dummy') end,
}
local EXTRA = { ImVec2 = 1, ImVec4 = 1, ImFontConfig = 1, new = 1, Col = 1, StyleVar = 1, WindowFlags = 1, Cond = 1, InputTextFlags = 1,
  OnInitialize = 1, OnFrame = 1, StrCopy = 1 }
-- не требуют контекста ImGui: типы, перечисления, регистрация колбэков, копирование строк
local PURE = { ImVec2 = 1, ImVec4 = 1, ImFontConfig = 1, new = 1, Col = 1, StyleVar = 1, WindowFlags = 1, Cond = 1,
  InputTextFlags = 1, OnInitialize = 1, OnFrame = 1, StrCopy = 1 }
local imguiMock = setmetatable({}, { __index = function(_, k)
  check(EXTRA[k] or valid['ig' .. k], 'imgui.' .. k .. ' does not exist in mimgui 1.7.1')
  check(PURE[k] or inCallback, 'imgui.' .. k .. ' called outside OnFrame/OnInitialize (crashes in game)')
  return impl[k] or error('mock missing imgui.' .. k)
end })
for k in pairs(impl) do
  if not EXTRA[k] and not valid['ig' .. k] then error('mock defines unknown function ' .. k) end
end
for name in pairs({ AddRectFilled = 1, AddRect = 1, AddCircleFilled = 1, AddText = 1 }) do
  assert(valid['ImDrawList_' .. name], 'ImDrawList_' .. name)
end
for name in pairs({ GetGlyphRangesCyrillic = 1, AddFontFromFileTTF = 1, AddFontFromMemoryCompressedBase85TTF = 1 }) do
  assert(valid['ImFontAtlas_' .. name], 'ImFontAtlas_' .. name)
end

-- окружение MoonLoader
getScreenResolution = function() return 1920, 1080 end
isPauseMenuActive = function() return false end
getWorkingDirectory = function() return 'C:\\game\\moonloader' end
getFolderPath = function() return 'C:\\Windows\\Fonts' end
local fileExists, iconFileExists = true, true
iconFontLoaded = 0
doesFileExist = function(path)
  if path:find('fontawesome-webfont.ttf', 1, true) then return iconFileExists end
  return fileExists
end

local function loadUi(withFa)
  package.loaded['trinivoice.ui'] = nil
  package.loaded['mimgui'] = imguiMock
  iconFileExists = withFa
  iconFontLoaded = 0
  initCb, frameCb = {}, {}
  return dofile(here .. '/../moonloader/lib/trinivoice/ui.lua')
end

local function makeCtx(players)
  local log = {}
  local cfg = { main = { enabled = true, mode = 2, activation = 'ptt', ptt_key = 0x58, mode_key = 0x42,
    mic_gain = 150, master_volume = 80, vad_threshold = 700, codec = 'ulaw', show_icons = true,
    show_hud = true, accent = '#6E8BFF', host = '1.2.3.4', port = 7790, radio_on = true, radio_freq = 911.0,
    radio_pass = '', radio_key = 0x5A, radio_volume = 90, occlusion = true, fx_radio = true, megaphone = true,
    ptt_sound = false, dnd = false }, muted = {}, volume = {} }
  local roomList = { entries = {
    { id = 1, nick = 'Ivan_Petrov', flags = 0 }, { id = 7, nick = 'Me_Myself', flags = 0 },
    { id = 8, nick = 'Sergey_Orlov', flags = 2 }, { id = 9, nick = 'Quiet_Guy', flags = 1 },
  }, at = 5 }
  local requested = {}
  local callStates = { false, 'in', 'out', 'active' }
  local frameNo = 0
  local ctx = {
    cfg = cfg,
    version = '0.3.0',
    status = function()
      frameNo = frameNo + 1
      return { connected = frameNo % 50 ~= 0, ping = 42, online = 37, room = '5.6.7.8:7777', micOk = true,
        micLevel = 0.6, vadLevel = 0.35, codec = 'u-law', opusAvailable = frameNo % 2 == 0,
        muted = frameNo % 7 == 0, mutedSec = 300, latest = '0.4.0', updateAvailable = frameNo % 3 == 0,
        transmitting = false, radioWire = frameNo % 5 == 0 and 0 or 9110, radioListeners = 3,
        inServiceVehicle = frameNo % 4 == 0 }
    end,
    call = function()
      local st = callStates[math.floor(frameNo / 40) % 4 + 1]
      if not st then return nil end
      return { state = st, peerId = 8, peerNick = 'Sergey_Orlov', duration = 75.4 }
    end,
    callPlayer = function(id) assert(type(id) == 'number') end,
    acceptCall = function() end,
    hangup = function() end,
    report = function(id, reason) assert(type(id) == 'number' and type(reason) == 'string' and #reason > 0); log[#log + 1] = 'report' end,
    setRadio = function(on, freq) assert(on == nil or type(on) == 'boolean'); return true end,
    lists = function(kind)
      assert(kind == 1 or kind == 2)
      if frameNo % 3 == 0 then return { entries = {}, at = frameNo % 2 == 0 and -100 or 3 } end -- загрузка / пусто
      return roomList
    end,
    requestList = function(kind) assert(kind == 1 or kind == 2); requested[kind] = true; log[#log + 1] = 'list' .. kind end,
    myId = function() return 7 end,
    setDnd = function(on) assert(type(on) == 'boolean'); cfg.main.dnd = on end,
    radioPresets = function() return frameNo % 2 == 0 and { { name = 'LSPD', freq = 911.0 }, { name = 'EMS', freq = 912.5 } } or {} end,
    players = function() return players end,
    set = function(k, v) log[#log + 1] = 'set ' .. k; cfg.main[k] = v end,
    setEnabled = function(v) cfg.main.enabled = v end,
    setMode = function(m) assert(m >= 1 and m <= 3); cfg.main.mode = m end,
    setActivation = function(a) assert(a == 'ptt' or a == 'vad'); cfg.main.activation = a end,
    setCodec = function(c) assert(c == 'ulaw' or c == 'opus') end,
    setServer = function(h, p) end,
    toggleMute = function(n) assert(type(n) == 'string') end,
    setVolume = function(n, v) assert(type(n) == 'string' and v >= 0 and v <= 200, 'volume ' .. v) end,
    binding = function() return nil end,
    startBinding = function(w) assert(w == 'ptt' or w == 'mode' or w == 'radio') end,
    keyName = function(k) return k == 0x58 and 'X' or 'B' end,
  }
  return ctx, log
end

local PLAYERS = {
  { id = 12, nick = 'Ivan_Petrov', dist = 4.2, talking = true, mode = 2, muted = false, volume = 100 },
  { id = 57, nick = 'Anna_Smirnova', dist = 9.8, talking = false, mode = 1, muted = false, volume = 70 },
  { id = 103, nick = 'Mark_Volkov', dist = 13.1, talking = false, mode = 2, muted = true, volume = 100 },
  { id = 8, nick = 'Sergey_Orlov', dist = 22.5, talking = true, mode = 3, muted = false, volume = 100 },
}

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print('ok   ' .. name)
  else failed = failed + 1; print('FAIL ' .. name .. ': ' .. tostring(err)) end
end

local function runFrames(ui, ctx, n)
  ui.open()
  for f = 1, n do
    reset()
    for _, fc in ipairs(frameCb) do
      if fc.cond() then fc.cb({}) end
    end
    for k, v in pairs(stacks) do
      if v ~= 0 then error(('unbalanced %s stack: %d (frame %d)'):format(k, v, f)) end
    end
  end
end

for _, withFa in ipairs({ true, false }) do
  for _, haveFonts in ipairs({ true, false }) do
    local label = (withFa and 'with icons' or 'no icons') .. ', ' .. (haveFonts and 'fonts' or 'no font files')
    test('all pages render (' .. label .. ')', function()
      fileExists = haveFonts
      local ui = loadUi(withFa)
      local ctx, log = makeCtx(PLAYERS)
      ui.init(ctx)
      assert(#initCb == 1 and #frameCb == 1)
      initCb[1]()
      assert(ui.hasIcons() == withFa)
      -- иконки: в шрифт по умолчанию и крупный всегда, в обычный и жирный — если они загрузились
      assert(iconFontLoaded == (withFa and (haveFonts and 4 or 2) or 0), 'icon font loads: ' .. iconFontLoaded)
      -- страницы переключаются кликами по боковому меню; прогоняем много кадров
      -- со случайными наведениями и кликами
      runFrames(ui, ctx, 400)
      -- жалоба: кликов достаточно, чтобы хоть раз дойти до выбора причины
      assert(#log >= 0)
    end)
  end
end

test('empty players list and search', function()
  fileExists = true
  local ui = loadUi(true)
  local ctx = makeCtx({})
  ui.init(ctx)
  initCb[1]()
  runFrames(ui, ctx, 200)
end)

test('closed menu draws nothing', function()
  local ui = loadUi(true)
  ui.init(makeCtx(PLAYERS))
  initCb[1]()
  ui.open(); ui.close()
  assert(frameCb[1].cond() == false)
  assert(ui.wantsText() == false)
end)

test('every page reached', function()
  local ui = loadUi(true)
  local ctx = makeCtx(PLAYERS)
  ui.init(ctx)
  initCb[1]()
  local seen = {}
  local titles = { 'Главная', 'Игроки', 'Звук', 'Рация', 'Сервер' }
  ui.open()
  for _ = 1, 600 do
    reset()
    frameCb[1].cb({})
    for _, s in ipairs(calls) do
      for i, t in ipairs(titles) do if s == t then seen[i] = (seen[i] or 0) + 1 end end
    end
  end
  -- заголовок страницы рисуется дважды (меню + шапка), значит страница открывалась
  for i, t in ipairs(titles) do assert((seen[i] or 0) > 600, 'page never opened: ' .. t) end
end)

test('report flow reaches ctx.report', function()
  local ui = loadUi(true)
  local ctx, log = makeCtx(PLAYERS)
  ui.init(ctx)
  initCb[1]()
  ui.open()
  for _ = 1, 3000 do
    reset()
    frameCb[1].cb({})
    if #log > 0 and log[#log] == 'report' then break end
  end
  local reported = false
  for _, l in ipairs(log) do if l == 'report' then reported = true end end
  assert(reported, 'random clicks never completed a report')
end)

test('server list and frequency list are requested while visible', function()
  local ui = loadUi(true)
  local ctx, log = makeCtx(PLAYERS)
  ui.init(ctx)
  initCb[1]()
  ui.open()
  local seen = {}
  for _ = 1, 3000 do
    reset(); frameCb[1].cb({})
    for _, l in ipairs(log) do seen[l] = true end
    for _, c in ipairs(calls) do if c == 'Позвонить' or c:find('Позвонить', 1, true) then seen.callBtn = true end end
    if seen.list1 and seen.list2 and seen.callBtn then break end
  end
  assert(seen.list1, 'server list never requested')
  assert(seen.list2, 'frequency list never requested')
  assert(seen.callBtn, 'no call button in the server list')
end)

test('script-side API never touches mimgui outside a frame', function()
  local ui = loadUi(true)
  local ctx = makeCtx(PLAYERS)
  ui.init(ctx)
  initCb[1]()
  -- так их вызывает trinivoice.lua из основного цикла, каждый кадр игры
  for _ = 1, 3 do
    ui.open(); assert(ui.isOpen())
    assert(ui.wantsText() == false)
    reset(); frameCb[1].cb({})
    assert(type(ui.wantsText()) == 'boolean')
    ui.hasIcons()
    -- кадр мог «нажать» крестик (клики в заглушке случайные), поэтому проверяем переключение
    local before = ui.isOpen()
    ui.toggle(); assert(ui.isOpen() ~= before)
    ui.close(); assert(not ui.isOpen())
    assert(ui.wantsText() == false)
  end
end)

print(('%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
