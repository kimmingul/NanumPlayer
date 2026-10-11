-- NanumPlayer Fluent chrome: start screen, playback toolbar, toasts.
--
-- Draws a Windows 11 style dark UI on one ASS overlay (no mpv OSC):
--   * idle: heading, "파일 열기" / "Blu-ray 열기" cards, "YouTube" / "AI 자막 설정" pills,
--   * playback: auto-hiding header (title + AI status) and rounded bottom panel
--     (timeline with drag + preview, play, +-10 s, volume, open file / disc,
--     audio / subtitle track lists, AI settings, fullscreen),
--   * toasts that replace the stock OSD text.
--
-- Script messages (`script-message nanum-fluent <cmd> ...`):
--   ui-modal yes|no          a Fluent modal opened/closed (pauses toolbar mouse handling)
--   ui-status <text> [kind] [action]  AI status chip; kind = ok|warn|busy|error|info; empty text clears;
--                            action "models": clicking the chip opens the AI component manager (CPU/CUDA/models)
--   ui-hide controls         hide the toolbar until the next mouse move
--   ui-show controls         wake the toolbar
--   toast <text> [secs] [kind] [id]
--   click <element id>       activate a toolbar/start screen element (test driver)
--   dump-layout              log element rectangles (window pixels)
-- The element rectangles (window pixels, same space as mouse-pos) are also
-- published in the user-data/fluent/layout property.

local mp = require 'mp'

local function load_ui()
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
    if ok and ed then dirs[#dirs + 1] = ed end
    for _, d in ipairs(dirs) do
        local f = loadfile(d .. "/fluent-input.lua")
        if f then return f() end
    end
    return nil
end

local F = load_ui()
if not F then
    mp.msg.error("nanum-fluent: scripts/fluent-input.lua not found")
    return
end
local C = F.C
local I = F.icons
local clamp, in_rect, fit, text_w = F.clamp, F.in_rect, F.fit, F.text_w
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

local HIDE_DELAY = 2.6

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

local S = {
    vis = 0,                    -- toolbar opacity 0..1
    last_tick = mp.get_time(),
    last_move = -1e9,
    force_until = 0,
    hide_override = false,
    modal = false,
    mouse = nil,                -- logical pointer {x, y}
    px = -1, py = -1,
    hover = nil,                -- hovered element id
    hover_since = 0,
    pressed = nil,
    drag = nil,                 -- "seek" | "vol"
    drag_frac = nil,
    status = nil,               -- { text, kind }
    toasts = {},
    L = nil,                    -- last layout
    dirty = true,
    last_data = nil,
    idle = true,
    loaded = false,
    has_video = true,
    cur_audio = nil,
    cur_sub = nil,
    sub_base = nil,
    sub_lifted = false,
    layout_key = nil,
    last_pulse = 0,
    click_timer = nil,
    first_vol = true,
    quiet_until = 0,
}

local overlay = mp.create_osd_overlay("ass-events")
overlay.z = 0

local function now() return mp.get_time() end
local function dirty() S.dirty = true end

----------------------------------------------------------------------------
-- Track labels
----------------------------------------------------------------------------

local LANG_KO = {
    eng = "영어", en = "영어", jpn = "일본어", ja = "일본어", kor = "한국어", ko = "한국어",
    chi = "중국어", zho = "중국어", zh = "중국어", cmn = "중국어", yue = "광둥어",
    spa = "스페인어", es = "스페인어", fre = "프랑스어", fra = "프랑스어", fr = "프랑스어",
    ger = "독일어", deu = "독일어", de = "독일어", ita = "이탈리아어", it = "이탈리아어",
    por = "포르투갈어", pt = "포르투갈어", rus = "러시아어", ru = "러시아어",
    tha = "태국어", th = "태국어", vie = "베트남어", vi = "베트남어", ara = "아랍어", ar = "아랍어",
    hin = "힌디어", hi = "힌디어", dut = "네덜란드어", nld = "네덜란드어", nl = "네덜란드어",
    pol = "폴란드어", pl = "폴란드어", tur = "튀르키예어", tr = "튀르키예어", swe = "스웨덴어",
    sv = "스웨덴어", dan = "덴마크어", da = "덴마크어", fin = "핀란드어", fi = "핀란드어",
    nor = "노르웨이어", no = "노르웨이어", cze = "체코어", ces = "체코어", cs = "체코어",
    gre = "그리스어", ell = "그리스어", el = "그리스어", heb = "히브리어", he = "히브리어",
    hun = "헝가리어", hu = "헝가리어", ind = "인도네시아어", id = "인도네시아어",
    ukr = "우크라이나어", uk = "우크라이나어", rum = "루마니아어", ron = "루마니아어", ro = "루마니아어",
}

local CODEC = {
    truehd = "TrueHD", ac3 = "Dolby Digital", eac3 = "Dolby Digital+", dts = "DTS", flac = "FLAC",
    aac = "AAC", mp3 = "MP3", opus = "Opus", vorbis = "Vorbis", alac = "ALAC", mp2 = "MP2",
    hdmv_pgs_subtitle = "PGS", subrip = "SRT", srt = "SRT", ass = "ASS", ssa = "SSA",
    webvtt = "WebVTT", dvd_subtitle = "VobSub", mov_text = "MOV", text = "TXT",
}

local function lang_name(l)
    if type(l) ~= "string" or l == "" then return nil end
    local k = l:lower():match("^([^%-_]+)") or l:lower()
    return LANG_KO[k] or l:upper()
end

local function channel_name(n)
    if n == 1 then return "모노" elseif n == 2 then return "스테레오" elseif n == 6 then return "5.1"
    elseif n == 8 then return "7.1" elseif n then return n .. "채널" end
    return nil
end

local function track_label(t)
    -- the AI tracks are titled "한국어 (영어 음성 기반)": no second "한국어" in front of that
    local lang = lang_name(t.lang)
    local title = (t.title and t.title ~= "") and t.title or nil
    local parts = {}
    if not (lang and title and title:sub(1, #lang) == lang) then
        parts[1] = lang or (t.external and "외부" or "알 수 없음")
    end
    if title then parts[#parts + 1] = title end
    local codec = t.codec and (CODEC[t.codec:lower()] or t.codec:upper()) or nil
    if t.type == "audio" then
        local ch = channel_name(t["demux-channel-count"])
        local extra = codec and ((ch and (codec .. " " .. ch)) or codec) or ch
        if extra then parts[#parts + 1] = extra end
    elseif codec then
        parts[#parts + 1] = codec
    end
    if t.forced then parts[#parts + 1] = "강제" end
    if t.external and lang_name(t.lang) then parts[#parts + 1] = "외부" end
    return table.concat(parts, " · ")
end

local function refresh_tracks()
    local tracks = mp.get_property_native("track-list") or {}
    local a, s, v = nil, nil, false
    for _, t in ipairs(tracks) do
        if t.type == "audio" and t.selected then a = track_label(t) end
        if t.type == "sub" and t.selected then s = track_label(t) end
        if t.type == "video" and not t.albumart then v = true end
    end
    S.cur_audio, S.cur_sub, S.has_video = a, s, v
    dirty()
end

----------------------------------------------------------------------------
-- Toasts
----------------------------------------------------------------------------

local function add_toast(text, secs, kind, id)
    if not text or text == "" then return end
    local t = { text = text, kind = kind or "info", born = now(), ttl = secs or 3, id = id }
    if id then
        for i, o in ipairs(S.toasts) do
            if o.id == id then
                table.remove(S.toasts, i)
                break
            end
        end
    end
    S.toasts[#S.toasts + 1] = t
    while #S.toasts > 3 do table.remove(S.toasts, 1) end
    dirty()
end

local function kind_color(k)
    if k == "ok" then return C.ok elseif k == "error" then return C.err
    elseif k == "warn" then return C.warn elseif k == "busy" then return C.accent end
    return C.text3
end

----------------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------------

local function run(...)
    local ok, err = mp.commandv(...)
    if not ok then
        add_toast("실행하지 못했습니다: " .. tostring((...)) .. (err and (" (" .. tostring(err) .. ")") or ""), 5, "error")
    end
    return ok
end

local function open_file() run("nanum-open-file") end
local function open_youtube() run("script-binding", "nanum-youtube") end
local function open_disc() run("nanum-open-disc") end
local function open_ai() run("script-binding", "nanum-settings") end

local DISPLAY_NAME = { translation = "번역만", bilingual = "번역+원문", source = "원문만" }

local function track_menu(kind, anchor)
    local tracks = mp.get_property_native("track-list") or {}
    local items, values, def, any_sel = {}, {}, 1, false
    -- the player keeps the secondary / disc (OCR) AI tracks once they exist: offer them only while they are
    -- being made / usable
    local cs = mp.get_property_native("demuxer-cache-state") or {}
    local hidden = {}
    for _, key in ipairs({ "secondary", "pgs" }) do
        local src, state = cs["nanum-track-" .. key], cs["nanum-" .. key .. "-state"]
        if type(src) == "number" and src >= 0 and (state == "off" or state == "unavailable") then hidden[src] = true end
    end
    if kind == "sub" then
        items[1], values[1] = "자막 끄기", "no"
    end
    for _, t in ipairs(tracks) do
        if t.type == kind and not (kind == "sub" and not t.external and not t.selected and hidden[t["src-id"]]) then
            items[#items + 1] = (t.selected and "● " or "  ") .. track_label(t)
            values[#values + 1] = t.id
            if t.selected then def, any_sel = #items, true end
        end
    end
    if kind == "audio" and #values == 0 then
        add_toast("재생할 음성 트랙이 없습니다", 3, "warn")
        return
    end
    if kind == "sub" then
        if #values == 1 then
            add_toast("이 영상에는 자막 트랙이 없습니다 (AI 자막은 준비되면 표시됩니다)", 4, "warn")
            return
        end
        items[1] = (any_sel and "  " or "● ") .. items[1]
        if not any_sel then def = 1 end
        -- how the AI subtitles are shown (translation / translation + source / source)
        local mode = mp.get_property("options/nanum-display")
        items[#items + 1] = "  자막 표시 방식: " .. (DISPLAY_NAME[mode] or "번역만") .. " …"
        values[#values + 1] = "display"
    end
    F.select({
        prompt = kind == "audio" and "음성 트랙" or "자막 트랙",
        items = items,
        default_item = def,
        anchor = anchor,
        submit = function(i)
            local v = values[i]
            if v == "display" then
                run("script-binding", "nanum-display")
                return
            end
            if kind == "audio" then
                mp.set_property_number("aid", v)
            else
                mp.set_property("sid", tostring(v))
            end
        end,
    })
end

local function seek_to_frac(frac)
    local dur = mp.get_property_number("duration")
    if not dur or dur <= 0 then return end
    -- seek in playback time (time-pos domain), same as duration
    mp.commandv("seek", string.format("%.3f", clamp(frac, 0, 1) * dur), "absolute")
end

local function set_volume_frac(frac)
    mp.set_property_number("volume", floor(clamp(frac, 0, 1) * 100 + 0.5))
    if mp.get_property_bool("mute") then mp.set_property_bool("mute", false) end
end

local function activate(id)
    local L = S.L
    local el = L and L.byid[id]
    if id == "play" then
        mp.commandv("cycle", "pause")
    elseif id == "back" then
        mp.commandv("seek", "-10")
    elseif id == "fwd" then
        mp.commandv("seek", "10")
    elseif id == "mute" then
        mp.commandv("cycle", "mute")
    elseif id == "open" or id == "card_file" then
        open_file()
    elseif id == "disc" or id == "card_disc" then
        open_disc()
    elseif id == "audio" then
        track_menu("audio", el and L.panel and { x = el.x + el.w / 2, y = L.panel.y })
    elseif id == "sub" then
        track_menu("sub", el and L.panel and { x = el.x + el.w / 2, y = L.panel.y })
    elseif id == "chip" and S.status and S.status.action == "models" then
        run("script-binding", "nanum-models")
    elseif id == "card_yt" then
        open_youtube()
    elseif id == "ai" or id == "chip" or id == "card_ai" then
        open_ai()
    elseif id == "fs" then
        mp.commandv("cycle", "fullscreen")
    end
    dirty()
end

----------------------------------------------------------------------------
-- Layout
----------------------------------------------------------------------------

local function add_el(L, id, x, y, w, h, tip, extra)
    local e = { id = id, x = x, y = y, w = w, h = h, tip = tip }
    if extra then for k, v in pairs(extra) do e[k] = v end end
    L.els[#L.els + 1] = e
    L.byid[id] = e
    return e
end

local function pill_w(label, show_label)
    if not show_label then return 38 end
    return floor(18 + 8 + text_w(label, 13.5) + 28)
end

local function layout_play(m)
    local W, H = m.W, m.H
    local L = { els = {}, byid = {}, W = W, H = H, kind = "play" }
    local pw = clamp(W - 40, 320, 960)
    local ph = 112
    local px = floor((W - pw) / 2)
    local slide = floor((1 - S.vis) * 14)
    local py = H - ph - 20 + slide
    L.panel = { x = px, y = py, w = pw, h = ph }
    L.header = { x = px, y = 16 - floor((1 - S.vis) * 10), w = pw, h = 46 }

    local cy1 = py + 34
    L.seek = { x0 = px + 24 + 56, x1 = px + pw - 24 - 56, cy = cy1 }
    add_el(L, "seek", L.seek.x0 - 8, cy1 - 14, L.seek.x1 - L.seek.x0 + 16, 28, nil, { kind = "slider" })

    local show_slider, show_open, show_labels = pw >= 760, pw >= 620, pw >= 500
    local cy2 = py + 80
    local x = px + 22
    add_el(L, "play", x, cy2 - 23, 46, 46, "재생 / 일시정지 (Space)")
    x = x + 46 + 8
    add_el(L, "back", x, cy2 - 19, 38, 38, "10초 뒤로")
    x = x + 38
    add_el(L, "fwd", x, cy2 - 19, 38, 38, "10초 앞으로")
    x = x + 38 + 10
    add_el(L, "mute", x, cy2 - 19, 38, 38, "음소거 (M)")
    x = x + 38
    if show_slider then
        L.vol = { x0 = x + 6, x1 = x + 6 + 84, cy = cy2 }
        add_el(L, "vol", x, cy2 - 14, 96, 28, "볼륨", { kind = "slider" })
    end

    local rx = px + pw - 22
    rx = rx - 38
    add_el(L, "fs", rx, cy2 - 19, 38, 38, "전체 화면 (F)")
    rx = rx - 14
    local function pill(id, label, tip)
        local w = pill_w(label, show_labels)
        rx = rx - w
        add_el(L, id, rx, cy2 - 19, w, 38, tip, { label = label, pill = true })
        rx = rx - 6
    end
    pill("ai", "AI", "AI 자막 설정 (Ctrl+N)")
    pill("sub", "자막", "자막 트랙" .. (S.cur_sub and (" · " .. S.cur_sub) or " · 꺼짐"))
    pill("audio", "음성", "음성 트랙" .. (S.cur_audio and (" · " .. S.cur_audio) or ""))
    if show_open then
        rx = rx - 8
        rx = rx - 38
        add_el(L, "disc", rx, cy2 - 19, 38, 38, "Blu-ray 열기 (Ctrl+D)")
        rx = rx - 6 - 38
        add_el(L, "open", rx, cy2 - 19, 38, 38, "파일 열기 (Ctrl+O)")
    end

    -- status chip in the header
    if S.status then
        local cw = clamp(text_w(S.status.text, 12.5) + 56, 80, pw * 0.5)
        add_el(L, "chip", L.header.x + L.header.w - 12 - cw, L.header.y + 8, cw, 30,
            S.status.action == "models" and "AI 구성 요소 관리 열기" or "AI 자막 설정 열기", { kind = "chip" })
    end
    return L
end

local function layout_idle(m)
    local W, H = m.W, m.H
    local L = { els = {}, byid = {}, W = W, H = H, kind = "idle" }
    local f = clamp(min(W / 760, H / 560), 0.6, 1.0)
    L.f = f
    local total = (84 + 20 + 44 + 8 + 24 + 40 + 124 + 22 + 44) * f
    local y0 = max(16, floor((H - total) / 2 - 10))
    L.logo = { cx = W / 2, cy = y0 + 42 * f, s = 84 * f }
    L.title_y = y0 + (84 + 20 + 22) * f
    L.sub_y = y0 + (84 + 20 + 44 + 8 + 12) * f
    local cw, ch, gap = 300 * f, 124 * f, 20 * f
    local cx0 = floor((W - (2 * cw + gap)) / 2)
    local cy = y0 + (84 + 20 + 44 + 8 + 24 + 40) * f
    add_el(L, "card_file", cx0, cy, cw, ch, nil, { kind = "card" })
    add_el(L, "card_disc", cx0 + cw + gap, cy, cw, ch, nil, { kind = "card" })
    local aw, agap = 250 * f, 20 * f
    local ax = floor((W - (2 * aw + agap)) / 2)
    add_el(L, "card_yt", ax, cy + ch + 22 * f, aw, 44 * f, nil, { kind = "card" })
    add_el(L, "card_ai", ax + aw + agap, cy + ch + 22 * f, aw, 44 * f, nil, { kind = "card" })
    return L
end

----------------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------------

local function glow(A, W, H)
    A:rect(0, 0, W, H, { fill = C.bg, fa = 1 })
    local r = min(280, max(W, H) * 0.32)
    A:circle(W * 0.16, H * 0.14, r, { fill = C.accent2, fa = 0.17, blur = 60 })
    A:circle(W * 0.86, H * 0.9, r * 0.9, { fill = "B0D62A", fa = 0.09, blur = 60 })
end

local function hover_bg(A, el, r)
    if S.pressed == el.id then
        A:rrect(el.x, el.y, el.w, el.h, r, { fill = C.white, fa = 0.06 })
    elseif S.hover == el.id then
        A:rrect(el.x, el.y, el.w, el.h, r, { fill = C.white, fa = 0.11 })
    end
end

local function draw_idle(A, L)
    local W, H, f = L.W, L.H, L.f
    glow(A, W, H)
    I.logo(A, L.logo.cx, L.logo.cy, L.logo.s)
    A:text(W / 2, L.title_y, "Nanum Player", { size = 34 * f, bold = true, color = C.text, an = 5 })
    A:text(W / 2, L.sub_y, "AI 한국어 자막과 함께 즐기는 미디어 플레이어",
        { size = 15 * f, color = C.text2, an = 5 })

    local function card(el, icon, title, desc, key)
        local hot, down = S.hover == el.id, S.pressed == el.id
        A:shadow(el.x, el.y, el.w, el.h, 14 * f, 0.45)
        A:rrect(el.x, el.y, el.w, el.h, 14 * f, {
            fill = down and C.bg or (hot and C.card2 or C.card), fa = 0.96,
            stroke = hot and C.accent or C.white, sa = hot and 0.9 or 0.1, sw = hot and 1.6 or 1,
        })
        local ic = 48 * f
        local icx, icy = el.x + 24 * f + ic / 2, el.y + 16 * f + ic / 2
        A:circle(icx, icy, ic / 2, { fill = C.accent, fa = hot and 0.28 or 0.16 })
        icon(A, icx, icy, 26 * f, C.accent, 1)
        A:text(el.x + 24 * f, el.y + el.h - 44 * f, title, { size = 18 * f, bold = true, color = C.text })
        A:text(el.x + 24 * f, el.y + el.h - 20 * f, fit(desc, 13 * f, el.w - 48 * f),
            { size = 13 * f, color = C.text2 })
        local kw = text_w(key, 11.5 * f) + 18 * f
        A:rrect(el.x + el.w - 16 * f - kw, el.y + 16 * f, kw, 22 * f, 6 * f, { fill = C.white, fa = 0.08 })
        A:text(el.x + el.w - 16 * f - kw / 2, el.y + 27 * f, key, { size = 11.5 * f, color = C.text3, an = 5 })
    end
    card(L.byid.card_file, I.folder, "파일 열기", "동영상·음악 파일을 선택해 재생합니다", "Ctrl+O")
    card(L.byid.card_disc, I.disc, "Blu-ray 열기", "디스크 드라이브의 영화를 바로 재생합니다", "Ctrl+D")

    local function pill(el, icon, label, key)
        local hot, down = S.hover == el.id, S.pressed == el.id
        A:rrect(el.x, el.y, el.w, el.h, el.h / 2, {
            fill = down and C.bg or (hot and C.card2 or C.card), fa = 0.92,
            stroke = hot and C.accent or C.white, sa = hot and 0.9 or 0.1, sw = 1.2,
        })
        icon(A, el.x + 30 * f, el.y + el.h / 2, 22 * f, C.accent, 1)
        A:text(el.x + 54 * f, el.y + el.h / 2, label, { size = 14.5 * f, color = C.text })
        A:text(el.x + el.w - 22 * f, el.y + el.h / 2, key, { size = 12 * f, color = C.text3, an = 6 })
    end
    pill(L.byid.card_yt, I.youtube, "YouTube", "Ctrl+Y")
    pill(L.byid.card_ai, I.sparkle, "AI 자막 설정", "Ctrl+N")

    A:text(W / 2, H - 52 * f, "파일이나 Blu-ray 폴더를 이 창으로 끌어다 놓아도 재생됩니다",
        { size = 13 * f, color = C.text3, an = 5 })
    A:text(W / 2, H - 28 * f, "Space 재생·일시정지   F 전체 화면   Ctrl+N AI 자막 설정",
        { size = 12 * f, color = C.text3, an = 5, a = 0.8 })
end

local function title_text()
    local mt = mp.get_property("media-title")
    local p = mp.get_property("path") or ""
    local lp = p:lower()
    if lp:find("^bd://") or lp:find("bdmv") or lp:find("^bluray://") then
        if mt and mt ~= "" and not mt:find("^%a+://") then return mt end
        return "Blu-ray 디스크"
    end
    if mt and mt ~= "" and not mt:find("^%a+://") then return mt end
    local base = p:match("([^/\\]+)[/\\]*$")
    return base or p
end

local function draw_status_chip(A, el, pulse)
    local st = S.status
    local col = kind_color(st.kind)
    A:rrect(el.x, el.y, el.w, el.h, el.h / 2, {
        fill = S.hover == "chip" and C.card2 or C.white, fa = S.hover == "chip" and 0.9 or 0.07,
        stroke = col, sa = 0.35, sw = 1,
    })
    local da = 1
    if st.kind == "busy" then da = 0.55 + 0.45 * math.sin(now() * 5) end
    A:circle(el.x + 16, el.y + el.h / 2, 4, { fill = col, fa = da })
    A:text(el.x + 28, el.y + el.h / 2, fit(st.text, 12.5, el.w - 36), { size = 12.5, color = C.text })
end

local function draw_toasts(A, L)
    local t0 = now()
    local y = L.H - 20 - 112 - 24
    if L.kind ~= "play" then y = L.H - 110 end
    for i = #S.toasts, 1, -1 do
        local t = S.toasts[i]
        local age = t0 - t.born
        local a = 1
        if age < 0.15 then a = age / 0.15 elseif age > t.ttl - 0.4 then a = clamp((t.ttl - age) / 0.4, 0, 1) end
        local lines = {}
        for line in (t.text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
        local tw = 0
        for _, ln in ipairs(lines) do tw = max(tw, text_w(ln, 14)) end
        local w = clamp(tw + 56, 140, L.W - 40)
        local h = #lines * 21 + 22
        local x = floor((L.W - w) / 2)
        local ty = y - h + (1 - a) * 8
        local TA = F.new_ass(a)
        TA:shadow(x, ty, w, h, 10, 0.45)
        TA:rrect(x, ty, w, h, 10, { fill = C.card, fa = 0.96, stroke = C.white, sa = 0.12, sw = 1 })
        TA:rrect(x + 1, ty + 9, 3, h - 18, 1.5, { fill = kind_color(t.kind), fa = 1 })
        for li, ln in ipairs(lines) do
            TA:text(x + 22, ty + 11 + (li - 0.5) * 21, fit(ln, 14, w - 44), { size = 14, color = C.text })
        end
        A:raw(TA:str())
        y = ty - 8
    end
end

local function seek_state()
    local dur = mp.get_property_number("duration")
    local pos = mp.get_property_number("time-pos") or 0
    return dur, pos
end

local function draw_play(A, L, m)
    local W, H = L.W, L.H
    local dur, pos = seek_state()
    local hot = S.hover
    local pnl, hd = L.panel, L.header

    if not S.has_video and S.loaded then
        glow(A, W, H)
        I.logo(A, W / 2, H / 2 - 40, 84)
        A:text(W / 2, H / 2 + 36, fit(title_text(), 22, W - 80), { size = 22, bold = true, color = C.text, an = 5 })
        A:text(W / 2, H / 2 + 66, "오디오 재생 중", { size = 14, color = C.text2, an = 5 })
    end

    if not S.loaded then
        local w, h = clamp(W - 40, 280, 460), 108
        local x, y = floor((W - w) / 2), floor(H / 2 - h / 2)
        glow(A, W, H)
        A:shadow(x, y, w, h, 14, 0.5)
        A:rrect(x, y, w, h, 14, { fill = C.card, fa = 0.97, stroke = C.white, sa = 0.12, sw = 1 })
        local dots = floor(now() * 3) % 4
        A:text(x + 28, y + 36, "불러오는 중" .. string.rep(".", dots), { size = 19, bold = true, color = C.text })
        A:text(x + 28, y + 68, fit(title_text(), 13, w - 56), { size = 13, color = C.text2 })
        local p = (mp.get_property("path") or ""):lower()
        if p:find("bd://") or p:find("bdmv") then
            A:text(x + 28, y + 90, "Blu-ray는 디스크 인증 때문에 시간이 걸릴 수 있습니다", { size = 11.5, color = C.text3 })
        end
    elseif mp.get_property_bool("paused-for-cache") or mp.get_property_bool("seeking") then
        local w, h = 150, 40
        local x, y = floor((W - w) / 2), floor(H * 0.2)
        A:rrect(x, y, w, h, 20, { fill = C.card, fa = 0.92, stroke = C.white, sa = 0.12, sw = 1 })
        local dots = floor(now() * 3) % 4
        A:text(x + 24, y + h / 2, "버퍼링 중" .. string.rep(".", dots), { size = 13.5, color = C.text })
    end

    local g = S.vis
    if g > 0.01 then
        local TA = F.new_ass(g)
        -- header
        TA:shadow(hd.x, hd.y, hd.w, hd.h, 12, 0.35)
        TA:rrect(hd.x, hd.y, hd.w, hd.h, 12, { fill = C.card, fa = 0.88, stroke = C.white, sa = 0.1, sw = 1 })
        local chip = L.byid.chip
        local tw = hd.w - 36 - (chip and chip.w + 16 or 0)
        TA:rrect(hd.x + 16, hd.y + hd.h / 2 - 8, 3, 16, 1.5, { fill = C.accent, fa = 1 })
        TA:text(hd.x + 30, hd.y + hd.h / 2, fit(title_text(), 15, tw - 14), { size = 15, bold = true, color = C.text })
        if chip then draw_status_chip(TA, chip) end

        -- panel
        TA:shadow(pnl.x, pnl.y, pnl.w, pnl.h, 16, 0.5)
        TA:rrect(pnl.x, pnl.y, pnl.w, pnl.h, 16, { fill = C.card, fa = 0.92, stroke = C.white, sa = 0.1, sw = 1 })

        -- timeline
        local sk = L.seek
        local cy = sk.cy
        local dragging = S.drag == "seek"
        local seek_hot = hot == "seek" or dragging
        local len = sk.x1 - sk.x0
        local frac = 0
        if dragging and S.drag_frac then
            frac = S.drag_frac
        elseif dur and dur > 0 then
            frac = clamp(pos / dur, 0, 1)
        end
        local shown_pos = dur and dur > 0 and frac * dur or pos
        TA:text(sk.x0 - 14, cy, F.fmt_time(shown_pos), { size = 12.5, color = C.text2, an = 6 })
        TA:text(sk.x1 + 14, cy, dur and F.fmt_time(dur) or "--:--", { size = 12.5, color = C.text2, an = 4 })
        local th = seek_hot and 6 or 4
        TA:rrect(sk.x0, cy - th / 2, len, th, th / 2, { fill = C.white, fa = 0.2 })
        local st = mp.get_property_number("demuxer-start-time") or 0
        local cs = mp.get_property_native("demuxer-cache-state")
        if cs and dur and dur > 0 then
            for _, r in ipairs(cs["seekable-ranges"] or {}) do
                local a = clamp((r.start - st) / dur, 0, 1)
                local b = clamp((r["end"] - st) / dur, 0, 1)
                if b > a then
                    TA:rrect(sk.x0 + a * len, cy - th / 2, (b - a) * len, th, th / 2, { fill = C.white, fa = 0.26 })
                end
            end
        end
        if dur and dur > 0 then
            local chs = mp.get_property_native("chapter-list")
            if chs and #chs > 1 then
                for _, c in ipairs(chs) do
                    if c.time > 0.5 and c.time < dur - 0.5 then
                        TA:rect(sk.x0 + c.time / dur * len - 0.75, cy - th / 2 - 1, 1.5, th + 2, { fill = C.card, fa = 0.9 })
                    end
                end
            end
        end
        local px = sk.x0 + frac * len
        if px > sk.x0 then
            TA:rrect(sk.x0, cy - th / 2, px - sk.x0, th, th / 2, { fill = C.accent, fa = 1 })
        end
        local ready = cs and cs["nanum-ready-until"]
        if ready and dur and dur > 0 then
            local a = clamp(pos / dur, 0, 1)
            local b = clamp((ready - st) / dur, 0, 1)
            if b > a then
                TA:rrect(sk.x0 + a * len, cy + th / 2 + 2, (b - a) * len, 2, 1, { fill = C.ok, fa = 0.9 })
            end
        end
        local tr = seek_hot and 8 or 6
        TA:circle(px, cy, tr + 2, { fill = C.black, fa = 0.25, blur = 2 })
        TA:circle(px, cy, tr, { fill = C.white, fa = 1 })
        TA:circle(px, cy, tr * 0.5, { fill = C.accent, fa = 1 })

        -- hover / drag preview
        if S.mouse and dur and dur > 0 and (hot == "seek" or dragging) then
            local f2 = dragging and S.drag_frac or clamp((S.mouse.x - sk.x0) / len, 0, 1)
            local t = f2 * dur
            local label = F.fmt_time(t)
            local chs = mp.get_property_native("chapter-list")
            if chs and #chs > 1 then
                local idx
                for i, c in ipairs(chs) do if c.time <= t + 0.01 then idx = i end end
                if idx then label = label .. "  ·  챕터 " .. idx end
            end
            local bw = text_w(label, 12.5) + 22
            local bx = clamp(sk.x0 + f2 * len - bw / 2, pnl.x + 8, pnl.x + pnl.w - bw - 8)
            TA:shadow(bx, cy - 46, bw, 26, 8, 0.4)
            TA:rrect(bx, cy - 46, bw, 26, 8, { fill = C.card2, fa = 0.98, stroke = C.white, sa = 0.14, sw = 1 })
            TA:text(bx + bw / 2, cy - 33, label, { size = 12.5, color = C.text, an = 5 })
        end

        -- buttons
        local paused = mp.get_property_bool("pause")
        local mute = mp.get_property_bool("mute")
        local vol = mp.get_property_number("volume") or 100
        local fs = mp.get_property_bool("fullscreen")
        local function btn(id, r, fn)
            local el = L.byid[id]
            if not el then return end
            hover_bg(TA, el, r or 8)
            fn(el.x + el.w / 2, el.y + el.h / 2, el)
        end
        local pl = L.byid.play
        local pcx, pcy = pl.x + pl.w / 2, pl.y + pl.h / 2
        local pa = S.pressed == "play" and 0.8 or (hot == "play" and 0.92 or 1)
        TA:circle(pcx, pcy, 23, { fill = C.accent, fa = pa })
        if paused then I.play(TA, pcx + 1, pcy, 24, C.on_accent, 1) else I.pause(TA, pcx, pcy, 24, C.on_accent, 1) end
        btn("back", 8, function(cx, cy2) I.skip(TA, cx, cy2, 26, C.text, 1, false) end)
        btn("fwd", 8, function(cx, cy2) I.skip(TA, cx, cy2, 26, C.text, 1, true) end)
        btn("mute", 8, function(cx, cy2) I.volume(TA, cx, cy2, 22, C.text, 1, vol / 100, mute) end)
        if L.vol then
            local v = L.vol
            local vf = (S.drag == "vol" and S.drag_frac) or clamp(vol / 100, 0, 1)
            if mute then vf = 0 end
            local vh = (hot == "vol" or S.drag == "vol") and 5 or 4
            TA:rrect(v.x0, v.cy - vh / 2, v.x1 - v.x0, vh, vh / 2, { fill = C.white, fa = 0.25 })
            if vf > 0 then
                TA:rrect(v.x0, v.cy - vh / 2, (v.x1 - v.x0) * vf, vh, vh / 2, { fill = C.accent, fa = 1 })
            end
            TA:circle(v.x0 + (v.x1 - v.x0) * vf, v.cy, 6, { fill = C.white, fa = 1 })
        end
        btn("open", 8, function(cx, cy2) I.folder(TA, cx, cy2, 22, C.text, 1) end)
        btn("disc", 8, function(cx, cy2) I.disc(TA, cx, cy2, 22, C.text, 1) end)
        btn("fs", 8, function(cx, cy2) I.fullscreen(TA, cx, cy2, 22, C.text, 1, fs) end)
        local show_labels = L.byid.audio and L.byid.audio.w > 38
        for _, id in ipairs({ "audio", "sub", "ai" }) do
            local el = L.byid[id]
            if el then
                hover_bg(TA, el, 8)
                -- state dot for AI drawn below
                local icon_fn = id == "audio" and I.audio or (id == "sub" and I.subtitle or I.sparkle)
                local tcol = C.text
                if id == "sub" and not S.cur_sub then tcol = C.text3 end
                local ix = show_labels and (el.x + 20) or (el.x + el.w / 2)
                icon_fn(TA, ix, el.y + el.h / 2, 18, id == "ai" and C.accent or tcol, 1)
                if show_labels then
                    TA:text(el.x + 36, el.y + el.h / 2, el.label, { size = 13.5, color = tcol })
                end
                if id == "ai" and S.status then
                    TA:circle(el.x + el.w - 9, el.y + 9, 4, { fill = kind_color(S.status.kind), fa = 1 })
                end
            end
        end

        -- tooltip
        if hot and S.mouse and now() - S.hover_since > 0.4 and not S.drag then
            local el = L.byid[hot]
            if el and el.tip then
                local tw2 = text_w(el.tip, 12.5) + 24
                tw2 = min(tw2, W - 16)
                local bx = clamp(el.x + el.w / 2 - tw2 / 2, 8, W - tw2 - 8)
                local by = el.y - 40
                if el.id == "chip" then by = el.y + el.h + 8 end
                TA:shadow(bx, by, tw2, 28, 8, 0.4)
                TA:rrect(bx, by, tw2, 28, 8, { fill = C.card2, fa = 0.98, stroke = C.white, sa = 0.14, sw = 1 })
                TA:text(bx + tw2 / 2, by + 14, fit(el.tip, 12.5, tw2 - 16), { size = 12.5, color = C.text, an = 5 })
            end
        end
        A:raw(TA:str())
    end
end

----------------------------------------------------------------------------
-- Mouse sections (clicks + blocking window drag over interactive regions)
----------------------------------------------------------------------------

local SECTIONS = { "nfui_a", "nfui_b", "nfui_c" }
local sec_rect = {}

local function hit_element(mx, my)
    local L = S.L
    if not L or not mx then return nil end
    for _, el in ipairs(L.els) do
        if in_rect(mx, my, el.x, el.y, el.w, el.h) then return el end
    end
    return nil
end

local function update_pointer()
    local m = S.m or F.metrics()
    if not m then return end
    local mx, my, hover = F.mouse(m)
    local prev = S.hover
    if mx and hover ~= false then
        S.mouse = { x = mx, y = my }
        local el = (S.idle or S.vis > 0.05) and hit_element(mx, my) or nil
        S.hover = el and el.id or nil
    else
        S.mouse = nil
        S.hover = nil
    end
    if S.hover ~= prev then S.hover_since = now() end
end

local function slider_frac(el_id, mx)
    local L = S.L
    local r = el_id == "seek" and L.seek or L.vol
    if not r then return 0 end
    return clamp((mx - r.x0) / (r.x1 - r.x0), 0, 1)
end

local function mouse_btn(state)
    update_pointer()
    local L = S.L
    if S.modal or not L then return end
    if S.want and S.m and L.kind == "play" and S.vis < 0.99 then
        -- The toolbar is still sliding in: hit-test (and later anchor menus) against its final position.
        S.vis = 1
        L = layout_play(S.m)
        S.L = L
    end
    if state == "down" then
        local el = S.mouse and hit_element(S.mouse.x, S.mouse.y)
        S.pressed = el and el.id or nil
        if el and el.kind == "slider" then
            if el.id == "seek" then
                local dur = mp.get_property_number("duration")
                if not dur or dur <= 0 then
                    S.pressed = nil
                    return
                end
            end
            S.drag = el.id
            S.drag_frac = slider_frac(el.id, S.mouse.x)
            if el.id == "vol" then set_volume_frac(S.drag_frac) end
        end
    else
        local id = S.pressed
        local drag = S.drag
        S.pressed, S.drag = nil, nil
        if drag then
            if drag == "seek" and S.drag_frac then seek_to_frac(S.drag_frac) end
            S.drag_frac = nil
            S.last_move = now()
        elseif id then
            local el = S.mouse and hit_element(S.mouse.x, S.mouse.y)
            if el and el.id == id then activate(id) end
        end
    end
    dirty()
end

local function setup_sections()
    for _, name in ipairs(SECTIONS) do
        mp.set_key_bindings({
            { "mbtn_left", function() mouse_btn("up") end, function() mouse_btn("down") end },
            { "mbtn_left_dbl", function() mouse_btn("up") end, function() mouse_btn("down") end },
            { "mbtn_right", function() end },
        }, name, "force")
    end
end
setup_sections()

local function set_section(name, rect)
    local cur = sec_rect[name]
    if not rect then
        if cur then
            mp.disable_key_bindings(name)
            sec_rect[name] = nil
        end
        return
    end
    local m = S.m
    local x0, y0 = floor(rect.x * m.kx), floor(rect.y * m.ky)
    local x1, y1 = ceil((rect.x + rect.w) * m.kx), ceil((rect.y + rect.h) * m.ky)
    local key = x0 .. "," .. y0 .. "," .. x1 .. "," .. y1
    if cur ~= key then
        mp.set_mouse_area(x0, y0, x1, y1, name)
        if not cur then mp.enable_key_bindings(name) end
        sec_rect[name] = key
    end
end

local function update_sections(L)
    local rects = {}
    if S.modal then
        rects = {}
    elseif L.kind == "idle" then
        rects = { L.byid.card_file, L.byid.card_disc, L.byid.card_yt, L.byid.card_ai }
    elseif S.vis > 0.3 or S.want then
        -- the panel slides in: accept clicks at its final position as soon as controls are wanted
        local slide = floor((1 - S.vis) * 14)
        rects = { { x = L.panel.x, y = L.panel.y - slide, w = L.panel.w, h = L.panel.h + slide }, L.byid.chip }
    end
    for i, name in ipairs(SECTIONS) do
        set_section(name, rects[i])
    end
end

----------------------------------------------------------------------------
-- Visibility
----------------------------------------------------------------------------

local function wake()
    S.last_move = now()
    S.hide_override = false
    dirty()
end

local function want_controls(t)
    if S.idle or not S.loaded then return false end
    if S.modal or S.drag then return true end
    if S.hide_override then return false end
    if mp.get_property_bool("pause") then return true end
    if S.hover then return true end
    if t - S.last_move < HIDE_DELAY then return true end
    if t < S.force_until then return true end
    return false
end

local function apply_sub_margin(lift)
    if lift == S.sub_lifted then return end
    S.sub_lifted = lift
    if not S.sub_base then S.sub_base = mp.get_property_number("sub-margin-y") or 22 end
    if lift and S.m then
        local extra = (112 + 20 + 14) * S.m.ky * 720 / S.m.ph
        mp.set_property_number("sub-margin-y", floor(S.sub_base + extra))
    else
        mp.set_property_number("sub-margin-y", S.sub_base)
    end
end

----------------------------------------------------------------------------
-- Render loop
----------------------------------------------------------------------------

local function publish_layout(L, m)
    local key = L.kind .. m.pw .. "x" .. m.ph .. (S.vis >= 0.99 and "v" or "h") .. (S.status and "s" or "")
    for _, el in ipairs(L.els) do key = key .. el.id .. floor(el.x) .. "," .. floor(el.y) end
    if key == S.layout_key then return end
    S.layout_key = key
    local els = {}
    for _, el in ipairs(L.els) do
        els[el.id] = {
            x = floor(el.x * m.kx), y = floor(el.y * m.ky),
            w = ceil(el.w * m.kx), h = ceil(el.h * m.ky),
            cx = floor((el.x + el.w / 2) * m.kx), cy = floor((el.y + el.h / 2) * m.ky),
        }
    end
    pcall(mp.set_property_native, "user-data/fluent/layout", {
        kind = L.kind, scale = m.k, window_w = m.pw, window_h = m.ph,
        controls_visible = S.vis >= 0.99, elements = els,
    })
end

local function render()
    S.dirty = false
    local m = F.metrics()
    if not m then
        if S.last_data then
            overlay:remove()
            S.last_data = nil
        end
        return
    end
    S.m = m
    local L = S.idle and layout_idle(m) or layout_play(m)
    S.L = L
    update_pointer()
    if not S.idle and S.loaded and S.has_video and S.vis <= 0.01 and #S.toasts == 0
        and not mp.get_property_bool("paused-for-cache") and not mp.get_property_bool("seeking") then
        -- nothing visible: drop the overlay instead of re-rendering on every time-pos tick
        if S.last_data then
            overlay:remove()
            S.last_data = nil
        end
        update_sections(L)
        publish_layout(L, m)
        return
    end
    local A = F.new_ass(1)
    local ok, err = pcall(function()
        if S.idle then draw_idle(A, L) else draw_play(A, L, m) end
        draw_toasts(A, L)
    end)
    if not ok then
        mp.msg.error("nanum-fluent render: " .. tostring(err))
        return
    end
    update_sections(L)
    publish_layout(L, m)
    local data = A:str()
    if data ~= S.last_data or overlay.res_x ~= m.W or overlay.res_y ~= m.H then
        S.last_data = data
        overlay.res_x, overlay.res_y = m.W, m.H
        overlay.data = data
        overlay:update()
    end
end

local function tick()
    local t = now()
    local dt = t - S.last_tick
    S.last_tick = t
    local want = want_controls(t)
    S.want = want
    local prev = S.vis
    if want then S.vis = min(1, S.vis + dt * 7) else S.vis = max(0, S.vis - dt * 2.5) end
    if S.vis ~= prev then dirty() end
    -- animations: busy chip, loading dots, toasts
    local animating = #S.toasts > 0 or not S.loaded or (S.vis > 0 and S.status and S.status.kind == "busy")
        or mp.get_property_bool("paused-for-cache") or mp.get_property_bool("seeking")
    if S.idle then animating = #S.toasts > 0 end
    if animating and t - S.last_pulse > (#S.toasts > 0 and 0.033 or 0.12) then
        S.last_pulse = t
        dirty()
    end
    for i = #S.toasts, 1, -1 do
        if t - S.toasts[i].born > S.toasts[i].ttl then
            table.remove(S.toasts, i)
            dirty()
        end
    end
    if S.dirty then render() end
    apply_sub_margin(not S.idle and S.loaded and S.vis > 0.5 and S.has_video)
end

mp.add_periodic_timer(1 / 30, tick)

----------------------------------------------------------------------------
-- Property / event wiring
----------------------------------------------------------------------------

mp.observe_property("mouse-pos", "native", function(_, p)
    local t = now()
    if p and p.hover and (p.x ~= S.px or p.y ~= S.py) then
        S.px, S.py = p.x, p.y
        if not S.modal then
            S.last_move = t
            S.hide_override = false
        end
    end
    update_pointer()
    if S.drag and S.mouse then
        S.drag_frac = slider_frac(S.drag, S.mouse.x)
        if S.drag == "vol" then set_volume_frac(S.drag_frac) end
    end
    dirty()
end)

for _, name in ipairs({ "time-pos", "duration", "pause", "mute", "fullscreen", "osd-dimensions",
    "display-hidpi-scale", "chapter-list", "demuxer-cache-state", "paused-for-cache", "seeking", "media-title" }) do
    mp.observe_property(name, "native", function() dirty() end)
end

mp.observe_property("idle-active", "bool", function(_, v)
    S.idle = v == true
    if S.idle then
        S.loaded = false
        S.drag, S.pressed = nil, nil
    end
    S.layout_key = nil
    dirty()
end)

mp.observe_property("track-list", "native", refresh_tracks)

-- Feedback that the stock OSD used to give (volume, speed, track changes).
mp.observe_property("volume", "number", function(_, v)
    if S.first_vol then
        S.first_vol = false
        return
    end
    if v and not S.idle and S.drag ~= "vol" then add_toast(string.format("볼륨 %d%%", floor(v + 0.5)), 1.2, "info", "volume") end
    dirty()
end)
mp.observe_property("mute", "bool", function(_, v)
    if S.idle then return end
    if v ~= nil and now() > S.quiet_until then add_toast(v and "음소거" or "음소거 해제", 1.2, "info", "volume") end
end)
mp.observe_property("speed", "number", function(_, v)
    if v and not S.idle and now() > S.quiet_until and math.abs(v - 1) > 1e-6 then
        add_toast(string.format("재생 속도 %.2fx", v), 1.4, "info", "speed")
    end
end)
local function track_toast(kind)
    return function()
        if S.idle or not S.loaded or now() < S.quiet_until then return end
        mp.add_timeout(0.05, function()
            local label = kind == "audio" and S.cur_audio or S.cur_sub
            add_toast((kind == "audio" and "음성: " or "자막: ") .. (label or "꺼짐"), 2, "info", kind)
        end)
    end
end
mp.observe_property("aid", "native", track_toast("audio"))
mp.observe_property("sid", "native", track_toast("sub"))

mp.register_event("start-file", function()
    S.loaded = false
    S.idle = false
    S.quiet_until = now() + 2
    S.status = nil
    S.layout_key = nil
    dirty()
end)
mp.register_event("file-loaded", function()
    S.loaded = true
    S.quiet_until = now() + 1.5
    S.last_move = now()
    refresh_tracks()
    dirty()
end)
mp.register_event("end-file", function(ev)
    S.loaded = false
    S.drag, S.pressed = nil, nil
    if ev and ev.reason == "error" then
        -- nanum.lua explains failures it understands (yt-dlp / YouTube) with its own toast
        local detail = ev.file_error
        mp.add_timeout(0.4, function()
            if mp.get_property_native("user-data/nanum/error-handled") ~= true then
                add_toast("재생하지 못했습니다" .. (detail and (": " .. detail) or ""), 8, "error")
            end
        end)
    end
    dirty()
end)
mp.register_event("seek", function()
    S.force_until = now() + 2
    dirty()
end)
mp.register_event("playback-restart", function() dirty() end)

----------------------------------------------------------------------------
-- Modal coordination, messages, key bindings
----------------------------------------------------------------------------

local enter_bound = false
local function update_idle_keys()
    local want = S.idle and not S.modal
    if want and not enter_bound then
        enter_bound = true
        mp.add_forced_key_binding("enter", "fluent-idle-enter", open_file)
        mp.add_forced_key_binding("kp_enter", "fluent-idle-kp-enter", open_file)
    elseif not want and enter_bound then
        enter_bound = false
        mp.remove_key_binding("fluent-idle-enter")
        mp.remove_key_binding("fluent-idle-kp-enter")
    end
end
mp.observe_property("idle-active", "bool", update_idle_keys)

mp.register_script_message("nanum-fluent", function(cmd, a, b, c, d)
    if cmd == "ui-modal" then
        S.modal = a == "yes"
        S.pressed, S.drag = nil, nil
        S.layout_key = nil
        if S.modal then S.vis = max(S.vis, 0.001) end
        update_idle_keys()
        dirty()
    elseif cmd == "ui-status" then
        if a and a ~= "" then
            S.status = { text = a, kind = b or "info", action = (c and c ~= "") and c or nil }
        else
            S.status = nil
        end
        S.layout_key = nil
        dirty()
    elseif cmd == "ui-hide" then
        S.hide_override = true
        S.force_until = 0
        dirty()
    elseif cmd == "ui-show" then
        wake()
    elseif cmd == "toast" then
        add_toast(a, tonumber(b) or 3, c, d ~= "" and d or nil)
    elseif cmd == "toast-clear" then
        for i = #S.toasts, 1, -1 do
            if a == "" or S.toasts[i].id == a then table.remove(S.toasts, i) end
        end
        dirty()
    elseif cmd == "click" then
        if a then activate(a) end
    elseif cmd == "dump-layout" then
        local L = S.L
        local m = S.m
        if not L or not m then
            mp.msg.info("fluent layout: no window")
            return
        end
        mp.msg.info(string.format("fluent layout kind=%s scale=%.3f window=%dx%d", L.kind, m.k, m.pw, m.ph))
        for _, el in ipairs(L.els) do
            mp.msg.info(string.format("  %-10s x=%d y=%d w=%d h=%d", el.id, el.x * m.kx, el.y * m.ky, el.w * m.kx, el.h * m.ky))
        end
    end
end)

-- Click on the video toggles pause (a double click goes fullscreen instead).
mp.add_key_binding("mbtn_left", "fluent-video-click", function()
    if S.idle or S.modal or not S.loaded then return end
    if S.click_timer then S.click_timer:kill() end
    S.click_timer = mp.add_timeout(0.28, function()
        S.click_timer = nil
        mp.commandv("cycle", "pause")
    end)
end)
mp.add_key_binding("mbtn_left_dbl", "fluent-video-dblclick", function()
    if S.click_timer then
        S.click_timer:kill()
        S.click_timer = nil
    end
    if not S.idle then mp.commandv("cycle", "fullscreen") end
end)

mp.add_key_binding("ctrl+o", "fluent-open-file", open_file)
mp.add_key_binding("ctrl+d", "fluent-open-disc", open_disc)
mp.add_key_binding("ctrl+a", "fluent-audio-menu", function() if not S.idle then track_menu("audio") end end)
mp.add_key_binding("ctrl+t", "fluent-sub-menu", function() if not S.idle then track_menu("sub") end end)

-- Stock OSD (volume bar, seek bar, property text) is replaced by the toasts
-- and the toolbar above; script messages (show-text) still appear.
mp.set_property("osd-level", "0")
mp.set_property_native("user-data/fluent/chrome", true)

S.idle = mp.get_property_bool("idle-active") == true
refresh_tracks()
update_idle_keys()
dirty()
