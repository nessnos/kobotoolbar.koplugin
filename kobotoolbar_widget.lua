--[[--
The overlay shown by the Kobo-style toolbar.

A transparent full-screen InputContainer that paints two white panels over the
page, like Kobo's reading toolbar:

  top     22:26                  ─                      ⌔ 82% ▭
          ←  Back to Home               ☼   Aa   ılı   ⚙   •••
  ─────────────────────────────────────────────────────────────
                       (the page shows through)
  ─────────────────────────────────────────────────────────────
  bottom                  PAGE 336 OF 1006
          |<   ━━━━━━━━━━━━◎──────────────────────────────   >|
          ☰  Chapter Twelve                              🗎   ⌕

A tap on the page (outside the panels) closes it.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local Font = require("ui/font")
local datetime = require("datetime")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext
local Fonts = require("kobotoolbar_fonts")
local Stats = require("kobotoolbar_stats")
local Screen = Device.screen

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local DARK = Blitbuffer.COLOR_DARK_GRAY
local GRAY = Blitbuffer.COLOR_GRAY
local LIGHT = Blitbuffer.COLOR_LIGHT_GRAY

local function S(v) return Screen:scaleBySize(v) end

local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./")
local function iconFile(name)
    if name:sub(1, 1) == "/" then return name end
    return PLUGIN_DIR .. "icons/" .. name
end

-- ---------------------------------------------------------------------------
-- Drawing helpers
-- ---------------------------------------------------------------------------

local icon_cache = {}

--- Paints an SVG icon (black line drawing) in a size×size box at x, y.
--- With `white`, it's drawn white (for the pressed / open state).
local function paintIcon(bb, name, x, y, size, white)
    local key = name .. "@" .. size
    local iw = icon_cache[key]
    if iw == nil then
        iw = ImageWidget:new{ file = iconFile(name), width = size, height = size, alpha = true, is_icon = true }
        local ok = pcall(function() iw:_render() end)
        if not ok then iw = false end
        icon_cache[key] = iw
    end
    if not iw then return end
    if white then
        -- draw it into a scratch buffer, then use it as a mask
        local tmp = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
        tmp:fill(WHITE)
        iw:paintTo(tmp, 0, 0)
        for yy = 0, size - 1 do
            for xx = 0, size - 1 do
                local v = tmp:getPixel(xx, yy):getColor8().a
                if v < 128 then bb:setPixel(x + xx, y + yy, WHITE) end
            end
        end
        tmp:free()
    else
        iw:paintTo(bb, x, y)
    end
end

local function textWidth(text, face)
    local t = TextWidget:new{ text = text, face = face }
    local w = t:getSize().w
    t:free()
    return w
end

--- Text vertically centred in a box of height h, starting at x. Returns its width.
--- `bold`: true = KOReader's bold; "synth" = a font without a bold file: KOReader's
--- own emboldening is very faint there, so the text is also drawn a second time,
--- shifted right by about 1/30 of the font size.
local function drawText(bb, text, face, x, y, h, color, max_w, bold)
    local shift = 0
    if bold == "synth" then
        shift = math.max(1, math.floor((face.size or 20) / 30 + 0.5))
        if max_w then max_w = max_w - shift end
    end
    local t = TextWidget:new{ text = text, face = face, fgcolor = color or BLACK,
        max_width = max_w, truncate_with_ellipsis = max_w ~= nil, bold = bold and true or nil }
    local sz = t:getSize()
    local ty = y + math.floor((h - sz.h) / 2)
    t:paintTo(bb, x, ty)
    if shift > 0 then t:paintTo(bb, x + shift, ty) end
    t:free()
    return sz.w + shift
end

local function disc(bb, cx, cy, r, color)
    bb:paintRoundedRect(cx - r, cy - r, r * 2, r * 2, color, r)
end

local function ring(bb, cx, cy, r, t, color)
    bb:paintBorder(cx - r, cy - r, r * 2, r * 2, t, color, r)
end

--- KoboUI's battery (infra/kui_battery.lua): an outlined body with nearly
--- square corners, the cap on the right, filled from the left; a small bolt
--- while charging. Same drawing, so it looks exactly like KoboUI's status bar.
--- `outline` = line thickness. Returns its width.
local function paintBattery(bb, x, y, h, level, charging, outline)
    local w = math.floor(h * 2.1)
    local b = outline or math.max(1, math.floor(h / 8))
    local cap_w = math.max(2, math.floor(h / 6))
    local body_w = w - cap_w
    local r = math.max(0, math.floor(h / 14))
    if r > 0 then bb:paintBorder(x, y, body_w, h, b, BLACK, r) else bb:paintBorder(x, y, body_w, h, b, BLACK) end
    local cap_h = math.floor(h / 2)
    bb:paintRect(x + body_w, y + math.floor((h - cap_h) / 2), cap_w, cap_h, BLACK)
    local gap = b + math.max(1, math.floor(h / 10))
    local inner_w = body_w - gap * 2
    local lvl = math.max(0, math.min(100, tonumber(level) or 0))
    local fill = math.floor(inner_w * lvl / 100 + 0.5)
    if fill > 0 then
        bb:paintRect(x + gap, y + gap, fill, h - gap * 2, BLACK)
    end
    if charging then
        local cx = x + math.floor(body_w / 2)
        local top, bot = y + gap, y + h - gap
        local mid = math.floor((top + bot) / 2)
        local col = fill > inner_w / 2 and WHITE or BLACK
        for yy = top, bot - 1 do
            local off
            if yy < mid then off = math.floor((mid - yy) / 2) else off = -math.floor((yy - mid) / 2) end
            bb:paintRect(cx + off - 1, yy, math.max(2, math.floor(h / 7)), 1, col)
        end
    end
    return w
end

--- The battery's height and outline: the very same as in KoboUI's status bar
--- (computed like kbo_statusbar.lua does, so its Status Bar size setting is
--- followed too); without KoboUI, the size it has there by default.
local function batterySize()
    local ok, h, outline = pcall(function()
        local TB = require("screens/sui_topbar")
        local bar_h = TB.TOPBAR_H() + TB.TOPBAR_PAD_TOP() + TB.TOPBAR_PAD_BOT()
        local size = math.max(S(14), math.floor(bar_h * 0.55))
        return math.floor(size * 0.46), math.max(1, math.floor(size / 24 + 0.5))
    end)
    if ok and h and h > 0 then return h, outline end
    local size = S(28)
    return math.floor(size * 0.46), math.max(1, math.floor(size / 24 + 0.5))
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

local function koboDuration(seconds)
    local mins = math.floor(seconds / 60 + 0.5)
    if mins < 1 then return _("less than a minute") end
    if mins < 60 then return T(N_("1 min", "%1 mins", mins), mins) end
    local h = math.floor(mins / 60)
    local m = mins % 60
    local hs = T(N_("1 hour", "%1 hours", h), h)
    if m == 0 then return hs end
    return hs .. " " .. T(N_("1 min", "%1 mins", m), m)
end

-- ---------------------------------------------------------------------------
-- Kobo-style drop-down (the … menu)
-- ---------------------------------------------------------------------------

local KoboDropdown = InputContainer:extend{
    name = "kobotoolbar_dropdown",
    items = nil,    -- { { text=, callback=, separator=, enabled= }, ... }
    anchor = nil,   -- Geom of the button that opened it
}

function KoboDropdown:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.face = Fonts.face(18)
    self.row_h = S(54)
    self.pad = S(24)
    self.border = math.max(2, S(1.5))
    local widest = 0
    for _i, it in ipairs(self.items) do
        widest = math.max(widest, textWidth(it.text, self.face))
    end
    local w = math.max(math.floor(sw * 0.45), widest + 2 * self.pad + S(10))
    w = math.min(w, sw - 2 * S(12))
    local h = 2 * S(6)
    for _i, it in ipairs(self.items) do h = h + self.row_h end
    local a = self.anchor or Geom:new{ x = sw - S(50), y = S(60), w = S(40), h = S(40) }
    local acx = a.x + math.floor(a.w / 2)
    self.caret_h = S(12)
    local x = math.max(S(12), math.min(sw - S(12) - w, acx + S(28) - w))
    local y = a.y + a.h + self.caret_h
    h = math.min(h, sh - y - S(10))
    self.card = Geom:new{ x = x, y = y, w = w, h = h }
    self.acx = math.max(x + S(20), math.min(x + w - S(20), acx))
    self.ges_events = {
        DDTap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        DDAny = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        DDHold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function KoboDropdown:region()
    local c = self.card
    return Geom:new{ x = c.x, y = c.y - self.caret_h, w = c.w, h = c.h + self.caret_h }
end

function KoboDropdown:paintTo(bb)
    local c, bw = self.card, self.border
    bb:paintRect(c.x, c.y, c.w, c.h, WHITE)
    bb:paintBorder(c.x, c.y, c.w, c.h, bw, BLACK)
    -- caret pointing at the button
    local ch = self.caret_h
    for i = 0, ch do
        local yy = c.y - ch + i
        bb:paintRect(self.acx - i, yy, i * 2 + 1, 1, BLACK)
        if i - bw > 0 then bb:paintRect(self.acx - i + bw, yy, (i - bw) * 2 + 1, 1, WHITE) end
    end
    bb:paintRect(self.acx - ch + bw, c.y, (ch - bw) * 2 + 1, bw, WHITE)
    local y = c.y + S(6)
    self.row_rects = {}
    for i, it in ipairs(self.items) do
        local r = Geom:new{ x = c.x + bw, y = y, w = c.w - 2 * bw, h = self.row_h }
        self.row_rects[i] = r
        if self.pressed == i then bb:paintRect(r.x, r.y, r.w, r.h, BLACK) end
        local col = self.pressed == i and WHITE or (it.enabled == false and GRAY or BLACK)
        drawText(bb, it.text, self.face, r.x + self.pad, r.y, r.h, col, r.w - 2 * self.pad)
        if it.separator and i < #self.items then
            bb:paintRect(r.x + self.pad, y + self.row_h - 1, r.w - 2 * self.pad, math.max(1, S(1)), LIGHT)
        end
        y = y + self.row_h
    end
end

function KoboDropdown:onShow()
    UIManager:setDirty(self, function() return "ui", self:region() end)
    return true
end

function KoboDropdown:onCloseWidget()
    local r = self:region()
    UIManager:setDirty(nil, function() return "ui", r end)
end

function KoboDropdown:onDDTap(_args, ges)
    local c = self.card
    if ges.pos:intersectWith(self:region()) then
        for i, r in ipairs(self.row_rects or {}) do
            if ges.pos:intersectWith(r) then
                local it = self.items[i]
                if it.enabled ~= false and it.callback then
                    if G_reader_settings:nilOrTrue("flash_ui") then
                        self.pressed = i
                        UIManager:setDirty(self, "fast", r)
                        UIManager:forceRePaint()
                        UIManager:yieldToEPDC()
                        self.pressed = nil
                    end
                    UIManager:close(self)
                    it.callback()
                end
                return true
            end
        end
        return true
    end
    UIManager:close(self)
    if self.on_outside then self.on_outside(ges) end
    return true
end

function KoboDropdown:onDDAny() UIManager:close(self) return true end
function KoboDropdown:onDDHold() return true end
function KoboDropdown:onClose() UIManager:close(self) return true end

-- ---------------------------------------------------------------------------
-- The overlay
-- ---------------------------------------------------------------------------

local KoboToolbarWidget = InputContainer:extend{
    name = "kobotoolbar",
    ui = nil,
    plugin = nil,
}

function KoboToolbarWidget:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.pad = S(16)
    self.ges_events = {}
    for _i, g in ipairs{ "tap", "touch", "pan", "hold", "hold_pan", "pan_release", "hold_release", "swipe", "double_tap" } do
        self.ges_events["Hud_" .. g] = { GestureRange:new{ ges = g, range = self.dimen }, event = "HudGesture" }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.plugin:onFlushSettings() -- custom-button actions picked in the menu
    self.page_count = self.ui.document:getPageCount()

    -- sizes (Kobo Clara Colour: 1072 × 1448, 300 dpi)
    -- (measured on a photo of Kobo's own toolbar)
    self.status_y = S(2)
    self.status_h = S(26)
    self.bar_h = S(46)
    self.icon_sz = S(27)
    self.cell_w = S(54)
    self.top_h = self.status_y + self.status_h + self.bar_h + S(1)
    self.info_top = S(22)
    self.info_h = S(36)
    self.slider_h = S(52)
    self.row_h = S(44)
    self.bottom_h = self.info_top + self.info_h + self.slider_h + self.row_h + S(17)

    self.f_clock = Fonts.face(16)  -- the clock
    self.f_pct = Fonts.face(15)    -- battery percentage
    -- "Back to Home": the font's own bold, a little bigger than the chapter name
    self.f_back, self.back_bold = Fonts.boldFace(19.5)
    self.f_info = Fonts.face(16)
    self.f_chapter, self.chapter_bold = Fonts.boldFace(18)
    self.f_aa = Font:getFace("NotoSerif-Regular.ttf", 22)

    self.top_dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.top_h }
    self.bottom_dimen = Geom:new{ x = 0, y = self.screen_h - self.bottom_h, w = self.screen_w, h = self.bottom_h }
    -- Kobo's reading-stats panel (ılı button), hanging under the toolbar
    self.stats_dimen = Geom:new{ x = 0, y = self.top_h, w = self.screen_w, h = Stats.height() }
    self.rects = {}
end

function KoboToolbarWidget:getSize()
    return self.dimen
end

-- ------------------------------------------------------------ page maths

function KoboToolbarWidget:pctForPage(page)
    if self.page_count <= 1 then return 0 end
    return (page - 1) / (self.page_count - 1)
end

function KoboToolbarWidget:pageForPct(pct)
    local p = 1 + math.floor(pct * (self.page_count - 1) + 0.5)
    return math.max(1, math.min(self.page_count, p))
end

function KoboToolbarWidget:currentPage()
    return self.ui:getCurrentPage()
end

function KoboToolbarWidget:shownPage()
    return self.preview_page or self:currentPage()
end

-- ------------------------------------------------------------ painting

function KoboToolbarWidget:paintTo(bb, x, y)
    self.rects = {}
    self:paintTop(bb)
    if self.stats_open then
        local ok, res = pcall(Stats.paint, bb, self.ui, self:currentPage(), self.top_h, self:statsView())
        if ok then
            self.stats_rects = res
        else
            logger.warn("kobotoolbar: stats panel failed:", res)
            self.stats_rects = {}
        end
        return
    end
    self:paintBottom(bb)
    self:paintPill(bb)
end

function KoboToolbarWidget:paintTop(bb)
    local W = self.screen_w
    bb:paintRect(0, 0, W, self.top_h, WHITE)
    local pad = self.pad
    -- status bar: clock | grabber | Wi-Fi, %, battery
    local sy = self.status_y
    local sh = self.status_h
    local clock = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    drawText(bb, clock, self.f_clock, pad + S(6), sy, sh, BLACK)
    -- the grabber: a short grey line in the middle, at the clock's height
    local gw = S(32)
    bb:paintRect(math.floor((W - gw) / 2), sy + math.floor(sh / 2), gw, math.max(1, S(1)), GRAY)
    local rx = W - pad - S(6)
    if Device:hasBattery() then
        local ok, lvl, charging = pcall(function()
            local powerd = Device:getPowerDevice()
            return powerd:getCapacity(), powerd:isCharging()
        end)
        if ok and type(lvl) == "number" then
            local bh, outline = batterySize()
            local bw = math.floor(bh * 2.1)
            rx = rx - bw
            paintBattery(bb, rx, sy + math.floor((sh - bh) / 2), bh, lvl, charging, outline)
            if self.plugin.settings.battery_pct then
                local t = lvl .. "%"
                local tw = textWidth(t, self.f_pct)
                rx = rx - S(6) - tw
                drawText(bb, t, self.f_pct, rx, sy, sh, BLACK)
            end
        end
    end
    if self.plugin.settings.show_wifi and Device:hasWifiToggle() then
        local ok, on = pcall(function() return require("ui/network/manager"):isWifiOn() end)
        if ok and on then
            local isz = S(17)
            rx = rx - S(14) - isz
            paintIcon(bb, "wifi.svg", rx, sy + math.floor((sh - isz) / 2), isz)
        end
    end
    self.rects.status = Geom:new{ x = 0, y = 0, w = W, h = sy + sh }

    -- toolbar row: ← Back to Home …  buttons
    local by = sy + sh
    local bh = self.bar_h
    local ax = pad + S(4)
    local asz = S(23)
    paintIcon(bb, "back.svg", ax, by + math.floor((bh - asz) / 2), asz)
    local label = self.plugin:getBackLabel()
    local tx = ax + asz + S(16)
    local lw = drawText(bb, label, self.f_back, tx, by, bh, BLACK, math.floor(W * 0.5), self.back_bold)
    self.rects.back = Geom:new{ x = 0, y = by, w = tx + lw + S(10), h = bh }

    -- buttons, right-aligned; "…" ends right at the margin
    local shown = {}
    for _i, b in ipairs(self.plugin:getButtons()) do
        if not b.hidden then table.insert(shown, b) end
    end
    local cx = W - S(3) - #shown * self.cell_w
    self.button_rects = {}
    for _i, b in ipairs(shown) do
        local r = Geom:new{ x = cx, y = by, w = self.cell_w, h = bh }
        table.insert(self.button_rects, { rect = r, button = b })
        self:paintButton(bb, b, r, self.open_button == b.id)
        cx = cx + self.cell_w
    end
    -- the line under the toolbar
    bb:paintRect(0, self.top_h - math.max(1, S(1)), W, math.max(1, S(1)), BLACK)
end

function KoboToolbarWidget:paintButton(bb, b, r, inverted)
    local sz = self.icon_sz
    local cx, cy = r.x + math.floor(r.w / 2), r.y + math.floor(r.h / 2)
    if inverted then
        disc(bb, cx, cy, math.floor(math.min(r.w, r.h) / 2) - S(4), BLACK)
    end
    local id = b.id
    if id == "font" and not b.icon then
        local face = self.f_aa
        local t = TextWidget:new{ text = "Aa", face = face, fgcolor = inverted and WHITE or BLACK }
        local ts = t:getSize()
        t:paintTo(bb, cx - math.floor(ts.w / 2), cy - math.floor(ts.h / 2))
        t:free()
        return
    end
    if id == "more" and not b.icon then
        local d = math.max(3, S(3.6))
        local gap = S(10)
        for i = -1, 1 do
            disc(bb, cx + i * gap, cy, math.floor(d / 2 + 0.5), inverted and WHITE or BLACK)
        end
        return
    end
    local name = b.icon or ({ light = "sun.svg", stats = "stats.svg", settings = "gear.svg" })[id] or "line/star.svg"
    local isz = (id == "light" and not b.icon) and math.floor(sz * 1.08) or sz
    paintIcon(bb, name, cx - math.floor(isz / 2), cy - math.floor(isz / 2), isz, inverted)
end

function KoboToolbarWidget:paintBottom(bb)
    local W, H = self.screen_w, self.screen_h
    local y0 = H - self.bottom_h
    local pad = self.pad
    bb:paintRect(0, y0, W, self.bottom_h, WHITE)
    bb:paintRect(0, y0, W, math.max(1, S(1)), BLACK)
    local page = self:shownPage()

    -- PAGE 336 OF 1006 (tap to switch)
    local iy = y0 + self.info_top
    local info = Fonts.caps(self:getInfoLine(page))
    local iw = textWidth(info, self.f_info)
    drawText(bb, info, self.f_info, math.floor((W - iw) / 2), iy, self.info_h, BLACK)
    self.rects.info = Geom:new{ x = math.floor((W - iw) / 2) - S(20), y = iy, w = iw + S(40), h = self.info_h }

    -- |<  ━━━━◎─────  >|
    local sy = iy + self.info_h
    local sh = self.slider_h
    local ssz = S(22)
    local cell = S(46)
    local lx = pad + S(10)
    paintIcon(bb, "skip_start.svg", lx + math.floor((cell - ssz) / 2), sy + math.floor((sh - ssz) / 2), ssz)
    self.rects.prev = Geom:new{ x = 0, y = sy, w = lx + cell, h = sh }
    local rx = W - pad - S(10) - cell
    paintIcon(bb, "skip_end.svg", rx + math.floor((cell - ssz) / 2), sy + math.floor((sh - ssz) / 2), ssz)
    self.rects.next = Geom:new{ x = rx, y = sy, w = W - rx, h = sh }
    local knob_r = S(13)
    local track_x0 = lx + cell + S(8) + knob_r
    local track_x1 = rx - S(8) - knob_r
    self.slider = { x0 = track_x0, x1 = track_x1, y = sy, h = sh, r = knob_r }
    local cy = sy + math.floor(sh / 2)
    local thin = math.max(1, S(1))
    local thick = math.max(3, S(2.5))
    bb:paintRect(track_x0, cy - math.floor(thin / 2), track_x1 - track_x0, thin, DARK)
    if self.plugin.settings.show_ticks then
        local th = S(8)
        for _i, p in ipairs(self.ui.toc:getTocTicksFlattened() or {}) do
            local tx = self:xForPct(self:pctForPage(p))
            bb:paintRect(tx, cy - math.floor(th / 2), thin, th, GRAY)
        end
    end
    local kx = self:xForPct(self:pctForPage(page))
    if kx > track_x0 then
        bb:paintRect(track_x0, cy - math.floor(thick / 2), kx - track_x0, thick, BLACK)
    end
    -- where you were before skimming: a small mark on the track
    local origin_page = self.plugin:getOriginPage()
    if origin_page and origin_page ~= page then
        local ox = self:xForPct(self:pctForPage(origin_page))
        local mh = S(14)
        bb:paintRect(ox - S(1), cy - math.floor(mh / 2), math.max(2, S(2)), mh, BLACK)
    end
    -- knob: white disc, black ring, thin inner ring (black while dragging)
    disc(bb, kx, cy, knob_r, BLACK)
    if self.dragging then
        ring(bb, kx, cy, math.floor(knob_r * 0.55), math.max(1, S(1)), WHITE)
    else
        disc(bb, kx, cy, knob_r - math.max(2, S(1.6)), WHITE)
        ring(bb, kx, cy, math.floor(knob_r * 0.6), math.max(1, S(1.2)), BLACK)
    end

    -- ☰ Chapter Twelve                    🗎  ⌕
    local ry = sy + sh
    local rh = self.row_h
    local isz = S(25)
    paintIcon(bb, "toc.svg", pad + S(14), ry + math.floor((rh - isz) / 2), isz)
    local sx = W - pad - S(20) - isz
    paintIcon(bb, "search.svg", sx, ry + math.floor((rh - isz) / 2), isz)
    self.rects.search = Geom:new{ x = sx - S(14), y = ry, w = W - sx + S(14), h = rh }
    local nx = sx - S(30) - isz
    paintIcon(bb, "notes.svg", nx, ry + math.floor((rh - isz) / 2), isz)
    self.rects.notes = Geom:new{ x = nx - S(14), y = ry, w = isz + S(28), h = rh }
    local chapter = self.ui.toc:getTocTitleByPage(page) or ""
    if chapter == "" then chapter = self.ui.doc_props and self.ui.doc_props.display_title or "" end
    local cx = pad + S(14) + isz + S(20)
    drawText(bb, chapter, self.f_chapter, cx, ry, rh, BLACK, nx - S(24) - cx, self.chapter_bold)
    self.rects.toc = Geom:new{ x = 0, y = ry, w = nx - S(16), h = rh }
end

function KoboToolbarWidget:xForPct(pct)
    local s = self.slider
    return math.floor(s.x0 + (s.x1 - s.x0) * math.max(0, math.min(1, pct)) + 0.5)
end

function KoboToolbarWidget:pctForX(x)
    local s = self.slider
    if not s or s.x1 <= s.x0 then return 0 end
    return math.max(0, math.min(1, (x - s.x0) / (s.x1 - s.x0)))
end

--- "Return to page 336": a pill floating just above the bottom panel, once you
--- have moved away with the slider or the chapter buttons.
function KoboToolbarWidget:pillRect()
    local origin_page = self.plugin:getOriginPage()
    if not origin_page or origin_page == self:shownPage() then return nil end
    local label = origin_page
    local pagemap = self.ui.pagemap
    if pagemap and pagemap:wantsPageLabels() and self.plugin.origin and self.plugin.origin.label then
        label = self.plugin.origin.label
    end
    local text = Fonts.caps(T(_("Return to page %1"), label))
    local tw = textWidth(text, self.f_info)
    local isz = S(18)
    local h = S(40)
    local w = S(18) + isz + S(10) + tw + S(22)
    local x = math.floor((self.screen_w - w) / 2)
    local y = self.screen_h - self.bottom_h - h - S(12)
    return Geom:new{ x = x, y = y, w = w, h = h }, text, isz
end

function KoboToolbarWidget:paintPill(bb)
    local r, text, isz = self:pillRect()
    self.rects.pill = r
    if not r then return end
    local rad = math.floor(r.h / 2)
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, WHITE, rad)
    bb:paintBorder(r.x, r.y, r.w, r.h, math.max(1, S(1.2)), BLACK, rad)
    paintIcon(bb, "return.svg", r.x + S(18), r.y + math.floor((r.h - isz) / 2), isz)
    drawText(bb, text, self.f_info, r.x + S(18) + isz + S(10), r.y, r.h, BLACK)
end

-- ------------------------------------------------------------ info line

function KoboToolbarWidget:getInfoLine(page)
    local mode = self.plugin.settings.info_mode or "page"
    local previewing = self.preview_page ~= nil and self.preview_page ~= self:currentPage()
    local doc = self.ui.document
    local total = self.page_count
    local chapter_left = self.ui.toc:getChapterPagesLeft(page, true)
    local book_left = doc:getTotalPagesLeft(page)
    if chapter_left == nil then chapter_left = book_left end
    local stats = self.ui.statistics
    local avg = stats and stats.settings and stats.settings.is_enabled and stats.avg_time
    if avg and (avg ~= avg or avg <= 0) then avg = nil end
    if (mode == "chapter_time" or mode == "book_time") and not avg then
        -- no reading statistics yet: pages instead
        mode = mode == "chapter_time" and "chapter_pages" or "page"
    end
    if mode == "chapter_pages" then
        local n = chapter_left + 1
        return T(N_("1 page left in chapter", "%1 pages left in chapter", n), n)
    elseif mode == "chapter_time" then
        return T(_("%1 left in chapter"), koboDuration((chapter_left + 1) * avg))
    elseif mode == "book_time" then
        return T(_("%1 left in book"), koboDuration((book_left + 1) * avg))
    elseif mode == "percent" then
        return T(_("%1% read"), math.floor(page / total * 100))
    end
    local pagemap = self.ui.pagemap
    if not previewing and pagemap and pagemap:wantsPageLabels() then
        return T(_("Page %1 of %2"), pagemap:getCurrentPageLabel(true), pagemap:getLastPageLabel(true))
    end
    return T(_("Page %1 of %2"), page, total)
end

function KoboToolbarWidget:cycleInfoMode()
    local modes = self.plugin.INFO_MODES
    local cur = self.plugin.settings.info_mode or "page"
    local idx = 1
    for i, m in ipairs(modes) do if m == cur then idx = i break end end
    self.plugin.settings.info_mode = modes[idx % #modes + 1]
    self.plugin:saveSettings()
    self:refresh()
end

-- ------------------------------------------------------------ showing / refresh

function KoboToolbarWidget:onShow()
    UIManager:setDirty(self, function() return "ui", self.top_dimen end)
    UIManager:setDirty(self, function() return "ui", self.bottom_dimen end)
    return true
end

--- Repaint the bottom (page changed, slider moved…). The pill floats over the
--- page, so when it goes away the reader repaints underneath it.
function KoboToolbarWidget:refresh(refresh_type)
    if self.stats_open then
        UIManager:setDirty(self, refresh_type or "ui", self.stats_dimen)
        return
    end
    local old_pill = self.rects.pill
    local new_pill = self:pillRect()
    local region = self.bottom_dimen
    if old_pill then region = region:combine(old_pill) end
    if new_pill then region = region:combine(new_pill) end
    -- (the reader repaints too when the pill goes away, and we paint over it)
    UIManager:setDirty(old_pill and not new_pill and self.ui or self, refresh_type or "ui", region)
end

function KoboToolbarWidget:refreshTop()
    UIManager:setDirty(self, "ui", self.top_dimen)
end

function KoboToolbarWidget:onCloseWidget()
    self.closed = true
    local top, bottom = self.top_dimen, self.bottom_dimen
    local pill = self.rects.pill
    if pill then bottom = bottom:combine(pill) end
    if self.stats_open then top = top:combine(self.stats_dimen) end
    UIManager:setDirty(nil, function() return "ui", top end)
    UIManager:setDirty(nil, function() return "ui", bottom end)
    if self.plugin then self.plugin:onToolbarClosed(self) end
end

function KoboToolbarWidget:onClose()
    UIManager:close(self)
    return true
end

function KoboToolbarWidget:closeAnd(fn)
    UIManager:close(self)
    if fn then
        UIManager:nextTick(function()
            local ok, err = pcall(fn)
            if not ok then logger.warn("kobotoolbar: action failed:", err) end
        end)
    end
end

function KoboToolbarWidget:openMainMenu()
    local ui = self.ui
    self:closeAnd(function() if ui.menu then ui.menu:onShowMenu() end end)
end

--- Same as swiping down from the top while reading: KOReader's own handler.
function KoboToolbarWidget:openMenuFromSwipe(ev)
    local ui = self.ui
    UIManager:close(self)
    local menu = ui.menu
    if not menu then return end
    local swipe_ev = { ges = "swipe", direction = "south", pos = ev.start_pos or ev.pos }
    local ok, handled = pcall(menu.onSwipeShowMenu, menu, swipe_ev)
    if not (ok and handled) then menu:onShowMenu() end
end

-- ------------------------------------------------------------ buttons

function KoboToolbarWidget:setOpenButton(id)
    self.open_button = id
    self:refreshTop()
end

function KoboToolbarWidget:onButton(b, rect)
    local id = b.id
    local ui = self.ui
    if self.stats_open and id ~= "stats" then
        -- another button: the stats panel goes away first
        self:showStats(false)
    end
    if b.custom then
        local action = b.action
        if type(action) == "table" and next(action) ~= nil then
            self:closeAnd(function() Dispatcher:execute(action) end)
        else
            UIManager:show(require("ui/widget/infomessage"):new{
                text = T(_("\"%1\" has no action yet. Choose one in the toolbar settings: Toolbar buttons."), self.plugin:buttonLabel(b)),
                timeout = 3,
            })
        end
    elseif id == "light" then
        self:openLightPanel(rect)
    elseif id == "font" then
        self:closeAnd(function() ui:handleEvent(Event:new("ShowConfigMenu")) end)
    elseif id == "stats" then
        if self.plugin.settings.stats_button == "koreader" then
            self:openKOReaderStats()
        else
            self:showStats(not self.stats_open)
        end
    elseif id == "settings" then
        self:openMainMenu()
    elseif id == "more" then
        self:showMoreMenu(rect)
    end
end

--- KoboUI's Light panel (brightness, natural light, dark mode) hanging from the
--- ☼ button, like on Kobo; KOReader's frontlight dialog without KoboUI.
function KoboToolbarWidget:openLightPanel(rect)
    local okP, Panels = pcall(require, "screens/kbo_panels")
    local okD, D = pcall(require, "screens/kbo_dropdown")
    local spec = okP and okD and type(Panels) == "table" and Panels.spec and Panels.spec("brightness")
    if spec and D.DropDown then
        local ok, err = pcall(function()
            local dd = D.DropDown:new{
                anchor = rect,
                width = spec.width,
                build = spec.build,
                paint_anchor = function(bb, r) self:paintButton(bb, { id = "light" }, r, true) end,
                on_close = function()
                    if spec.on_close then pcall(spec.on_close) end
                    if not self.closed then self:setOpenButton(nil) end
                end,
            }
            self.open_button = "light"
            dd:show()
            if spec.on_open then UIManager:nextTick(function() pcall(spec.on_open, dd) end) end
        end)
        if ok then return end
        logger.warn("kobotoolbar: KoboUI light panel failed:", err)
        self.open_button = nil
    end
    if Device:hasFrontlight() then
        local ui = self.ui
        self:closeAnd(function() ui:handleEvent(Event:new("ShowFlDialog")) end)
    end
end

function KoboToolbarWidget:openKOReaderStats()
    self:closeAnd(function() Dispatcher:execute({ book_statistics = true }) end)
end

function KoboToolbarWidget:statsView()
    local v = self.plugin.settings.stats_view
    for _i, k in ipairs(Stats.VIEWS) do if k == v then return v end end
    return Stats.VIEWS[1]
end

--- Shows / hides Kobo's stats panel under the toolbar. While it's shown, the
--- bottom panel is hidden (the page shows there), like on Kobo.
function KoboToolbarWidget:showStats(open)
    if (self.stats_open and true or false) == (open and true or false) then return end
    local bottom = self.bottom_dimen
    if self.rects.pill then bottom = bottom:combine(self.rects.pill) end
    self.stats_open = open and true or nil
    self.open_button = open and "stats" or nil
    self.preview_page = nil
    self.dragging = false
    if open then
        -- the page shows again where the bottom panel was
        UIManager:setDirty(self.ui, "ui", bottom)
        UIManager:setDirty(self, "ui", self.top_dimen:combine(self.stats_dimen))
    else
        UIManager:setDirty(self.ui, "ui", self.stats_dimen)
        UIManager:setDirty(self, "ui", self.top_dimen)
        local new_bottom = self.bottom_dimen
        local pill = self:pillRect()
        if pill then new_bottom = new_bottom:combine(pill) end
        UIManager:setDirty(self, "ui", new_bottom)
    end
end

function KoboToolbarWidget:cycleStatsView(dir)
    local views = Stats.VIEWS
    local cur = self:statsView()
    local idx = 1
    for i, v in ipairs(views) do if v == cur then idx = i break end end
    idx = (idx - 1 + dir) % #views + 1
    self.plugin.settings.stats_view = views[idx]
    self.plugin:saveSettings()
    UIManager:setDirty(self, "ui", self.stats_dimen)
end

-- Friendlier names for a few actions in the … menu
local ACTION_LABELS = {
    go_to = _("Go to Page…"),
    book_info = _("Book Details"),
    book_statistics = _("Reading Stats"),
    show_menu = _("KOReader Menu"),
    kobo_toolbar_settings = _("Toolbar Settings"),
}

function KoboToolbarWidget:showMoreMenu(rect)
    local actions = self.plugin:getMoreActions()
    local cfg = actions.settings or {}
    local separators = cfg.quickmenu_separators or {}
    local custom_names = cfg.quickmenu_action_names or {}
    local items = {}
    local unknown = _("Unknown item")
    for k, v in Dispatcher.iter_func(actions) do
        if type(k) == "number" then
            k = v
            v = actions[k]
        end
        if k ~= "settings" and v ~= nil then
            local label = custom_names[k]
            if not label then
                if k == "toggle_bookmark" then
                    local marked = self.ui.bookmark and self.ui.bookmark:isPageBookmarked()
                    label = marked and _("Remove Bookmark") or _("Add Bookmark")
                else
                    label = ACTION_LABELS[k] or Dispatcher:getNameFromItem(k, actions)
                end
            end
            if label ~= unknown then
                local key, value = k, v
                table.insert(items, {
                    text = label,
                    separator = separators[k] and true or nil,
                    callback = function()
                        self:closeAnd(function() Dispatcher:execute({ [key] = value }) end)
                    end,
                })
            end
        end
    end
    if #items == 0 then
        table.insert(items, { text = _("KOReader Menu"), callback = function() self:openMainMenu() end })
    end
    self:setOpenButton("more")
    local dd = KoboDropdown:new{ items = items, anchor = rect }
    local orig_close = dd.onCloseWidget
    dd.onCloseWidget = function(this)
        orig_close(this)
        if not self.closed then self:setOpenButton(nil) end
    end
    UIManager:show(dd)
end

-- ------------------------------------------------------------ navigation

function KoboToolbarWidget:gotoChapter(dir)
    local cur = self:currentPage()
    local target
    if dir > 0 then
        target = self.ui.toc:getNextChapter(cur)
    else
        -- like Kobo: first back to the start of this chapter, then the one before
        target = self.ui.toc:getPreviousChapter(cur)
    end
    if target and target ~= cur then
        self.preview_page = nil
        self.plugin:goToPage(target)
        self:refresh()
    end
end

function KoboToolbarWidget:previewAt(x)
    local page = self:pageForPct(self:pctForX(x))
    if page ~= self.preview_page then
        self.preview_page = page
        self:refresh("fast")
    end
end

function KoboToolbarWidget:commitAt(x)
    self.dragging = false
    local page = self:pageForPct(self:pctForX(x))
    self.preview_page = nil
    if page ~= self:currentPage() then
        self.plugin:goToPage(page)
    end
    self:refresh()
end

--- The reader's page changed while we're shown.
function KoboToolbarWidget:onReaderPageUpdate()
    if self.dragging then return end
    self.page_count = self.ui.document:getPageCount()
    self:refresh()
end

-- ------------------------------------------------------------ gestures

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

function KoboToolbarWidget:inSlider(pos)
    local s = self.slider
    if not s or not pos or self.stats_open then return false end
    local grow = S(10)
    return pos.x >= s.x0 - s.r and pos.x <= s.x1 + s.r and pos.y >= s.y - grow and pos.y < s.y + s.h + grow
end

function KoboToolbarWidget:inPanels(pos)
    if self.stats_open then
        return inside(pos, self.top_dimen) or inside(pos, self.stats_dimen)
    end
    return inside(pos, self.top_dimen) or inside(pos, self.bottom_dimen) or inside(pos, self.rects.pill)
end

function KoboToolbarWidget:statsButtonAt(pos)
    for _i, br in ipairs(self.button_rects or {}) do
        if br.button.id == "stats" and inside(pos, br.rect) then return true end
    end
end

function KoboToolbarWidget:onHudGesture(_args, ev)
    local g, pos = ev.ges, ev.pos
    -- Swipe (or slow drag) down from the top edge: KOReader's menu, as when reading.
    if (g == "swipe" or g == "pan") and ev.direction == "south" and not self.dragging then
        local start = g == "pan" and ev.start_pos or pos
        if start and start.y < self.screen_h / 8 then
            self:openMenuFromSwipe(ev)
            return true
        end
    end
    -- long-press on ılı: KOReader's own book statistics
    if g == "hold" and not self.dragging and self:statsButtonAt(pos) then
        self:openKOReaderStats()
        return true
    end
    -- swipe left / right on the stats panel: the other chart
    if g == "swipe" and self.stats_open and inside(pos, self.stats_dimen) then
        if ev.direction == "west" then self:cycleStatsView(1)
        elseif ev.direction == "east" then self:cycleStatsView(-1) end
        return true
    end
    if g == "touch" then
        if self:inSlider(pos) then
            self.dragging = true
            self:previewAt(pos.x)
        end
    elseif g == "pan" or g == "hold_pan" or g == "hold" then
        if not self.dragging and ev.start_pos and self:inSlider(ev.start_pos) then
            self.dragging = true
        end
        if self.dragging then self:previewAt(pos.x) end
    elseif g == "pan_release" or g == "hold_release" then
        if self.dragging then self:commitAt(pos.x) end
    elseif g == "swipe" then
        if self.dragging or self:inSlider(pos) then
            self:commitAt((ev.end_pos or pos).x)
        elseif not self:inPanels(pos) then
            -- a swipe on the page: close, and let the reader turn the page
            local ui = self.ui
            UIManager:close(self)
            ui:handleEvent(Event:new("Gesture", ev))
        end
    elseif g == "tap" or g == "double_tap" then
        self:onTap(pos)
    end
    return true -- nothing leaks to the page underneath
end

function KoboToolbarWidget:onTap(pos)
    if self.dragging or self:inSlider(pos) then
        self:commitAt(pos.x)
        return
    end
    local r = self.rects
    if self.stats_open and inside(pos, self.stats_dimen) then
        local sr = self.stats_rects or {}
        if inside(pos, sr.prev) then
            self:cycleStatsView(-1)
        elseif inside(pos, sr.next) or inside(pos, sr.chart) then
            self:cycleStatsView(1)
        end
        return
    end
    if inside(pos, r.pill) then
        self.preview_page = nil
        self.plugin:goToOrigin()
        self:refresh()
        return
    end
    if inside(pos, self.top_dimen) then
        for _i, br in ipairs(self.button_rects or {}) do
            if inside(pos, br.rect) then
                self:onButton(br.button, br.rect)
                return
            end
        end
        if inside(pos, r.back) then
            local plugin = self.plugin
            self:closeAnd(function() plugin:goBack() end)
        elseif inside(pos, r.status) then
            self:openMainMenu()
        end
        return
    end
    if inside(pos, self.bottom_dimen) and not self.stats_open then
        local ui = self.ui
        if inside(pos, r.info) then
            self:cycleInfoMode()
        elseif inside(pos, r.prev) then
            self:gotoChapter(-1)
        elseif inside(pos, r.next) then
            self:gotoChapter(1)
        elseif inside(pos, r.search) then
            self:closeAnd(function() ui:handleEvent(Event:new("ShowFulltextSearchInput")) end)
        elseif inside(pos, r.notes) then
            self:closeAnd(function() ui:handleEvent(Event:new("ShowBookmark")) end)
        elseif inside(pos, r.toc) then
            self:closeAnd(function() ui:handleEvent(Event:new("ShowToc")) end)
        end
        return
    end
    -- on the page: close, like Kobo
    UIManager:close(self)
end

KoboToolbarWidget.KoboDropdown = KoboDropdown
KoboToolbarWidget.paintIcon = paintIcon
KoboToolbarWidget.iconFile = iconFile

return KoboToolbarWidget
