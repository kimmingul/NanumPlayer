-- NanumPlayer Fluent UI toolkit.
--
-- Shared by scripts/nanum.lua and scripts/nanum-fluent.lua (each script loads
-- its own copy, nothing is registered until it is used):
--
--   * drawing helpers on top of mpv's ASS overlay (rounded rectangles, vector
--     icons, Segoe UI / Malgun Gothic text, DPI aware metrics),
--   * an mp.input compatible modal component: F.select{...}, F.get{...},
--     F.terminate(). It is drawn as a Fluent flyout card (search, scrolling,
--     keyboard + mouse, IME / Unicode text entry) instead of the mpv console.
--
-- Coordinates are "logical" pixels: the overlay resolution is the window size
-- divided by the UI scale (display-hidpi-scale * a mild window-height factor),
-- so every layout constant below is DPI independent.

local mp = require 'mp'

local F = {}

-- Parent localization loader (scripts/nanum-i18n.lua), resolved like the other sibling modules.
local function load_i18n()
    local dirs = {}
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local src = info and info.source or ""
    if src:sub(1, 1) == "@" then
        local d = src:sub(2):match("^(.*)[/\\][^/\\]*$")
        if d then dirs[#dirs + 1] = d end
    end
    local sd = mp.get_script_directory and mp.get_script_directory()
    if sd then dirs[#dirs + 1] = sd end
    local ok, ed = pcall(mp.command_native, { "expand-path", "~~exe_dir/scripts" })
    if ok and type(ed) == "string" and ed ~= "" then dirs[#dirs + 1] = ed end
    for _, d in ipairs(dirs) do
        local f = loadfile(d .. "/nanum-i18n.lua")
        if f then
            local okf, mod = pcall(f)
            if okf and type(mod) == "table" then return mod end
            mp.msg.error("nanum-i18n.lua: " .. tostring(mod))
        end
    end
    mp.msg.error("fluent-input: scripts/nanum-i18n.lua not found; the UI stays in its source language")
    local stub = {}
    function stub.t(_, key, ...) if select("#", ...) > 0 then return string.format(key, ...) end return key end
    function stub.translator(ns) return function(key, ...) return stub.t(ns, key, ...) end end
    function stub.language() return "ko" end
    function stub.on_change() end
    return stub
end

F.i18n = load_i18n()
F.tr = F.i18n.translator("fluent")
F.core_tr = F.i18n.translator("core")
local tr = F.tr

local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local sin, cos, rad, sqrt = math.sin, math.cos, math.rad, math.sqrt

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end
F.clamp = clamp

----------------------------------------------------------------------------
-- Theme (Windows 11 dark, cyan/blue accent)
----------------------------------------------------------------------------

local function bgr(hex)
    local r, g, b = hex:match("^#?(%x%x)(%x%x)(%x%x)$")
    return (b .. g .. r):upper()
end

F.C = {
    bg       = bgr "#14161A",
    card     = bgr "#1E2126",
    card2    = bgr "#272B32",
    white    = "FFFFFF",
    black    = "000000",
    text     = bgr "#FFFFFF",
    text2    = bgr "#CBD1DA",
    text3    = bgr "#8E96A4",
    accent   = bgr "#4CC2FF",
    accent2  = bgr "#2B7FE0",
    on_accent = bgr "#06151F",
    ok       = bgr "#6CCB5F",
    warn     = bgr "#F8C94A",
    err      = bgr "#FF99A4",
}
local C = F.C

F.FONT = "Segoe UI"
F.FONT_KO = "Malgun Gothic"

----------------------------------------------------------------------------
-- Text helpers (UTF-8, width estimate)
----------------------------------------------------------------------------

local function char_len(b)
    if b < 0x80 then return 1
    elseif b >= 0xF0 then return 4
    elseif b >= 0xE0 then return 3
    elseif b >= 0xC0 then return 2 end
    return 1
end

local function chars_of(s)
    local t, i, n = {}, 1, #s
    while i <= n do
        local l = char_len(s:byte(i))
        t[#t + 1] = s:sub(i, i + l - 1)
        i = i + l
    end
    return t
end
F.chars = chars_of

local function codepoint(ch)
    local b1 = ch:byte(1)
    local n = #ch
    if n == 1 then return b1 end
    if n == 2 then return (b1 - 0xC0) * 64 + (ch:byte(2) - 0x80) end
    if n == 3 then return (b1 - 0xE0) * 4096 + (ch:byte(2) - 0x80) * 64 + (ch:byte(3) - 0x80) end
    return (b1 - 0xF0) * 262144 + (ch:byte(2) - 0x80) * 4096 + (ch:byte(3) - 0x80) * 64 + (ch:byte(4) - 0x80)
end

local function is_hangul(cp)
    return (cp >= 0xAC00 and cp <= 0xD7AF) or (cp >= 0x1100 and cp <= 0x11FF)
        or (cp >= 0x3130 and cp <= 0x318F) or (cp >= 0xA960 and cp <= 0xA97F)
        or (cp >= 0xD7B0 and cp <= 0xD7FF)
end

local function is_neutral(cp)
    return cp < 0x41 or (cp >= 0x5B and cp <= 0x60) or (cp >= 0x7B and cp <= 0x7F)
end

-- Width of one character in em (Segoe UI / Malgun Gothic approximation).
local NARROW = { i = .25, l = .25, j = .25, I = .27, t = .34, f = .33, r = .35, ["1"] = .56 }
local WIDE = { m = .83, w = .77, M = .88, W = .95 }
local PUNCT = {
    [" "] = .27, ["."] = .26, [","] = .26, [":"] = .26, [";"] = .26, ["!"] = .3, ["|"] = .3,
    ["("] = .33, [")"] = .33, ["["] = .33, ["]"] = .33, ["-"] = .36, ["'"] = .2, ["/"] = .4,
}
local function char_em(ch)
    local cp = codepoint(ch)
    if cp < 0x80 then
        return PUNCT[ch] or NARROW[ch] or WIDE[ch] or ((cp >= 65 and cp <= 90) and .64 or .54)
    end
    if cp == 0xB7 then return .27 end
    if cp < 0x250 then return .56 end                  -- Latin-1 / Latin Extended (Spanish accents)
    if (cp >= 0x1100 and cp <= 0x11FF) or (cp >= 0x2E80 and cp <= 0xA4CF) or (cp >= 0xAC00 and cp <= 0xD7A3)
        or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFF00 and cp <= 0xFF60) or (cp >= 0x3130 and cp <= 0x318F) then
        return 1.0
    end
    if cp == 0x2026 then return .9 end
    if cp >= 0x1F000 then return 1.2 end
    return .62
end
F.char_em = char_em

local function text_w(s, em)
    local w = 0
    for _, ch in ipairs(chars_of(s)) do w = w + char_em(ch) end
    return w * em
end
F.text_w = text_w

-- Shorten with an ellipsis so the estimated width fits maxw.
local function fit(s, em, maxw)
    if maxw <= 0 then return "" end
    if text_w(s, em) <= maxw then return s end
    local out, w, limit = {}, 0, maxw - 0.9 * em
    for _, ch in ipairs(chars_of(s)) do
        w = w + char_em(ch) * em
        if w > limit then break end
        out[#out + 1] = ch
    end
    return table.concat(out) .. "…"
end
F.fit = fit

function F.fmt_time(sec)
    if not sec or sec ~= sec then return "--:--" end
    if sec < 0 then sec = 0 end
    sec = floor(sec)
    local h, m, s = floor(sec / 3600), floor(sec / 60) % 60, sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

----------------------------------------------------------------------------
-- ASS builder
----------------------------------------------------------------------------

local Ass = {}
Ass.__index = Ass

function F.new_ass(opacity)
    return setmetatable({ buf = {}, g = opacity or 1 }, Ass)
end

local function n2(v) return string.format("%.2f", v) end

local function alpha_tag(a, g)
    return string.format("&H%02X&", 255 - floor(clamp(a, 0, 1) * g * 255 + 0.5))
end

local function esc(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\239\187\191")
    s = s:gsub("{", "\\{")
    s = s:gsub("}", "\\}")
    s = s:gsub("\r?\n", "\\N")
    return s
end
F.esc = esc

local function rect_path(x, y, w, h)
    return string.format("m %s %s l %s %s %s %s %s %s", n2(x), n2(y), n2(x + w), n2(y), n2(x + w), n2(y + h), n2(x), n2(y + h))
end
F.rect_path = rect_path

local function rrect_path(x, y, w, h, r)
    r = min(r, w / 2, h / 2)
    if r <= 0.5 then return rect_path(x, y, w, h) end
    local x1, y1 = x + w, y + h
    local k = r * 0.5523
    return string.format(
        "m %s %s l %s %s b %s %s %s %s %s %s l %s %s b %s %s %s %s %s %s l %s %s b %s %s %s %s %s %s l %s %s b %s %s %s %s %s %s",
        n2(x + r), n2(y), n2(x1 - r), n2(y),
        n2(x1 - r + k), n2(y), n2(x1), n2(y + r - k), n2(x1), n2(y + r),
        n2(x1), n2(y1 - r),
        n2(x1), n2(y1 - r + k), n2(x1 - r + k), n2(y1), n2(x1 - r), n2(y1),
        n2(x + r), n2(y1),
        n2(x + r - k), n2(y1), n2(x), n2(y1 - r + k), n2(x), n2(y1 - r),
        n2(x), n2(y + r),
        n2(x), n2(y + r - k), n2(x + r - k), n2(y), n2(x + r), n2(y))
end
F.rrect_path = rrect_path

local function poly_path(pts)
    local t = { "m" }
    for i = 1, #pts, 2 do
        if i == 3 then t[#t + 1] = "l" end
        t[#t + 1] = n2(pts[i]) .. " " .. n2(pts[i + 1])
    end
    return table.concat(t, " ")
end

-- A thick line as a polygon.
local function line_pts(x0, y0, x1, y1, w)
    local dx, dy = x1 - x0, y1 - y0
    local len = sqrt(dx * dx + dy * dy)
    if len == 0 then len = 1 end
    local nx, ny = -dy / len * w / 2, dx / len * w / 2
    return { x0 + nx, y0 + ny, x1 + nx, y1 + ny, x1 - nx, y1 - ny, x0 - nx, y0 - ny }
end

-- Ring segment from angle a0 to a1 (degrees, screen coordinates), polygon path.
local function ring_path(cx, cy, ro, ri, a0, a1, mirror)
    local steps = max(4, floor(math.abs(a1 - a0) / 8))
    local pts = {}
    local function px(a, r)
        local x = cx + r * cos(rad(a))
        if mirror then x = 2 * cx - x end
        return x, cy + r * sin(rad(a))
    end
    for i = 0, steps do
        local a = a0 + (a1 - a0) * i / steps
        local x, y = px(a, ro)
        pts[#pts + 1] = x
        pts[#pts + 1] = y
    end
    for i = steps, 0, -1 do
        local a = a0 + (a1 - a0) * i / steps
        local x, y = px(a, ri)
        pts[#pts + 1] = x
        pts[#pts + 1] = y
    end
    return poly_path(pts)
end

-- Full annulus: outer clockwise, inner counter clockwise (hole under non-zero fill).
local function annulus_path(cx, cy, ro, ri)
    local a, b = {}, {}
    local n = 28
    for i = 0, n - 1 do
        local ang = rad(360 * i / n)
        a[#a + 1] = cx + ro * cos(ang)
        a[#a + 1] = cy + ro * sin(ang)
    end
    for i = n - 1, 0, -1 do
        local ang = rad(360 * i / n)
        b[#b + 1] = cx + ri * cos(ang)
        b[#b + 1] = cy + ri * sin(ang)
    end
    return poly_path(a) .. " " .. poly_path(b)
end

function Ass:raw(line)
    self.buf[#self.buf + 1] = line
end

-- o: fill (BGR), fa (opacity), stroke (BGR), sa, sw, blur
function Ass:shape(path, o)
    o = o or {}
    local t = { "{\\an7\\pos(0,0)\\shad0" }
    if o.fill then
        t[#t + 1] = "\\1c&H" .. o.fill .. "&\\1a" .. alpha_tag(o.fa or 1, self.g)
    else
        t[#t + 1] = "\\1a&HFF&"
    end
    if o.stroke then
        t[#t + 1] = "\\bord" .. n2(o.sw or 1) .. "\\3c&H" .. o.stroke .. "&\\3a" .. alpha_tag(o.sa or 1, self.g)
    else
        t[#t + 1] = "\\bord0"
    end
    if o.blur then t[#t + 1] = "\\blur" .. n2(o.blur) end
    t[#t + 1] = "\\p1}" .. path
    self.buf[#self.buf + 1] = table.concat(t)
end

function Ass:rect(x, y, w, h, o) self:shape(rect_path(x, y, w, h), o) end
function Ass:rrect(x, y, w, h, r, o) self:shape(rrect_path(x, y, w, h, r), o) end
function Ass:circle(cx, cy, r, o) self:shape(rrect_path(cx - r, cy - r, 2 * r, 2 * r, r), o) end

-- Drop shadow for a rounded card.
function Ass:shadow(x, y, w, h, r, strength)
    self:shape(rrect_path(x - 1, y + 5, w + 2, h + 2, r + 2), { fill = C.black, fa = strength or 0.4, blur = 10 })
end

-- Script classes for font selection: Segoe UI for Latin, Malgun Gothic for Hangul, a per-language face for Han / kana.
local function is_cjk(cp)
    return (cp >= 0x3000 and cp <= 0x30FF) or (cp >= 0x31F0 and cp <= 0x31FF) or (cp >= 0x3400 and cp <= 0x4DBF)
        or (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFF00 and cp <= 0xFFEF)
        or (cp >= 0x20000 and cp <= 0x2FA1F)
end

-- Typeface of Han / kana text for a UI language (nil: leave it to the base font and font fallback).
local CJK_FONT = { ja = "Yu Gothic UI", ["zh-CN"] = "Microsoft YaHei UI", ["zh-TW"] = "Microsoft JhengHei UI", ko = "Malgun Gothic" }
function F.cjk_font(lang)
    return CJK_FONT[lang or F.i18n.language()]
end

local function font_runs(parts, base_font, ko_font, cjk_font)
    local out, cur = {}, nil
    local function put_font(f)
        if cur ~= f then
            out[#out + 1] = "{\\fn" .. f .. "}"
            cur = f
        end
    end
    for _, part in ipairs(parts) do
        if type(part) == "table" then
            out[#out + 1] = part.raw
        else
            local run, run_font = {}, nil
            local function flush()
                if #run > 0 then
                    put_font(run_font or cur or base_font)
                    out[#out + 1] = esc(table.concat(run))
                    run = {}
                end
            end
            for _, ch in ipairs(chars_of(part)) do
                local cp = codepoint(ch)
                local want
                if is_hangul(cp) then
                    want = ko_font
                elseif is_cjk(cp) then
                    want = cjk_font or base_font
                elseif not is_neutral(cp) then
                    want = base_font
                end
                if want and want ~= run_font then
                    flush()
                    run_font = want
                end
                run[#run + 1] = ch
            end
            flush()
        end
    end
    return table.concat(out)
end

-- o: size (em px), color, a, an (default 4: left/middle), bold, clip{x0,y0,x1,y1},
--    spacing, font, blur. s: string or list of strings / {raw=...}.
function Ass:text(x, y, s, o)
    o = o or {}
    local em = o.size or 14
    local font = o.font or F.FONT
    local t = {
        string.format("{\\an%d\\pos(%s,%s)\\fn%s\\fs%s\\bord0\\shad0\\q2\\1c&H%s&\\1a%s",
            o.an or 4, n2(x), n2(y), font, n2(em * 1.33), o.color or C.text, alpha_tag(o.a or 1, self.g)),
    }
    if o.bold then t[#t + 1] = "\\b1" end
    if o.spacing then t[#t + 1] = "\\fsp" .. n2(o.spacing) end
    if o.blur then t[#t + 1] = "\\blur" .. n2(o.blur) end
    if o.clip then
        t[#t + 1] = string.format("\\clip(%d,%d,%d,%d)", floor(o.clip[1]), floor(o.clip[2]), ceil(o.clip[3]), ceil(o.clip[4]))
    end
    t[#t + 1] = "}"
    local parts = type(s) == "table" and s or { s }
    t[#t + 1] = font_runs(parts, font, o.font_ko or F.FONT_KO, o.font_cjk or F.cjk_font())
    self.buf[#self.buf + 1] = table.concat(t)
end

function Ass:str()
    return table.concat(self.buf, "\n")
end

----------------------------------------------------------------------------
-- Vector icons. Each draws centered at (cx, cy) inside roughly an s x s box.
----------------------------------------------------------------------------

local I = {}
F.icons = I

local function solid(color, a) return { fill = color, fa = a or 1 } end
local function stroke_only(color, a, w) return { stroke = color, sa = a or 1, sw = w } end

function I.play(A, cx, cy, s, color, a)
    local o = { fill = color, fa = a or 1, stroke = color, sa = a or 1, sw = max(1, s * 0.09) }
    A:shape(poly_path({ cx - 0.2 * s, cy - 0.27 * s, cx + 0.3 * s, cy, cx - 0.2 * s, cy + 0.27 * s }), o)
end

function I.pause(A, cx, cy, s, color, a)
    local w, h = 0.17 * s, 0.56 * s
    A:rrect(cx - 0.17 * s - w / 2, cy - h / 2, w, h, w / 2.5, solid(color, a))
    A:rrect(cx + 0.17 * s - w / 2, cy - h / 2, w, h, w / 2.5, solid(color, a))
end

-- Skip 10 s: forward=false -> counter clockwise "replay", true -> "forward".
function I.skip(A, cx, cy, s, color, a, forward)
    local ro, th = 0.42 * s, max(1.6, 0.085 * s)
    local ri = ro - th
    local ccy = cy + 0.03 * s
    A:shape(ring_path(cx, ccy, ro, ri, -60, 240, forward), solid(color, a))
    -- arrow head on the -60 degree end
    local R = (ro + ri) / 2
    local ang = rad(-60)
    local px, py = cx + R * cos(ang), ccy + R * sin(ang)
    local dx, dy = sin(ang), -cos(ang)            -- direction of travel (decreasing angle)
    local nx, ny = dy, -dx
    local hw, hl = 0.15 * s, 0.2 * s
    local pts = { px + nx * hw, py + ny * hw, px + dx * hl, py + dy * hl, px - nx * hw, py - ny * hw }
    if forward then
        for i = 1, #pts, 2 do pts[i] = 2 * cx - pts[i] end
    end
    A:shape(poly_path(pts), { fill = color, fa = a or 1, stroke = color, sa = a or 1, sw = 0.6 })
    A:text(cx, ccy + 0.02 * s, "10", { size = 0.34 * s, color = color, a = a, an = 5, bold = true })
end

function I.volume(A, cx, cy, s, color, a, level, muted)
    local pts = { -0.38, -0.12, -0.2, -0.12, 0.04, -0.33, 0.04, 0.33, -0.2, 0.12, -0.38, 0.12 }
    for i = 1, #pts, 2 do
        pts[i] = cx + pts[i] * s
        pts[i + 1] = cy + pts[i + 1] * s
    end
    A:shape(poly_path(pts), { fill = color, fa = a or 1, stroke = color, sa = a or 1, sw = 0.8 })
    local th = max(1.3, 0.075 * s)
    if muted or level <= 0 then
        local x, y = cx + 0.27 * s, cy
        A:shape(poly_path(line_pts(x - 0.14 * s, y - 0.14 * s, x + 0.14 * s, y + 0.14 * s, th)), solid(color, a))
        A:shape(poly_path(line_pts(x - 0.14 * s, y + 0.14 * s, x + 0.14 * s, y - 0.14 * s, th)), solid(color, a))
    else
        A:shape(ring_path(cx + 0.02 * s, cy, 0.24 * s, 0.24 * s - th, -45, 45), solid(color, a))
        if level > 0.45 then
            A:shape(ring_path(cx + 0.02 * s, cy, 0.4 * s, 0.4 * s - th, -45, 45), solid(color, a))
        end
    end
end

function I.audio(A, cx, cy, s, color, a)
    local hs = { 0.26, 0.56, 0.8, 0.46, 0.3 }
    local w = 0.09 * s
    for i, h in ipairs(hs) do
        local x = cx + (i - 3) * 0.17 * s
        A:rrect(x - w / 2, cy - h * s / 2, w, h * s, w / 2, solid(color, a))
    end
end

function I.subtitle(A, cx, cy, s, color, a)
    local sw = max(1.2, 0.08 * s)
    A:rrect(cx - 0.42 * s + sw / 2, cy - 0.3 * s + sw / 2, 0.84 * s - sw, 0.6 * s - sw, 0.1 * s,
        stroke_only(color, a, sw))
    local h = max(1.4, 0.08 * s)
    A:rrect(cx - 0.28 * s, cy - 0.07 * s - h / 2, 0.2 * s, h, h / 2, solid(color, a))
    A:rrect(cx - 0.02 * s, cy - 0.07 * s - h / 2, 0.3 * s, h, h / 2, solid(color, a))
    A:rrect(cx - 0.28 * s, cy + 0.1 * s - h / 2, 0.34 * s, h, h / 2, solid(color, a))
    A:rrect(cx + 0.12 * s, cy + 0.1 * s - h / 2, 0.16 * s, h, h / 2, solid(color, a))
end

local function star_pts(cx, cy, r, inner)
    local p = { 0, -1, inner, -inner, 1, 0, inner, inner, 0, 1, -inner, inner, -1, 0, -inner, -inner }
    for i = 1, #p, 2 do
        p[i] = cx + p[i] * r
        p[i + 1] = cy + p[i + 1] * r
    end
    return p
end

function I.sparkle(A, cx, cy, s, color, a)
    local o = { fill = color, fa = a or 1, stroke = color, sa = a or 1, sw = max(0.8, 0.05 * s) }
    A:shape(poly_path(star_pts(cx - 0.08 * s, cy + 0.07 * s, 0.4 * s, 0.14)), o)
    A:shape(poly_path(star_pts(cx + 0.29 * s, cy - 0.3 * s, 0.17 * s, 0.17)), o)
end

function I.fullscreen(A, cx, cy, s, color, a, on)
    local th, L = max(1.4, 0.085 * s), 0.25 * s
    local d = on and 0.12 * s or 0.38 * s
    for _, sx in ipairs({ -1, 1 }) do
        for _, sy in ipairs({ -1, 1 }) do
            local x, y = cx + sx * d, cy + sy * d
            local dir = on and 1 or -1
            A:shape(poly_path(line_pts(x - sx * th / 2, y, x + sx * dir * L, y, th)), solid(color, a))
            A:shape(poly_path(line_pts(x, y - sy * th / 2, x, y + sy * dir * L, th)), solid(color, a))
        end
    end
end

function I.folder(A, cx, cy, s, color, a)
    A:rrect(cx - 0.42 * s, cy - 0.32 * s, 0.32 * s, 0.2 * s, 0.06 * s, solid(color, (a or 1) * 0.75))
    A:rrect(cx - 0.42 * s, cy - 0.2 * s, 0.84 * s, 0.52 * s, 0.07 * s, solid(color, a))
end

function I.disc(A, cx, cy, s, color, a)
    A:shape(annulus_path(cx, cy, 0.44 * s, 0.32 * s), solid(color, a))
    A:shape(annulus_path(cx, cy, 0.15 * s, 0.07 * s), solid(color, a))
    A:shape(ring_path(cx, cy, 0.26 * s, 0.2 * s, -50, 10), solid(color, (a or 1) * 0.6))
end

-- Rounded video frame with a play mark.
function I.youtube(A, cx, cy, s, color, a)
    local sw = max(1.4, 0.08 * s)
    A:rrect(cx - 0.44 * s + sw / 2, cy - 0.31 * s + sw / 2, 0.88 * s - sw, 0.62 * s - sw, 0.17 * s, stroke_only(color, a, sw))
    A:shape(poly_path({ cx - 0.1 * s, cy - 0.14 * s, cx + 0.17 * s, cy, cx - 0.1 * s, cy + 0.14 * s }), solid(color, a))
end

-- Globe: ring, equator and a central meridian ring.
function I.globe(A, cx, cy, s, color, a)
    local th = max(1.3, 0.07 * s)
    A:shape(annulus_path(cx, cy, 0.42 * s, 0.42 * s - th), solid(color, a))
    A:shape(poly_path(line_pts(cx - 0.42 * s, cy, cx + 0.42 * s, cy, th)), solid(color, a))
    A:shape(annulus_path(cx, cy, 0.2 * s, 0.2 * s - th), solid(color, a))
    A:shape(poly_path(line_pts(cx, cy - 0.42 * s, cx, cy + 0.42 * s, th)), solid(color, a))
end

function I.search(A, cx, cy, s, color, a)
    local th = max(1.3, 0.09 * s)
    A:shape(annulus_path(cx - 0.08 * s, cy - 0.08 * s, 0.28 * s, 0.28 * s - th), solid(color, a))
    A:shape(poly_path(line_pts(cx + 0.14 * s, cy + 0.14 * s, cx + 0.38 * s, cy + 0.38 * s, th)), solid(color, a))
end

function I.check(A, cx, cy, s, color, a)
    local th = max(1.4, 0.11 * s)
    A:shape(poly_path(line_pts(cx - 0.3 * s, cy + 0.02 * s, cx - 0.09 * s, cy + 0.23 * s, th)), solid(color, a))
    A:shape(poly_path(line_pts(cx - 0.09 * s, cy + 0.23 * s, cx + 0.32 * s, cy - 0.22 * s, th)), solid(color, a))
end

function I.close(A, cx, cy, s, color, a)
    local th = max(1.3, 0.09 * s)
    A:shape(poly_path(line_pts(cx - 0.25 * s, cy - 0.25 * s, cx + 0.25 * s, cy + 0.25 * s, th)), solid(color, a))
    A:shape(poly_path(line_pts(cx - 0.25 * s, cy + 0.25 * s, cx + 0.25 * s, cy - 0.25 * s, th)), solid(color, a))
end

function I.chevron(A, cx, cy, s, color, a)
    local th = max(1.3, 0.09 * s)
    A:shape(poly_path(line_pts(cx - 0.1 * s, cy - 0.24 * s, cx + 0.14 * s, cy, th)), solid(color, a))
    A:shape(poly_path(line_pts(cx + 0.14 * s, cy, cx - 0.1 * s, cy + 0.24 * s, th)), solid(color, a))
end

-- Rounded media mark used as the app logo.
function I.logo(A, cx, cy, s)
    A:shadow(cx - s / 2, cy - s / 2, s, s, s * 0.24, 0.5)
    A:rrect(cx - s / 2, cy - s / 2, s, s, s * 0.24, { fill = C.accent2, fa = 1 })
    A:rrect(cx - s / 2, cy - s / 2, s, s * 0.55, s * 0.24, { fill = C.accent, fa = 0.55 })
    I.play(A, cx - s * 0.02, cy + s * 0.03, s * 0.78, C.white, 1)
    A:circle(cx + s * 0.36, cy - s * 0.36, s * 0.17, { fill = C.bg, fa = 1 })
    I.sparkle(A, cx + s * 0.36, cy - s * 0.36, s * 0.26, C.ok, 1)
end

----------------------------------------------------------------------------
-- Metrics, pointer
----------------------------------------------------------------------------

-- Overlay resolution (W x H, logical px) and the physical/logical ratios.
function F.metrics()
    local d = mp.get_property_native("osd-dimensions")
    if not d or not d.w or d.w < 2 or d.h < 2 then return nil end
    local dpi = mp.get_property_number("display-hidpi-scale") or 1
    if dpi <= 0 then dpi = 1 end
    local k = dpi * clamp((d.h / dpi) / 800, 1.0, 1.3)
    local W, H = max(1, floor(d.w / k + 0.5)), max(1, floor(d.h / k + 0.5))
    return { W = W, H = H, kx = d.w / W, ky = d.h / H, pw = d.w, ph = d.h, k = k }
end

-- Mouse position in logical px (nil if the pointer is outside / unknown).
function F.mouse(m)
    m = m or F.metrics()
    local p = mp.get_property_native("mouse-pos")
    if not m or not p or p.x == nil or p.x < 0 or p.y < 0 then return nil end
    return p.x / m.kx, p.y / m.ky, p.hover
end

local function in_rect(px, py, x, y, w, h)
    return px and px >= x and px < x + w and py >= y and py < y + h
end
F.in_rect = in_rect

-- Report to the Fluent chrome (toast). kind: info | ok | warn | error.
function F.toast(text, secs, kind)
    mp.commandv("script-message", "nanum-fluent", "toast", tostring(text), tostring(secs or 3), kind or "info")
end

----------------------------------------------------------------------------
-- Modal component: select / get
----------------------------------------------------------------------------

local overlay = nil
local cur = nil                 -- active request state
local depth = 0                 -- callbacks being dispatched
local pending = nil             -- request issued from inside a callback
local blink_timer = nil
local bound_names = {}
local section_name = nil
local ime_prev = nil
local registered = false
local observers = {}

local MODAL_PROP = "user-data/fluent/modal-" .. mp.get_script_name()

local function report_error(where, err)
    mp.msg.error("fluent-input " .. where .. ": " .. tostring(err))
    F.toast(tr("UI 오류 (%s): %s", where, tostring(err)), 6, "error")
end

local open_request, close_current, render_modal

local function run_pending()
    if depth == 0 and pending then
        local p = pending
        pending = nil
        open_request(p.kind, p.t)
    end
end

local function dispatch(fn, ...)
    if not fn then return end
    depth = depth + 1
    local ok, err = pcall(fn, ...)
    depth = depth - 1
    if not ok then report_error("callback", err) end
    run_pending()
end

local function text_of(s) return table.concat(s.chars) end

-- Items ------------------------------------------------------------------

-- "label: value" of a settings row; the separator is ASCII ':' or full-width '：' (ja / zh).
local function split_setting(text)
    local a, b = text:find(":", 1, true), text:find("：", 1, true)
    local pos, len
    if a and (not b or a < b) then pos, len = a, 1 elseif b then pos, len = b, 3 else return nil end
    return text:sub(1, pos - 1), (text:sub(pos + len):match("^%s*(.*)$"))
end

-- Values that render as an on/off switch: the callers' own (already translated) 켬 / 끔 labels.
local function toggle_labels()
    local set = { ["켬"] = "on", ["끔"] = "off", [tr("켬")] = "on", [tr("끔")] = "off" }
    set[F.core_tr("켬")], set[F.core_tr("끔")] = "on", "off"
    return set
end

local function build_rows(t)
    local rows, has_marks = {}, t.marks == true
    local toggles = toggle_labels()
    for _, it in ipairs(t.items or {}) do
        if tostring(it):sub(1, 4) == "● " then has_marks = true break end
    end
    for i, it in ipairs(t.items or {}) do
        local text = tostring(it):gsub("[\r\n].*", "…")
        local sel = false
        if text:sub(1, 4) == "● " then
            sel = true
            text = text:sub(5)
        elseif has_marks and text:sub(1, 2) == "  " then
            text = text:sub(3)
        end
        local label, value, toggle = text, nil, nil
        if t.style == "settings" then
            local l, v = split_setting(text)
            if l and #l <= 120 then
                label, value = l, (v ~= "" and v or tr("(비어 있음)"))
                toggle = toggles[v]
            end
        end
        -- key: stable row identity across update_select (defaults to the item index)
        rows[i] = { idx = i, key = t.keys and t.keys[i] or i, label = label, value = value, toggle = toggle,
            sel = sel, low = text:lower() }
    end
    return rows, has_marks
end

local function refilter(s)
    local q = text_of(s):lower()
    local tokens = {}
    for w in q:gmatch("%S+") do tokens[#tokens + 1] = w end
    local keep = s.rows[s.filtered and s.filtered[s.focus] or 1]
    local f = {}
    for i, r in ipairs(s.rows) do
        local ok = true
        for _, tk in ipairs(tokens) do
            if not r.low:find(tk, 1, true) then ok = false break end
        end
        if ok then f[#f + 1] = i end
    end
    s.filtered = f
    s.focus = 1
    if #tokens == 0 and keep then
        for fi, ri in ipairs(f) do
            if s.rows[ri] == keep then s.focus = fi break end
        end
    end
    s.top = 1
end

local function ensure_visible(s)
    local vis = s.geo and s.geo.vis or 8
    local n = #s.filtered
    if s.focus < s.top then s.top = s.focus end
    if s.focus > s.top + vis - 1 then s.top = s.focus - vis + 1 end
    s.top = clamp(s.top, 1, max(1, n - vis + 1))
end

-- Rendering ---------------------------------------------------------------

local function ensure_overlay()
    if not overlay then
        overlay = mp.create_osd_overlay("ass-events")
        overlay.z = 100
    end
    return overlay
end

local function hide_overlay()
    if overlay then overlay:remove() end
end

local function draw_toggle(A, x, y, on, hot)
    local w, h = 40, 20
    if on then
        A:rrect(x, y, w, h, h / 2, { fill = C.accent, fa = 1 })
        A:circle(x + w - 10, y + h / 2, 6.5, { fill = C.on_accent, fa = 1 })
    else
        A:rrect(x + 0.75, y + 0.75, w - 1.5, h - 1.5, (h - 1.5) / 2, { stroke = C.white, sa = hot and 0.8 or 0.55, sw = 1.5 })
        A:circle(x + 10, y + h / 2, 5.5, { fill = C.white, fa = 0.78 })
    end
end

local function title_of(s)
    local p = tostring(s.t.prompt or "")
    p = p:gsub("%s*:%s*$", "")
    p = p:gsub("%s*：%s*$", "")
    if p == "" then p = s.kind == "get" and tr("입력") or tr("선택") end
    return p
end

local function draw_cursor_text(A, x, y, s, size, maxw, color)
    -- visible window of the line (estimated widths) around the cursor
    local chars = s.chars
    local st = s.cur + 1
    local wsum = 0
    while st > 1 and wsum + char_em(chars[st - 1]) * size <= maxw * 0.88 do
        st = st - 1
        wsum = wsum + char_em(chars[st]) * size
    end
    local en = s.cur
    local after_w = 0
    while en < #chars and wsum + after_w + char_em(chars[en + 1]) * size <= maxw do
        en = en + 1
        after_w = after_w + char_em(chars[en]) * size
    end
    local before = table.concat(chars, "", st, s.cur)
    local after = table.concat(chars, "", s.cur + 1, en)
    local cur_a = s.blink_on and 1 or 0
    local adv = 0.22 * size
    local raw = string.format("{\\1c&H%s&\\1a%s\\fsp%s\\b1}|{\\b0\\fsp0\\1c&H%s&\\1a%s}",
        C.accent, alpha_tag(cur_a, A.g), n2(-adv), color, alpha_tag(1, A.g))
    A:text(x, y, { before, { raw = raw }, after }, { size = size, color = color, clip = { x - 2, y - size, x + maxw + 4, y + size } })
end

function render_modal()
    local s = cur
    if not s then return end
    local m = F.metrics()
    if not m then return end
    local ov = ensure_overlay()
    local A = F.new_ass()
    local W, H = m.W, m.H
    local mx, my = F.mouse(m)
    local geo = {}
    s.geo = geo

    A:rect(0, 0, W, H, { fill = C.black, fa = s.t.anchor and 0.3 or 0.5 })

    local pad = 24
    local x, y, w, h
    if s.kind == "select" then
        local maxtext = 0
        for _, r in ipairs(s.rows) do
            local tw = text_w(r.label, 15) + (r.value and (text_w(r.value, 14) + 40) or 0)
            if tw > maxtext then maxtext = tw end
        end
        w = clamp(maxtext + 110, s.style == "settings" and 480 or 380, min(W - 32, 680))
        local rowh = s.style == "settings" and 44 or 40
        local show_search = #s.rows > 8 or #s.chars > 0
        local head = 62 + (show_search and 46 or 0)
        local foot = 38
        local avail = H - 48 - head - foot - 24
        local maxrows = max(2, floor(avail / rowh))
        local n = #s.filtered
        local vis = clamp(n, 1, min(maxrows, 10))
        if n == 0 then vis = 2 end
        h = head + vis * rowh + foot
        if s.t.anchor then
            x = clamp(s.t.anchor.x - w / 2, 16, max(16, W - w - 16))
            y = clamp(s.t.anchor.y - 14 - h, 16, max(16, H - h - 16))
        else
            x = floor((W - w) / 2)
            y = max(16, floor((H - h) * 0.46))
        end
        geo.vis, geo.rowh, geo.n = vis, rowh, n
        geo.list = { x = x + 8, y = y + head, w = w - 16, h = vis * rowh }
        geo.search = show_search and { x = x + pad, y = y + 56, w = w - 2 * pad, h = 36 } or nil
    else
        w = clamp(W - 32, 320, 520)
        h = 204
        x = floor((W - w) / 2)
        y = max(16, floor((H - h) * 0.4))
        geo.input = { x = x + pad, y = y + 64, w = w - 2 * pad, h = 46 }
        geo.cancel_label, geo.ok_label = tr("취소"), tr("확인")
        local okw = max(96, ceil(text_w(geo.ok_label, 14) + 44))
        local cancelw = max(96, ceil(text_w(geo.cancel_label, 14) + 44))
        geo.ok = { x = x + w - pad - okw, y = y + h - 62, w = okw, h = 36 }
        geo.cancel = { x = x + w - pad - okw - 12 - cancelw, y = y + h - 62, w = cancelw, h = 36 }
    end
    geo.card = { x = x, y = y, w = w, h = h }
    geo.close = { x = x + w - 44, y = y + 14, w = 30, h = 30 }

    A:shadow(x, y, w, h, 12, 0.55)
    A:rrect(x, y, w, h, 12, { fill = C.card, fa = 0.98, stroke = C.white, sa = 0.12, sw = 1 })
    A:text(x + pad, y + 32, fit(title_of(s), 19, w - 2 * pad - 40),
        { size = 19, bold = true, color = C.text })
    local hot_close = in_rect(mx, my, geo.close.x, geo.close.y, geo.close.w, geo.close.h)
    if hot_close then
        A:rrect(geo.close.x, geo.close.y, geo.close.w, geo.close.h, 6, { fill = C.white, fa = 0.1 })
    end
    I.close(A, geo.close.x + 15, geo.close.y + 15, 14, C.text2, 1)

    if s.kind == "select" then
        local sb = geo.search
        if sb then
            A:rrect(sb.x, sb.y, sb.w, sb.h, 6, { fill = C.white, fa = 0.06, stroke = C.white, sa = 0.1, sw = 1 })
            A:rrect(sb.x + 4, sb.y + sb.h - 2, sb.w - 8, 2, 1, { fill = C.accent, fa = 1 })
            I.search(A, sb.x + 20, sb.y + sb.h / 2, 16, C.text3, 1)
            if #s.chars == 0 then
                A:text(sb.x + 38, sb.y + sb.h / 2, fit(tr("입력하여 검색"), 14, sb.w - 50), { size = 14, color = C.text3 })
                if s.blink_on then
                    A:rect(sb.x + 36, sb.y + sb.h / 2 - 9, 1.5, 18, { fill = C.accent, fa = 1 })
                end
            else
                draw_cursor_text(A, sb.x + 38, sb.y + sb.h / 2, s, 14.5, sb.w - 50, C.text)
            end
        end
        local list, rowh, vis, n = geo.list, geo.rowh, geo.vis, geo.n
        ensure_visible(s)
        local scroll_pad = n > vis and 12 or 0
        if n == 0 then
            A:text(list.x + list.w / 2, list.y + list.h / 2, fit(tr("일치하는 항목이 없습니다"), 14, list.w - 24),
                { size = 14, color = C.text3, an = 5 })
        end
        local mark_pad = s.has_marks and 26 or 0
        for j = 1, vis do
            local fi = s.top + j - 1
            if fi > n then break end
            local r = s.rows[s.filtered[fi]]
            local ry = list.y + (j - 1) * rowh
            local focused = fi == s.focus
            local hot = in_rect(mx, my, list.x, ry, list.w - scroll_pad, rowh)
            if focused then
                A:rrect(list.x, ry + 2, list.w - scroll_pad, rowh - 4, 6, { fill = C.white, fa = s.pressed == fi and 0.05 or 0.09 })
                A:rrect(list.x + 1, ry + rowh / 2 - 8, 3, 16, 1.5, { fill = C.accent, fa = 1 })
            elseif hot then
                A:rrect(list.x, ry + 2, list.w - scroll_pad, rowh - 4, 6, { fill = C.white, fa = 0.05 })
            end
            local cy = ry + rowh / 2
            local lx = list.x + 16
            if s.has_marks and r.sel then
                I.check(A, lx + 8, cy, 16, C.accent, 1)
            end
            local left = lx + mark_pad
            local right = list.x + list.w - scroll_pad - 14
            if r.value then
                if r.toggle then
                    draw_toggle(A, right - 40, cy - 10, r.toggle == "on", focused or hot)
                    A:text(right - 48, cy, r.value, { size = 13, color = C.text2, an = 6 })
                    right = right - 48 - text_w(r.value, 13) - 14
                else
                    local vw = min(text_w(r.value, 14), (right - left) * 0.55)
                    A:text(right, cy, fit(r.value, 14, vw), { size = 14, color = C.text2, an = 6 })
                    right = right - vw - 16
                end
            end
            A:text(left, cy, fit(r.label, 15, right - left),
                { size = 15, color = (r.sel and s.has_marks) and C.accent or C.text, bold = r.sel and s.has_marks })
            local frac = s.progress and s.progress[r.key]
            if frac then
                local bx, bw = list.x + 16 + mark_pad, list.w - scroll_pad - 30 - mark_pad
                A:rrect(bx, ry + rowh - 9, bw, 3, 1.5, { fill = C.white, fa = 0.14 })
                if frac > 0 then
                    A:rrect(bx, ry + rowh - 9, max(3, bw * min(1, frac)), 3, 1.5, { fill = C.accent, fa = 1 })
                end
            end
        end
        if n > vis then
            local tx = list.x + list.w - 8
            A:rrect(tx, list.y + 4, 3, list.h - 8, 1.5, { fill = C.white, fa = 0.1 })
            local th = max(24, (list.h - 8) * vis / n)
            local ty = list.y + 4 + (list.h - 8 - th) * (s.top - 1) / max(1, n - vis)
            A:rrect(tx, ty, 3, th, 1.5, { fill = C.text2, fa = 0.7 })
        end
        local fy = list.y + list.h + 20
        local count = (n > vis or #s.chars > 0) and string.format("%d / %d", n == 0 and 0 or s.focus, n) or nil
        local hint_w = w - 2 * pad - (count and (text_w(count, 12) + 16) or 0)
        A:text(x + pad, fy, fit(tr("↑↓ 이동   Enter 선택   Esc 닫기"), 12, hint_w), { size = 12, color = C.text3 })
        if count then
            A:text(x + w - pad, fy, count, { size = 12, color = C.text3, an = 6 })
        end
    else
        local ib = geo.input
        A:rrect(ib.x, ib.y, ib.w, ib.h, 7, { fill = C.white, fa = 0.07, stroke = C.white, sa = 0.12, sw = 1 })
        A:rrect(ib.x + 4, ib.y + ib.h - 2, ib.w - 8, 2, 1, { fill = C.accent, fa = 1 })
        draw_cursor_text(A, ib.x + 14, ib.y + ib.h / 2, s, 16.5, ib.w - 28, C.text)
        local function button(r, label, primary, id)
            local hot = in_rect(mx, my, r.x, r.y, r.w, r.h)
            if primary then
                A:rrect(r.x, r.y, r.w, r.h, 6, { fill = C.accent, fa = hot and 0.88 or 1 })
                A:text(r.x + r.w / 2, r.y + r.h / 2, label, { size = 14, bold = true, color = C.on_accent, an = 5 })
            else
                A:rrect(r.x, r.y, r.w, r.h, 6, { fill = C.white, fa = hot and 0.14 or 0.08, stroke = C.white, sa = 0.1, sw = 1 })
                A:text(r.x + r.w / 2, r.y + r.h / 2, label, { size = 14, color = C.text, an = 5 })
            end
        end
        button(geo.cancel, geo.cancel_label, false)
        button(geo.ok, geo.ok_label, true)
        A:text(x + pad, y + h - 80, fit(tr("Enter 확인   Esc 취소"), 12, w - 2 * pad), { size = 12, color = C.text3 })
    end

    ov.res_x, ov.res_y = W, H
    ov.data = A:str()
    ov:update()
end

-- Editing -----------------------------------------------------------------

local function changed(s)
    s.blink_on = true
    if blink_timer then blink_timer:kill() blink_timer:resume() end
    if s.kind == "select" then
        refilter(s)
    elseif s.t.edited then
        dispatch(s.t.edited, text_of(s))
    end
    render_modal()
end

local function insert_text(s, str)
    str = str:gsub("[%c]", " ")
    local add = chars_of(str)
    if #add == 0 then return end
    for i, ch in ipairs(add) do
        table.insert(s.chars, s.cur + i, ch)
    end
    s.cur = s.cur + #add
    changed(s)
end

local function is_space(ch) return ch == " " or ch == "\t" end

local function word_start(s)
    local i = s.cur
    while i > 0 and is_space(s.chars[i]) do i = i - 1 end
    while i > 0 and not is_space(s.chars[i]) do i = i - 1 end
    return i
end

local function word_end(s)
    local i, n = s.cur, #s.chars
    while i < n and is_space(s.chars[i + 1]) do i = i + 1 end
    while i < n and not is_space(s.chars[i + 1]) do i = i + 1 end
    return i
end

local function delete_range(s, from, to)       -- chars from+1 .. to
    if to <= from then return end
    for _ = 1, to - from do table.remove(s.chars, from + 1) end
    s.cur = from
    changed(s)
end

local function move_cursor(s, pos)
    s.cur = clamp(pos, 0, #s.chars)
    s.blink_on = true
    if blink_timer then blink_timer:kill() blink_timer:resume() end
    render_modal()
end

local function paste(s)
    pcall(mp.commandv, "update-clipboard", "text")
    local ok, text = pcall(mp.get_property, "clipboard/text", "")
    if ok and text and text ~= "" then
        insert_text(s, (text:gsub("\r?\n", " ")))
    end
end

local function move_focus(s, delta, wrap)
    local n = #s.filtered
    if n == 0 then return end
    local f = s.focus + delta
    if wrap then
        if f < 1 then f = n elseif f > n then f = 1 end
    else
        f = clamp(f, 1, n)
    end
    s.focus = f
    ensure_visible(s)
    render_modal()
end

local function cancel()
    if cur then close_current() end
end

local function accept()
    local s = cur
    if not s then return end
    if s.kind == "select" then
        local ri = s.filtered[s.focus]
        if not ri then return end
        local idx = s.rows[ri].idx
        dispatch(s.t.submit, idx)
    else
        dispatch(s.t.submit, text_of(s))
    end
    if cur == s then
        if s.t.keep_open then
            if s.kind == "get" then s.chars, s.cur = {}, 0 end
            render_modal()
        else
            close_current()
        end
    end
end

local function wheel(dir)
    local s = cur
    if not s or s.kind ~= "select" then return end
    local vis, n = s.geo and s.geo.vis or 8, #s.filtered
    s.top = clamp(s.top + dir * 2, 1, max(1, n - vis + 1))
    render_modal()
end

-- Mouse -------------------------------------------------------------------

local function click()
    local s = cur
    if not s or not s.geo then return end
    local mx, my = F.mouse()
    if not mx then return end
    local g = s.geo
    if in_rect(mx, my, g.close.x, g.close.y, g.close.w, g.close.h) then return cancel() end
    if not in_rect(mx, my, g.card.x, g.card.y, g.card.w, g.card.h) then return cancel() end
    if s.kind == "select" then
        local l = g.list
        if in_rect(mx, my, l.x, l.y, l.w, l.h) then
            local fi = s.top + floor((my - l.y) / g.rowh)
            if fi >= 1 and fi <= #s.filtered then
                s.focus = fi
                accept()
            end
        end
    else
        if in_rect(mx, my, g.ok.x, g.ok.y, g.ok.w, g.ok.h) then return accept() end
        if in_rect(mx, my, g.cancel.x, g.cancel.y, g.cancel.w, g.cancel.h) then return cancel() end
    end
end

local function mouse_moved()
    local s = cur
    if not s then return end
    if s.kind == "select" and s.geo then
        local mx, my = F.mouse()
        local l = s.geo.list
        if mx and in_rect(mx, my, l.x, l.y, l.w, l.h) then
            local fi = s.top + floor((my - l.y) / s.geo.rowh)
            if fi >= 1 and fi <= #s.filtered and fi ~= s.focus then s.focus = fi end
        end
    end
    render_modal()
end

-- Bindings ------------------------------------------------------------------

local function bind_all(s)
    local n = 0
    local function bind(key, fn)
        n = n + 1
        local name = "_fluent_in_" .. n
        bound_names[#bound_names + 1] = name
        mp.add_forced_key_binding(key, name, fn, { repeatable = true })
    end
    local sel = s.kind == "select"
    local function typed(fn_sel, fn_get)
        return function()
            local c = cur
            if not c then return end
            if c.kind == "select" then fn_sel(c) else fn_get(c) end
        end
    end
    local function nop() end
    local function bs(c) if c.cur > 0 then delete_range(c, c.cur - 1, c.cur) end end
    local function del(c) if c.cur < #c.chars then delete_range(c, c.cur, c.cur + 1) end end

    for _, k in ipairs({ "esc", "ctrl+[", "ctrl+c" }) do bind(k, cancel) end
    for _, k in ipairs({ "enter", "kp_enter", "ctrl+j", "ctrl+m" }) do bind(k, accept) end
    for _, k in ipairs({ "bs", "shift+bs", "ctrl+h" }) do bind(k, function() if cur then bs(cur) end end) end
    for _, k in ipairs({ "del", "shift+del" }) do bind(k, function() if cur then del(cur) end end) end
    for _, k in ipairs({ "ctrl+bs", "ctrl+w" }) do
        bind(k, function() if cur then delete_range(cur, word_start(cur), cur.cur) end end)
    end
    bind("ctrl+del", function() if cur then delete_range(cur, cur.cur, word_end(cur)) end end)
    bind("ctrl+u", function() if cur then delete_range(cur, 0, cur.cur) end end)
    bind("ctrl+k", function() if cur then delete_range(cur, cur.cur, #cur.chars) end end)
    bind("left", function() if cur then move_cursor(cur, cur.cur - 1) end end)
    bind("right", function() if cur then move_cursor(cur, cur.cur + 1) end end)
    bind("ctrl+b", function() if cur then move_cursor(cur, cur.cur - 1) end end)
    bind("ctrl+f", function() if cur then move_cursor(cur, cur.cur + 1) end end)
    bind("ctrl+left", function() if cur then move_cursor(cur, word_start(cur)) end end)
    bind("ctrl+right", function() if cur then move_cursor(cur, word_end(cur)) end end)
    bind("ctrl+a", function() if cur then move_cursor(cur, 0) end end)
    bind("ctrl+e", function() if cur then move_cursor(cur, #cur.chars) end end)
    bind("home", typed(function(c) c.focus = 1 ensure_visible(c) render_modal() end,
        function(c) move_cursor(c, 0) end))
    bind("end", typed(function(c) c.focus = max(1, #c.filtered) ensure_visible(c) render_modal() end,
        function(c) move_cursor(c, #c.chars) end))
    bind("up", typed(function(c) move_focus(c, -1, true) end, nop))
    bind("down", typed(function(c) move_focus(c, 1, true) end, nop))
    bind("ctrl+p", typed(function(c) move_focus(c, -1, true) end, nop))
    bind("ctrl+n", typed(function(c) move_focus(c, 1, true) end, nop))
    bind("tab", typed(function(c) move_focus(c, 1, true) end, nop))
    bind("shift+tab", typed(function(c) move_focus(c, -1, true) end, nop))
    bind("pgup", typed(function(c) move_focus(c, -(c.geo and c.geo.vis or 8)) end, nop))
    bind("pgdwn", typed(function(c) move_focus(c, c.geo and c.geo.vis or 8) end, nop))
    bind("wheel_up", function() wheel(-1) end)
    bind("wheel_down", function() wheel(1) end)
    for _, k in ipairs({ "ctrl+v", "meta+v", "shift+ins" }) do bind(k, function() if cur then paste(cur) end end) end
    -- NumLock-off numpad (or Home/End sent without the extended-key flag) arrives as KP_*.
    bind("kp_home", typed(function(c) c.focus = 1 ensure_visible(c) render_modal() end,
        function(c) move_cursor(c, 0) end))
    bind("kp_end", typed(function(c) c.focus = max(1, #c.filtered) ensure_visible(c) render_modal() end,
        function(c) move_cursor(c, #c.chars) end))
    bind("kp_up", typed(function(c) move_focus(c, -1, true) end, nop))
    bind("kp_down", typed(function(c) move_focus(c, 1, true) end, nop))
    bind("kp_pgup", typed(function(c) move_focus(c, -(c.geo and c.geo.vis or 8)) end, nop))
    bind("kp_pgdwn", typed(function(c) move_focus(c, c.geo and c.geo.vis or 8) end, nop))
    bind("kp_left", function() if cur then move_cursor(cur, cur.cur - 1) end end)
    bind("kp_right", function() if cur then move_cursor(cur, cur.cur + 1) end end)
    for d = 0, 9 do bind("kp" .. d, function() if cur then insert_text(cur, tostring(d)) end end) end
    bind("kp_dec", function() if cur then insert_text(cur, ".") end end)
    bind("kp_add", function() if cur then insert_text(cur, "+") end end)
    bind("kp_subtract", function() if cur then insert_text(cur, "-") end end)
    bind("kp_multiply", function() if cur then insert_text(cur, "*") end end)
    bind("kp_divide", function() if cur then insert_text(cur, "/") end end)

    n = n + 1
    local tname = "_fluent_in_text"
    bound_names[#bound_names + 1] = tname
    mp.add_forced_key_binding("any_unicode", tname, function(info)
        if cur and info.key_text and (info.event == "press" or info.event == "down" or info.event == "repeat") then
            insert_text(cur, info.key_text)
        end
    end, { repeatable = true, complex = true })

    -- Mouse section: a full-window area without allow-vo-dragging, so clicks
    -- never drag the window while the modal is open.
    section_name = "fluent_modal_" .. mp.get_script_name()
    mp.set_key_bindings({
        { "mbtn_left", click },
        { "mbtn_left_dbl", click },
        { "mbtn_right", cancel },
        { "mbtn_mid", function() end },
    }, section_name, "force")
    mp.enable_key_bindings(section_name)
end

local function unbind_all()
    for _, name in ipairs(bound_names) do mp.remove_key_binding(name) end
    bound_names = {}
    if section_name then
        mp.disable_key_bindings(section_name)
        section_name = nil
    end
end

-- Open / close --------------------------------------------------------------

local function set_modal_flag(on)
    pcall(mp.set_property_native, MODAL_PROP, on)
    mp.commandv("script-message", "nanum-fluent", "ui-modal", on and "yes" or "no")
end

local function setup(s)
    cur = s
    bind_all(s)
    ime_prev = mp.get_property_bool("input-ime")
    mp.set_property_bool("input-ime", true)
    local function on_dims() if cur then render_modal() end end
    local function on_mouse() if cur then mouse_moved() end end
    observers = { on_dims, on_mouse }
    mp.observe_property("osd-dimensions", "native", on_dims)
    mp.observe_property("mouse-pos", "native", on_mouse)
    blink_timer = mp.add_periodic_timer(0.53, function()
        if cur then
            cur.blink_on = not cur.blink_on
            render_modal()
        end
    end)
    set_modal_flag(true)
    if not registered then
        registered = true
        mp.register_script_message("fluent-modal-takeover", function(owner)
            if owner ~= mp.get_script_name() and cur then close_current() end
        end)
    end
    mp.commandv("script-message", "fluent-modal-takeover", mp.get_script_name())
end

local function teardown(silent)
    unbind_all()
    for _, fn in ipairs(observers) do mp.unobserve_property(fn) end
    observers = {}
    if blink_timer then blink_timer:kill() blink_timer = nil end
    hide_overlay()
    if ime_prev ~= nil then
        mp.set_property_bool("input-ime", ime_prev)
        ime_prev = nil
    end
    if not silent then set_modal_flag(false) end
end

-- Close the active request; the closed callback runs after the UI is gone.
function close_current()
    local s = cur
    if not s then return end
    cur = nil
    teardown(false)
    if s.t.closed then
        dispatch(s.t.closed, s.chars and text_of(s) or "", (s.cur or 0) + 1)
    end
end

function open_request(kind, t)
    if depth > 0 then
        pending = { kind = kind, t = t }
        return
    end
    local prev = cur
    if prev then
        if prev.t.keep_open then
            cur = nil
            teardown(true)              -- seamless transition
        else
            close_current()
        end
    end
    local s = { kind = kind, t = t, style = t.style, blink_on = true, chars = {}, cur = 0, top = 1, focus = 1, progress = t.progress }
    if kind == "select" then
        s.rows, s.has_marks = build_rows(t)
        s.filtered = {}
        for i = 1, #s.rows do s.filtered[i] = i end
        s.focus = clamp(tonumber(t.default_item) or 1, 1, max(1, #s.rows))
        if t.default_text and t.default_text ~= "" then
            s.chars = chars_of(t.default_text)
            s.cur = #s.chars
            refilter(s)
        end
    else
        s.chars = chars_of(tostring(t.default_text or ""))
        s.cur = t.cursor_position and clamp(t.cursor_position - 1, 0, #s.chars) or #s.chars
    end
    setup(s)
    local ok, err = pcall(render_modal)
    if not ok then report_error("render", err) end
    if t.opened then dispatch(t.opened) end
end

-- The built-in labels (placeholder, hints, buttons, fonts) follow the UI language; caller text stays as passed.
F.i18n.on_change(function()
    if cur then
        local ok, err = pcall(render_modal)
        if not ok then report_error("render", err) end
    end
end)

----------------------------------------------------------------------------
-- Public API (mp.input compatible)
----------------------------------------------------------------------------

function F.select(t)
    t = t or {}
    t.items = t.items or {}
    open_request("select", t)
end

function F.get(t)
    t = t or {}
    open_request("get", t)
end

function F.terminate()
    if depth > 0 and pending then pending = nil end
    if cur then close_current() end
end

-- Replace the rows of the open select modal `id` (select{ id = ... }) without
-- closing it: the focused row (by key), the scroll position and the search text
-- stay. o.keys: stable key per item (default: its index); o.progress: key ->
-- fraction 0..1 drawn as a bar under the row. False if that modal is not open.
function F.update_select(id, items, o)
    local s = cur
    if not s or s.kind ~= "select" or s.t.id ~= id then return false end
    o = o or {}
    local focus_key = s.filtered[s.focus] and s.rows[s.filtered[s.focus]].key
    local top = s.top
    s.t.items, s.t.keys = items, o.keys
    s.progress = o.progress
    s.rows, s.has_marks = build_rows(s.t)
    refilter(s)
    for fi, ri in ipairs(s.filtered) do
        if s.rows[ri].key == focus_key then s.focus = fi break end
    end
    s.top = top
    ensure_visible(s)
    render_modal()
    return true
end

-- id of the open modal request (nil if none or it has no id).
function F.open_id()
    return cur and cur.t.id or nil
end

function F.is_open()
    return cur ~= nil
end

-- True while any script's Fluent modal is open.
function F.modal_busy()
    for _, name in ipairs({ "nanum", "nanum_fluent" }) do
        if mp.get_property_native("user-data/fluent/modal-" .. name) == true then return true end
    end
    return false
end

return F
