-- TriniVoice: меню /tv на mimgui.
-- Модуль ничего не знает про звук и сеть: всё берёт из ctx, который передаёт
-- trinivoice.lua (см. M.init). Строки здесь в UTF-8, как и требует mimgui.
--
-- Нужно: mimgui. Желательно: fAwesome6 (иконки) и шрифты Montserrat в
-- moonloader/resource/trinivoice/. Без них меню работает со шрифтом по умолчанию
-- и без иконок.

local imgui = require 'mimgui'
local ffi = require 'ffi'
local okFa, fa = pcall(require, 'fAwesome6')
if not okFa then fa = nil end

local M = {}

local W, H, SIDE = 900, 560, 224
local X0, CW = SIDE + 26, W - SIDE - 52 -- контентная область
local V = imgui.ImVec2

local ctx
local show = imgui.new.bool(false)
local page = 1
local fonts = {}
local iconRanges
local anim = {}
local dt = 0.016
local searchBuf = imgui.new.char[64]()
local hostBuf = imgui.new.char[128]()
local portBuf = imgui.new.char[8]()
local freqBuf = imgui.new.char[12]()
local passBuf = imgui.new.char[64]()
local reportTarget -- { id, nick }, пока выбирается причина жалобы
local meter = { bars = {}, t = 0 }
for i = 1, 14 do meter.bars[i] = 0 end

-- состояние кадра
local dl, org

---------------------------------------------------------------------------
-- Цвета
---------------------------------------------------------------------------

local function hex(h, a)
  h = tostring(h or ''):gsub('#', '')
  local r = tonumber(h:sub(1, 2), 16) or 110
  local g = tonumber(h:sub(3, 4), 16) or 139
  local b = tonumber(h:sub(5, 6), 16) or 255
  return imgui.ImVec4(r / 255, g / 255, b / 255, a or 1)
end
local function u32(c) return imgui.ColorConvertFloat4ToU32(c) end
local function mix(a, b, t)
  return imgui.ImVec4(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t)
end
local function alpha(c, a) return imgui.ImVec4(c.x, c.y, c.z, c.w * a) end

local C = {
  shade = hex('07080B'), bg = hex('111218'), side = hex('0C0D11'), card = hex('16181F'),
  card2 = hex('1A1C24'), field = hex('0F1015'), border = hex('23252E'), border2 = hex('2A2D38'),
  key = hex('1F2129'), keyEdge = hex('343846'),
  white = hex('FFFFFF'), text = hex('E9EBF2'), soft = hex('C9CCD8'), soft2 = hex('B4B8C6'),
  muted = hex('8A8FA0'), green = hex('4CD27A'), greenText = hex('7BE495'),
  orange = hex('FF9A3C'), orangeText = hex('FFB067'), red = hex('FF5A5A'), redText = hex('FF8C8C'),
  whisper = hex('C8C8C8'),
}
local AVATARS = { hex('2B3A66'), hex('5A2E55'), hex('23454A'), hex('4A3A23'), hex('2F4A2B'), hex('46304F') }
local ACCENTS = { '#6E8BFF', '#3FBF7F', '#FF8A3D', '#A57CFF' }
local acc = hex(ACCENTS[1])

local MODE_LABEL = { 'шёпот', 'обычный', 'крик' }

---------------------------------------------------------------------------
-- Вспомогательное
---------------------------------------------------------------------------

local function icon(name)
  if not fa then return '' end
  local ok, r = pcall(fa, name)
  if ok and type(r) == 'string' then return r end
  return ''
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

local function smooth(id, target, speed)
  local v = anim[id] or target
  v = v + (target - v) * math.min(1, dt * (speed or 14))
  anim[id] = v
  return v
end

local function pushFont(f) if f then imgui.PushFont(f) end end
local function popFont(f) if f then imgui.PopFont() end end

local function textSize(s, f)
  pushFont(f)
  local sz = imgui.CalcTextSize(s)
  popFont(f)
  return sz
end

-- Текст в координатах окна (x, y — левый верхний угол).
local function text(x, y, s, col, f)
  pushFont(f)
  dl:AddText(org + V(x, y), u32(col), s)
  popFont(f)
end

-- Текст, выровненный по вертикали внутри строки высотой h.
local function textMid(x, y, h, s, col, f)
  local sz = textSize(s, f)
  text(x, y + (h - sz.y) / 2, s, col, f)
  return sz.x
end

local function rect(x, y, w, h, col, r, corners)
  dl:AddRectFilled(org + V(x, y), org + V(x + w, y + h), u32(col), r or 0, corners or 15)
end
local function frame(x, y, w, h, col, r, thick)
  dl:AddRect(org + V(x, y), org + V(x + w, y + h), u32(col), r or 0, 15, thick or 1)
end

local function card(x, y, w, h)
  rect(x, y, w, h, C.card, 12)
  frame(x, y, w, h, C.border, 12)
end

-- Невидимая кнопка-область. Возвращает clicked, hovered, active.
local function hit(id, x, y, w, h)
  imgui.SetCursorPos(V(x, y))
  local clicked = imgui.InvisibleButton(id, V(w, h))
  return clicked, imgui.IsItemHovered(), imgui.IsItemActive()
end

local function initials(nick)
  local a, b = nick:match('^(%a)%a*[_%.](%a)')
  if a then return (a .. b):upper() end
  return nick:sub(1, 2):upper()
end

local function nickColor(nick)
  local h = 0
  for i = 1, #nick do h = (h * 31 + nick:byte(i)) % 1000003 end
  return AVATARS[h % #AVATARS + 1]
end

---------------------------------------------------------------------------
-- Виджеты
---------------------------------------------------------------------------

local function button(id, x, y, w, h, label, primary)
  local clicked, hov = hit(id, x, y, w, h)
  local bg = primary and acc or C.key
  if hov then bg = mix(bg, C.white, 0.08) end
  rect(x, y, w, h, bg, 9)
  local sz = textSize(label, fonts.bold)
  text(x + (w - sz.x) / 2, y + (h - sz.y) / 2, label, C.white, fonts.bold)
  return clicked
end

local function iconButton(id, x, y, size, ico, col, bg)
  local clicked, hov = hit(id, x, y, size, size)
  rect(x, y, size, size, hov and mix(bg, C.white, 0.08) or bg, 9)
  if ico ~= '' then
    local sz = textSize(ico)
    text(x + (size - sz.x) / 2, y + (size - sz.y) / 2, ico, col)
  end
  return clicked
end

local function toggle(id, x, y, on)
  local clicked, hov = hit(id, x, y, 46, 26)
  local t = smooth(id, on and 1 or 0, 16)
  rect(x, y, 46, 26, mix(C.border2, acc, t), 13)
  dl:AddCircleFilled(org + V(x + 13 + 20 * t, y + 13), 10, u32(C.white), 24)
  return clicked
end

-- Выпадающих списков нет: выбор из нескольких вариантов — сегменты.
local function segmented(id, x, y, w, h, labels, idx)
  rect(x, y, w, h, C.field, 9)
  frame(x, y, w, h, C.border, 9)
  local n = #labels
  local sw = (w - 6) / n
  local pos = smooth(id, idx - 1, 16)
  rect(x + 3 + pos * sw, y + 3, sw, h - 6, acc, 7)
  local picked
  for i, label in ipairs(labels) do
    local cx = x + 3 + (i - 1) * sw
    if hit(id .. i, cx, y + 3, sw, h - 6) and i ~= idx then picked = i end
    local f = i == idx and fonts.bold or nil
    local sz = textSize(label, f)
    text(cx + (sw - sz.x) / 2, y + (h - sz.y) / 2, label, i == idx and C.white or C.soft2, f)
  end
  return picked
end

local function keycap(id, x, y, label, listening)
  local sz = textSize(label, fonts.bold)
  local w = math.max(34, sz.x + 18)
  x = x - w -- выравнивание по правому краю
  local clicked, hov = hit(id, x, y, w, 30)
  rect(x, y, w, 30, listening and acc or C.keyEdge, 7)
  rect(x + 1, y + 1, w - 2, 25, hov and mix(C.key, C.white, 0.06) or C.key, 6)
  text(x + (w - sz.x) / 2, y + (26 - sz.y) / 2, label, C.white, fonts.bold)
  return clicked
end

-- Ползунок: возвращает новое значение, когда пользователь его тянет.
local function slider(id, x, y, w, value, min, max)
  local _, hov, active = hit(id, x, y - 7, w, 20)
  local t = clamp((value - min) / (max - min), 0, 1)
  local nv
  if active then
    local mx = imgui.GetMousePos().x - (org.x + x)
    t = clamp(mx / w, 0, 1)
    nv = math.floor(min + t * (max - min) + 0.5)
    if nv == value then nv = nil end
  end
  rect(x, y, w, 6, C.border2, 3)
  rect(x, y, math.max(6, w * t), 6, acc, 3)
  local cx = x + w * t
  local r = (hov or active) and 9 or 8
  dl:AddCircleFilled(org + V(cx, y + 3), r, u32(acc), 24)
  dl:AddCircleFilled(org + V(cx, y + 3), r - 3, u32(C.white), 24)
  return nv
end

local function tile(id, x, y, w, h, ico, title, sub, active)
  local _, hov = hit(id, x, y, w, h)
  local clicked = imgui.IsItemClicked(0)
  local t = smooth(id, active and 1 or 0, 14)
  local bg = mix(hov and mix(C.card2, C.white, 0.03) or C.card2, mix(C.card, acc, 0.16), t)
  rect(x, y, w, h, bg, 10)
  frame(x, y, w, h, mix(C.border2, acc, t), 10)
  local isz = textSize(ico, fonts.icon)
  text(x + (w - isz.x) / 2, y + 16, ico, active and acc or C.soft, fonts.icon)
  local tsz = textSize(title, fonts.bold)
  local ssz = textSize(' · ' .. sub)
  local tx = x + (w - tsz.x - ssz.x) / 2
  text(tx, y + h - 28, title, active and C.white or C.soft, fonts.bold)
  text(tx + tsz.x, y + h - 28 + (tsz.y - ssz.y) / 2, ' · ' .. sub, active and C.soft or C.muted)
  return clicked
end

local function avatar(x, y, nick, ring)
  local c = org + V(x + 20, y + 20)
  if ring then
    dl:AddCircleFilled(c, 24, u32(ring), 32)
    dl:AddCircleFilled(c, 22, u32(C.card), 32)
  end
  dl:AddCircleFilled(c, 20, u32(nickColor(nick)), 32)
  local s = initials(nick)
  local sz = textSize(s, fonts.bold)
  text(x + 20 - sz.x / 2, y + 20 - sz.y / 2, s, C.white, fonts.bold)
end

local function sectionTitle(x, y, s) text(x, y, s, C.white, fonts.bold) end

---------------------------------------------------------------------------
-- Боковое меню
---------------------------------------------------------------------------

local PAGES = {
  { 'HOUSE', 'Главная' },
  { 'USERS', 'Игроки рядом' },
  { 'SLIDERS', 'Звук' },
  { 'WALKIE_TALKIE', 'Рация' },
  { 'SERVER', 'Сервер' },
}

local function drawSidebar(st, playerCount)
  rect(0, 0, SIDE, H, C.side, 14, 5) -- скругление слева
  rect(SIDE, 0, 1, H, C.border)

  -- логотип
  rect(22, 18, 36, 36, acc, 10)
  local mic = icon('MICROPHONE')
  if mic ~= '' then
    local sz = textSize(mic, fonts.icon)
    text(22 + (36 - sz.x) / 2, 18 + (36 - sz.y) / 2, mic, C.white, fonts.icon)
  end
  text(68, 19, 'TriniVoice', C.white, fonts.bold)
  text(68, 38, 'голосовой чат', C.muted, fonts.small)

  for i, p in ipairs(PAGES) do
    local x, y, w, h = 14, 74 + (i - 1) * 46, SIDE - 28, 40
    local clicked, hov = hit('##nav' .. i, x, y, w, h)
    if clicked then page = i end
    local active = page == i
    local t = smooth('nav' .. i, active and 1 or (hov and 0.45 or 0), 14)
    if t > 0.01 then
      local bg = active and mix(C.side, acc, 0.20) or C.card
      rect(x, y, w, h, alpha(bg, active and t or t * 1.6), 10)
    end
    local ico = icon(p[1])
    local tx = x + 12
    if ico ~= '' then
      textMid(tx, y, h, ico, active and acc or C.soft2)
      tx = tx + 30
    end
    textMid(tx, y, h, p[2], active and C.white or C.soft2, active and fonts.bold or nil)
    if i == 4 and st.radioWire > 0 then
      local s = ('%.1f'):format(st.radioWire / 10)
      local sz = textSize(s, fonts.small)
      rect(x + w - sz.x - 22, y + 11, sz.x + 14, 18, active and acc or C.border, 8)
      text(x + w - sz.x - 15, y + 11 + (18 - sz.y) / 2, s, C.white, fonts.small)
    elseif i == 5 and st.updateAvailable then
      dl:AddCircleFilled(org + V(x + w - 18, y + 20), 4, u32(C.orange), 12)
    elseif i == 2 and playerCount > 0 then
      local s = tostring(playerCount)
      local sz = textSize(s, fonts.small)
      local bw = math.max(20, sz.x + 12)
      rect(x + w - bw - 8, y + 10, bw, 20, active and acc or C.border, 10)
      text(x + w - bw - 8 + (bw - sz.x) / 2, y + 10 + (20 - sz.y) / 2, s, C.white, fonts.small)
    end
  end

  -- звонок
  local cl = ctx.call()
  if cl then
    local cy, ch = H - 76 - 14 - 124, 124
    local ringing = cl.state ~= 'active'
    local pulse = ringing and (0.5 + 0.5 * math.sin(imgui.GetTime() * 6)) or 0
    rect(14, cy, SIDE - 28, ch, mix(hex('15171E'), C.green, 0.06 + 0.06 * pulse), 12)
    frame(14, cy, SIDE - 28, ch, mix(C.border, C.green, 0.4 + 0.4 * pulse), 12)
    local title = cl.state == 'in' and 'Входящий звонок' or (cl.state == 'out' and 'Вызов...' or 'Разговор')
    local ph = icon('PHONE')
    local tx = 26
    if ph ~= '' then textMid(tx, cy + 10, 20, ph, C.greenText); tx = tx + 22 end
    textMid(tx, cy + 10, 20, title, C.greenText, fonts.bold)
    text(26, cy + 36, cl.peerNick, C.white, fonts.bold)
    local sub = cl.state == 'active' and ('%02d:%02d'):format(math.floor(cl.duration / 60), math.floor(cl.duration) % 60)
      or ('ID ' .. cl.peerId)
    text(26, cy + 56, sub, C.muted, fonts.small)
    local bw = SIDE - 28 - 24
    if cl.state == 'in' then
      local hw2 = (bw - 8) / 2
      if button('##accept', 26, cy + 80, hw2, 32, 'Ответить', true) then ctx.acceptCall() end
      if button('##decline', 26 + hw2 + 8, cy + 80, hw2, 32, 'Сбросить') then ctx.hangup() end
    else
      if button('##hangup', 26, cy + 80, bw, 32, 'Положить трубку') then ctx.hangup() end
    end
  end

  -- карточка связи
  local y = H - 76
  rect(14, y, SIDE - 28, 60, hex('15171E'), 12)
  frame(14, y, SIDE - 28, 60, C.border, 12)
  local col = st.connected and C.green or C.red
  dl:AddCircleFilled(org + V(30, y + 20), 7, u32(alpha(col, 0.2)), 16)
  dl:AddCircleFilled(org + V(30, y + 20), 4, u32(col), 16)
  textMid(42, y + 10, 20, st.connected and 'На связи' or 'Нет связи', st.connected and C.greenText or C.redText, fonts.bold)
  local info = st.connected and (('%d мс · онлайн с голосом: %d'):format(st.ping or 0, st.online or 0)) or 'проверьте адрес на вкладке «Сервер»'
  text(26, y + 34, info, C.muted, fonts.small)
end

---------------------------------------------------------------------------
-- Шапка
---------------------------------------------------------------------------

local function header(title, sub)
  text(X0, 20, title, C.white, fonts.title)
  text(X0, 50, sub, C.muted)
  if iconButton('##close', W - 26 - 32, 22, 32, icon('XMARK'), C.soft2, C.card2) then show[0] = false end
  if icon('XMARK') == '' then text(W - 26 - 21, 29, 'x', C.soft2, fonts.bold) end
end

---------------------------------------------------------------------------
-- Страницы
---------------------------------------------------------------------------

local function micLabel(st)
  if not st.micOk then return 'нет микрофона', C.redText end
  if st.micLevel >= st.vadLevel then return 'слышно', C.greenText end
  return 'тихо', C.muted
end

local function updateMeter(st)
  meter.t = meter.t + dt
  if meter.t >= 0.06 then
    meter.t = 0
    table.remove(meter.bars, 1)
    meter.bars[#meter.bars + 1] = st.micLevel
  end
end

local function drawMeter(x, y, w, h, st)
  local n = #meter.bars
  local gap = 4
  local bw = (w - gap * (n - 1)) / n
  for i, lvl in ipairs(meter.bars) do
    local bh = math.max(4, h * lvl)
    local col = (st.micOk and lvl >= st.vadLevel) and acc or C.border2
    rect(x + (i - 1) * (bw + gap), y + h - bh, bw, bh, col, 2)
  end
  -- порог активации голосом
  local ty = y + h - h * st.vadLevel
  rect(x, ty, w, 1, alpha(C.orange, 0.6))
end

local function pageHome(st)
  local m = ctx.cfg.main
  header('Главная', st.muted and 'Голос выключен администратором ретранслятора'
    or (m.enabled and 'Вас слышат игроки рядом с вами' or 'Голосовой чат выключен'))
  local tw = textSize('Включён', fonts.bold).x
  text(W - 26 - 32 - 12 - 46 - 10 - tw, 30, m.enabled and 'Включён' or 'Выключен', C.soft2, fonts.bold)
  if toggle('##enabled', W - 26 - 32 - 12 - 46, 25, m.enabled) then ctx.setEnabled(not m.enabled) end

  -- дальность речи
  local y = 86
  card(X0, y, CW, 128)
  sectionTitle(X0 + 16, y + 14, 'Дальность речи')
  local icons = { icon('EAR_LISTEN'), icon('COMMENT'), icon('VOLUME_HIGH') }
  local subs = { '3 м', '15 м', '40 м' }
  local names = { 'Шёпот', 'Обычный', 'Крик' }
  if st.inServiceVehicle and m.megaphone then
    icons[3], subs[3], names[3] = icon('BULLHORN'), '60 м', 'Мегафон'
  end
  local tw3 = (CW - 32 - 20) / 3
  for i = 1, 3 do
    if tile('##mode' .. i, X0 + 16 + (i - 1) * (tw3 + 10), y + 40, tw3, 74, icons[i], names[i], subs[i], m.mode == i) then
      ctx.setMode(i)
    end
  end

  -- как говорить
  y = 228
  local hw = (CW - 14) / 2
  card(X0, y, hw, 192)
  sectionTitle(X0 + 16, y + 14, 'Как говорить')
  local sel = segmented('##act', X0 + 16, y + 42, hw - 32, 36, { 'По клавише', 'Голосом' }, m.activation == 'vad' and 2 or 1)
  if sel then ctx.setActivation(sel == 2 and 'vad' or 'ptt') end
  local bind = ctx.binding()
  local rows = {
    { 'KEYBOARD', 'Говорить', 'ptt', m.ptt_key },
    { 'ARROWS_ROTATE', 'Сменить дальность', 'mode', m.mode_key },
  }
  for i, r in ipairs(rows) do
    local ry = y + 96 + (i - 1) * 42
    local tx = X0 + 16
    local ico = icon(r[1])
    if ico ~= '' then textMid(tx, ry, 30, ico, C.muted); tx = tx + 26 end
    textMid(tx, ry, 30, r[2], C.soft)
    local label = bind == r[3] and 'нажмите клавишу' or ctx.keyName(r[4])
    if keycap('##key' .. r[3], X0 + hw - 16, ry, label, bind == r[3]) then ctx.startBinding(r[3]) end
  end

  -- микрофон
  local mx = X0 + hw + 14
  card(mx, y, hw, 192)
  sectionTitle(mx + 16, y + 14, 'Микрофон')
  local label, col = micLabel(st)
  local lsz = textSize(label, fonts.small)
  text(mx + hw - 16 - lsz.x, y + 17, label, col, fonts.small)
  drawMeter(mx + 16, y + 44, hw - 32, 50, st)
  text(mx + 16, y + 112, 'Усиление', C.soft)
  local gv = ('%d%%'):format(m.mic_gain)
  local gsz = textSize(gv, fonts.bold)
  text(mx + hw - 16 - gsz.x, y + 112, gv, C.white, fonts.bold)
  local ng = slider('##gain', mx + 16, y + 146, hw - 32, m.mic_gain, 50, 400)
  if ng then ctx.set('mic_gain', ng) end

  -- громкость других
  y = 434
  card(X0, y, CW, 58)
  local tx = X0 + 16
  local vi = icon('VOLUME_HIGH')
  if vi ~= '' then textMid(tx, y, 58, vi, C.soft); tx = tx + 28 end
  textMid(tx, y, 58, 'Громкость других', C.soft)
  local vv = ('%d%%'):format(m.master_volume)
  local vsz = textSize(vv, fonts.bold)
  textMid(X0 + CW - 16 - vsz.x, y, 58, vv, C.white, fonts.bold)
  local nv = slider('##master', tx + 150, y + 26, CW - (tx - X0) - 150 - 70, m.master_volume, 0, 100)
  if nv then ctx.set('master_volume', nv) end
end

local function pagePlayers(st)
  header('Игроки рядом', 'Настройки запоминаются по нику')
  -- поиск
  imgui.SetCursorPos(V(W - 26 - 32 - 12 - 200, 24))
  imgui.SetNextItemWidth(200)
  imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 9)
  imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(10, 8))
  imgui.InputTextWithHint('##search', icon('MAGNIFYING_GLASS') .. '  Ник или ID', searchBuf, ffi.sizeof(searchBuf))
  imgui.PopStyleVar(2)
  local query = ffi.string(searchBuf):lower()

  if reportTarget then
    local y = 86
    card(X0, y, CW, 320)
    sectionTitle(X0 + 16, y + 14, 'Жалоба на ' .. reportTarget.nick)
    text(X0 + 16, y + 40, 'Последние 30 секунд его голоса сохранятся у вас как WAV-файл,', C.muted, fonts.small)
    text(X0 + 16, y + 58, 'а жалоба уйдёт администрации ретранслятора.', C.muted, fonts.small)
    local reasons = { 'Оскорбления', 'Музыка и шум в микрофон', 'Помехи и спам в рации', 'Нарушение правил сервера' }
    for i, r in ipairs(reasons) do
      if button('##reason' .. i, X0 + 16, y + 86 + (i - 1) * 44, CW - 32, 36, r) then
        ctx.report(reportTarget.id, r)
        reportTarget = nil
        return
      end
    end
    if button('##reportCancel', X0 + 16, y + 270, 140, 34, 'Отмена') then reportTarget = nil end
    return
  end

  local list = {}
  for _, p in ipairs(ctx.players()) do
    if query == '' or p.nick:lower():find(query, 1, true) or tostring(p.id) == query then list[#list + 1] = p end
  end

  if #list == 0 then
    local cy = 220
    local ico = icon('MICROPHONE_SLASH')
    if ico ~= '' then
      local sz = textSize(ico, fonts.icon)
      text(X0 + (CW - sz.x) / 2, cy, ico, C.muted, fonts.icon)
    end
    local t1 = query == '' and 'Пока никого не слышно' or 'Никого не найдено'
    local s1 = textSize(t1, fonts.bold)
    text(X0 + (CW - s1.x) / 2, cy + 40, t1, C.white, fonts.bold)
    local t2 = 'Здесь появятся игроки с TriniVoice, которых вы слышали рядом'
    local s2 = textSize(t2)
    text(X0 + (CW - s2.x) / 2, cy + 64, t2, C.muted)
    return
  end

  -- список с прокруткой
  imgui.SetCursorPos(V(X0, 86))
  imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
  imgui.BeginChild('##players', V(CW + 8, 404), false, 0)
  local saveDl, saveOrg = dl, org
  dl = imgui.GetWindowDrawList()
  org = imgui.GetWindowPos() - V(0, imgui.GetScrollY())
  for i, p in ipairs(list) do
    local y = (i - 1) * 68
    local ring = p.talking and (p.mode == 3 and C.orange or (p.mode == 1 and C.whisper or C.green)) or nil
    rect(0, y, CW, 60, C.card, 12)
    frame(0, y, CW, 60, ring and mix(C.border, ring, 0.45) or C.border, 12)
    avatar(14, y + 10, p.nick, ring)
    text(68, y + 12, p.nick, p.muted and C.soft2 or C.white, fonts.bold)
    local nw = textSize(p.nick, fonts.bold).x
    text(68 + nw + 6, y + 12, '[' .. p.id .. ']', C.muted)
    local status, scol
    if p.muted then status, scol = 'заглушён', C.redText
    elseif p.talking then status, scol = 'говорит · ' .. MODE_LABEL[p.mode or 2], p.mode == 3 and C.orangeText or C.greenText
    else status, scol = 'молчит', C.muted end
    text(68, y + 32, status, scol, fonts.small)

    local dist = ('%.1f м'):format(p.dist)
    local dsz = textSize(dist, fonts.small)
    rect(262, y + 19, 64, 22, C.key, 8)
    text(262 + (64 - dsz.x) / 2, y + 19 + (22 - dsz.y) / 2, dist, C.soft, fonts.small)

    local sx, sw = 262 + 64 + 16, CW - (262 + 64 + 16) - 190
    local vol = p.muted and 0 or p.volume
    if p.muted then
      rect(sx, y + 27, sw, 6, hex('22242C'), 3)
    else
      local nv = slider('##vol' .. p.nick, sx, y + 27, sw, p.volume, 0, 100)
      if nv then ctx.setVolume(p.nick, nv) end
    end
    local vs = vol .. '%'
    local vsz = textSize(vs, fonts.bold)
    text(CW - 140 - vsz.x, y + 30 - vsz.y / 2, vs, p.muted and C.muted or C.white, fonts.bold)
    local inCall = ctx.call() ~= nil
    local pico = icon('PHONE')
    if pico == '' then pico = 'тел' end
    if iconButton('##call' .. p.nick, CW - 128, y + 13, 34, pico, inCall and C.muted or C.soft, C.key) and not inCall then
      ctx.callPlayer(p.id)
    end
    local fico = icon('FLAG')
    if fico == '' then fico = '!' end
    if iconButton('##report' .. p.nick, CW - 88, y + 13, 34, fico, C.soft, C.key) then
      reportTarget = { id = p.id, nick = p.nick }
    end
    local ico = p.muted and icon('VOLUME_XMARK') or icon('VOLUME_HIGH')
    if ico == '' then ico = p.muted and 'вкл' or 'выкл' end
    if iconButton('##mute' .. p.nick, CW - 48, y + 13, 34, ico, p.muted and C.redText or C.soft,
        p.muted and alpha(C.red, 0.16) or C.key) then
      ctx.toggleMute(p.nick)
    end
  end
  imgui.SetCursorPos(V(0, #list * 68))
  imgui.Dummy(V(1, 1))
  dl, org = saveDl, saveOrg
  imgui.EndChild()
  imgui.PopStyleColor(1)
end

local function pageSound(st)
  local m = ctx.cfg.main
  header('Звук', 'Громкость, микрофон и отображение')
  local hw = (CW - 14) / 2
  local y = 86

  card(X0, y, hw, 176)
  sectionTitle(X0 + 16, y + 14, 'Громкость')
  local rows = { { 'Громкость других', 'master_volume', 0, 100 }, { 'Усиление микрофона', 'mic_gain', 50, 400 } }
  for i, r in ipairs(rows) do
    local ry = y + 44 + (i - 1) * 62
    text(X0 + 16, ry, r[1], C.soft)
    local v = ('%d%%'):format(m[r[2]])
    local vsz = textSize(v, fonts.bold)
    text(X0 + hw - 16 - vsz.x, ry, v, C.white, fonts.bold)
    local nv = slider('##s' .. r[2], X0 + 16, ry + 32, hw - 32, m[r[2]], r[3], r[4])
    if nv then ctx.set(r[2], nv) end
  end

  local mx = X0 + hw + 14
  card(mx, y, hw, 176)
  sectionTitle(mx + 16, y + 14, 'Активация голосом')
  local label, col = micLabel(st)
  local lsz = textSize(label, fonts.small)
  text(mx + hw - 16 - lsz.x, y + 17, label, col, fonts.small)
  drawMeter(mx + 16, y + 44, hw - 32, 40, st)
  text(mx + 16, y + 100, 'Порог', C.soft)
  local tv = tostring(m.vad_threshold)
  local tsz = textSize(tv, fonts.bold)
  text(mx + hw - 16 - tsz.x, y + 100, tv, C.white, fonts.bold)
  local nt = slider('##vad', mx + 16, y + 134, hw - 32, m.vad_threshold, 50, 5000)
  if nt then ctx.set('vad_threshold', nt) end
  text(mx + 16, y + 150, 'оранжевая линия на шкале — порог', C.muted, fonts.small)

  y = 276
  card(X0, y, hw, 164)
  sectionTitle(X0 + 16, y + 14, 'Кодек')
  local sel = segmented('##codec', X0 + 16, y + 42, hw - 32, 36, { 'u-law', 'Opus' }, m.codec == 'opus' and 2 or 1)
  if sel then ctx.setCodec(sel == 2 and 'opus' or 'ulaw') end
  local note = st.opusAvailable and 'Opus: лучше звук, нужен opus.dll у всех'
    or 'opus.dll не найден в moonloader/lib'
  text(X0 + 16, y + 94, note, st.opusAvailable and C.muted or C.orangeText, fonts.small)
  text(X0 + 16, y + 114, 'u-law работает у всех без доп. файлов', C.muted, fonts.small)

  card(mx, y, hw, 164)
  sectionTitle(mx + 16, y + 14, 'Эффекты')
  local fx = {
    { 'Приглушение за стенами', 'occlusion' },
    { 'Эффект рации и телефона', 'fx_radio' },
    { 'Мегафон в спецмашине', 'megaphone' },
    { 'Звук нажатия клавиши', 'ptt_sound' },
  }
  for i, t in ipairs(fx) do
    local ry = y + 40 + (i - 1) * 30
    textMid(mx + 16, ry, 26, t[1], C.soft)
    if toggle('##fx' .. t[2], mx + hw - 16 - 46, ry, m[t[2]]) then ctx.set(t[2], not m[t[2]]) end
  end

  y = 454
  card(X0, y, CW, 70)
  sectionTitle(X0 + 16, y + 12, 'Отображение')
  local toggles = { { 'Метки', 'show_icons' }, { 'Строка состояния', 'show_hud' } }
  local tx = X0 + 16
  for _, t in ipairs(toggles) do
    textMid(tx, y + 34, 26, t[1], C.soft)
    tx = tx + textSize(t[1]).x + 10
    if toggle('##t' .. t[2], tx, y + 34, m[t[2]]) then ctx.set(t[2], not m[t[2]]) end
    tx = tx + 46 + 24
  end
  textMid(tx, y + 34, 26, 'Цвет', C.soft)
  tx = tx + textSize('Цвет').x + 10
  for i, a in ipairs(ACCENTS) do
    local cx = tx + (i - 1) * 30
    local _, hov = hit('##acc' .. i, cx, y + 34, 26, 26)
    if imgui.IsItemClicked(0) then ctx.set('accent', a) end
    local cc = org + V(cx + 13, y + 47)
    if m.accent == a then dl:AddCircleFilled(cc, 13, u32(C.white), 24) end
    dl:AddCircleFilled(cc, (m.accent == a or hov) and 10 or 9, u32(hex(a)), 24)
  end
end

local function pageRadio(st)
  local m = ctx.cfg.main
  local on = m.radio_on
  header('Рация', on and ('Частота %.1f МГц · на частоте ещё %d'):format(st.radioWire / 10, st.radioListeners)
    or 'Связь на частоте на любом расстоянии')
  local lbl = on and 'Включена' or 'Выключена'
  local tw = textSize(lbl, fonts.bold).x
  text(W - 26 - 32 - 12 - 46 - 10 - tw, 30, lbl, C.soft2, fonts.bold)
  if toggle('##radioOn', W - 26 - 32 - 12 - 46, 25, on) then ctx.setRadio(not on) end

  -- частота
  local y = 86
  card(X0, y, CW, 140)
  sectionTitle(X0 + 16, y + 14, 'Частота')
  local f = ('%.1f'):format(tonumber(m.radio_freq) or 0)
  local fsz = textSize(f, fonts.title)
  text(X0 + 16, y + 44, f, on and C.white or C.soft2, fonts.title)
  text(X0 + 22 + fsz.x, y + 44 + fsz.y - 18, 'МГц', C.muted)
  local steps = { { '-1', -1 }, { '-0.1', -0.1 }, { '+0.1', 0.1 }, { '+1', 1 } }
  for i, sp in ipairs(steps) do
    if button('##step' .. i, X0 + 16 + (i - 1) * 60, y + 92, 52, 32, sp[1]) then
      local nf = math.floor(((tonumber(m.radio_freq) or 100) + sp[2]) * 10 + 0.5) / 10
      if ctx.setRadio(nil, nf) then imgui.StrCopy(freqBuf, ('%.1f'):format(nf)) end
    end
  end
  imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 9)
  imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(10, 9))
  imgui.SetCursorPos(V(X0 + CW - 16 - 130 - 10 - 120, y + 92))
  imgui.SetNextItemWidth(120)
  imgui.InputTextWithHint('##freq', '911.0', freqBuf, ffi.sizeof(freqBuf))
  imgui.PopStyleVar(2)
  if button('##setFreq', X0 + CW - 16 - 130, y + 92, 130, 34, 'Настроить', true) then
    ctx.setRadio(true, ffi.string(freqBuf))
  end

  -- пароль и управление
  y = 240
  local hw = (CW - 14) / 2
  card(X0, y, hw, 150)
  sectionTitle(X0 + 16, y + 14, 'Пароль частоты')
  text(X0 + 16, y + 40, 'Нужен для закрытых частот фракций', C.muted, fonts.small)
  imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 9)
  imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(10, 9))
  imgui.SetCursorPos(V(X0 + 16, y + 64))
  imgui.SetNextItemWidth(hw - 32)
  imgui.InputTextWithHint('##radioPass', 'пароль от лидера фракции', passBuf, ffi.sizeof(passBuf), imgui.InputTextFlags.Password)
  imgui.PopStyleVar(2)
  if button('##savePass', X0 + 16, y + 106, 120, 32, 'Сохранить') then ctx.set('radio_pass', ffi.string(passBuf)) end

  local mx = X0 + hw + 14
  card(mx, y, hw, 150)
  sectionTitle(mx + 16, y + 14, 'Управление')
  local bind = ctx.binding()
  local ry = y + 42
  local tx = mx + 16
  local ki = icon('KEYBOARD')
  if ki ~= '' then textMid(tx, ry, 30, ki, C.muted); tx = tx + 26 end
  textMid(tx, ry, 30, 'Говорить в рацию', C.soft)
  local label = bind == 'radio' and 'нажмите клавишу' or ctx.keyName(m.radio_key)
  if keycap('##keyradio', mx + hw - 16, ry, label, bind == 'radio') then ctx.startBinding('radio') end
  text(mx + 16, y + 88, 'Громкость рации', C.soft)
  local rv = ('%d%%'):format(m.radio_volume)
  local rsz = textSize(rv, fonts.bold)
  text(mx + hw - 16 - rsz.x, y + 88, rv, C.white, fonts.bold)
  local nv = slider('##radioVol', mx + 16, y + 124, hw - 32, m.radio_volume, 0, 100)
  if nv then ctx.set('radio_volume', nv) end

  -- избранные частоты
  y = 404
  card(X0, y, CW, 100)
  sectionTitle(X0 + 16, y + 14, 'Избранные частоты')
  local presets = ctx.radioPresets()
  if #presets == 0 then
    text(X0 + 16, y + 44, 'Добавьте в trinivoice.ini раздел [radio_presets], например:', C.muted, fonts.small)
    text(X0 + 16, y + 64, 'LSPD=911.0    EMS=912.0    Такси=150.5', C.soft, fonts.small)
  else
    local cx = X0 + 16
    for i, pr in ipairs(presets) do
      local label2 = ('%s  %.1f'):format(pr.name, pr.freq)
      local w = textSize(label2, fonts.bold).x + 24
      if cx + w > X0 + CW - 16 then break end
      local activeP = on and math.abs((tonumber(m.radio_freq) or 0) - pr.freq) < 0.05
      if button('##preset' .. i, cx, y + 46, w, 34, label2, activeP) then
        ctx.setRadio(true, pr.freq)
        imgui.StrCopy(freqBuf, ('%.1f'):format(pr.freq))
      end
      cx = cx + w + 8
    end
  end
end

local function pageServer(st)
  local m = ctx.cfg.main
  header('Сервер', 'Куда подключается голосовой чат')
  local y = 86
  card(X0, y, CW, 132)
  sectionTitle(X0 + 16, y + 14, 'Ретранслятор')
  text(X0 + 16, y + 44, 'Адрес', C.muted, fonts.small)
  text(X0 + CW - 16 - 150 - 12 - 110, y + 44, 'Порт', C.muted, fonts.small)
  imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 9)
  imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(10, 9))
  imgui.SetCursorPos(V(X0 + 16, y + 64))
  imgui.SetNextItemWidth(CW - 32 - 150 - 12 - 110 - 12)
  imgui.InputTextWithHint('##host', 'IP или домен', hostBuf, ffi.sizeof(hostBuf))
  imgui.SetCursorPos(V(X0 + CW - 16 - 150 - 12 - 110, y + 64))
  imgui.SetNextItemWidth(110)
  imgui.InputTextWithHint('##port', '7790', portBuf, ffi.sizeof(portBuf))
  imgui.PopStyleVar(2)
  if button('##connect', X0 + CW - 16 - 150, y + 64, 150, 34, 'Подключиться', true) then
    local host, port = ffi.string(hostBuf), tonumber(ffi.string(portBuf))
    if host ~= '' and port then ctx.setServer(host, port) end
  end

  y = 232
  card(X0, y, CW, 252)
  sectionTitle(X0 + 16, y + 14, 'Состояние')
  local rows = {
    { 'Связь', st.connected and 'на связи' or 'нет связи', st.connected and C.greenText or C.redText },
    { 'Пинг', st.connected and (st.ping .. ' мс') or '—', C.white },
    { 'Игроков с голосом на сервере', st.connected and tostring(st.online) or '—', C.white },
    { 'Комната (SA-MP сервер)', st.room or '—', C.white },
    { 'Ваш кодек', st.codec, C.white },
    { 'Версия скрипта', ctx.version, C.white },
    { 'Последняя версия', st.latest ~= '' and st.latest or '—', st.updateAvailable and C.orangeText or C.white },
  }
  for i, r in ipairs(rows) do
    local ry = y + 44 + (i - 1) * 28
    text(X0 + 16, ry, r[1], C.soft)
    local sz = textSize(r[2], fonts.bold)
    text(X0 + CW - 16 - sz.x, ry, r[2], r[3], fonts.bold)
    if i < #rows then rect(X0 + 16, ry + 22, CW - 32, 1, C.border) end
  end
  local note = st.updateAvailable and ('Доступна версия ' .. st.latest .. ': скачайте её у владельца ретранслятора.')
    or 'Адрес ретранслятора выдаёт его владелец. Настройки сохраняются в trinivoice.ini.'
  text(X0, y + 264, note, st.updateAvailable and C.orangeText or C.muted, fonts.small)
end

---------------------------------------------------------------------------
-- Инициализация
---------------------------------------------------------------------------

local function applyStyle()
  local s = imgui.GetStyle()
  s.WindowRounding = 14
  s.WindowBorderSize = 1
  s.ChildRounding = 12
  s.ChildBorderSize = 0
  s.FrameRounding = 9
  s.FrameBorderSize = 1
  s.ScrollbarSize = 8
  s.ScrollbarRounding = 8
  s.GrabRounding = 8
  s.PopupRounding = 10
  s.ItemSpacing = V(10, 10)
  local c = s.Colors
  c[imgui.Col.WindowBg] = C.bg
  c[imgui.Col.ChildBg] = imgui.ImVec4(0, 0, 0, 0)
  c[imgui.Col.PopupBg] = C.card
  c[imgui.Col.Border] = C.border
  c[imgui.Col.FrameBg] = C.card
  c[imgui.Col.FrameBgHovered] = C.card2
  c[imgui.Col.FrameBgActive] = C.card2
  c[imgui.Col.Text] = C.text
  c[imgui.Col.TextDisabled] = C.muted
  c[imgui.Col.ScrollbarBg] = imgui.ImVec4(0, 0, 0, 0)
  c[imgui.Col.ScrollbarGrab] = C.border2
  c[imgui.Col.ScrollbarGrabHovered] = C.keyEdge
  c[imgui.Col.ScrollbarGrabActive] = C.keyEdge
  c[imgui.Col.TextSelectedBg] = alpha(acc, 0.35)
end

local function loadFonts()
  local io = imgui.GetIO()
  io.IniFilename = nil
  local cyr = io.Fonts:GetGlyphRangesCyrillic()
  if fa then iconRanges = imgui.new.ImWchar[3](fa.min_range, fa.max_range, 0) end

  local function mergeIcons(size)
    if not fa then return end
    local cfg = imgui.ImFontConfig()
    cfg.MergeMode = true
    cfg.PixelSnapH = true
    io.Fonts:AddFontFromMemoryCompressedBase85TTF(fa.get_font_data_base85('solid'), size, cfg, iconRanges)
  end

  -- иконки в шрифт по умолчанию, который mimgui уже загрузил
  mergeIcons(14)

  local dir = getWorkingDirectory() .. '\\resource\\trinivoice\\'
  local fallback = getFolderPath(0x14) .. '\\trebucbd.ttf'
  local function add(file, size, withIcons)
    local path = dir .. file
    if not doesFileExist(path) then path = fallback end
    if not doesFileExist(path) then return nil end
    local f = io.Fonts:AddFontFromFileTTF(path, size, nil, cyr)
    if withIcons then mergeIcons(size) end
    return f
  end
  fonts.regular = add('Montserrat-Medium.ttf', 15, true)
  fonts.bold = add('Montserrat-SemiBold.ttf', 15, true)
  fonts.small = add('Montserrat-Medium.ttf', 12, false)
  fonts.title = add('Montserrat-Bold.ttf', 22, false)
  if fa then
    -- крупные иконки для плиток и пустых состояний
    local cfg = imgui.ImFontConfig()
    cfg.PixelSnapH = true
    fonts.icon = io.Fonts:AddFontFromMemoryCompressedBase85TTF(fa.get_font_data_base85('solid'), 20, cfg, iconRanges)
  end
  if fonts.regular then io.FontDefault = fonts.regular end
end

local function drawWindow()
  local st = ctx.status()
  acc = hex(ctx.cfg.main.accent)
  dt = imgui.GetIO().DeltaTime
  updateMeter(st)

  local sw, sh = getScreenResolution()
  imgui.SetNextWindowPos(V(sw / 2, sh / 2), imgui.Cond.FirstUseEver, V(0.5, 0.5))
  imgui.SetNextWindowSize(V(W, H), imgui.Cond.Always)
  imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(0, 0))
  local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
    + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
  if imgui.Begin('TriniVoice##main', show, flags) then
    dl = imgui.GetWindowDrawList()
    org = imgui.GetWindowPos()
    local players = ctx.players()
    drawSidebar(st, #players)
    if page == 1 then pageHome(st)
    elseif page == 2 then pagePlayers(st)
    elseif page == 3 then pageSound(st)
    elseif page == 4 then pageRadio(st)
    else pageServer(st) end
  end
  imgui.End()
  imgui.PopStyleVar(1)
end

---------------------------------------------------------------------------
-- API для trinivoice.lua
---------------------------------------------------------------------------

function M.init(c)
  ctx = c
  imgui.OnInitialize(function()
    applyStyle()
    local ok, err = pcall(loadFonts)
    if not ok then print('[TriniVoice] шрифты не загружены: ' .. tostring(err)) end
  end)
  imgui.OnFrame(function() return show[0] and not isPauseMenuActive() end, function(self)
    self.LockPlayer = imgui.GetIO().WantTextInput
    drawWindow()
  end)
end

function M.open()
  local m = ctx.cfg.main
  imgui.StrCopy(hostBuf, m.host)
  imgui.StrCopy(portBuf, tostring(m.port))
  imgui.StrCopy(freqBuf, ('%.1f'):format(tonumber(m.radio_freq) or 100))
  imgui.StrCopy(passBuf, tostring(m.radio_pass or ''))
  reportTarget = nil
  show[0] = true
end
function M.close() show[0] = false end
function M.toggle() if show[0] then M.close() else M.open() end end
function M.isOpen() return show[0] end
function M.hasIcons() return fa ~= nil end
-- true, пока игрок печатает в поле меню: клавиша разговора не должна срабатывать
function M.wantsText() return show[0] and imgui.GetIO().WantTextInput end

return M
