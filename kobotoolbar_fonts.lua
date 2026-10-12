--[[--
The toolbar's sans-serif font.

  * With KoboUI installed: the Label Font chosen in KoboUI
    (Settings → Style → Label Font), so the toolbar matches Home and My Books.
  * Without KoboUI: KOReader's own UI font ("cfont", Noto Sans by default).

Bold: the family's real bold file when it has one (…-Bold.ttf); otherwise the
regular file drawn bold by KOReader (as KOReader does for any font without a
bold file, e.g. a single variable-weight Jost file).
--]]

local Font = require("ui/font")

local M = {}

local function koboUIFonts()
    local ok, KF = pcall(require, "infra/kbo_fonts")
    if ok and type(KF) == "table" and type(KF.face) == "function" then return KF end
end

--- A regular face.
function M.face(size)
    local KF = koboUIFonts()
    if KF then
        local ok, face = pcall(KF.face, size, false)
        if ok and face then return face end
    end
    return Font:getFace("cfont", size)
end

--- A bold face, and how to draw it: false = it is the real bold file;
--- true = KOReader's bold (finds Noto Sans Bold for the UI font);
--- "synth" = no bold file: drawn bold by the toolbar (see drawText).
function M.boldFace(size)
    local KF = koboUIFonts()
    if KF then
        local ok_b, has_bold = pcall(function() return KF.hasBold and KF.hasBold() end)
        if ok_b and has_bold then
            local ok, face = pcall(KF.face, size, true)
            if ok and face then return face, false end
        end
        local ok, face = pcall(KF.face, size, false)
        if ok and face then return face, "synth" end
    end
    -- KOReader's UI font: `bold = true` makes KOReader use Noto Sans Bold
    return Font:getFace("cfont", size), true
end

--- Capitals ("PAGE 336 OF 1006").
function M.caps(s)
    if type(s) ~= "string" or s == "" then return s end
    local ok, U = pcall(require, "ffi/utf8proc")
    if ok and U and U.uppercase_dumb then
        local ok2, r = pcall(U.uppercase_dumb, s)
        if ok2 and r then return r end
    end
    return s:upper()
end

return M
