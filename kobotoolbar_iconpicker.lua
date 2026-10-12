--[[--
A grid of the toolbar's line icons (icons/line, the same thin icons as
KoboUI's), to pick a custom button's icon. Tap one to choose it; tap outside
the card to cancel. Several pages when the screen is small.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local Fonts = require("kobotoolbar_fonts")
local Screen = Device.screen

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local LIGHT = Blitbuffer.COLOR_LIGHT_GRAY

local function S(v) return Screen:scaleBySize(v) end

local IconPicker = InputContainer:extend{
    current = nil,    -- "line/star.svg"
    on_select = nil,  -- function("line/xxx.svg")
}

function IconPicker:show(opts)
    UIManager:show(IconPicker:new(opts))
end

function IconPicker:init()
    local W = require("kobotoolbar_widget")
    self.paintIcon = W.paintIcon
    local dir = W.iconFile("line")
    self.icons = {}
    for f in lfs.dir(dir) do
        if f:match("%.svg$") then table.insert(self.icons, "line/" .. f) end
    end
    table.sort(self.icons)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.cell = S(60)
    self.isz = S(28)
    self.title_h = S(56)
    self.foot_h = S(52)
    self.cols = math.max(3, math.floor((sw - S(48)) / self.cell))
    local rows_max = math.max(2, math.floor((sh - S(80) - self.title_h - self.foot_h) / self.cell))
    self.rows = math.min(rows_max, math.ceil(#self.icons / self.cols))
    self.per_page = self.cols * self.rows
    self.pages = math.max(1, math.ceil(#self.icons / self.per_page))
    self.page = 1
    for i, name in ipairs(self.icons) do
        if name == self.current then self.page = math.floor((i - 1) / self.per_page) + 1 end
    end
    local w = self.cols * self.cell + S(32)
    local h = self.title_h + self.rows * self.cell + self.foot_h
    self.card = Geom:new{ x = math.floor((sw - w) / 2), y = math.floor((sh - h) / 2), w = w, h = h }
    self.face, self.face_bold = Fonts.boldFace(18)
    self.small = Fonts.face(15)
    self.ges_events = {
        PickTap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        PickSwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function IconPicker:paintTo(bb)
    local c = self.card
    bb:paintRect(c.x, c.y, c.w, c.h, WHITE)
    bb:paintBorder(c.x, c.y, c.w, c.h, math.max(2, S(1.5)), BLACK)
    local TextWidget = require("ui/widget/textwidget")
    local t = TextWidget:new{ text = _("Choose an icon"), face = self.face, bold = self.face_bold and true or nil }
    t:paintTo(bb, c.x + S(20), c.y + math.floor((self.title_h - t:getSize().h) / 2))
    t:free()
    bb:paintRect(c.x, c.y + self.title_h - 1, c.w, math.max(1, S(1)), LIGHT)
    self.cells = {}
    local first = (self.page - 1) * self.per_page
    local gx = c.x + S(16)
    local gy = c.y + self.title_h
    for i = 1, self.per_page do
        local name = self.icons[first + i]
        if not name then break end
        local col = (i - 1) % self.cols
        local row = math.floor((i - 1) / self.cols)
        local r = Geom:new{ x = gx + col * self.cell, y = gy + row * self.cell, w = self.cell, h = self.cell }
        self.cells[i] = { rect = r, name = name }
        local sel = name == self.current
        if sel then
            local rad = math.floor(self.cell / 2) - S(4)
            bb:paintRoundedRect(r.x + math.floor(r.w / 2) - rad, r.y + math.floor(r.h / 2) - rad, rad * 2, rad * 2, BLACK, rad)
        end
        self.paintIcon(bb, name, r.x + math.floor((r.w - self.isz) / 2), r.y + math.floor((r.h - self.isz) / 2), self.isz, sel)
    end
    -- footer: ‹ 1 / 2 ›   (or just the hint)
    local fy = c.y + c.h - self.foot_h
    bb:paintRect(c.x, fy, c.w, math.max(1, S(1)), LIGHT)
    local label = self.pages > 1 and string.format("‹   %d / %d   ›", self.page, self.pages) or _("Tap outside to cancel")
    local f = TextWidget:new{ text = label, face = self.small }
    local fs = f:getSize()
    f:paintTo(bb, c.x + math.floor((c.w - fs.w) / 2), fy + math.floor((self.foot_h - fs.h) / 2))
    f:free()
    self.foot = Geom:new{ x = c.x, y = fy, w = c.w, h = self.foot_h }
end

function IconPicker:onShow()
    UIManager:setDirty(self, function() return "ui", self.card end)
    return true
end

function IconPicker:onCloseWidget()
    local c = self.card
    UIManager:setDirty(nil, function() return "ui", c end)
end

function IconPicker:turn(dir)
    local p = math.max(1, math.min(self.pages, self.page + dir))
    if p ~= self.page then
        self.page = p
        UIManager:setDirty(self, "ui", self.card)
    end
end

function IconPicker:onPickTap(_args, ges)
    local pos = ges.pos
    if not pos:intersectWith(self.card) then
        UIManager:close(self)
        return true
    end
    for _i, cell in ipairs(self.cells or {}) do
        if pos:intersectWith(cell.rect) then
            UIManager:close(self)
            if self.on_select then self.on_select(cell.name) end
            return true
        end
    end
    if self.foot and pos:intersectWith(self.foot) and self.pages > 1 then
        self:turn(pos.x < self.foot.x + self.foot.w / 2 and -1 or 1)
    end
    return true
end

function IconPicker:onPickSwipe(_args, ges)
    if ges.direction == "west" then self:turn(1)
    elseif ges.direction == "east" then self:turn(-1) end
    return true
end

function IconPicker:onClose()
    UIManager:close(self)
    return true
end

return IconPicker
