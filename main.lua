--[[--
Kobo-style toolbar for KOReader (made to go with KoboUI).

Tap the middle of the page (or the top, or the bottom) while reading to show a
Kobo-like overlay over the page:
  * its own status bar: clock, Wi-Fi (when on), battery (and %, if you like);
  * "← Back to Home / My Books" and a row of buttons you can hide, reorder,
    or add to (☼ Aa stats ⚙ … by default);
  * at the bottom: PAGE X OF Y, a progress slider with |< >| chapter jumps,
    and the chapter name with the notes and search buttons.

Swipes are left alone: swiping down from the top still opens KOReader's menu.

@module koplugin.KoboToolbar
--]]

local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local ZONE_ID = "kobotoolbar_tap"
local TOP_TAP_ID = "kobotoolbar_top_tap"
local TOP_EXT_TAP_ID = "kobotoolbar_top_ext_tap"
local BOTTOM_TAP_ID = "kobotoolbar_bottom_tap"
local BOTTOM_EXT_TAP_ID = "kobotoolbar_bottom_ext_tap"

-- Zones that keep priority over ours: links, existing highlights, and the corner
-- taps you set up in Taps and gestures (e.g. the bookmark corner).
local ZONES_BEFORE_US = {
    "tap_link",
    "readerhighlight_tap",
    "readerhighlight_tap_select_mode",
}
local EDGE_ZONES_BEFORE_US = {
    "tap_link",
    "readerhighlight_tap",
    "readerhighlight_tap_select_mode",
    "tap_top_left_corner",
    "tap_top_right_corner",
    "tap_left_bottom_corner",
    "tap_right_bottom_corner",
}
local OUR_ZONES = {
    [ZONE_ID] = ZONES_BEFORE_US,
    [TOP_TAP_ID] = EDGE_ZONES_BEFORE_US,
    [TOP_EXT_TAP_ID] = EDGE_ZONES_BEFORE_US,
    [BOTTOM_TAP_ID] = EDGE_ZONES_BEFORE_US,
    [BOTTOM_EXT_TAP_ID] = EDGE_ZONES_BEFORE_US,
}

-- The middle column of the page (screen ratios). Left and right of it turn pages.
local ZONES = {
    narrow = { x = 1/3, y = 1/8, w = 1/3, h = 3/4 },
    medium = { x = 1/4, y = 1/8, w = 1/2, h = 3/4 },
    wide   = { x = 1/8, y = 1/8, w = 3/4, h = 3/4 },
}
local ZONE_ORDER = { "narrow", "medium", "wide" }

local DEFAULTS = {
    enabled = true,       -- tapping the middle of the page opens the toolbar
    zone = "medium",
    top_tap = true,       -- tapping the top of the page opens the toolbar (not KOReader's menu)
    bottom_tap = true,    -- tapping the bottom of the page opens the toolbar (not KOReader's settings)
    back_target = "auto", -- "auto" (where the book was opened from), "home", "mybooks"
    info_mode = "page",
    show_ticks = false,
    battery_pct = false,
    show_wifi = true,
}

-- Built-in toolbar buttons, in Kobo's order.
local BUILTIN_BUTTONS = { "light", "font", "stats", "settings", "more" }

-- What the … menu offers out of the box (Dispatcher action ids, in order).
local DEFAULT_MORE_ACTIONS = { "toggle_bookmark", "go_to", "book_info", "book_statistics", "show_menu", "kobo_toolbar_settings" }

local function defaultMoreActions()
    local t = { settings = { order = {}, show_as_quickmenu = true, quickmenu_separators = { book_statistics = true } } }
    for _i, id in ipairs(DEFAULT_MORE_ACTIONS) do
        t[id] = true
        table.insert(t.settings.order, id)
    end
    return t
end

-- ---------------------------------------------------------------------------
-- Where the book was opened from (Home screen or My Books)
-- ---------------------------------------------------------------------------
-- Every plugin's main.lua is loaded once at start-up, in the file manager, so
-- this hook is in place before the first book is opened. It looks at what was
-- on screen at the moment a book is opened: KoboUI's Home screen, or anything
-- else (My Books: the library, its Authors / Series / Collections tabs, history…).
local opened_from -- "home" | "mybooks" | nil (not known: opened at start-up)

local function detectOrigin()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return nil end
    for i = 1, #stack do
        local w = stack[i] and stack[i].widget
        -- a book opened from inside a book (history, next in series…): keep the old answer
        if type(w) == "table" and w.name == "ReaderUI" then return nil end
    end
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if type(w) == "table" and not w._parked then
            if w.name == "homescreen" then return "home" end
            if w.name == "filemanager" or w.covers_fullscreen then return "mybooks" end
        end
    end
    return nil
end

do
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and ReaderUI and not ReaderUI._kobotoolbar_origin_hooked and type(ReaderUI.showReader) == "function" then
        ReaderUI._kobotoolbar_origin_hooked = true
        local orig = ReaderUI.showReader
        ReaderUI.showReader = function(...)
            local ok2, where = pcall(detectOrigin)
            if ok2 and where then opened_from = where end
            return orig(...)
        end
    end
end

-- A home-screen plugin built on SimpleUI (KoboUI, KindleUI, SimpleUI).
local function homePlugin(ui)
    for _i, key in ipairs{ "simpleui", "koboui", "kindleui" } do
        local p = ui and ui[key]
        if type(p) == "table" and p.onSimpleUIGoLibrary then return p end
    end
end

local BACK_TARGETS = { "auto", "home", "mybooks" }

local KoboToolbar = WidgetContainer:extend{
    name = "kobotoolbar",
    is_doc_only = true,
}

function KoboToolbar:init()
    self.settings = G_reader_settings:readSetting("kobo_toolbar") or {}
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    if self.settings.more_actions == nil then
        self.settings.more_actions = defaultMoreActions()
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    if Device:isTouchDevice() then
        self:hookZoneRegistration()
        self:registerZones()
    end
    self:hookPageAnimation()
end

function KoboToolbar:saveSettings()
    G_reader_settings:saveSetting("kobo_toolbar", self.settings)
end

function KoboToolbar:onFlushSettings()
    if self.updated then
        self.updated = nil
        self:saveSettings()
    end
end

function KoboToolbar:onDispatcherRegisterActions()
    Dispatcher:registerAction("kobo_toolbar_show", {
        category = "none",
        event = "ShowKoboToolbar",
        title = _("Kobo-style toolbar"),
        reader = true,
    })
    Dispatcher:registerAction("kobo_toolbar_settings", {
        category = "none",
        event = "ShowKoboToolbarSettings",
        title = _("Kobo-style toolbar: settings"),
        reader = true,
    })
end

-- ------------------------------------------------------------ Back to …

function KoboToolbar:getHomePlugin()
    return homePlugin(self.ui)
end

--- "home", "mybooks", or "library" (no KoboUI: KOReader's file browser).
function KoboToolbar:getBackTarget()
    local hp = homePlugin(self.ui)
    if not hp then return "library" end
    local want = self.settings.back_target or "auto"
    if want == "home" or want == "mybooks" then return want end
    return opened_from or "home"
end

function KoboToolbar:getBackLabel()
    local t = self:getBackTarget()
    if t == "home" then return _("Back to Home") end
    if t == "mybooks" then return _("Back to My Books") end
    return _("Back to Library")
end

function KoboToolbar:goBack()
    local ui = self.ui
    local target = self:getBackTarget()
    local ok, err = pcall(function()
        local hp = homePlugin(ui)
        if target == "home" and hp and hp.onSimpleUIGoHomescreen then
            hp:onSimpleUIGoHomescreen()
        elseif target == "mybooks" and hp then
            hp:onSimpleUIGoLibrary()
        else
            ui:handleEvent(Event:new("Home"))
        end
    end)
    if not ok then
        logger.warn("kobotoolbar: back button failed, using the file browser:", err)
        ui:handleEvent(Event:new("Home"))
    end
end

-- ------------------------------------------------------------ buttons

local function copy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = copy(v) end
    return r
end

--- The ordered toolbar buttons: { id, hidden, custom, label, icon, action }.
function KoboToolbar:getButtons()
    local list = self.settings.buttons
    if type(list) ~= "table" then
        list = {}
        self.settings.buttons = list
    end
    local have = {}
    for _i, b in ipairs(list) do have[b.id] = true end
    for _i, id in ipairs(BUILTIN_BUTTONS) do
        if not have[id] then table.insert(list, { id = id }) end
    end
    return list
end

function KoboToolbar:getButton(id)
    for _i, b in ipairs(self:getButtons()) do
        if b.id == id then return b end
    end
end

function KoboToolbar:addCustomButton(label)
    local list = self:getButtons()
    local used = {}
    for _i, b in ipairs(list) do used[b.id] = true end
    local n = 1
    while used["c" .. n] do n = n + 1 end
    local b = { id = "c" .. n, custom = true, label = label, icon = "line/star.svg" }
    -- custom buttons go before "…", which stays last
    local pos = #list + 1
    for i, x in ipairs(list) do if x.id == "more" then pos = i end end
    table.insert(list, pos, b)
    self:saveSettings()
    return b
end

function KoboToolbar:deleteButton(id)
    local list = self:getButtons()
    for i = #list, 1, -1 do
        if list[i].id == id and list[i].custom then table.remove(list, i) end
    end
    self:saveSettings()
end

function KoboToolbar:getMoreActions()
    if type(self.settings.more_actions) ~= "table" then
        self.settings.more_actions = defaultMoreActions()
    end
    local cfg = self.settings.more_actions.settings
    if type(cfg) ~= "table" then
        cfg = {}
        self.settings.more_actions.settings = cfg
    end
    cfg.show_as_quickmenu = true -- lets "Arrange actions" offer separators
    if self.updated then
        self.updated = nil
        self:saveSettings()
    end
    return self.settings.more_actions
end

-- ------------------------------------------------------------ touch zones

function KoboToolbar:registerZones()
    local z = ZONES[self.settings.zone] or ZONES.medium
    local function sz(r) return { ratio_x = r.x, ratio_y = r.y, ratio_w = r.w, ratio_h = r.h } end
    local function open(flag)
        return function()
            if not self.settings[flag] then return false end
            self:showToolbar()
            return true
        end
    end
    local menu_zone = G_defaults:readSetting("DTAP_ZONE_MENU")
    local menu_ext = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
    local cfg_zone = G_defaults:readSetting("DTAP_ZONE_CONFIG")
    local cfg_ext = G_defaults:readSetting("DTAP_ZONE_CONFIG_EXT")
    self.ui:registerTouchZones({
        { id = ZONE_ID, ges = "tap", screen_zone = sz(z),
          overrides = { "tap_forward", "tap_backward" }, handler = open("enabled") },
        -- the top: the same areas KOReader uses to open its menu
        { id = TOP_TAP_ID, ges = "tap", screen_zone = sz(menu_zone),
          overrides = { "readermenu_tap", "tap_forward", "tap_backward" }, handler = open("top_tap") },
        { id = TOP_EXT_TAP_ID, ges = "tap", screen_zone = sz(menu_ext),
          overrides = { "readermenu_ext_tap", "readermenu_tap", TOP_TAP_ID, "tap_forward", "tap_backward" },
          handler = open("top_tap") },
        -- the bottom: the areas of KOReader's settings panel (the Aa button opens it)
        { id = BOTTOM_TAP_ID, ges = "tap", screen_zone = sz(cfg_zone),
          overrides = { "readerconfigmenu_tap", "readerfooter_tap", "tap_forward", "tap_backward" }, handler = open("bottom_tap") },
        { id = BOTTOM_EXT_TAP_ID, ges = "tap", screen_zone = sz(cfg_ext),
          overrides = { "readerconfigmenu_ext_tap", "readerconfigmenu_tap", "readerfooter_tap", BOTTOM_TAP_ID, "tap_forward", "tap_backward" },
          handler = open("bottom_tap") },
    })
end

-- Links / highlights / corner taps first: other modules re-register their zones
-- at times, so the ordering is re-asserted after every (un)registration.
function KoboToolbar:fixZoneOrder()
    local ui = self.ui
    local dg = ui.touch_zone_dg
    if not dg then return end
    local changed = false
    for our_id, before in pairs(OUR_ZONES) do
        if dg:checkNode(our_id) then
            for _i, id in ipairs(before) do
                if dg:checkNode(id) then
                    dg:addNodeDep(our_id, id)
                    changed = true
                end
            end
        end
    end
    if changed then
        local ordered = {}
        for _i, zone_id in ipairs(dg:serialize()) do
            if ui._zones[zone_id] then table.insert(ordered, ui._zones[zone_id]) end
        end
        ui._ordered_touch_zones = ordered
    end
end

function KoboToolbar:hookZoneRegistration()
    local ui = self.ui
    if ui._kobotoolbar_hooked then return end
    ui._kobotoolbar_hooked = true
    local plugin = self
    local orig_register = ui.registerTouchZones
    local orig_unregister = ui.unRegisterTouchZones
    ui.registerTouchZones = function(this, zones)
        orig_register(this, zones)
        local ok, err = pcall(plugin.fixZoneOrder, plugin)
        if not ok then logger.warn("kobotoolbar: fixZoneOrder failed:", err) end
    end
    ui.unRegisterTouchZones = function(this, zones)
        orig_unregister(this, zones)
        local ok, err = pcall(plugin.fixZoneOrder, plugin)
        if not ok then logger.warn("kobotoolbar: fixZoneOrder failed:", err) end
    end
end

-- No page-turn animation behind the toolbar (slider, |< >|): the page turns
-- under the overlay; normal reading keeps the animation.
function KoboToolbar:hookPageAnimation()
    local view = self.ui.view
    if not view or view._kobotoolbar_anim_hooked then return end
    view._kobotoolbar_anim_hooked = true
    local plugin = self
    local orig = view.onPageChangeAnimation
    if type(orig) ~= "function" then return end
    view.onPageChangeAnimation = function(this, forward)
        if plugin.hud then
            local Screen = Device.screen
            if Screen.setSwipeAnimations then pcall(Screen.setSwipeAnimations, Screen, false) end
            return true
        end
        return orig(this, forward)
    end
end

function KoboToolbar:onSetDimensions()
    self:closeToolbar()
    if Device:isTouchDevice() then
        UIManager:nextTick(function() self:registerZones() end)
    end
end

-- ------------------------------------------------------------ the overlay

function KoboToolbar:showToolbar()
    if self.hud then return end
    local ToolbarWidget = require("kobotoolbar_widget")
    self.hud = ToolbarWidget:new{ ui = self.ui, plugin = self }
    UIManager:show(self.hud)
end

function KoboToolbar:closeToolbar()
    if self.hud then
        UIManager:close(self.hud)
        self.hud = nil
    end
end

function KoboToolbar:onToolbarClosed(widget)
    if self.hud == widget then self.hud = nil end
    if self.origin and self:getOriginPage() == self.ui:getCurrentPage() then
        self:clearOrigin()
    end
end

function KoboToolbar:onShowKoboToolbar()
    if self.hud then self:closeToolbar() else self:showToolbar() end
    return true
end

-- ------------------------------------------------------------ "return to page"

function KoboToolbar:setOriginIfNeeded()
    if self.origin then return end
    local ui = self.ui
    local location = ui.link:getCurrentLocation()
    local label
    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        label = ui.pagemap:getCurrentPageLabel(true)
    end
    self.origin = { location = location, page = ui:getCurrentPage(), label = label }
    ui.link:addCurrentLocationToStack(location)
end

function KoboToolbar:clearOrigin()
    self.origin = nil
end

function KoboToolbar:getOriginPage()
    local o = self.origin
    if not o then return nil end
    if self.ui.rolling and o.location and o.location.xpointer then
        local ok, page = pcall(self.ui.document.getPageFromXPointer, self.ui.document, o.location.xpointer)
        if ok and page then return page end
    end
    return o.page
end

function KoboToolbar:goToPage(page)
    self:setOriginIfNeeded()
    self._navigating = true
    self.ui:handleEvent(Event:new("GotoPage", page))
    self._navigating = false
end

function KoboToolbar:goToOrigin()
    local o = self.origin
    if not o then return end
    self._navigating = true
    self.ui:handleEvent(Event:new("RestoreBookLocation", o.location))
    self._navigating = false
    local stack = self.ui.link.location_stack
    if stack and stack[#stack] == o.location then table.remove(stack) end
    self:clearOrigin()
end

function KoboToolbar:onPageUpdate()
    if self.hud then
        self.hud:onReaderPageUpdate()
    elseif self.origin and not self._navigating then
        self:clearOrigin() -- you turned a page yourself: that's your new spot
    end
end

function KoboToolbar:onCloseDocument()
    self:closeToolbar()
    self:clearOrigin()
end

function KoboToolbar:onCloseWidget()
    self:closeToolbar()
end

-- ------------------------------------------------------------ settings menu

local INFO_MODE_NAMES = {
    page = _("Page X of Y"),
    chapter_pages = _("Pages left in chapter"),
    chapter_time = _("Time left in chapter"),
    book_time = _("Time left in book"),
    percent = _("Percent read"),
}
local INFO_MODES = { "page", "chapter_pages", "chapter_time", "book_time", "percent" }
KoboToolbar.INFO_MODES = INFO_MODES

local ZONE_NAMES = {
    narrow = _("Narrow (middle third)"),
    medium = _("Medium (middle half)"),
    wide = _("Wide (all but the edges)"),
}

function KoboToolbar:backTargetName(id)
    if id == "auto" then return _("Where I opened the book (Home or My Books)") end
    if id == "home" then return _("Always Home") end
    return _("Always My Books")
end

function KoboToolbar:addToMainMenu(menu_items)
    menu_items.kobo_toolbar = {
        text = _("Kobo-style toolbar"),
        sorting_hint = "setting",
        sub_item_table_func = function() return self:buildSettingsItems() end,
    }
end

function KoboToolbar:buttonLabel(b)
    if not b then return "?" end
    if b.label and b.label ~= "" then return b.label end
    local names = {
        light = _("Light"), font = _("Font (Aa)"), stats = _("Reading statistics"),
        settings = _("Settings"), more = _("More (…)"),
    }
    return names[b.id] or b.id
end

function KoboToolbar:buildButtonPage(id)
    local b = self:getButton(id)
    if not b then return {} end
    local items = {
        {
            text = _("Show on the toolbar"),
            keep_menu_open = true,
            checked_func = function() local x = self:getButton(id); return x and not x.hidden end,
            callback = function()
                local x = self:getButton(id)
                if x then x.hidden = (not x.hidden) or nil; self:saveSettings() end
            end,
        },
        {
            text = _("Move left"),
            keep_menu_open = true,
            callback = function(tm) self:moveButton(id, -1); if tm then tm:updateItems() end end,
        },
        {
            text = _("Move right"),
            keep_menu_open = true,
            callback = function(tm) self:moveButton(id, 1); if tm then tm:updateItems() end end,
            separator = b.custom and true or nil,
        },
    }
    if b.custom then
        table.insert(items, {
            text_func = function() return _("Name") .. ": " .. self:buttonLabel(self:getButton(id)) end,
            keep_menu_open = true,
            callback = function(tm)
                self:askText(_("Button name"), self:getButton(id).label or "", function(t)
                    local x = self:getButton(id)
                    if x and t and t ~= "" then x.label = t; self:saveSettings() end
                    if tm then tm:updateItems() end
                end)
            end,
        })
        table.insert(items, {
            text = _("Icon"),
            keep_menu_open = true,
            callback = function()
                require("kobotoolbar_iconpicker"):show{
                    current = self:getButton(id).icon,
                    on_select = function(icon)
                        local x = self:getButton(id)
                        if x then x.icon = icon; self:saveSettings() end
                    end,
                }
            end,
        })
        table.insert(items, {
            text_func = function()
                local x = self:getButton(id)
                local a = x and x.action
                return _("Action") .. ": " .. (a and Dispatcher:menuTextFunc(a) or _("none"))
            end,
            sub_item_table_func = function()
                local x = self:getButton(id)
                if type(x.action) ~= "table" then x.action = {} end
                local sub = {}
                Dispatcher:addSubMenu(self, sub, x, "action")
                return sub
            end,
            separator = true,
        })
        table.insert(items, {
            text = _("Delete this button"),
            callback = function(tm)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Delete the button \"%s\"?"), self:buttonLabel(self:getButton(id))),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        self:deleteButton(id)
                        if tm then tm:onBack() end
                    end,
                })
            end,
        })
    end
    return items
end

function KoboToolbar:moveButton(id, dir)
    local list = self:getButtons()
    for i, b in ipairs(list) do
        if b.id == id then
            local j = i + dir
            if j >= 1 and j <= #list then
                list[i], list[j] = list[j], list[i]
                self:saveSettings()
            end
            return
        end
    end
end

function KoboToolbar:askText(title, value, cb)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = value or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("OK"), is_enter_default = true, callback = function()
                local t = dlg:getInputText()
                UIManager:close(dlg)
                cb(t)
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function KoboToolbar:buildButtonsItems()
    local items = {}
    for _i, b in ipairs(self:getButtons()) do
        local id = b.id
        table.insert(items, {
            text_func = function()
                local x = self:getButton(id)
                if not x then return "?" end
                return self:buttonLabel(x) .. (x.hidden and ("  (" .. _("hidden") .. ")") or "")
            end,
            sub_item_table_func = function() return self:buildButtonPage(id) end,
        })
    end
    items[#items].separator = true
    table.insert(items, {
        text = _("Arrange buttons"),
        keep_menu_open = true,
        callback = function(tm)
            local SortWidget = require("ui/widget/sortwidget")
            local sort_items = {}
            for _i, x in ipairs(self:getButtons()) do
                table.insert(sort_items, {
                    text = self:buttonLabel(x) .. (x.hidden and ("  (" .. _("hidden") .. ")") or ""),
                    orig = x,
                })
            end
            UIManager:show(SortWidget:new{
                title = _("Arrange buttons"),
                item_table = sort_items,
                callback = function()
                    local new = {}
                    for _i, s in ipairs(sort_items) do table.insert(new, s.orig) end
                    self.settings.buttons = new
                    self:saveSettings()
                    if tm then tm:updateItems() end
                end,
            })
        end,
    })
    table.insert(items, {
        text = _("Add a custom button"),
        help_text = _("A new button on the toolbar: give it a name, then pick its icon and the KOReader action it runs."),
        keep_menu_open = true,
        callback = function(tm)
            self:askText(_("Button name"), "", function(t)
                local b = self:addCustomButton((t and t ~= "") and t or _("Button"))
                if tm then tm:updateItems() end
                require("kobotoolbar_iconpicker"):show{
                    current = b.icon,
                    on_select = function(icon)
                        local x = self:getButton(b.id)
                        if x then x.icon = icon; self:saveSettings() end
                        local Notification = require("ui/widget/notification")
                        Notification:notify(_("Now choose its action under Toolbar buttons."))
                    end,
                }
            end)
        end,
    })
    table.insert(items, {
        text = _("Reset buttons to default"),
        keep_menu_open = true,
        callback = function(tm)
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = _("Show the default buttons in Kobo's order and delete your custom buttons?"),
                ok_text = _("Reset"),
                ok_callback = function()
                    self.settings.buttons = nil
                    self:saveSettings()
                    if tm then tm:onBack() end
                end,
            })
        end,
    })
    return items
end

function KoboToolbar:buildSettingsItems()
    local function toggle(text, key, help, sep)
        return {
            text = text,
            help_text = help,
            checked_func = function() return self.settings[key] end,
            callback = function()
                self.settings[key] = not self.settings[key]
                self:saveSettings()
            end,
            separator = sep,
        }
    end
    local zone_items = {}
    for _i, key in ipairs(ZONE_ORDER) do
        table.insert(zone_items, {
            text = ZONE_NAMES[key],
            radio = true,
            checked_func = function() return self.settings.zone == key end,
            callback = function()
                self.settings.zone = key
                self:saveSettings()
                self:registerZones()
            end,
        })
    end
    local info_items = {}
    for _i, key in ipairs(INFO_MODES) do
        table.insert(info_items, {
            text = INFO_MODE_NAMES[key],
            radio = true,
            checked_func = function() return self.settings.info_mode == key end,
            callback = function() self.settings.info_mode = key; self:saveSettings() end,
        })
    end
    local back_items = {}
    for _i, key in ipairs(BACK_TARGETS) do
        table.insert(back_items, {
            text = self:backTargetName(key),
            radio = true,
            enabled_func = function() return homePlugin(self.ui) ~= nil end,
            checked_func = function() return (self.settings.back_target or "auto") == key end,
            callback = function() self.settings.back_target = key; self:saveSettings() end,
        })
    end
    return {
        toggle(_("Tapping the middle of the page opens the toolbar"), "enabled"),
        {
            text_func = function()
                return _("Middle tap area") .. ": " .. (ZONE_NAMES[self.settings.zone] or "")
            end,
            help_text = _("The column in the middle of the page that opens the toolbar. Taps left and right of it turn pages."),
            sub_item_table = zone_items,
        },
        toggle(_("Tapping the top of the page opens the toolbar"), "top_tap",
            _("Instead of KOReader's menu. Swiping down from the top still opens KOReader's menu, and so does the ⚙ button.")),
        toggle(_("Tapping the bottom of the page opens the toolbar"), "bottom_tap",
            _("Instead of KOReader's settings panel, which the Aa button opens. Swiping up from the bottom still opens it too."), true),
        {
            text_func = function()
                local short = { auto = _("automatic"), home = _("Home"), mybooks = _("My Books") }
                return _("Back button goes to") .. ": " .. (short[self.settings.back_target or "auto"] or "")
            end,
            help_text = _("Where \"Back to …\" takes you. By default, back where you opened the book from: the Home screen or My Books. Needs KoboUI; without it the button goes back to KOReader's file browser."),
            sub_item_table = back_items,
        },
        {
            text = _("Toolbar buttons"),
            help_text = _("Show or hide the buttons next to \"Back to …\", change their order, or add your own buttons with any KOReader action."),
            sub_item_table_func = function() return self:buildButtonsItems() end,
        },
        {
            text_func = function()
                return _("… menu") .. ": " .. Dispatcher:menuTextFunc(self:getMoreActions())
            end,
            help_text = _("Pick any KOReader action to show in the … menu. Use 'Arrange actions' to change their order."),
            sub_item_table_func = function()
                self:getMoreActions()
                local sub = {}
                Dispatcher:addSubMenu(self, sub, self.settings, "more_actions")
                -- keep "Nothing", the categories and "Arrange actions"; drop the
                -- Execute / QuickMenu entries, which don't apply here
                local cut
                for i, item in ipairs(sub) do
                    if item.text_func and i > 1 then cut = i break end
                end
                if cut then
                    for i = #sub, cut + 1, -1 do table.remove(sub, i) end
                    sub[cut].separator = nil
                end
                table.insert(sub, 1, {
                    text = _("Reset to default"),
                    keep_menu_open = true,
                    callback = function(tm)
                        self.settings.more_actions = defaultMoreActions()
                        self:saveSettings()
                        if tm then tm:updateItems() end
                    end,
                    separator = true,
                })
                return sub
            end,
            separator = true,
        },
        toggle(_("Show battery percentage"), "battery_pct",
            _("Next to the battery in the toolbar's status bar (Kobo doesn't show it).")),
        toggle(_("Show the Wi-Fi icon when Wi-Fi is on"), "show_wifi"),
        {
            text_func = function()
                return _("Page line shows") .. ": " .. (INFO_MODE_NAMES[self.settings.info_mode] or "")
            end,
            help_text = _("The line above the slider. Tap it on the toolbar to switch."),
            sub_item_table = info_items,
        },
        toggle(_("Show chapter marks on the slider"), "show_ticks"),
    }
end

--- Just this plugin's settings, as a one-tab KOReader menu.
function KoboToolbar:onShowKoboToolbarSettings()
    local tab = self:buildSettingsItems()
    tab.icon = "appbar.settings"
    local CenterContainer = require("ui/widget/container/centercontainer")
    local TouchMenu = require("ui/widget/touchmenu")
    local Screen = Device.screen
    local container = CenterContainer:new{
        covers_header = true,
        ignore = "height",
        dimen = Screen:getSize(),
    }
    local menu = TouchMenu:new{
        width = Screen:getWidth(),
        tab_item_table = { tab },
        show_parent = container,
    }
    menu.close_callback = function() UIManager:close(container) end
    container[1] = menu
    UIManager:show(container)
    return true
end

return KoboToolbar
