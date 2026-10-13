--[[--
Kobo's reading-stats panel, shown under the toolbar by the ılı button.

  ┌ THIS CHAPTER ─────────────────────────┐ ┌ NEXT CHAPTER ─────────┐
    ▬▬▬▬▬▬▬▬▬▬▬▬▬                14  minutes to    10  minutes to read
    0%  read                          go
  ┌ THIS BOOK ──────────────────────────────────────────────────────┐
    <  ____▁▃▂▅▃▆▅▇▆▅▃▂▄▁▁▂▃▂▂▄▅  >   5.6  hours to go
       Chapters

  * Times come from the Reading statistics plugin (its average time per
    page); without it, pages are shown instead.
  * The chart: one bar per chapter, as tall as the chapter is long. Chapters
    already read are dark, the current one black, the rest light grey.
  * < > switch the chart between "Chapters" and "Last 7 days" (minutes read
    per day in this book; the figure on the right becomes the time read).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext
local Fonts = require("kobotoolbar_fonts")
local Screen = Device.screen

local function S(v) return Screen:scaleBySize(v) end

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local BAND = Blitbuffer.Color8(0xC8)      -- the grey title bands
local BAND_TEXT = Blitbuffer.Color8(0x22)
local READ = Blitbuffer.Color8(0x33)      -- chapters already read
local UNREAD = Blitbuffer.Color8(0xA0)    -- chapters still to read
local ARROW = Blitbuffer.Color8(0x55)

local M = {}

M.VIEWS = { "chapters", "days" }

-- ------------------------------------------------------------ text helpers

--- Draws text with its baseline at `base`. Returns its width.
local function drawBase(bb, text, face, x, base, color, max_w)
    local t = TextWidget:new{ text = text, face = face, fgcolor = color or BLACK,
        max_width = max_w, truncate_with_ellipsis = max_w ~= nil }
    local w = t:getSize().w
    t:paintTo(bb, x, base - t:getBaseline())
    t:free()
    return w
end

local function width(text, face)
    local t = TextWidget:new{ text = text, face = face }
    local w = t:getSize().w
    t:free()
    return w
end

--- Splits a label in two lines when it doesn't fit ("minutes to" / "go").
local function wrap2(text, face, max_w)
    if width(text, face) <= max_w then return { text } end
    local words = {}
    for wd in text:gmatch("%S+") do table.insert(words, wd) end
    for i = #words - 1, 1, -1 do
        local a = table.concat(words, " ", 1, i)
        if width(a, face) <= max_w then
            return { a, table.concat(words, " ", i + 1) }
        end
    end
    return { text }
end

-- ------------------------------------------------------------ numbers

--- A duration the way Kobo writes it: "14" "minutes …" under an hour,
--- "5.6" "hours …" above.
local function koboTime(seconds, minute_label, hour_label)
    local mins = math.max(1, math.floor(seconds / 60 + 0.5))
    if mins < 60 then
        return tostring(mins), minute_label(mins)
    end
    local h = math.floor(seconds / 360 + 0.5) / 10
    local s = string.format("%.1f", h)
    return s, hour_label(s == "1.0" and 1 or 2)
end

local function avgTime(ui)
    local st = ui.statistics
    local avg = st and st.settings and st.settings.is_enabled and st.avg_time
    if not avg or avg ~= avg or avg <= 0 then return nil end
    return avg
end

--- Everything the panel shows, for `page`.
function M.gather(ui, page)
    local doc = ui.document
    local toc = ui.toc
    local total = doc:getPageCount()
    local d = { page = page, total = total, avg = avgTime(ui) }

    local ticks = toc and toc:getTocTicksFlattened() or {}
    d.has_toc = #ticks > 0

    -- this chapter
    local done, count, left
    if d.has_toc then
        done = toc:getChapterPagesDone(page)
        count = toc:getChapterPageCount(page)
        left = toc:getChapterPagesLeft(page, true)
    end
    if not count or count <= 0 then count = total end
    if not done then
        -- before the first chapter: the part before it counts as a chapter
        local first = ticks[1]
        done = page - 1
        if first and first > page then count = first - 1 end
    end
    if not left then
        -- last chapter (or no chapters): until the end of the book
        left = doc:getTotalPagesLeft(page)
    end
    d.chapter_pct = count > 0 and math.floor(done / count * 100) or 0
    d.chapter_pages_left = left + 1
    -- times count the pages after this one, like KOReader's footer and Bookends
    d.chapter_time_pages = left

    -- next chapter
    local nxt = d.has_toc and toc:getNextChapter(page)
    if nxt then
        d.next_pages = toc:getChapterPageCount(nxt)
    end

    -- this book
    d.book_pages_left = doc:getTotalPagesLeft(page) + 1
    d.book_time_pages = doc:getTotalPagesLeft(page)

    -- the chapters chart: one entry per chapter { pages, state }
    d.chapters = M.chapterList(ui, ticks, page, total)
    return d
end

function M.chapterList(ui, ticks, page, total)
    local starts = {}
    local last
    for _i, p in ipairs(ticks) do
        if p ~= last and p >= 1 and p <= total then
            table.insert(starts, p)
            last = p
        end
    end
    if #starts == 0 then return {} end
    if starts[1] > 1 then table.insert(starts, 1, 1) end
    local list = {}
    for i, s in ipairs(starts) do
        local e = (starts[i + 1] or (total + 1)) - 1
        local state
        if page > e then state = "read"
        elseif page >= s then state = "current"
        else state = "unread" end
        table.insert(list, { pages = e - s + 1, state = state })
    end
    return list
end

--- Merges chapters two by two until they fit in `max_bars` bars.
local function fitBars(list, max_bars)
    while #list > max_bars and max_bars > 0 do
        local merged = {}
        for i = 1, #list, 2 do
            local a, b = list[i], list[i + 1]
            if b then
                local state = (a.state == "current" or b.state == "current") and "current"
                    or (b.state == "read" and "read") or (a.state == "unread" and "unread")
                    or "current"
                table.insert(merged, { pages = a.pages + b.pages, state = state })
            else
                table.insert(merged, a)
            end
        end
        list = merged
    end
    return list
end

--- Minutes read in this book on each of the last 7 days (oldest first),
--- from the statistics database plus what isn't saved there yet.
function M.lastDays(ui, ndays)
    ndays = ndays or 7
    local days, index = {}, {}
    local now = os.time()
    for i = ndays - 1, 0, -1 do
        local key = os.date("%Y-%m-%d", now - i * 86400)
        table.insert(days, { key = key, secs = 0 })
        index[key] = #days
    end
    local st = ui.statistics
    local total_secs
    if not (st and st.settings and st.settings.is_enabled) then return days, nil end
    local ok, err = pcall(function()
        local id_book = st.id_curr_book
        if id_book then
            local DataStorage = require("datastorage")
            local SQ3 = require("lua-ljsqlite3/init")
            local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
            local since = now - (ndays + 1) * 86400
            local sql = string.format([[
                SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS d,
                       sum(duration)
                FROM page_stat_data
                WHERE id_book = %d AND start_time >= %d
                GROUP BY d;]], tonumber(id_book), since)
            local res = conn:exec(sql)
            if res and res[1] then
                for i = 1, #res[1] do
                    local k = res[1][i]
                    local idx = index[k]
                    if idx then days[idx].secs = days[idx].secs + (tonumber(res[2][i]) or 0) end
                end
            end
            local t = conn:rowexec(string.format("SELECT sum(duration) FROM page_stat_data WHERE id_book = %d;", tonumber(id_book)))
            total_secs = tonumber(t) or 0
            conn:close()
        end
        -- this session's pages, not in the database yet
        for _p, list in pairs(st.page_stat or {}) do
            for _i, tuple in ipairs(list) do
                local ts, dur = tuple[1], tuple[2]
                if dur and dur > 0 then
                    local idx = index[os.date("%Y-%m-%d", ts)]
                    if idx then days[idx].secs = days[idx].secs + dur end
                    total_secs = (total_secs or 0) + dur
                end
            end
        end
    end)
    if not ok then logger.warn("kobotoolbar: reading time query failed:", err) end
    return days, total_secs
end

-- ------------------------------------------------------------ layout

--- The panel's height (it hangs under the toolbar).
function M.height()
    return S(22) + S(23) + S(42) + S(24) + S(23) + S(76)
end

--- Paints the panel at y0 (full width). Returns the tap areas:
--- { prev = Geom, next = Geom, chart = Geom }.
function M.paint(bb, ui, page, y0, view)
    local W = Screen:getWidth()
    local H = M.height()
    bb:paintRect(0, y0, W, H, WHITE)

    local d = M.gather(ui, page)
    local margin = S(10)
    local inner = W - 2 * margin
    local function X(frac) return margin + math.floor(inner * frac + 0.5) end

    local f_band = Fonts.face(12.5)
    local f_big = Font:getFace("NotoSerif-Regular.ttf", 38)
    local f_pct = Font:getFace("NotoSerif-Regular.ttf", 19)
    local f_small = Font:getFace("NotoSerif-Regular.ttf", 15)
    local line_gap = S(17.5)   -- between the two lines of "minutes to / go"
    local label_up = S(11)     -- first label line sits that much above the number's baseline

    local band_h = S(23)
    local left_x0, left_x1 = margin, X(0.648)
    local right_x0, right_x1 = X(0.666), W - margin

    local function band(x0, x1, y, text)
        bb:paintRect(x0, y, x1 - x0, band_h, BAND)
        local t = TextWidget:new{ text = Fonts.caps(text), face = f_band, fgcolor = BAND_TEXT,
            max_width = x1 - x0 - S(20), truncate_with_ellipsis = true }
        t:paintTo(bb, x0 + S(12), y + math.floor((band_h - t:getSize().h) / 2))
        t:free()
    end

    --- big number + its label (one or two lines), label first line raised
    local function figure(x, base, num, label, label_max_x)
        local nw = drawBase(bb, num, f_big, x, base, BLACK)
        local lx = x + nw + S(18)
        local lines = wrap2(label, f_small, math.max(S(40), label_max_x - lx))
        local ly = base - label_up
        for i, l in ipairs(lines) do
            drawBase(bb, l, f_small, lx, ly + (i - 1) * line_gap, BLACK, label_max_x - lx)
        end
    end

    -- ---- THIS CHAPTER | NEXT CHAPTER
    local y = y0 + S(22)
    band(left_x0, left_x1, y, _("This chapter"))
    band(right_x0, right_x1, y, _("Next chapter"))
    y = y + band_h
    local base1 = y + S(42)

    -- progress bar + "0% read"
    local bar_x0, bar_x1 = X(0.022), X(0.376)
    local bar_y = y + S(11)
    local bar_h = math.max(3, S(5.5))
    bb:paintRect(bar_x0, bar_y, bar_x1 - bar_x0, bar_h, BAND)
    local fill = math.floor((bar_x1 - bar_x0) * math.min(100, d.chapter_pct) / 100 + 0.5)
    if fill > 0 then bb:paintRect(bar_x0, bar_y, fill, bar_h, BLACK) end
    local pw = drawBase(bb, d.chapter_pct .. "%", f_pct, bar_x0 + S(1), base1 + S(2), BLACK)
    drawBase(bb, _("read"), f_small, bar_x0 + pw + S(16), base1 + S(1), BLACK)

    -- time (or pages) left in this chapter
    local num, label
    if d.avg then
        num, label = koboTime(d.chapter_time_pages * d.avg,
            function(n) return N_("minute to go", "minutes to go", n) end,
            function(n) return N_("hour to go", "hours to go", n) end)
    else
        num = tostring(d.chapter_pages_left)
        label = N_("page to go", "pages to go", d.chapter_pages_left)
    end
    figure(X(0.395), base1, num, label, left_x1 - S(6))

    -- next chapter
    if d.next_pages then
        if d.avg then
            num, label = koboTime(d.next_pages * d.avg,
                function(n) return N_("minute to read", "minutes to read", n) end,
                function(n) return N_("hour to read", "hours to read", n) end)
        else
            num = tostring(d.next_pages)
            label = N_("page to read", "pages to read", d.next_pages)
        end
        figure(right_x0 + S(8), base1, num, label, right_x1 - S(4))
    else
        local msg = d.has_toc and _("This is the last chapter") or _("No chapters in this book")
        local lines = wrap2(msg, f_small, right_x1 - right_x0 - S(16))
        for i, l in ipairs(lines) do
            drawBase(bb, l, f_small, right_x0 + S(8), base1 - label_up + (i - 1) * line_gap, BLACK, right_x1 - right_x0 - S(16))
        end
    end

    -- ---- THIS BOOK
    y = base1 + S(24)
    band(left_x0, right_x1, y, _("This book"))
    y = y + band_h

    local chart_top = y + S(9)
    local chart_bot = y + S(28)
    local chart_x0, chart_x1 = X(0.07), X(0.585)
    local rects = {}

    -- < and > (thin chevrons)
    local ch = S(16)
    local cw = S(8)
    local cy = chart_bot - math.floor(S(19) / 2) - S(1)
    local function chevron(x, dir)
        local t = math.max(2, S(1.4))
        for i = 0, ch - 1 do
            local off = math.floor(math.abs(i - ch / 2) / (ch / 2) * cw + 0.5)
            local xx = dir < 0 and (x + off) or (x + cw - off)
            bb:paintRect(xx, cy - math.floor(ch / 2) + i, t, 1, ARROW)
        end
    end
    local lx = X(0.022)
    chevron(lx, -1)
    rects.prev = Geom:new{ x = 0, y = y, w = chart_x0 - S(2), h = y0 + H - y }
    local rx = chart_x1 + S(18)
    chevron(rx, 1)
    rects.next = Geom:new{ x = chart_x1 + S(2), y = y, w = right_x0 - chart_x1 - S(2), h = y0 + H - y }
    rects.chart = Geom:new{ x = chart_x0, y = chart_top, w = chart_x1 - chart_x0, h = chart_bot - chart_top }

    local f_caption = f_small
    local caption, right_num, right_label
    local stub = math.max(1, S(1))
    if view == "days" then
        caption = _("Last 7 days")
        local days, total_secs = M.lastDays(ui, 7)
        local maxs = 0
        for _i, dd in ipairs(days) do maxs = math.max(maxs, dd.secs) end
        local n = #days
        local slot = (chart_x1 - chart_x0) / n
        local bw = math.max(2, math.min(S(14), math.floor(slot * 0.55)))
        for i, dd in ipairs(days) do
            local bx = chart_x0 + math.floor((i - 1) * slot + (slot - bw) / 2)
            local h = maxs > 0 and math.floor((chart_bot - chart_top) * dd.secs / maxs + 0.5) or 0
            h = math.max(stub, h)
            bb:paintRect(bx, chart_bot - h, bw, h, i == n and BLACK or READ)
        end
        if total_secs and total_secs > 0 then
            right_num, right_label = koboTime(total_secs,
                function(k) return N_("minute read", "minutes read", k) end,
                function(k) return N_("hour read", "hours read", k) end)
        else
            right_num, right_label = "0", _("minutes read")
        end
    else
        caption = _("Chapters")
        local list = d.chapters
        if #list == 0 then
            drawBase(bb, _("No chapters"), f_small, chart_x0, chart_bot - S(4), ARROW)
        else
            local max_bars = math.max(1, math.floor((chart_x1 - chart_x0) / math.max(3, S(2.2))))
            list = fitBars(list, max_bars)
            local maxp = 0
            for _i, c in ipairs(list) do maxp = math.max(maxp, c.pages) end
            local n = #list
            local slot = (chart_x1 - chart_x0) / n
            local bw = math.max(1, math.min(S(7), math.floor(slot * 0.62 + 0.5)))
            local full = chart_bot - chart_top
            for i, c in ipairs(list) do
                local bx = chart_x0 + math.floor((i - 1) * slot)
                local h = math.max(stub, math.floor(full * c.pages / maxp + 0.5))
                local col = c.state == "read" and READ or (c.state == "current" and BLACK or UNREAD)
                bb:paintRect(bx, chart_bot - h, bw, h, col)
            end
        end
        if d.avg then
            right_num, right_label = koboTime(d.book_time_pages * d.avg,
                function(k) return N_("minute to go", "minutes to go", k) end,
                function(k) return N_("hour to go", "hours to go", k) end)
        else
            right_num = tostring(d.book_pages_left)
            right_label = N_("page to go", "pages to go", d.book_pages_left)
        end
    end
    drawBase(bb, caption, f_caption, chart_x0, chart_bot + S(17.5), BLACK, chart_x1 - chart_x0)
    figure(right_x0 + S(8), chart_bot + S(11), right_num, right_label, right_x1 - S(4))

    -- the line under the panel
    bb:paintRect(0, y0 + H - math.max(1, S(1)), W, math.max(1, S(1)), BLACK)
    return rects
end

return M
