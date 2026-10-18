-- NanumPlayer control script.
--
--  * Pre-roll: pauses at start until the AI engine has
--    recognised and translated enough audio ahead of the playback position. Seeks never pause.
--  * Re-syncs after an audio track change: mpv refreshes the new track at the
--    demuxer's read-ahead position, which leaves a long gap, so seek to the
--    current position.
--  * Selects the AI subtitle track made from the playback audio automatically. A second AI track made
--    from the original-language audio (several audio languages) is only offered in the subtitle menu.
--  * Chooses the INPUT of the AI subtitles: speech recognition (stt) or a text
--    subtitle track (sub). "auto": subtitle in the audio language if there is
--    one, otherwise speech recognition.
--  * Full mode: the engine translates the whole file in the background; the
--    finished file is added as the "ko (AI full)" track.
--  * Ctrl+k shows the AI status, Ctrl+n opens the settings menu.
--
-- Load with --script=scripts/nanum.lua. Options (--script-opts=nanum-preroll=20):
--   preroll       seconds of subtitles to have ready before playback starts (0: off)
--   timeout       longest pre-roll wait in seconds
--   auto_select   select the AI subtitle track made from the playback audio when it appears (yes/no)
--   input_mode    auto | stt
--   full          full translation mode (yes/no)
--   full_engine   ollama | omp
--   omp_model     omp --model selector
--   display       translation | bilingual | source   (subtitle presentation, no reprocessing)
--   library_auto_use  use the saved library translation without asking (yes/no)
--   model_prompt  offer the model download once when the speech models are missing (yes/no)
--   acceleration  auto | cpu | cuda (cuda: AI subtitles are off when CUDA cannot run); applied per file
--   accel_prompt  offer the CUDA install / CPU choice once when the chosen engine cannot run (yes/no)
--   translate_style       natural | polite | casual | literal | custom (translation speech style, applied immediately)
--   translate_style_text  instruction used by the "custom" style
--   secondary     also make subtitles from the original-language audio of media with several audio languages (yes/no)
--   bar_hide      playback bar auto-hide delay: short (1.2 s) | normal (2 s) | long (3 s); applied at once
--   ai_tags       show the AI info tags (recognition device / source / translation) above the playback bar (yes/no)

local mp = require 'mp'
local options = require 'mp.options'

-- Fluent UI supplies the select/get popup API.
local function load_helper(file, kind)
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
        local f = loadfile(d .. "/" .. file)
        if f then
            local okf, mod = pcall(f)
            if okf and type(mod) == (kind or "table") then return mod end
            mp.msg.error(file .. ": " .. tostring(mod))
        end
    end
    return nil
end
local function load_fluent() return load_helper("fluent-input.lua", "table") end
local fluent = assert(load_fluent(), "scripts/fluent-input.lua is required")
local input = fluent

-- Messages go to the Fluent chrome (toast / status chip); stock OSD only if it is not running.
local function chrome_alive()
    return mp.get_property_native("user-data/fluent/chrome") == true
end

local function notify(text, secs, kind, id)
    if text == nil or text == "" then return end
    if chrome_alive() then
        mp.commandv("script-message", "nanum-fluent", "toast", text, tostring(secs or 3), kind or "info", id or "")
    else
        mp.osd_message(text, secs or 3)
    end
end

local function notify_clear(id)
    if chrome_alive() then
        mp.commandv("script-message", "nanum-fluent", "toast-clear", id or "")
    else
        mp.osd_message("", 0)
    end
end

local publish_status                -- defined with the status chip logic

local opts = {
    preroll = 30,
    timeout = 90,
    auto_select = true,
    input_mode = "auto",
    full = false,
    full_engine = "ollama",
    omp_model = "",
    translate_model = "",       -- engine options, applied to the next file
    target_language = "",
    translate_endpoint = "",
    display = "translation",
    original_first = true,      -- a subtitle already in the target language is shown directly and the AI work is skipped
    library_auto_use = false,
    model_prompt = true,
    accel_prompt = true,
    cuda_license = false,
    acceleration = "auto",
    translate_style = "natural",
    translate_style_text = "",
    secondary = true,
    pgs = true,
    bar_hide = "short",         -- playback bar auto-hide: short | normal | long (1.2 / 2 / 3 s)
    ai_tags = true,             -- AI info tags above the playback bar
    downloads_dir = "",
}
options.read_options(opts, "nanum")
if opts.input_mode ~= "stt" then opts.input_mode = "auto" end
if opts.full_engine ~= "omp" then opts.full_engine = "ollama" end
if opts.display ~= "bilingual" and opts.display ~= "source" then opts.display = "translation" end
if opts.bar_hide ~= "normal" and opts.bar_hide ~= "long" then opts.bar_hide = "short" end
if opts.acceleration ~= "cpu" and opts.acceleration ~= "cuda" then opts.acceleration = "auto" end

local STYLES = {
    { key = "natural", label = "자연스럽게 (기본)" },
    { key = "polite", label = "존댓말" },
    { key = "casual", label = "반말" },
    { key = "literal", label = "원문에 충실" },
    { key = "custom", label = "직접 입력" },
}
local function style_known(key)
    for _, s in ipairs(STYLES) do
        if s.key == key then return true end
    end
    return false
end
opts.translate_style_text = opts.translate_style_text:gsub("%s+", " "):match("^%s*(.-)%s*$")
if not style_known(opts.translate_style) or (opts.translate_style == "custom" and opts.translate_style_text == "") then
    opts.translate_style = "natural"
end
-- --nanum-acceleration=cpu|cuda on the command line overrides the saved choice for this session.
local session_accel
do
    local okc, cli = pcall(mp.get_property, "options/nanum-acceleration")
    if okc and (cli == "cpu" or cli == "cuda") then session_accel = cli end
end

local FULL_SUFFIX = " (AI full)"       -- the title of the complete translation track ends with this (it names the target language)

-- The player's virtual AI subtitle tracks are recognised by the demuxer stream id it publishes in
-- demuxer-cache-state (their titles are localised and name the audio language): the primary track is
-- made from the playback audio (the default), the secondary one from the original-language audio.
local ai_ids = { primary = nil, secondary = nil, pgs = nil, import = nil }

local function refresh_ai_ids(st)
    st = st or mp.get_property_native("demuxer-cache-state")
    local function id(v) return (type(v) == "number" and v >= 0) and v or nil end
    ai_ids.primary = st and id(st["nanum-track-primary"]) or nil
    ai_ids.secondary = st and id(st["nanum-track-secondary"]) or nil
    ai_ids.pgs = st and id(st["nanum-track-pgs"]) or nil
    ai_ids.import = st and id(st["nanum-track-import"]) or nil
end

-- "primary" | "secondary" | "pgs" (disc image subtitles) | "import" (user-downloaded subtitles) |
-- "full" | nil (not one of ours)
local function ai_role(t)
    if type(t) ~= "table" or t.type ~= "sub" then return nil end
    if type(t.title) == "string" and t.title:sub(-#FULL_SUFFIX) == FULL_SUFFIX then return "full" end
    local s = t["src-id"]
    if t.external or type(s) ~= "number" then return nil end
    if s == ai_ids.primary then return "primary" end
    if s == ai_ids.secondary then return "secondary" end
    if s == ai_ids.pgs then return "pgs" end
    if s == ai_ids.import then return "import" end
    -- the player's virtual tracks have the demuxer ids 0x4e414e + input (nanum.c virtual_id()); the state that
    -- names them may not have been published yet when a file has just loaded
    local k = s - 0x4e414e
    if k >= 0 and k <= 3 then return ({ [0] = "primary", "secondary", "pgs", "import" })[k] end
    return nil
end

----------------------------------------------------------------------------
-- Input selection (pure logic)
----------------------------------------------------------------------------

local LANG_MAP = {
    eng = "en", jpn = "ja", jap = "ja", spa = "es", fre = "fr", fra = "fr",
    ger = "de", deu = "de", ita = "it", por = "pt", rus = "ru", kor = "ko",
    chi = "zh", zho = "zh", cmn = "zh", yue = "zh", ara = "ar", hin = "hi",
    tha = "th", vie = "vi", dut = "nl", nld = "nl", pol = "pl", tur = "tr",
    swe = "sv", nor = "no", dan = "da", fin = "fi", cze = "cs", ces = "cs",
    gre = "el", ell = "el", heb = "he", hun = "hu", ind = "id", ukr = "uk",
    rum = "ro", ron = "ro", per = "fa", fas = "fa",
}
local UNKNOWN_LANG = { und = true, unk = true, mis = true, mul = true, zxx = true, [""] = true }

-- "eng", "en-US", "EN" -> "en"; unknown/undetermined -> nil
local function norm_lang(l)
    if type(l) ~= "string" then return nil end
    l = l:lower():match("^%s*([^%-_%s]*)") or ""
    if UNKNOWN_LANG[l] then return nil end
    return LANG_MAP[l] or l
end

local LANG_KO = {
    en = "영어", ja = "일본어", ko = "한국어", zh = "중국어", fr = "프랑스어", de = "독일어",
    es = "스페인어", it = "이탈리아어", ru = "러시아어", pt = "포르투갈어",
}

-- Interface-language name of an ISO code (nil if unknown/empty; the code itself if it has no name).
local function lang_name(l)
    l = norm_lang(l)
    if not l then return nil end
    return LANG_KO[l] and input.core_tr(LANG_KO[l]) or l
end

-- mpv leaves external subtitles without a language unless the file name says
-- so ("movie.en.srt" is not parsed everywhere): fall back to that suffix.
local function track_lang(t)
    if t.lang and t.lang ~= "" then return t.lang end
    local f = t["external-filename"]
    if type(f) == "string" then
        return f:match("[%._%-](%a%a%a?)%.[%w]+$")
    end
    return nil
end

local TEXT_CODECS = {
    subrip = true, srt = true, ass = true, ssa = true, mov_text = true,
    webvtt = true, text = true,
}
local FALLBACK_LANGS = { "en", "ja", "es", "fr" }

local function is_text_codec(c)
    return type(c) == "string" and TEXT_CODECS[c:lower()] == true
end

-- A text subtitle track the engine can read (not ours, not forced/commentary).
local function usable_sub(t)
    if type(t) ~= "table" or t.type ~= "sub" then return false end
    if not is_text_codec(t.codec) then return false end
    if t.forced then return false end
    if not (t["src-id"] or t["external-filename"]) then return false end
    if ai_role(t) then return false end
    local title = type(t.title) == "string" and t.title:lower() or ""
    if title:find("commentary", 1, true) or title:find("forced", 1, true) then return false end
    return true
end

local function usable_subs(tracks)
    local r = {}
    for _, t in ipairs(tracks or {}) do
        if usable_sub(t) then r[#r + 1] = t end
    end
    return r
end

local function audio_language(tracks)
    local first
    for _, t in ipairs(tracks or {}) do
        if t.type == "audio" then
            if t.selected then return norm_lang(t.lang) end
            first = first or t
        end
    end
    return nil
end

-- -> { input = "stt" } or { input = "sub", track = <track> }
local function select_input(tracks, audio_lang)
    local subs = usable_subs(tracks)
    local L = norm_lang(audio_lang)
    if L then
        for _, t in ipairs(subs) do
            if norm_lang(track_lang(t)) == L then return { input = "sub", track = t } end
        end
        return { input = "stt" }
    end
    for _, want in ipairs(FALLBACK_LANGS) do
        for _, t in ipairs(subs) do
            if norm_lang(track_lang(t)) == want then return { input = "sub", track = t } end
        end
    end
    return { input = "stt" }
end

local function track_label(t)
    local tl = track_lang(t)
    local parts = { tl and tl ~= "" and tl or "?" }
    if t.title and t.title ~= "" then parts[#parts + 1] = t.title end
    parts[#parts + 1] = "(" .. tostring(t.codec) .. ")"
    if t.external then parts[#parts + 1] = input.core_tr("[외부]") end
    return table.concat(parts, " ")
end

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

local waiting = nil         -- active pre-roll: {timer=, deadline=}
local we_paused = false     -- we paused playback for the pre-roll
local resuming = false      -- ignore the pause change caused by our own resume
local selected_once = false
local last_aid = nil
local file_loaded = false

local sel_mode = opts.input_mode    -- "auto" | "stt" | "track" (session only)
local sel_track_id = nil
local hint_until = nil
local hint_shown = false

local last_full_state = nil
local last_full_osd = 0
local last_error_shown = nil
local engine_old = false
local file_active = false      -- between start-file and end-file
local loaded_at = 0
local pinned_aud = nil         -- { src=, lang= }: playback audio track the AI input is pinned to
local ai_disabled = false      -- the user turned AI subtitles off for this file
local keep_full = false        -- a library action rebuilds the file: keep the shown full track until the new one is done
local applied_path = nil       -- path of the full track applied last
local deferred = nil           -- pre-roll postponed while a library decision is outstanding
local save_settings            -- defined with the settings menu
local decision_outstanding     -- defined with the library state handling
local cancel_glossary_edit        -- defined with the settings menu
local gloss_wait = nil            -- nil | "requested" | "running": the user asked the AI to rebuild the glossary
local gloss_pending = nil         -- { entries=, base=, expires= }: glossary edited in the menu, not yet published by the player

local SUBS = {                  -- online subtitle search / import / PGS (functions are defined with the settings menu)
    watch = nil,                -- { dir=, known=, since=, deadline=, timer=, origin=, lang=, seen= }: waiting for a download
    tmp = nil,                  -- private temp dir of the last extracted zip
    import_prev = nil,          -- last import state seen (toasts)
    query = nil,                -- search text typed by the user (overrides the title)
    dir_auto = nil,             -- resolved Downloads folder
    ext_seen = nil,             -- external subtitle track ids present when the file was loaded
    req_timers = {},
    yt = { data = nil, log = {}, cmd_ok = nil, after = nil, last_text = nil, last_at = 0 },    -- YouTube (defined with the settings menu)
}

-- AI model state, guard and manager (defined with the "AI models" section and the settings menu).
local AIM = {
    data = nil,             -- user-data/nanum/models as published by the engine
    cmd_ok = nil,           -- the engine accepts nanum-models-refresh (false: old engine)
    sig = nil,
    file_block = nil,       -- speech models missing when this file started (list of ids)
    notified = false,       -- the missing-model notice was shown for this file
    notified_accel = false, -- the engine notice was shown for this file
    file_accel = nil,       -- verdict table when the chosen engine could not start for this file
    file_mode = nil,        -- acceleration mode in effect for this file's engine
    prompted_accel = false, -- the engine prompt was offered in this session
    fallback_noted = false, -- the CPU fallback hint was shown in this session
    acc = nil,              -- user-data/nanum/accelerator as published by the engine
    acc_cmd_ok = nil,       -- the engine accepts nanum-accelerator-refresh (false: old engine)
    acc_sig = nil,
    accel_opt_ok = nil,     -- the engine knows nanum-acceleration
    prompted = false,       -- the missing-model prompt was offered in this session
    last_cmd = -10,
    toast_at = 0,
    toast_text = nil,
    menu = { actions = {}, keys = {} },
}

local prompt_queue, popup_open, popup_kind, popup_at = {}, false, nil, 0

local lib = {}                 -- last library state reported by the engine
local lib_decided = {}         -- source id -> the user (or the saved preference) already decided
local lib_option_ok = false    -- the engine knows nanum-library-action
local lib_probe_until = 0
local lib_error_shown = nil
local pending_saved = nil      -- "use saved" after an audio switch waits for the lookup of the new source
local lib_action_timer = nil

local function lib_reset()
    lib = { state = nil, sid = "", lang = "", has_source = false, has_translation = false, summary = "", error = "" }
    lib_decided, lib_error_shown, pending_saved, lib_probe_until = {}, nil, nil, 0
    if lib_action_timer then
        lib_action_timer:kill()
        lib_action_timer = nil
    end
end
lib_reset()

-- The demuxer stream id the engine pins: src-id, or for demuxers that have
-- none (raw WAV) the engine's stable fallback 0x40000000 + stream index.
local function audio_src(t)
    local s = t["src-id"]
    if type(s) == "number" and s >= 0 then return s end
    local ff = t["ff-index"]
    if type(ff) == "number" and ff >= 0 then return 0x40000000 + ff end
    return nil
end

local function selected_audio(tracks)
    for _, t in ipairs(tracks or {}) do
        if t.type == "audio" and t.selected then return t end
    end
    return nil
end

local function audio_by_src(tracks, src)
    for _, t in ipairs(tracks or {}) do
        if t.type == "audio" and audio_src(t) == src then return t end
    end
    return nil
end

-- Language of the audio the AI input is pinned to (not the one being played).
local function ai_audio_language(tracks)
    if pinned_aud then
        local t = audio_by_src(tracks, pinned_aud.src)
        if t then return norm_lang(t.lang) end
        return pinned_aud.lang
    end
    return audio_language(tracks)
end

local function cache_state()
    return mp.get_property_native("demuxer-cache-state")
end

local function ready_until()
    local st = cache_state()
    return st and st["nanum-ready-until"] or nil,
           st and st["nanum-text-complete"] or false
end

-- ready_until() is a container timestamp, time-pos is relative to the start.
local function abs_pos()
    local pos = mp.get_property_number("time-pos") or 0
    return pos + (mp.get_property_number("demuxer-start-time") or 0)
end

local function hint_text()
    if hint_until and mp.get_time() < hint_until then return input.core_tr("Ctrl+N: AI 자막 설정") end
    return nil
end

local function stop_wait(resume)
    if waiting then
        waiting.timer:kill()
        waiting = nil
    end
    if resume and we_paused then
        resuming = true
        mp.set_property_bool("pause", false)
        resuming = false
    end
    we_paused = false
    if not chrome_alive() then mp.osd_message(hint_text() or "", hint_text() and 3 or 0) end
    publish_status()
end

function decision_outstanding()
    if ai_disabled or not file_active then return false end
    if not (lib_option_ok or lib.state ~= nil) then return false end
    for _, p in ipairs(prompt_queue) do
        if p.kind == "library" then return true end
    end
    if popup_open and popup_kind == "library" then return true end
    if lib.state == "loading" then return true end
    if lib.state == nil then return mp.get_time() < lib_probe_until end
    if lib.state == "available" then return not lib_decided[lib.sid ~= "" and lib.sid or "-"] end
    return false
end

local function wait_for_ai(lead)
    if lead <= 0 or ai_disabled then
        return
    end
    local reason, ids = AIM.block_reason()
    if reason then
        -- engine switched off or speech models missing: nothing to wait for, playback goes on
        if waiting then stop_wait(true) end
        AIM.note_blocked(reason, ids)
        return
    end
    if waiting then
        stop_wait(false)
    end
    -- No AI-imposed pause while the saved-library decision is outstanding.
    if decision_outstanding() then
        deferred = { lead = lead, since = mp.get_time() }
        return
    end
    local r, text_complete = ready_until()
    if text_complete or (r and r >= abs_pos() + lead) then
        return                  -- already enough subtitles ahead
    end
    if not mp.get_property_bool("pause") then
        mp.set_property_bool("pause", true)
        we_paused = true
    end
    waiting = { deadline = mp.get_time() + opts.timeout, lead = lead }
    waiting.timer = mp.add_periodic_timer(0.3, function()
        local blocked, bids = AIM.block_reason()
        if blocked then             -- e.g. the model list arrived after the file started
            stop_wait(true)
            AIM.note_blocked(blocked, bids)
            return
        end
        if decision_outstanding() then
            stop_wait(true)         -- only our own pause is released
            deferred = { lead = lead, since = mp.get_time() }
            return
        end
        local now = abs_pos()
        local ready, text_complete = ready_until()
        if text_complete or (ready and ready >= now + lead) or mp.get_time() > waiting.deadline then
            stop_wait(true)
        else
            if chrome_alive() then
                publish_status()
            else
                local have = ready and math.max(0, ready - now) or 0
                local msg = input.core_tr("AI 자막 준비 중... %.0f / %d초", have, lead)
                local h = hint_text()
                if h then msg = msg .. "\n" .. h end
                mp.osd_message(msg, 1)
            end
        end
    end)
end

-- The user resumed by hand: stop waiting.
mp.observe_property("pause", "bool", function(_, paused)
    if waiting and paused == false and not resuming then
        stop_wait(false)
    end
end)

----------------------------------------------------------------------------
-- Engine options
----------------------------------------------------------------------------

-- false when the engine does not know the option (old binary).
local function set_opt(name, value)
    local ok, r = pcall(mp.set_property, "options/" .. name, value)
    if ok and r == true then return true end
    engine_old = true
    return false
end

local function get_opt(name)
    local ok, r = pcall(mp.get_property, "options/" .. name)
    if ok then return r end
    return nil
end

-- Setter for options added with the subtitle library: no "old engine" verdict.
local function set_opt_soft(name, value)
    local ok, r = pcall(mp.set_property, "options/" .. name, value)
    return ok and r == true
end

local resync_timer = nil
-- mpv refreshes demuxer-side changes only at the next seek.
local function resync()
    if resync_timer then resync_timer:kill() end
    resync_timer = mp.add_timeout(0.3, function()
        resync_timer = nil
        local pos = mp.get_property_number("time-pos")
        if pos and file_loaded then
            mp.msg.info(string.format("nanum input changed: resync at %.1f", pos))
            mp.commandv("seek", tostring(pos), "absolute+exact")
        end
    end)
end

local function ai_track(role)
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if ai_role(t) == role then return t end
    end
    return nil
end

-- The primary AI track (default selection; the secondary track is only ever chosen by the user).
local function select_live()
    if ai_disabled then return end
    refresh_ai_ids()
    local t = ai_track("primary")
    if t and not t.selected then mp.set_property_number("sid", t.id) end
end

-- Once per file: select the primary AI track as soon as it appears.
local function auto_select_primary(st)
    if not opts.auto_select or ai_disabled or selected_once then return end
    refresh_ai_ids(st)
    local t = ai_track("primary")
    if not t then return end
    selected_once = true
    -- the old "원문만" display setting: with a subtitle-based input the original track is that text
    local original = (opts.display == "source" and SUBS.ux) and SUBS.ux.source_track() or nil
    if original then
        if not original.selected then mp.set_property_number("sid", original.id) end
        return
    end
    if not t.selected then mp.set_property_number("sid", t.id) end
end

local function select_full_track(path)
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "sub" and ai_role(t) == "full" and t["external-filename"] == path then
            if not t.selected then mp.set_property_number("sid", t.id) end
            return
        end
    end
end

-- Set the engine's input options. Returns true if something changed.
local function apply_choice(choice)
    local changed = false
    local function put(name, value)
        if get_opt(name) ~= value then
            if set_opt(name, value) then changed = true end
        end
    end
    put("nanum-input", choice.input)
    if choice.input == "sub" and choice.track then
        local t = choice.track
        if t.external and t["external-filename"] then
            put("nanum-sub-file", t["external-filename"])
        else
            put("nanum-sub-file", "")
            put("nanum-sub-id", tostring(t["src-id"] or 0))
        end
    end
    return changed
end

local function resolve_choice(tracks)
    if sel_mode == "stt" then return { input = "stt" } end
    if sel_mode == "track" and sel_track_id then
        for _, t in ipairs(tracks) do
            if t.type == "sub" and t.id == sel_track_id and usable_sub(t) then
                return { input = "sub", track = t }
            end
        end
    end
    return select_input(tracks, ai_audio_language(tracks))
end

-- Re-evaluate the input. no_seek: the caller resyncs anyway.
local function reevaluate(no_seek)
    local tracks = mp.get_property_native("track-list")
    if not tracks then return end
    local choice = resolve_choice(tracks)
    mp.msg.info("nanum input: " .. choice.input .. (choice.track and (" " .. track_label(choice.track)) or ""))
    if apply_choice(choice) then
        AIM.file_block, AIM.file_accel = nil, nil       -- the engine restarts for the new input
        AIM.file_mode = AIM.mode()
        if not no_seek then resync() end
        mp.add_timeout(1.0, function()
            if last_full_state ~= "done" then select_live() end
        end)
    end
end

local function apply_full_options()
    local function put(name, value)
        if get_opt(name) ~= value then return set_opt(name, value) end
        return false
    end
    local c = put("nanum-full", opts.full and "yes" or "no")
    c = put("nanum-full-engine", opts.full_engine) or c
    if opts.omp_model ~= "" then c = put("nanum-omp-model", opts.omp_model) or c end
    return c
end

----------------------------------------------------------------------------
-- Full-mode status
----------------------------------------------------------------------------

local function full_status_text(st)
    local s = st and st["nanum-full-state"]
    if not s or s == "off" then return nil end
    local pct = math.floor((st["nanum-full-progress"] or 0) * 100 + 0.5)
    if s == "scanning" then return input.core_tr("전체 번역: 원문 수집 중 %d%%", pct) end
    if s == "translating" then return input.core_tr("전체 번역: 번역 중 %d%%", pct) end
    if s == "done" then return input.core_tr("전체 번역: 완료") end
    if s == "error" then
        local e = st["nanum-full-error"]
        return input.core_tr("전체 번역 오류") .. ((e and e ~= "") and (": " .. e) or "")
    end
    return nil
end

----------------------------------------------------------------------------
-- Saved library: prompts, actions, state
----------------------------------------------------------------------------

local function lib_key()
    return lib.sid ~= "" and lib.sid or "-"
end

local function lib_supported(saved)
    if saved then
        local privacy = mp.get_property_native("user-data/nanum/privacy")
        if (type(privacy) == "table" and privacy.library == false) or lib.state == "disabled" then return false end
    end
    return lib_option_ok or lib.state ~= nil
end

-- Per-file engine options: presentation, preference, pinned audio, library action.
local function prepare_file_options()
    lib_option_ok = set_opt_soft("nanum-library-action", "ask")
    set_opt_soft("nanum-audio-id", "-1")
    set_opt_soft("nanum-display", opts.display)
    set_opt_soft("nanum-library-auto-use", opts.library_auto_use and "yes" or "no")
    AIM.accel_opt_ok = set_opt_soft("nanum-acceleration", AIM.mode())
    set_opt_soft("nanum-glossary-request", "")
    set_opt_soft("nanum-import-sub", "")
    set_opt_soft("nanum-import-adjust", "0")
end

-- Non-blocking mp.input.select popups, one at a time, never over another menu.
local pump_prompts

local function console_open()
    if fluent then return fluent.modal_busy() end
    return mp.get_property_bool("user-data/mpv/console/open") == true
end

local function queue_prompt(kind, build)
    for _, p in ipairs(prompt_queue) do
        if p.kind == kind then
            p.build = build
            return
        end
    end
    local entry = { kind = kind, build = build }
    if kind == "library" then
        table.insert(prompt_queue, 1, entry)
    else
        prompt_queue[#prompt_queue + 1] = entry
    end
end

function pump_prompts()
    if popup_open then
        -- the console was taken over without a closed event: do not stay blocked
        if fluent then
            if fluent.is_open() or mp.get_time() - popup_at < 1 then return end
        elseif console_open() or mp.get_time() - popup_at < 3 then
            return
        end
        popup_open, popup_kind = false, nil
    end
    if #prompt_queue == 0 or not file_loaded or console_open() then return end
    local p = table.remove(prompt_queue, 1)
    local spec = p.build()
    if not spec then
        return pump_prompts()
    end
    local inner_closed = spec.closed
    spec.closed = function()
        popup_open, popup_kind = false, nil
        if inner_closed then inner_closed() end
        mp.add_timeout(0.3, pump_prompts)
    end
    popup_open, popup_kind, popup_at = true, p.kind, mp.get_time()
    input.select(spec)
end

-- action: ask | use | retranslate | regenerate | disable.
-- The option is set to "ask" first so that choosing the same action again
-- still retriggers the engine; demuxer-side changes apply at the next seek.
local function library_action(action, o)
    o = o or {}
    if not lib_supported() then
        notify(input.core_tr("이 엔진 버전은 저장 자막 라이브러리를 지원하지 않습니다 (nanum 갱신 필요)"), 4, "error")
        return false
    end
    ai_disabled = (action == "disable")
    keep_full = (o.keep_full and applied_path ~= nil) or false
    deferred = nil
    stop_wait(true)
    if action == "ask" then lib_decided = {} end
    if lib_action_timer then lib_action_timer:kill() end
    local messages = {
        ask = "저장된 자막을 조회합니다",
        use = "저장된 자막을 불러옵니다",
        retranslate = "저장된 원문으로 다시 번역합니다 (기존 자막은 완료될 때까지 유지)",
        regenerate = "음성 인식부터 새로 생성합니다 (기존 자막은 완료될 때까지 유지)",
        disable = "이 파일에서는 AI 자막을 사용하지 않습니다",
    }
    if not o.quiet then notify(messages[action] and input.core_tr(messages[action]) or action, 3) end
    local function finish()
        lib_action_timer = nil
        if action ~= "ask" and not set_opt_soft("nanum-library-action", action) then
            notify(input.core_tr("저장 자막 작업을 시작하지 못했습니다 (nanum 갱신 필요)"), 4, "error")
            return
        end
        if action == "disable" then
            refresh_ai_ids()
            for _, t in ipairs(mp.get_property_native("track-list") or {}) do
                if t.selected and ai_role(t) then
                    mp.set_property("sid", "no")
                end
            end
        end
        resync()
        if action ~= "disable" and not o.keep_selection then
            mp.add_timeout(1.5, function()
                if not keep_full and last_full_state ~= "done" then select_live() end
            end)
        end
    end
    set_opt_soft("nanum-library-action", "ask")
    if action == "ask" then
        finish()
    else
        lib_action_timer = mp.add_timeout(0.2, finish)
    end
    return true
end

local function set_auto_use(on)
    opts.library_auto_use = on
    set_opt_soft("nanum-library-auto-use", on and "yes" or "no")
    save_settings()
end

local LIB_STATE_TEXT = {
    loading = "확인 중", none = "저장본 없음", available = "저장본 있음",
    using = "저장본 사용 중", working = "작업 중", error = "오류",
}

local function lib_status_text()
    if not lib.state then return nil end
    local s = input.core_tr("저장 자막: %s", LIB_STATE_TEXT[lib.state] and input.core_tr(LIB_STATE_TEXT[lib.state]) or lib.state)
    if lib.summary ~= "" then s = s .. " — " .. lib.summary end
    if lib.state == "error" and lib.error ~= "" then s = s .. " (" .. lib.error .. ")" end
    return s
end

-- The saved material popup. Only choices the backend can honour are listed.
local function build_library_prompt()
    if lib.state ~= "available" then return nil end
    local items, actions = {}, {}
    local function add(text, fn)
        items[#items + 1] = text
        actions[#actions + 1] = fn
    end
    if lib.has_translation then
        add(input.core_tr("저장된 번역 사용"), function() library_action("use") end)
        add(input.core_tr("저장된 번역 사용 + 이 선택 기억 (다음부터 묻지 않음)"), function()
            set_auto_use(true)
            library_action("use")
        end)
    end
    if lib.has_source then
        add(input.core_tr("저장된 원문으로 다시 번역"), function() library_action("retranslate", { keep_full = true }) end)
    end
    add(input.core_tr("음성 인식부터 새로 생성"), function() library_action("regenerate", { keep_full = true }) end)
    add(input.core_tr("이 파일은 AI 자막 사용 안 함"), function() library_action("disable") end)
    local chosen = false
    return {
        prompt = lib.summary ~= "" and input.core_tr("저장된 AI 자막이 있습니다 (%s):", lib.summary)
            or input.core_tr("저장된 AI 자막이 있습니다:"),
        items = items,
        default_item = 1,
        submit = function(i)
            chosen = true
            actions[i]()
        end,
        closed = function()
            if chosen then return end
            if fluent and fluent.modal_busy() then
                queue_prompt("library", build_library_prompt)   -- another panel took over: ask again afterwards
                return
            end
            deferred = nil              -- cancelled: no action
            if file_loaded then
                notify(input.core_tr("저장된 자막은 사용하지 않았습니다 (Ctrl+N 에서 선택 가능)"), 4)
            end
        end,
    }
end

-- Pin the AI input to a playback audio track (demux src-id).
local function pin_to(t)
    pinned_aud = { src = audio_src(t), lang = norm_lang(t.lang) }
    set_opt_soft("nanum-audio-id", tostring(audio_src(t)))
end

local function pin_audio(tracks)
    if pinned_aud or not tracks then return end
    local t = selected_audio(tracks)
    if t and audio_src(t) then pin_to(t) end
end

local function audio_label(t)
    local l = (t.lang and t.lang ~= "") and t.lang or "?"
    local s = "#" .. tostring(audio_src(t) or "?") .. " " .. l
    if t.title and t.title ~= "" then s = s .. " " .. t.title end
    return s
end

-- mode "generate": run the AI on the new audio; "saved": use what is stored for it.
local function switch_ai_audio(t, mode)
    pin_to(t)
    reevaluate(true)                    -- auto source rule on the new audio language
    local ok
    if mode == "generate" then
        ok = library_action("regenerate", { keep_full = true })
    else
        ok = library_action("ask", { keep_full = true })
        if ok then
            pending_saved = { since = mp.get_time(), old_sid = lib.sid, saw_loading = false }
        end
    end
    if not ok then resync() end
end

local function build_audio_prompt()
    local tracks = mp.get_property_native("track-list")
    local cur = selected_audio(tracks)
    if not (cur and audio_src(cur) and pinned_aud) or audio_src(cur) == pinned_aud.src then return nil end
    local old = audio_by_src(tracks, pinned_aud.src) or { ["src-id"] = pinned_aud.src, lang = pinned_aud.lang }
    local chosen = false
    local items = {
        input.core_tr("유지 — AI 자막은 기존 입력 유지 (%s)", audio_label(old)),
        input.core_tr("현재 음성 (%s) 으로 AI 자막 새로 생성", audio_label(cur)),
    }
    if lib_supported(true) then items[#items + 1] = input.core_tr("현재 음성의 저장된 AI 자막 사용 (조회)") end
    return {
        prompt = input.core_tr("재생 음성이 AI 입력 음성과 다릅니다:"),
        items = items,
        default_item = 1,
        submit = function(i)
            chosen = true
            if i == 2 then
                switch_ai_audio(cur, "generate")
            elseif i == 3 then
                switch_ai_audio(cur, "saved")
            end
        end,
        closed = function()
            if chosen then return end
            if fluent and fluent.modal_busy() then queue_prompt("audio", build_audio_prompt) end
        end,
    }
end

-- Debounced: ignore quick audio flips; only differing languages need a decision.
local audio_prompt_timer = nil
local function schedule_audio_prompt()
    if audio_prompt_timer then audio_prompt_timer:kill() end
    audio_prompt_timer = mp.add_timeout(0.8, function()
        audio_prompt_timer = nil
        if not file_loaded or not pinned_aud or ai_disabled then return end
        local cur = selected_audio(mp.get_property_native("track-list"))
        if not (cur and audio_src(cur)) or audio_src(cur) == pinned_aud.src then return end
        local a, b = pinned_aud.lang, norm_lang(cur.lang)
        if a and b and a == b then return end
        queue_prompt("audio", build_audio_prompt)
        pump_prompts()
    end)
end

local function on_library(st)
    local ls = st["nanum-library-state"]
    if ls == nil then return end
    local prev = lib.state
    lib.state = ls
    lib.sid = st["nanum-library-source-id"] or ""
    lib.lang = st["nanum-library-source-language"] or ""
    lib.has_source = st["nanum-library-has-source"] == true
    lib.has_translation = st["nanum-library-has-translation"] == true
    lib.summary = st["nanum-library-summary"] or ""
    lib.error = st["nanum-library-error"] or ""
    if ls ~= "error" then lib_error_shown = nil end
    local key = lib_key()
    if ls == "loading" then
        if pending_saved then pending_saved.saw_loading = true end
    elseif ls == "available" then
        local p = pending_saved
        if p and (lib.sid ~= p.old_sid or p.saw_loading) then
            -- "use saved" on the audio just switched to
            pending_saved = nil
            lib_decided[key] = true
            if lib.has_translation then
                library_action("use", { keep_full = true })
            else
                library_action("retranslate", { keep_full = true })
            end
        elseif not p and not lib_decided[key] then
            lib_decided[key] = true
            if opts.library_auto_use and lib.has_translation then
                library_action("use")
            else
                queue_prompt("library", build_library_prompt)
                pump_prompts()
            end
        end
    elseif ls == "disabled" then
        pending_saved = nil
    elseif ls == "none" then
        local p = pending_saved
        if p and (lib.sid ~= p.old_sid or p.saw_loading) then
            pending_saved = nil
            notify(input.core_tr("현재 음성에 저장된 AI 자막이 없어 새로 생성합니다"), 4, "warn")
        end
    elseif ls == "using" then
        if prev ~= "using" then
            notify(lib.summary ~= "" and input.core_tr("저장된 AI 자막 사용 중: %s", lib.summary)
                or input.core_tr("저장된 AI 자막 사용 중"), 3, "ok")
        end
    elseif ls == "error" then
        pending_saved = nil
        if lib_error_shown ~= lib.error then
            lib_error_shown = lib.error
            local hint = lib.has_source and input.core_tr("Ctrl+N → 저장된 원문으로 다시 번역")
                or input.core_tr("Ctrl+N → 저장 자막 다시 조회 / 새로 생성")
            notify((lib.error ~= "" and input.core_tr("AI 자막 라이브러리 오류: %s", lib.error)
                or input.core_tr("AI 자막 라이브러리 오류")) .. "\n" .. hint, 7, "error")
        end
    end
end

----------------------------------------------------------------------------
-- AI models (Whisper speech models + Silero VAD)
--
-- The engine publishes user-data/nanum/models (status, current, received,
-- total, error, directory, models[]) and downloads on request:
--   nanum-models-refresh
--   nanum-download-models <all|english|multilingual|multilingual_large|vad>   (all: the required models, not the optional large one)
--   nanum-cancel-model-download
-- Nothing is downloaded unless the user chooses it (settings menu or the
-- one-time prompt). Missing models never block playback: the AI pre-roll is
-- skipped, and the status chip / a toast tells how to install them.
----------------------------------------------------------------------------

local MODEL_SHORT = { english = "영어", multilingual = "다국어", multilingual_large = "다국어 고정밀", vad = "VAD" }

-- Not required: never counted as missing and not part of "all" (the player prefers it when installed).
AIM.OPTIONAL = { multilingual_large = true }

function AIM.name(id)
    return input.core_tr(MODEL_SHORT[id] or tostring(id or ""))
end

function AIM.fmt_size(n)
    n = tonumber(n) or 0
    if n >= 1073741824 then return string.format("%.1f GiB", n / 1073741824) end
    if n >= 1048576 then return string.format("%.0f MiB", n / 1048576) end
    if n >= 1024 then return string.format("%.0f KiB", n / 1024) end
    return string.format("%d B", n)
end

function AIM.list()
    local d = AIM.data
    return d and type(d.models) == "table" and d.models or {}
end

function AIM.by_id(id)
    for _, m in ipairs(AIM.list()) do
        if m.id == id then return m end
    end
    return nil
end

function AIM.active()
    local d = AIM.data
    return d ~= nil and (d.status == "downloading" or d.status == "verifying")
end

-- 0..1 of the file being downloaded, nil if unknown
function AIM.fraction()
    local d = AIM.data
    local total = d and tonumber(d.total) or 0
    if total <= 0 then return nil end
    return math.max(0, math.min(1, (tonumber(d.received) or 0) / total))
end

function AIM.pct()
    local f = AIM.fraction()
    return f and math.floor(f * 100 + 0.5) or nil
end

-- Required models that are not installed (the optional high-accuracy model never counts).
function AIM.missing()
    local r = {}
    for _, m in ipairs(AIM.list()) do
        if m.installed ~= true and not AIM.OPTIONAL[m.id] then r[#r + 1] = m end
    end
    return r
end

-- A needed model is there; the plain multilingual model is replaced by the high-accuracy one.
function AIM.satisfied(id)
    local m = AIM.by_id(id)
    if not m or m.installed == true then return true end
    local large = id == "multilingual" and AIM.by_id("multilingual_large") or nil
    return large ~= nil and large.installed == true
end

-- The engine exists and was not switched off (--nanum=no).
function AIM.engine_enabled()
    return get_opt("nanum") == "yes"
end

-- Speech models the STT input needs for the audio being recognised.
function AIM.needed(tracks)
    local lang = get_opt("nanum-language")
    if lang and lang ~= "" and lang ~= "auto" then
        lang = norm_lang(lang)
    else
        lang = ai_audio_language(tracks)
    end
    return { "vad", lang == "en" and "english" or "multilingual" }
end

-- nil: AI can run. "disabled": engine off. "models", ids: speech models missing.
-- "accel", info: the chosen engine (CPU / CUDA) cannot run speech recognition.
-- A subtitle input (text translation) needs neither models nor CUDA.
function AIM.block_reason()
    if not AIM.engine_enabled() then return "disabled" end
    local tracks = mp.get_property_native("track-list") or {}
    if resolve_choice(tracks).input ~= "stt" then return nil end    -- a subtitle input needs no speech model
    local ids = {}
    for _, id in ipairs(AIM.needed(tracks)) do
        if not AIM.satisfied(id) then ids[#ids + 1] = id end
    end
    if #ids > 0 then return "models", ids end
    -- the file started without them: its engine stays without until the next file
    if AIM.file_block then return "models", AIM.file_block end
    if AIM.file_accel then return "accel", AIM.file_accel end
    -- The engine reports per file whether it started (demuxer-cache-state); without that
    -- (old engine, state not yet published) the accelerator status decides.
    local st = cache_state()
    local ai = st and st["nanum-ai-state"]
    if ai == "ready" then return nil end
    local mode = AIM.file_mode or AIM.mode()
    local info = AIM.accel_block(mode)
    if not info and (ai == "unavailable" or ai == "failed") then
        local a = AIM.acc
        info = { mode = mode, cause = "engine", cpu = not a or a.cpu_available ~= false,
            reason = tostring(st["nanum-ai-reason"] or "") }
    end
    if info then return "accel", info end
    return nil
end

function AIM.note_blocked(reason, info)
    if reason == "accel" then return AIM.note_accel_blocked(info) end
    if reason ~= "models" then return end      -- engine off on purpose: silent
    AIM.file_block = AIM.file_block or info
    publish_status()
    if AIM.notified then return end
    AIM.notified = true
    if AIM.active() then
        notify(input.core_tr("AI 모델을 내려받는 중입니다 · 재생은 그대로 진행되며 완료 후 다음에 여는 파일부터 AI 자막이 켜집니다"), 6, "busy")
        return
    end
    local names = {}
    for _, id in ipairs(info or {}) do names[#names + 1] = AIM.name(id) end
    notify(input.core_tr("AI 모델 없음 (%s) — 음성 자막 없이 재생합니다\nCtrl+N → AI 구성 요소에서 모델을 내려받을 수 있습니다", table.concat(names, " · ")), 8, "warn")
    if opts.model_prompt and not AIM.prompted and #AIM.list() > 0 then
        AIM.prompted = true
        queue_prompt("models", AIM.build_prompt)
        mp.add_timeout(1.5, pump_prompts)
    end
end

function AIM.refresh()
    AIM.cmd_ok = mp.commandv("nanum-models-refresh") == true
    AIM.acc_cmd_ok = mp.commandv("nanum-accelerator-refresh") == true
end

-- which: all | english | multilingual | multilingual_large | vad (every speech model fetches the VAD too)
function AIM.download(which)
    local t = mp.get_time()
    if t - AIM.last_cmd < 0.7 then return false end        -- double click
    AIM.last_cmd = t
    if AIM.active() or AIM.acc_active() then
        notify(input.core_tr("이미 내려받는 중입니다 — 끝나거나 취소한 뒤 다시 선택하세요"), 4, "warn")
        return false
    end
    if not mp.commandv("nanum-download-models", which) then
        notify(AIM.data and input.core_tr("내려받기를 시작하지 못했습니다 (다른 작업이 진행 중일 수 있습니다)")
            or input.core_tr("이 엔진 버전은 모델 내려받기를 지원하지 않습니다 (nanum 갱신 필요)"), 5, "error")
        return false
    end
    AIM.toast_at = 0
    notify(which == "all" and input.core_tr("AI 모델 내려받기를 시작합니다 (VAD · 영어 · 다국어)")
        or input.core_tr(which ~= "vad" and "%s 모델 내려받기를 시작합니다 (VAD 포함)" or "%s 모델 내려받기를 시작합니다",
            AIM.name(which)),
        4, "busy", "model-dl")
    return true
end

function AIM.cancel()
    if AIM.active() then
        mp.commandv("nanum-cancel-model-download")
        notify(input.core_tr("내려받기를 취소하는 중..."), 3, "busy", "model-dl")
    elseif AIM.acc_active() then
        mp.commandv("nanum-cancel-accelerator-download")
        notify(input.core_tr("CUDA 구성 요소 내려받기를 취소하는 중..."), 3, "busy", "accel-dl")
    else
        notify(input.core_tr("진행 중인 내려받기가 없습니다"), 3)
    end
end

function AIM.progress_text()
    local d = AIM.data
    if not d then return nil end
    local name = AIM.name(d.current)
    if d.status == "verifying" then return input.core_tr("%s 무결성 검증 중", name) end
    local pct = AIM.pct()
    if pct then
        return input.core_tr("%s 내려받는 중 %d%% (%s / %s)", name, pct, AIM.fmt_size(d.received), AIM.fmt_size(d.total))
    end
    return input.core_tr("%s 내려받는 중", name)
end

function AIM.status_text()
    local d = AIM.data
    if not d then
        return AIM.cmd_ok == false and input.core_tr("이 엔진 버전은 모델 관리를 지원하지 않습니다") or input.core_tr("확인 중…")
    end
    local s = d.status
    if s == "downloading" or s == "verifying" then return AIM.progress_text() end
    if s == "checking" then return input.core_tr("설치된 파일 확인 중…") end
    if s == "done" then return input.core_tr("내려받기 완료 · 다음에 여는 파일부터 사용") end
    if s == "cancelled" then return input.core_tr("취소됨") end
    if s == "error" then
        local e = tostring(d.error or "")
        return input.core_tr("오류 — %s", e ~= "" and e or input.core_tr("알 수 없는 오류"))
    end
    if #AIM.list() > 0 and #AIM.missing() == 0 then return input.core_tr("모든 모델 설치됨") end
    return input.core_tr("대기 중")
end

-- Short form for the settings menu row.
function AIM.summary()
    local d = AIM.data
    if not d then return AIM.cmd_ok == false and input.core_tr("지원 안 됨") or input.core_tr("확인 중…") end
    if AIM.active() then
        local pct = AIM.pct()
        return input.core_tr(d.status == "verifying" and "%s 검증 중" or "%s 내려받는 중", AIM.name(d.current))
            .. (pct and (" " .. pct .. "%") or "")
    end
    if #AIM.list() == 0 then return input.core_tr("목록 없음") end
    local miss, bytes = AIM.missing(), 0
    if #miss == 0 then return input.core_tr("모두 설치됨") end
    for _, m in ipairs(miss) do bytes = bytes + (tonumber(m.size) or 0) end
    return input.core_tr("미설치 %d개 · %s", #miss, AIM.fmt_size(bytes))
end

-- Progress toast that survives closing the menu: refreshed when the text
-- changed (at most once per second) and at least every 3 seconds.
function AIM.heartbeat()
    local text, id
    if AIM.active() then
        text, id = input.core_tr("AI 모델: %s", AIM.progress_text()), "model-dl"
    elseif AIM.acc_active() then
        text, id = input.core_tr("CUDA 구성 요소: %s", AIM.acc_progress_text()), "accel-dl"
    else
        return
    end
    if fluent.open_id() == "nanum-models" then return end
    local t = mp.get_time()
    if (text ~= AIM.toast_text and t - AIM.toast_at >= 1) or t - AIM.toast_at >= 3 then
        AIM.toast_text, AIM.toast_at = text, t
        notify(text, 4, "busy", id)
    end
end

function AIM.on_change(_, v)
    local prev = AIM.data
    local d = type(v) == "table" and v or nil
    AIM.data = d
    local sig = d and (tostring(d.status) .. "|" .. tostring(d.error or "")) or nil
    local changed = sig ~= AIM.sig
    AIM.sig = sig
    if d and prev and changed then
        if d.status == "done" then
            notify(input.core_tr("AI 모델 내려받기 완료 · 다음에 여는 파일부터 AI 자막을 만듭니다"), 6, "ok", "model-dl")
        elseif d.status == "error" then
            local e = tostring(d.error or "")
            notify(input.core_tr("AI 모델 내려받기 실패") .. (e ~= "" and (": " .. e) or "")
                .. "\n" .. input.core_tr("Ctrl+N → AI 구성 요소에서 다시 시도할 수 있습니다"), 9, "error", "model-dl")
        elseif d.status == "cancelled" then
            notify(input.core_tr("AI 모델 내려받기를 취소했습니다"), 3, "info", "model-dl")
        end
    end
    if d then AIM.heartbeat() end
    AIM.schedule_menu_update()
    publish_status()
end

-- One-time offer when a file is played without the speech models.
function AIM.build_prompt()
    if not (opts.model_prompt and AIM.engine_enabled()) or AIM.any_active() then return nil end
    local miss, bytes = AIM.missing(), 0
    if #miss == 0 then return nil end
    for _, m in ipairs(miss) do bytes = bytes + (tonumber(m.size) or 0) end
    return {
        prompt = input.core_tr("AI 모델 없음"),
        items = {
            input.core_tr("AI 구성 요소 관리 열기"),
            input.core_tr("미설치 모델 모두 내려받기 (%s)", AIM.fmt_size(bytes)),
            input.core_tr("나중에"),
            input.core_tr("다시 묻지 않음"),
        },
        default_item = 1,
        submit = function(i)
            if i == 1 then
                mp.add_timeout(0.1, AIM.open_menu)
            elseif i == 2 then
                AIM.download("all")
            elseif i == 4 then
                opts.model_prompt = false
                save_settings()
            end
        end,
    }
end

----------------------------------------------------------------------------
-- AI engines are bundled; only cuBLAS may need downloading.
--
-- The engine publishes user-data/nanum/accelerator (mode, backend,
-- cpu_available, cuda_available, toolkit, toolkit_directory, directory, busy,
-- status, current, received, total, error, reason, download_size,
-- components[]) and accepts:
--   nanum-accelerator-refresh
--   nanum-download-accelerator
--   nanum-cancel-accelerator-download
-- The option nanum-acceleration=auto|cpu|cuda is applied per file: a finished
-- download or a changed mode never swaps the engine of the running file.
-- Only speech recognition needs the engine; text translation never needs CUDA.
----------------------------------------------------------------------------

AIM.MODES = { "auto", "cpu", "cuda" }
AIM.MODE_LABEL = { auto = "자동", cpu = "CPU만", cuda = "CUDA 필수" }
AIM.MODE_DESC = {
    auto = "자동 — CUDA를 쓸 수 있으면 GPU, 아니면 CPU",
    cpu = "CPU만 — 항상 내장 CPU 엔진",
    cuda = "CUDA 필수 — 쓸 수 없으면 AI 자막을 만들지 않음",
}
AIM.COMP_NAME = { cuda_engine = "CUDA 엔진", cublas = "cuBLAS", cublas_lt = "cuBLASLt" }
AIM.COMP_SOURCE = { user = "내려받은 파일", reused = "이전 버전에서 복사", toolkit = "CUDA Toolkit 사용", app = "앱 폴더", bundled = "앱에 포함" }
AIM.TOOLKIT_URL = "https://developer.nvidia.com/cuda-downloads"

-- "v13.4" of the installed CUDA Toolkit, "" if unknown.
function AIM.toolkit_label()
    local a = AIM.acc
    local v = a and tostring(a.toolkit_version or "") or ""
    if v == "" and a then v = tostring(a.toolkit_directory or ""):match("[\\/][vV](%d+%.%d+)[\\/]") or "" end
    return v ~= "" and ("v" .. v) or ""
end

-- Missing bundled engine bytes and optional cuBLAS runtime bytes, separately.
function AIM.missing_parts()
    local engine, runtimes
    for _, c in ipairs(AIM.acc_list()) do
        if c.installed ~= true then
            if c.id == "cuda_engine" then
                engine = (engine or 0) + (tonumber(c.size) or 0)
            else
                runtimes = (runtimes or 0) + (tonumber(c.size) or 0)
            end
        end
    end
    return engine, runtimes
end

-- The NVIDIA license matters only for the cuBLAS download.
function AIM.cublas_missing()
    local _, runtimes = AIM.missing_parts()
    return runtimes ~= nil
end

-- What to do for GPU acceleration, from what is missing.
function AIM.toolkit_hint()
    local engine, runtimes = AIM.missing_parts()
    if engine then
        return input.core_tr("앱에 포함된 CUDA 엔진이 없거나 손상되었습니다 — NanumPlayer를 다시 설치하세요")
    end
    return input.core_tr("CUDA 13 Toolkit을 설치하면 다운로드 없이 GPU를 사용합니다 (또는 cuBLAS 약 %s 받기)",
        AIM.fmt_size(runtimes or AIM.acc_bytes()))
end

-- The player's own actionable CUDA notice while auto mode uses the CPU.
function AIM.acc_notice()
    local a = AIM.acc
    local r = a and tostring(a.reason or "") or ""
    if a and a.cuda_available ~= true and a.busy ~= true and AIM.mode() == "auto" and not AIM.custom_dll()
        and r:find("^CUDA") then
        return r
    end
    return nil
end

-- A bundled engine is repaired by reinstalling the app, never by downloading.
function AIM.engine_reinstall_needed()
    local a = AIM.acc
    local engine = AIM.missing_parts()
    return a ~= nil and a.catalog ~= false and a.status ~= "checking" and engine ~= nil
        and AIM.mode() ~= "cpu" and not AIM.custom_dll()
end

function AIM.mode()
    return session_accel or opts.acceleration
end

function AIM.mode_text()
    local s = AIM.MODE_DESC[AIM.mode()] and input.core_tr(AIM.MODE_DESC[AIM.mode()]) or AIM.mode()
    if session_accel then s = s .. " " .. input.core_tr("[명령줄 지정]") end
    return s
end

function AIM.acc_name(id)
    return input.core_tr(AIM.COMP_NAME[id] or tostring(id or ""))
end

function AIM.acc_list()
    local a = AIM.acc
    return a and type(a.components) == "table" and a.components or {}
end

function AIM.acc_active()
    local a = AIM.acc
    return a ~= nil and (a.status == "downloading" or a.status == "verifying")
end

function AIM.any_active()
    return AIM.active() or AIM.acc_active()
end

function AIM.acc_fraction()
    local a = AIM.acc
    local total = a and tonumber(a.total) or 0
    if total <= 0 then return nil end
    return math.max(0, math.min(1, (tonumber(a.received) or 0) / total))
end

function AIM.acc_pct()
    local f = AIM.acc_fraction()
    return f and math.floor(f * 100 + 0.5) or nil
end

function AIM.acc_missing()
    local r = {}
    for _, c in ipairs(AIM.acc_list()) do
        if c.id ~= "cuda_engine" and c.installed ~= true then r[#r + 1] = c end
    end
    return r
end

-- Bytes still to fetch: what the engine reports, else the missing components.
function AIM.acc_bytes()
    local a = AIM.acc
    local n = a and tonumber(a.download_size)
    if n then return n end
    local sum = 0
    for _, c in ipairs(AIM.acc_missing()) do sum = sum + (tonumber(c.size) or 0) end
    return sum
end

-- A custom --nanum-ai-dll replaces the managed engines: the accelerator verdict does not apply.
function AIM.custom_dll()
    local v = get_opt("nanum-ai-dll")
    if type(v) ~= "string" or v == "" then return nil end
    local base = v:lower():match("([^/\\]*)$")
    if base == "nanum_ai.dll" or base == "nanum_ai_cpu.dll" or base == "nanum_ai_cuda.dll" then return nil end
    return v
end

-- nvcuda.dll is installed with the NVIDIA driver; without it CUDA cannot work.
function AIM.has_driver()
    if package.config:sub(1, 1) ~= "\\" then return true end
    local t = mp.get_time()
    if AIM.driver_at and t - AIM.driver_at < 10 then return AIM.driver end
    local root = os.getenv("SystemRoot") or "C:\\Windows"
    AIM.driver = require('mp.utils').file_info(root .. "\\System32\\nvcuda.dll") ~= nil
    AIM.driver_at = t
    return AIM.driver
end

-- Distinguish damaged bundled engines from missing downloadable cuBLAS.
function AIM.cuda_cause()
    local a = AIM.acc
    if not AIM.has_driver() then return "nodriver" end
    local listed = #AIM.acc_list() > 0
    local needs = (listed and #AIM.acc_missing() > 0) or (not listed and (tonumber(a and a.download_size) or 0) > 0)
    -- the shipped component catalogue is unreadable: nothing can be downloaded
    if a and a.catalog == false and (needs or not listed) then return "nocatalog" end
    if AIM.engine_reinstall_needed() then return "bundled" end
    if needs then return "missing" end
    return "incompatible"
end

-- "cpu" | "cuda" | "unavailable" the engine would use for a file opened in this mode; nil: unknown.
function AIM.effective(mode)
    local a = AIM.acc
    if not a then return nil end
    local cpu, cuda = a.cpu_available ~= false, a.cuda_available == true
    if mode == "cpu" then return cpu and "cpu" or "unavailable" end
    if mode == "cuda" then return cuda and "cuda" or "unavailable" end
    if cuda then return "cuda" end
    return cpu and "cpu" or "unavailable"
end

-- nil when the engine can run in this mode, else the verdict used by notices and prompts.
function AIM.accel_block(mode)
    local a = AIM.acc
    if not a or AIM.custom_dll() then return nil end
    if AIM.effective(mode) ~= "unavailable" then return nil end
    local info = { mode = mode, reason = tostring(a.reason or ""), cpu = a.cpu_available ~= false }
    if mode == "cpu" then
        local st = cache_state()
        info.cause = "cpu"
        info.reason = tostring(st and st["nanum-ai-reason"] or "")
    else
        info.cause = AIM.cuda_cause()
        info.size = AIM.acc_bytes()
        info.catalog_error = tostring(a.catalog_error or "")
    end
    return info
end

function AIM.accel_text(info)
    local rs = info.reason ~= "" and (" (" .. info.reason .. ")") or ""
    local a = AIM.acc
    if info.cause == "cpu" then
        local tail = (a and a.cuda_available == true)
            and input.core_tr("Ctrl+N → AI 구성 요소에서 '자동' 모드로 바꾸면 CUDA로 만들 수 있습니다")
            or input.core_tr("NanumPlayer를 다시 설치하세요 (nanum_ai_cpu.dll 확인)")
        return input.core_tr("CPU AI 엔진을 사용할 수 없어 AI 자막 없이 재생합니다") .. rs .. "\n" .. tail
    end
    if info.cause == "engine" then
        return input.core_tr("AI 엔진을 사용할 수 없어 AI 자막 없이 재생합니다") .. rs
            .. ((info.mode == "cuda" and info.cpu) and ("\n" .. input.core_tr("Ctrl+N → AI 구성 요소에서 CPU 모드로 바꿀 수 있습니다")) or "")
    end
    local alt = info.cpu and ("\n" .. input.core_tr("Ctrl+N → AI 구성 요소에서 CPU 모드로 바꿀 수 있습니다")) or ""
    local body
    if info.cause == "nodriver" then
        body = input.core_tr("NVIDIA 드라이버를 찾을 수 없어 CUDA를 쓸 수 없습니다 — AI 자막 없이 재생합니다\nNVIDIA 드라이버를 설치하세요")
    elseif info.cause == "nocatalog" then
        body = input.core_tr("CUDA 구성 요소 목록(components\\catalog.json)을 읽을 수 없어 내려받을 수 없습니다%s — AI 자막 없이 재생합니다\nNanumPlayer를 다시 설치하세요",
            (info.catalog_error or "") ~= "" and (" (" .. info.catalog_error .. ")") or "")
    elseif info.cause == "bundled" then
        body = AIM.toolkit_hint()
    elseif info.cause == "missing" then
        body = input.core_tr(info.cpu and "%s — AI 자막 없이 재생합니다\nCtrl+N → AI 구성 요소에서 받을 수 있습니다 (또는 CPU 모드로 바꾸세요)"
            or "%s — AI 자막 없이 재생합니다\nCtrl+N → AI 구성 요소에서 받을 수 있습니다", AIM.toolkit_hint())
    else
        body = input.core_tr("이 PC의 GPU/드라이버에서는 CUDA를 사용할 수 없습니다%s — AI 자막 없이 재생합니다\n구성 요소를 다시 받아도 해결되지 않습니다", rs)
    end
    return input.core_tr(info.mode == "cuda" and "CUDA 필수 모드: %s" or "사용할 AI 엔진이 없습니다 (CPU 엔진 불가) · %s", body) .. alt
end

function AIM.note_accel_blocked(info)
    AIM.file_accel = AIM.file_accel or info
    publish_status()
    if AIM.notified_accel then return end
    AIM.notified_accel = true
    if AIM.acc_active() then
        notify(input.core_tr("CUDA 구성 요소를 내려받는 중입니다 · 재생은 그대로 진행되며 완료 후 다음에 여는 파일부터 적용됩니다"), 6, "busy")
        return
    end
    notify(AIM.accel_text(info), 9, "warn")
    local useful = info.cause == "missing" and info.mode ~= "cpu" or (info.mode == "cuda" and info.cpu)
    if opts.accel_prompt and not AIM.prompted_accel and useful then
        AIM.prompted_accel = true
        queue_prompt("accel", AIM.build_accel_prompt)
        mp.add_timeout(1.5, pump_prompts)
    end
end

-- Auto mode without usable CUDA: say once per session that the CPU is used and, only
-- if installing could help, where to get the GPU engine.
function AIM.note_fallback()
    if AIM.fallback_noted or not (file_active and file_loaded) then return end
    local a = AIM.acc
    if not a or (AIM.file_mode or AIM.mode()) ~= "auto" then return end
    if a.cuda_available == true or a.cpu_available == false or AIM.custom_dll() then return end
    local st = cache_state()
    if st and (st["nanum-ai-backend"] == "cuda" or st["nanum-ai-state"] == "unavailable" or st["nanum-ai-state"] == "failed") then return end
    if not AIM.engine_enabled() or resolve_choice(mp.get_property_native("track-list") or {}).input ~= "stt" then return end
    if AIM.any_active() then return end
    local cause = AIM.cuda_cause()
    if cause == "nodriver" then return end                  -- no NVIDIA GPU stack: nothing to offer
    if cause == "missing" then
        if not opts.accel_prompt then return end
        AIM.fallback_noted = true
        notify(input.core_tr("GPU 가속 없이 CPU로 AI 자막을 만듭니다\n%s", AIM.toolkit_hint()), 8, "info")
    else
        AIM.fallback_noted = true
        local r = tostring(a.reason or "")
        notify(input.core_tr("이 PC에서는 CUDA를 사용할 수 없어 CPU로 AI 자막을 만듭니다%s\n구성 요소를 다시 받아도 해결되지 않습니다",
            r ~= "" and (": " .. r) or ""), 8, "warn")
    end
end

function AIM.set_mode(mode)
    session_accel = nil
    opts.acceleration = mode
    save_settings()
    if set_opt_soft("nanum-acceleration", mode) then
        AIM.accel_opt_ok = true
        notify(input.core_tr("AI 가속 모드: %s · 다음에 여는 파일부터 적용", input.core_tr(AIM.MODE_LABEL[mode])), 4, "ok")
    else
        AIM.accel_opt_ok = false
        notify(input.core_tr("이 엔진 버전은 가속 모드 선택을 지원하지 않습니다 (nanum 갱신 필요)"), 5, "error")
    end
    mp.commandv("nanum-accelerator-refresh")
    publish_status()
    AIM.schedule_menu_update()
end

function AIM.acc_download()
    if AIM.engine_reinstall_needed() then
        notify(AIM.toolkit_hint(), 7, "error", "accel-dl")
        return false
    end
    if AIM.cublas_missing() and not AIM.license_accepted() then      -- the NVIDIA CUDA license comes before the cuBLAS download
        mp.add_timeout(0.1, AIM.open_license_dialog)
        return false
    end
    local t = mp.get_time()
    if t - AIM.last_cmd < 0.7 then return false end        -- double click
    AIM.last_cmd = t
    if AIM.any_active() then
        notify(input.core_tr("이미 내려받는 중입니다 — 끝나거나 취소한 뒤 다시 선택하세요"), 4, "warn")
        return false
    end
    if AIM.acc and AIM.acc.catalog == false and AIM.cuda_cause() == "nocatalog" then
        notify(input.core_tr("CUDA 구성 요소 목록을 읽을 수 없어 내려받을 수 없습니다 — NanumPlayer를 다시 설치하세요"), 6, "warn")
        return false
    end
    if not mp.commandv("nanum-download-accelerator") then
        notify(AIM.acc and input.core_tr("내려받기를 시작하지 못했습니다 (다른 작업이 진행 중일 수 있습니다)")
            or input.core_tr("이 엔진 버전은 CUDA 가속 내려받기를 지원하지 않습니다 (nanum 갱신 필요)"), 5, "error")
        return false
    end
    AIM.toast_at = 0
    notify(input.core_tr("cuBLAS 내려받기를 시작합니다 (%s)", AIM.fmt_size(AIM.acc_bytes())), 4, "busy", "accel-dl")
    return true
end

function AIM.acc_progress_text()
    local a = AIM.acc
    if not a then return nil end
    local name = AIM.acc_name(a.current)
    if a.status == "verifying" then return input.core_tr("%s 무결성 검증 중", name) end
    local pct = AIM.acc_pct()
    if pct then
        return input.core_tr("%s 내려받는 중 %d%% (%s / %s)", name, pct, AIM.fmt_size(a.received), AIM.fmt_size(a.total))
    end
    return input.core_tr("%s 내려받는 중", name)
end

function AIM.acc_status_text()
    local a = AIM.acc
    if not a then
        return AIM.acc_cmd_ok == false and input.core_tr("이 엔진 버전은 CUDA 가속 관리를 지원하지 않습니다") or input.core_tr("확인 중…")
    end
    local s = a.status
    if s == "downloading" or s == "verifying" then return AIM.acc_progress_text() end
    if s == "checking" then return input.core_tr("구성 요소 확인 중…") end
    if s == "cancelled" then return input.core_tr("취소됨") end
    if s == "error" then
        local e = tostring(a.error or "")
        return input.core_tr("오류 — %s", e ~= "" and e or input.core_tr("알 수 없는 오류"))
    end
    if s == "done" then
        if a.cuda_available == true then return input.core_tr("내려받기 완료 · 다음에 여는 파일부터 GPU 사용") end
        return input.core_tr("내려받기 완료 · 그러나 이 PC에서는 CUDA를 쓸 수 없음")
    end
    if AIM.engine_reinstall_needed() then return input.core_tr("CUDA 엔진 복구 필요 — NanumPlayer를 다시 설치하세요") end
    local eff = AIM.effective(AIM.mode())
    if eff == "cuda" then return input.core_tr("다음 파일: CUDA(GPU)로 AI 자막") end
    if eff == "cpu" then
        local notice = AIM.acc_notice()
        return notice and input.core_tr("다음 파일: CPU로 AI 자막 · %s", notice) or input.core_tr("다음 파일: CPU로 AI 자막")
    end
    return input.core_tr("다음 파일: AI 자막 사용 불가 (선택한 엔진 없음)")
end

function AIM.components_summary()
    local models = AIM.summary()
    if AIM.acc_active() then
        local pct = AIM.acc_pct()
        return input.core_tr("CUDA %s 내려받는 중", AIM.acc_name(AIM.acc.current)) .. (pct and (" " .. pct .. "%") or "")
    end
    return input.core_tr("가속 %s · %s", AIM.MODE_LABEL[AIM.mode()] and input.core_tr(AIM.MODE_LABEL[AIM.mode()]) or AIM.mode(), models)
end


function AIM.on_acc_change(_, v)
    local prev = AIM.acc
    local d = type(v) == "table" and v or nil
    AIM.acc = d
    local sig = d and (tostring(d.status) .. "|" .. tostring(d.error or "")) or nil
    local changed = sig ~= AIM.acc_sig
    AIM.acc_sig = sig
    if d and prev and changed then
        if d.status == "done" then
            mp.add_timeout(0.6, AIM.acc_done_notice)
        elseif d.status == "error" then
            local e = tostring(d.error or "")
            notify(input.core_tr("CUDA 구성 요소 내려받기 실패") .. (e ~= "" and (": " .. e) or "")
                .. "\n" .. input.core_tr("Ctrl+N → AI 구성 요소에서 다시 시도할 수 있습니다 (받은 파일은 유지됩니다)"), 9, "error", "accel-dl")
        elseif d.status == "cancelled" then
            notify(input.core_tr("CUDA 구성 요소 내려받기를 취소했습니다 (받은 파일은 유지됩니다)"), 3, "info", "accel-dl")
        end
    end
    if d then
        AIM.heartbeat()
        AIM.note_fallback()
    end
    AIM.schedule_menu_update()
    publish_status()
end

-- After a finished download: the real verdict of the engine decides the message.
function AIM.acc_done_notice()
    local a = AIM.acc
    if not a then return end
    local mode = AIM.mode()
    if a.cuda_available == true then
        local s = input.core_tr("CUDA 가속 구성 요소 설치 완료 · 다음에 여는 파일부터 적용됩니다")
        if mode == "cpu" then s = s .. "\n" .. input.core_tr("현재 가속 모드는 'CPU만'입니다 — Ctrl+N → AI 구성 요소에서 바꿀 수 있습니다") end
        notify(s, 7, "ok", "accel-dl")
    else
        local r = tostring(a.reason or "")
        local s = input.core_tr("CUDA 구성 요소를 설치했지만 이 PC에서는 CUDA를 사용할 수 없습니다") .. (r ~= "" and (": " .. r) or "")
        if mode == "cuda" then
            s = s .. "\n" .. input.core_tr("CUDA 필수 모드에서는 AI 자막이 꺼집니다 — Ctrl+N → AI 구성 요소에서 CPU 모드로 바꾸세요")
        else
            s = s .. "\n" .. input.core_tr("CPU로 계속 사용합니다")
        end
        notify(s, 10, "warn", "accel-dl")
    end
end

-- One-time offer (CUDA required but not runnable, or no engine at all).
function AIM.build_accel_prompt()
    local info = AIM.file_accel
    if not (opts.accel_prompt and info) or AIM.any_active() then return nil end
    local items, actions = {}, {}
    local function add(text, fn)
        items[#items + 1] = text
        actions[#actions + 1] = fn
    end
    if info.cause == "missing" and info.mode ~= "cpu" then
        add(input.core_tr("CUDA 가속 구성 요소 내려받기 (%s)", AIM.fmt_size(info.size)), function() AIM.acc_download() end)
        if AIM.cublas_missing() then
            add(input.core_tr("CUDA 13 Toolkit 받는 곳 열기 (설치하면 cuBLAS 다운로드 불필요)"), function() SUBS.open_url(AIM.TOOLKIT_URL) end)
        end
    end
    if info.mode == "cuda" and info.cpu then
        add(input.core_tr("CPU 모드로 전환 (다음 파일부터)"), function() AIM.set_mode("cpu") end)
    end
    add(input.core_tr("AI 구성 요소 관리 열기"), function() mp.add_timeout(0.1, AIM.open_menu) end)
    add(input.core_tr("나중에"), function() end)
    add(input.core_tr("다시 묻지 않음"), function()
        opts.accel_prompt = false
        save_settings()
    end)
    return {
        prompt = input.core_tr(info.mode == "cuda" and "CUDA를 사용할 수 없음" or "GPU 가속 구성 요소가 필요합니다"),
        items = items,
        default_item = 1,
        submit = function(i)
            if actions[i] then actions[i]() end
        end,
    }
end

----------------------------------------------------------------------------
-- Full track application
----------------------------------------------------------------------------

local function find_full_track(path)
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "sub" and ai_role(t) == "full" and t["external-filename"] == path then return t end
    end
    return nil
end

-- Drop superseded full tracks once the current one is loaded.
local function prune_full_tracks()
    local keep = applied_path and find_full_track(applied_path)
    if not keep then return end
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "sub" and ai_role(t) == "full" and t.id ~= keep.id and not t.selected then
            mp.commandv("sub-remove", tostring(t.id))
        end
    end
end

-- True unless the user picked a non-AI subtitle track on purpose.
local function ai_track_in_use()
    refresh_ai_ids()
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "sub" and t.selected then
            local role = ai_role(t)
            return role == "primary" or role == "full"
        end
    end
    return true
end

local function apply_full(path, reload)
    local existing = find_full_track(path)
    local select = applied_path == nil or ai_track_in_use()
    if existing then
        if reload then mp.commandv("sub-reload", tostring(existing.id)) end
        if select and not existing.selected then mp.set_property_number("sid", existing.id) end
    else
        local tgt = SUBS.ux and SUBS.ux.target() or nil
        mp.commandv("sub-add", path, select and "select" or "auto", (tgt and tgt.label or "ko") .. FULL_SUFFIX, tgt and tgt.code or "ko")
    end
    applied_path = path
    keep_full = false
    mp.add_timeout(0.7, prune_full_tracks)
    mp.add_timeout(2.5, prune_full_tracks)
end

----------------------------------------------------------------------------
-- Status chip (Fluent chrome header): real engine state, no OSD spam
----------------------------------------------------------------------------

-- State of an optional input the player publishes as nanum-<key>-state / -language / -ready-until /
-- -reason (off | waiting | running | done | unavailable). running_only: only the progress of a
-- running input (status chip).
local function input_state_text(st, key, label, running_only)
    local s = st and st["nanum-" .. key .. "-state"]
    if not s or s == "off" then return nil end
    if s == "running" then
        local r = st["nanum-" .. key .. "-ready-until"]
        local ahead = r and (r - abs_pos())
        if ahead and ahead > 1 then return input.core_tr("%s 준비 중 · %.0f초 앞", label, ahead) end
        return input.core_tr("%s 분석 중", label)
    end
    if running_only then return nil end
    if s == "waiting" then return input.core_tr("%s 대기 중 (기본 자막이 앞서가면 시작)", label) end
    if s == "done" then return input.core_tr("%s 준비 완료", label) end
    if s == "unavailable" then
        local why = tostring(st["nanum-" .. key .. "-reason"] or "")
        return why ~= "" and input.core_tr("%s 사용 불가 (%s)", label, why) or input.core_tr("%s 사용 불가", label)
    end
    return nil
end

-- Secondary (original-language audio) input.
local function secondary_text(st, running_only)
    local name = lang_name(st and st["nanum-secondary-language"])
    return input_state_text(st, "secondary", name and input.core_tr("%s 기반", name) or input.core_tr("원어 기반"), running_only)
end

-- Disc image subtitles read by OCR.
function SUBS.pgs_text(st, running_only)
    local name = lang_name(st and st["nanum-pgs-language"])
    local text = input_state_text(st, "pgs", name and input.core_tr("%s 디스크 자막 기반", name) or input.core_tr("디스크 자막 기반"), running_only)
    -- the player says e.g. which OCR language pack stands in for a missing one
    local why = tostring(st and st["nanum-pgs-reason"] or "")
    if text and not running_only and why ~= "" and st["nanum-pgs-state"] ~= "unavailable" then text = text .. " · " .. why end
    return text
end

-- Subtitle file the user downloaded / picked: alignment and translation progress, result.
function SUBS.import_text(st)
    local s = st and st["nanum-import-state"]
    if not s or s == "off" then return nil end
    local pct = math.floor((tonumber(st["nanum-import-progress"]) or 0) * 100 + 0.5)
    if s == "aligning" then return input.core_tr("가져온 자막 시간 맞추는 중 %d%%", pct) end
    if s == "translating" then return input.core_tr("가져온 자막 번역 중 %d%%", pct) end
    if s == "done" then return input.core_tr("가져온 자막 준비 완료") .. SUBS.alignment_text(st) end
    if s == "error" then
        local e = tostring(st["nanum-import-error"] or "")
        return input.core_tr("가져온 자막 오류") .. (e ~= "" and (": " .. e) or "")
    end
    return nil
end

-- " (시간 +1.2초 · 속도 보정 ×1.0427 · 정렬 신뢰도 80%)" from the alignment fields; "" if none.
function SUBS.alignment_text(st)
    local parts = {}
    local off, scale, conf = tonumber(st["nanum-import-offset"]), tonumber(st["nanum-import-scale"]), tonumber(st["nanum-import-confidence"])
    if off then parts[#parts + 1] = input.core_tr("시간 %+.1f초", off) end
    if scale and math.abs(scale - 1) > 0.0005 then parts[#parts + 1] = input.core_tr("속도 보정 ×%.4f", scale) end
    if conf then parts[#parts + 1] = input.core_tr("정렬 신뢰도 %d%%", math.floor(conf * 100 + 0.5)) end
    return #parts > 0 and (" (" .. table.concat(parts, " · ") .. ")") or ""
end

local function with_secondary(text, st)
    local extras = { secondary_text(st, true) or false, SUBS.pgs_text(st, true) or false,
        (not AIM.acc_active() and AIM.acc_notice()) or false }
    for _, extra in ipairs(extras) do
        if extra then text = text .. " · " .. extra end
    end
    return text
end

-- Work and original language the AI identified from the title.
local function original_text(st)
    local work = st and st["nanum-profile-work"]
    local lang = lang_name(st and st["nanum-original-language"])
    local parts = {}
    if type(work) == "string" and work ~= "" then parts[#parts + 1] = input.core_tr("작품: %s", work) end
    if lang then parts[#parts + 1] = input.core_tr("원어: %s", lang) end
    return #parts > 0 and table.concat(parts, " · ") or nil
end

-- Progress / result of applying a glossary edit (the player retranslates the lines that use the changed names).
local function glossary_apply_text(st)
    local s = st and st["nanum-glossary-apply-state"]
    if s == "running" then
        return input.core_tr("용어집 반영 중 %d%%", math.floor((tonumber(st["nanum-glossary-apply-progress"]) or 0) * 100 + 0.5))
    elseif s == "done" then
        local n = tonumber(st["nanum-glossary-apply-changed"]) or 0
        return n > 0 and input.core_tr("용어집 반영 완료 (자막 %d줄 다시 번역)", n) or input.core_tr("용어집 반영 완료 (바뀐 자막 없음)")
    elseif s == "error" then
        local e = tostring(st["nanum-glossary-apply-error"] or "")
        return input.core_tr("용어집 반영 실패") .. (e ~= "" and (": " .. e) or "")
    end
    return nil
end

local gloss_apply_prev, gloss_apply_text, gloss_apply_at = nil, nil, 0
local function on_glossary_apply(st)
    local s = st["nanum-glossary-apply-state"]
    if s == nil then return end
    local prev = gloss_apply_prev
    gloss_apply_prev = s
    local now = mp.get_time()
    if s == "running" then
        local text = glossary_apply_text(st)
        if prev ~= "running" or (text ~= gloss_apply_text and now - gloss_apply_at >= 1) then
            gloss_apply_text, gloss_apply_at = text, now
            notify(text, 4, "busy", "glossary")
        end
    elseif s == "done" and prev == "running" then
        local n = tonumber(st["nanum-glossary-apply-changed"]) or 0
        notify(n > 0 and input.core_tr("용어집을 반영해 자막 %d줄을 다시 번역했습니다", n)
            or input.core_tr("용어집을 반영했습니다 (바뀐 자막은 없습니다)"), 5, "ok", "glossary")
    elseif s == "error" and prev ~= "error" then
        notify(glossary_apply_text(st), 7, "error", "glossary")
    end
end

-- Result of a glossary rebuild the user asked for.
local function on_profile(st)
    local ps = st["nanum-profile-state"]
    if gloss_wait == "requested" and ps == "running" then
        gloss_wait = "running"
    elseif gloss_wait == "running" and ps ~= "running" then
        gloss_wait = nil
        if ps == "ready" then
            local n = st["nanum-glossary-count"]
            local work = tostring(st["nanum-profile-work"] or "")
            local count = type(n) == "number"
            local msg
            if work ~= "" and count then
                msg = input.core_tr("용어집을 AI로 다시 만들었습니다 · %s · %d개", work, n)
            elseif work ~= "" then
                msg = input.core_tr("용어집을 AI로 다시 만들었습니다 · %s", work)
            elseif count then
                msg = input.core_tr("용어집을 AI로 다시 만들었습니다 · %d개", n)
            else
                msg = input.core_tr("용어집을 AI로 다시 만들었습니다")
            end
            notify(msg, 5, "ok", "glossary")
        else
            notify(input.core_tr("AI 용어집 생성에 실패했습니다 (번역 서버 확인) — 기존 용어집을 유지합니다"), 6, "error", "glossary")
        end
    end
end

local last_status, last_status_at = nil, 0

-- -> text, kind (ok | busy | error | info); "" clears the chip
local function compute_status()
    if not (file_active and file_loaded) then return "", "info" end
    if mp.get_property_bool("paused-for-cache") and (mp.get_property("path") or ""):lower():find("^https?://") then
        return input.core_tr("네트워크에서 미리 받는 중"), "busy"
    end
    if not AIM.engine_enabled() then return "", "info" end
    do
        local skip_text, skip_kind = nil, nil
        if SUBS.ux then skip_text, skip_kind = SUBS.ux.status() end
        if skip_text then return skip_text, skip_kind end
    end
    if ai_disabled then return input.core_tr("AI 자막 꺼짐"), "info" end
    local reason, info = AIM.block_reason()
    if reason == "models" then
        if AIM.active() then
            local pct = AIM.pct()
            return input.core_tr("AI 모델 내려받는 중") .. (pct and (" " .. pct .. "%") or ""), "busy", "models"
        end
        if #AIM.missing() > 0 then return input.core_tr("AI 모델 없음 · 눌러서 설치"), "warn", "models" end
        return input.core_tr("AI 모델 설치됨 · 다음 파일부터 적용"), "info", "models"
    elseif reason == "accel" then
        if AIM.acc_active() then
            local pct = AIM.acc_pct()
            return input.core_tr("CUDA 구성 요소 내려받는 중") .. (pct and (" " .. pct .. "%") or ""), "busy", "models"
        end
        if info.mode ~= AIM.mode() then return input.core_tr("AI 가속 모드 변경됨 · 다음 파일부터 적용"), "info", "models" end
        if info.cause ~= "engine" and AIM.effective(info.mode) ~= "unavailable" then
            return input.core_tr("AI 엔진 사용 가능 · 다음 파일부터 적용"), "info", "models"
        end
        if info.cause == "missing" and info.mode ~= "cpu" then return input.core_tr("CUDA 필요 · AI 꺼짐 · 눌러서 설치"), "warn", "models" end
        return input.core_tr("AI 엔진 사용 불가 · 눌러서 확인"), "warn", "models"
    end
    local st = cache_state()
    if waiting then
        local ready = ready_until()
        local have = ready and math.max(0, ready - abs_pos()) or 0
        return input.core_tr("AI 자막 준비 중 %.0f / %d초", have, waiting.lead or opts.preroll), "busy"
    end
    local fs = st and st["nanum-full-state"]
    if fs == "error" then
        local e = st["nanum-full-error"]
        return input.core_tr("AI 전체 번역 오류") .. ((e and e ~= "") and (": " .. e) or ""), "error"
    end
    if lib.state == "error" then
        return input.core_tr("AI 자막 라이브러리 오류") .. (lib.error ~= "" and (": " .. lib.error) or ""), "error"
    end
    local pct = st and math.floor((st["nanum-full-progress"] or 0) * 100 + 0.5) or 0
    if fs == "scanning" then return input.core_tr("AI 원문 수집 중 %d%%", pct), "busy" end
    if fs == "translating" then return input.core_tr("AI 전체 번역 중 %d%%", pct), "busy" end
    if lib.state == "loading" then return input.core_tr("저장된 AI 자막 확인 중"), "busy" end
    if fs == "done" then return input.core_tr("AI 전체 번역 완료"), "ok" end
    if lib.state == "using" then return input.core_tr("저장된 AI 자막 사용 중"), "ok" end
    if st and st["nanum-glossary-apply-state"] == "running" then return glossary_apply_text(st), "busy" end
    local its = st and st["nanum-import-state"]
    if its == "aligning" or its == "translating" then return SUBS.import_text(st), "busy" end
    if SUBS.server_down and st and st["nanum-profile-state"] == "error" then
        -- the translation of a line that fails is shown as its original text (never a blank screen)
        return input.core_tr("번역 서버에 연결할 수 없습니다 · 번역되지 않은 줄은 원문으로 표시합니다"), "warn"
    end
    local r = ready_until()
    if r then
        local ahead = r - abs_pos()
        if ahead > 1 then return with_secondary(input.core_tr("AI 자막 준비됨 · %.0f초 앞", ahead), st), "ok" end
        return with_secondary(input.core_tr("AI 자막 분석 중"), st), "busy"
    end
    if st and st["nanum-input-active"] then return with_secondary(input.core_tr("AI 자막 분석 중"), st), "busy" end
    return input.core_tr("AI 자막 엔진 대기 중"), "info"
end

function publish_status()
    if not chrome_alive() then return end
    local text, kind, action = compute_status()
    local key = text .. "|" .. kind .. "|" .. (action or "")
    local t = mp.get_time()
    if key == last_status and t - last_status_at < 3 then return end
    last_status, last_status_at = key, t
    mp.commandv("script-message", "nanum-fluent", "ui-status", text, kind, action or "")
end

local function on_cache_state(_, st)
    if not st or not file_active then return end
    on_library(st)
    refresh_ai_ids(st)
    auto_select_primary(st)
    on_profile(st)
    if st["nanum-profile-state"] == "error" then SUBS.probe_server() elseif SUBS.server_down then SUBS.server_down = false end
    on_glossary_apply(st)
    SUBS.on_state(st)
    local s = st["nanum-full-state"]
    if not s then return end            -- old engine: nothing to do
    local prev = last_full_state
    last_full_state = s
    if s == "done" then
        local path = st["nanum-full-file"]
        if path and path ~= "" then
            if path ~= applied_path then
                -- first completion, rebuilt file or another presentation of the same revision
                local first = applied_path == nil
                apply_full(path, false)
                if first or prev ~= "done" then
                    notify(input.core_tr("AI 전체 번역 자막을 적용했습니다"), 3, "ok")
                end
            elseif prev ~= "done" then
                apply_full(path, keep_full)     -- same path: reload a rebuilt file, else just select it
            end
        end
    elseif prev == "done" and not keep_full then
        select_live()                   -- state reset (input changed): back to the live track
    end
    if s == "error" then
        keep_full = false               -- the previous complete track stays
        local e = st["nanum-full-error"] or ""
        if last_error_shown ~= e then
            last_error_shown = e
            local hint = lib_supported() and ("\n" .. input.core_tr("Ctrl+N → 저장 자막 다시 조회 / 새로 생성")) or ""
            notify(full_status_text(st) .. hint, 6, "error")
        end
    elseif s == "scanning" or s == "translating" then
        local now = mp.get_time()
        -- not intrusive: every 2 s while paused, every 20 s during playback
        local interval = mp.get_property_bool("pause") and 2 or 20
        if prev ~= s or now - last_full_osd >= interval then
            if not chrome_alive() and not waiting and not popup_open and not decision_outstanding() and now - last_full_osd >= 2 then
                last_full_osd = now
                mp.osd_message(full_status_text(st), 2)
            end
        end
    end
end

mp.observe_property("demuxer-cache-state", "native", on_cache_state)

----------------------------------------------------------------------------
-- File events
----------------------------------------------------------------------------

mp.register_event("start-file", function()
    stop_wait(false)
    selected_once = false
    file_loaded = false
    file_active = true
    last_aid = nil
    last_full_state = nil
    last_error_shown = nil
    applied_path = nil
    keep_full = false
    ai_disabled = false
    pinned_aud = nil
    deferred = nil
    SUBS.yt.log = {}
    mp.set_property_native("user-data/nanum/error-handled", false)
    AIM.file_block, AIM.notified = nil, false
    AIM.file_accel, AIM.notified_accel = nil, false
    AIM.file_mode = AIM.mode()
    prompt_queue = {}
    lib_reset()
    ai_ids.primary, ai_ids.secondary, ai_ids.pgs, ai_ids.import = nil, nil, nil, nil
    SUBS.reset()
    gloss_wait = nil
    gloss_apply_prev, gloss_pending = nil, nil
    cancel_glossary_edit()
    if SUBS.ux then SUBS.ux.reset() end
    prepare_file_options()
    sel_mode = opts.input_mode
    sel_track_id = nil
end)

mp.register_event("end-file", function(event)
    file_loaded = false
    file_active = false
    last_full_state = nil
    hint_until = nil
    deferred = nil
    AIM.file_block = nil
    AIM.file_accel, AIM.file_mode = nil, nil
    prompt_queue = {}
    if popup_open then input.terminate() end
    pinned_aud = nil
    lib_reset()
    prepare_file_options()
    stop_wait(true)                    -- cancel the timer and release only our pause
    if event.reason == "error" then
        if SUBS.yt.on_play_error() then return end
        if SUBS.disc.on_play_error() then return end
        local detail = event.file_error or input.core_tr("알 수 없는 오류")
        mp.msg.error("재생 실패: " .. detail)
        notify(input.core_tr("재생 실패: %s\nBlu-ray라면 디스크 상태와 자동 키 DB 다운로드 오류를 확인하세요.\n필요하면 Ctrl+N에서 디스크 진단 로그를 명시적으로 켤 수 있습니다.", detail), 12, "error")
    end
end)

local last_sub_sig, sub_signature
mp.register_event("file-loaded", function()
    last_sub_sig = nil
    file_loaded = true
    loaded_at = mp.get_time()
    last_aid = mp.get_property_number("aid")    -- baseline, no change event is sent for it
    pin_audio(mp.get_property_native("track-list"))
    if lib_option_ok then lib_probe_until = loaded_at + 6 end
    if SUBS.ux then SUBS.ux.file_loaded() end      -- a subtitle already in the target language: shown, AI work skipped
    apply_full_options()
    reevaluate(false)
    AIM.file_block, AIM.file_accel = nil, nil
    do
        local reason, info = AIM.block_reason()
        if reason == "models" then
            AIM.file_block = info
        elseif reason == "accel" then
            AIM.file_accel = info
        else
            AIM.note_fallback()
        end
    end
    last_sub_sig = sub_signature()
    SUBS.baseline()
    if not hint_shown then
        hint_shown = true
        hint_until = mp.get_time() + 5
        notify(input.core_tr("Ctrl+N: AI 자막 설정"), 4)
    end
    wait_for_ai(opts.preroll)
end)

-- A user seek must not revive a deferred initial subtitle wait.
mp.register_event("seek", function() deferred = nil end)

function sub_signature()
    refresh_ai_ids()
    local parts = {}
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "sub" and not ai_role(t) then
            parts[#parts + 1] = t.id
        end
    end
    return table.concat(parts, ",")
end

-- demuxer-cache-state is only re-published when the cache changes; a file that
-- is fully cached never does, so poll the engine state (full track, library).
mp.add_periodic_timer(1, function()
    if not file_loaded then return end
    on_cache_state(nil, mp.get_property_native("demuxer-cache-state"))
    if pending_saved and mp.get_time() - pending_saved.since > 20 then
        pending_saved = nil
        notify(input.core_tr("현재 음성에 저장된 AI 자막을 찾지 못했습니다"), 4, "warn")
    end
    if deferred and not decision_outstanding() then
        local d = deferred
        deferred = nil
        -- a long wait means playback is already well in: no pause for the start pre-roll
        if mp.get_time() - d.since <= 5 then wait_for_ai(d.lead) end
    end
    publish_status()
    pump_prompts()
end)
mp.observe_property("track-list", "native", function(_, tracks)
    if tracks and file_active then pin_audio(tracks) end
    -- External/late subtitle tracks (sub-add, --sub-file) appear after file-loaded.
    -- Our own tracks are excluded from the signature.
    if tracks and file_loaded and sel_mode == "auto" then
        refresh_ai_ids()
        local parts = {}
        for _, t in ipairs(tracks) do
            if t.type == "sub" and not ai_role(t) then
                parts[#parts + 1] = t.id
            end
        end
        local sig = table.concat(parts, ",")
        if last_sub_sig ~= nil and sig ~= last_sub_sig then
            reevaluate(true)
        end
        last_sub_sig = sig
    end
    if tracks then auto_select_primary() end
    if tracks then SUBS.on_tracks(tracks) end
    if tracks and SUBS.ux then SUBS.ux.tracks_changed() end
end)

-- Playback audio only. The AI input stays pinned to the track chosen at load
-- (nanum-audio-id): no source re-evaluation, no engine restart; a language
-- mismatch is offered as a prompt (keep / generate / use saved).
mp.observe_property("aid", "number", function(_, aid)
    if aid == nil then
        return
    end
    local changed = last_aid ~= nil and aid ~= last_aid
    last_aid = aid
    if not changed then return end
    -- mpv fills the new track from the demuxer's read-ahead position, far
    -- ahead of playback. Seek to the current position (a relative seek by
    -- 0 is ignored) so the audio restarts from here.
    mp.add_timeout(0.2, function()
        local pos = mp.get_property_number("time-pos")
        if pos then
            mp.msg.info(string.format("audio track changed to %d: resync at %.1f", aid, pos))
            mp.commandv("seek", tostring(pos), "absolute+exact")
        end
    end)
    if mp.get_time() - loaded_at > 1.5 then schedule_audio_prompt() end   -- not the initial selection
end)

mp.add_key_binding("ctrl+k", "nanum-status", function()
    local r = ready_until()
    local now = abs_pos()
    local st = cache_state()
    local line
    if r then
        line = input.core_tr("AI 자막: %.0f초 앞까지 준비됨 (재생 %.0f초)", r - now, now)
    else
        line = input.core_tr("AI 자막: 분석 중이거나 사용 불가")
    end
    local active = st and st["nanum-input-active"]
    if active then
        line = line .. input.core_tr(active == "sub" and " [입력: 자막]" or " [입력: 음성 인식]")
    end
    local ai_backend = st and st["nanum-ai-backend"]
    if ai_backend == "cpu" or ai_backend == "cuda" then
        line = line .. input.core_tr(" [엔진: %s]", ai_backend == "cuda" and "CUDA" or "CPU")
    end
    local full = full_status_text(st)
    if full then
        line = line .. "\n" .. full
    elseif opts.full and st and st["nanum-full-state"] == nil then
        line = line .. "\n" .. input.core_tr("전체 번역: 이 엔진 버전은 지원하지 않습니다")
    end
    local lsx = lib_status_text()
    if lsx then line = line .. "\n" .. lsx end
    local sec = secondary_text(st)
    if sec then line = line .. "\n" .. sec end
    local pgs = SUBS.pgs_text(st)
    if pgs then line = line .. "\n" .. pgs end
    local imp = SUBS.import_text(st)
    if imp then line = line .. "\n" .. imp end
    local ga = glossary_apply_text(st)
    if ga then line = line .. "\n" .. ga end
    local tk = AIM.acc_notice()
    if tk then line = line .. "\n" .. tk end
    local orig = original_text(st)
    if orig then line = line .. "\n" .. orig end
    local ver = mp.get_property_native("user-data/nanum/app-version")
    ver = type(ver) == "string" and ver or ""
    if ver ~= "" then line = "NanumPlayer " .. ver .. "\n" .. line end
    notify(line, 4)
end)

----------------------------------------------------------------------------
-- Settings menu (Ctrl+n). Values are saved to ~~/script-opts/nanum.conf.
-- The translation model / target language are engine options: they are applied
-- to the next file that is opened (the engine starts per file).
----------------------------------------------------------------------------

local ENGINE = {
    { key = "translate_model", opt = "nanum-translate-model", label = "번역 모델" },
    { key = "target_language", opt = "nanum-target-language", label = "목표 언어" },
    { key = "translate_endpoint", opt = "nanum-translate-endpoint", label = "번역 서버 주소" },
}
local engine_vals = opts        -- saved engine values were read with the other options
for _, e in ipairs(ENGINE) do
    if engine_vals[e.key] ~= "" then
        mp.set_property("options/" .. e.opt, engine_vals[e.key])
    end
end
apply_full_options()

-- Translation style and the secondary input are runtime options of the player: apply the saved
-- non-default choices (a command line value stays when the saved one is the default).
local function apply_translate_options()
    if opts.translate_style ~= "natural" then set_opt_soft("nanum-translate-style", opts.translate_style) end
    if opts.translate_style_text ~= "" then set_opt_soft("nanum-translate-style-text", opts.translate_style_text) end
    if not opts.secondary then set_opt_soft("nanum-secondary", "no") end
    if not opts.pgs then set_opt_soft("nanum-pgs", "no") end
end
apply_translate_options()
prepare_file_options()

function save_settings()
    local path = mp.command_native({ "expand-path", "~~/script-opts/nanum.conf" })
    local dir = path:match("^(.*)[/\\]"):gsub("/", "\\")
    mp.command_native({ name = "subprocess", args = { "cmd", "/c", "mkdir", dir },     -- fails harmlessly if it exists
                        playback_only = false })
    local f, err = io.open(path, "w")
    if not f then
        notify(input.core_tr("설정 저장 실패: %s", tostring(err)), 4, "error")
        return
    end
    f:write(string.format("preroll=%d\ntimeout=%d\nauto_select=%s\n",
        opts.preroll, opts.timeout, opts.auto_select and "yes" or "no"))
    f:write(string.format("input_mode=%s\nfull=%s\nfull_engine=%s\n",
        opts.input_mode, opts.full and "yes" or "no", opts.full_engine))
    f:write(string.format("display=%s\nlibrary_auto_use=%s\nmodel_prompt=%s\n", opts.display,
        opts.library_auto_use and "yes" or "no", opts.model_prompt and "yes" or "no"))
    f:write(string.format("acceleration=%s\naccel_prompt=%s\n", opts.acceleration, opts.accel_prompt and "yes" or "no"))
    f:write(string.format("translate_style=%s\nsecondary=%s\n", opts.translate_style, opts.secondary and "yes" or "no"))
    f:write("pgs=" .. (opts.pgs and "yes" or "no") .. "\n")
    f:write("original_first=" .. (opts.original_first and "yes" or "no") .. "\n")
    f:write(string.format("bar_hide=%s\nai_tags=%s\n", opts.bar_hide, opts.ai_tags and "yes" or "no"))
    if opts.downloads_dir ~= "" then f:write("downloads_dir=" .. opts.downloads_dir .. "\n") end
    if opts.translate_style_text ~= "" then f:write("translate_style_text=" .. opts.translate_style_text .. "\n") end
    if opts.cuda_license then f:write("cuda_license=yes\n") end
    if opts.omp_model ~= "" then
        f:write("omp_model=" .. opts.omp_model .. "\n")
    end
    for _, e in ipairs(ENGINE) do
        if engine_vals[e.key] ~= "" then
            f:write(string.format("%s=%s\n", e.key, engine_vals[e.key]))
        end
    end
    f:close()
end

local open_menu

local menu_last_key, menu_keep = nil, false

local function reopen_menu()
    menu_keep = true
    mp.add_timeout(0.1, open_menu)
end

-- How the AI entries present their cues (translation / translation + original / original only). Presentation
-- only: the engine re-renders without any reprocessing. The saved value is the last AI presentation chosen in
-- the subtitle list (older versions saved it as the "자막 표시" setting).
local function set_display(key)
    opts.display = key
    save_settings()
    if set_opt_soft("nanum-display", key) then return true end
    notify(input.core_tr("이 엔진 버전은 자막 표시 방식 전환을 지원하지 않습니다 (nanum 갱신 필요)"), 4, "error")
    return false
end

-- Apply changed full-mode settings; the engine restarts, so resync.
local function full_settings_changed()
    save_settings()
    local changed = apply_full_options()
    if engine_old then
        notify(input.core_tr("이 엔진 버전은 전체 번역을 지원하지 않습니다 (nanum 갱신 필요)"), 4, "error")
    elseif changed then
        resync()
        mp.add_timeout(1.0, function()
            if last_full_state ~= "done" then select_live() end
        end)
    end
end

local function ask_number(label, key)
    input.get({
        prompt = input.core_tr("%s (초):", label),
        default_text = tostring(opts[key]),
        submit = function(text)
            input.terminate()
            local n = tonumber(text)
            if n and n >= 0 then
                opts[key] = math.floor(n)
                save_settings()
            else
                notify(input.core_tr("숫자가 아닙니다: %s", text), 3, "warn")
            end
            reopen_menu()
        end,
    })
end

local function ask_text(e, standalone)
    input.get({
        prompt = input.core_tr("%s:", input.core_tr(e.label)),
        default_text = engine_vals[e.key] ~= "" and engine_vals[e.key]
            or mp.get_property("options/" .. e.opt) or "",
        submit = function(text)
            input.terminate()
            engine_vals[e.key] = text
            mp.set_property("options/" .. e.opt, text)
            save_settings()
            notify(input.core_tr("%s: 다음에 여는 파일부터 적용", input.core_tr(e.label)), 3, "ok")
            if not standalone then reopen_menu() end
        end,
    })
end

-- Text cut to n characters (UTF-8 aware); tail marks the cut.
local function ellipsize(s, n, tail)
    local out, count = {}, 0
    for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > n then return table.concat(out) .. (tail or "…") end
        out[count] = ch
    end
    return s
end

local function style_label()
    for _, s in ipairs(STYLES) do
        if s.key == opts.translate_style then
            if s.key == "custom" then return input.core_tr("직접 입력 — %s", ellipsize(opts.translate_style_text, 24)) end
            return input.core_tr(s.label)
        end
    end
    return opts.translate_style
end

-- Applies to the lines translated from now on (the player forwards it to the running engines).
local function set_style(key, text)
    opts.translate_style = key
    if text then opts.translate_style_text = text end
    save_settings()
    local ok = set_opt_soft("nanum-translate-style-text", opts.translate_style_text)
    ok = set_opt_soft("nanum-translate-style", key) and ok
    if ok then
        notify(input.core_tr("번역 말투: %s\n지금부터 번역되는 자막에 바로 적용됩니다 (이미 만든 자막은 그대로)", style_label()), 4, "ok")
    else
        notify(input.core_tr("이 엔진 버전은 번역 말투 선택을 지원하지 않습니다 (nanum 갱신 필요)"), 5, "error")
    end
end

local function ask_style_text()
    input.get({
        prompt = input.core_tr("번역 말투 지시문 (예: 아이에게 말하듯 다정하게):"),
        default_text = opts.translate_style_text,
        submit = function(text)
            input.terminate()
            text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
            if text == "" then
                notify(input.core_tr("지시문이 비어 있어 말투를 바꾸지 않았습니다"), 3, "warn")
            else
                set_style("custom", text)
            end
            reopen_menu()
        end,
    })
end

local function open_style_menu()
    local items, default = {}, 1
    for i, s in ipairs(STYLES) do
        items[i] = (s.key == opts.translate_style and "● " or "  ") .. input.core_tr(s.label)
        if s.key == opts.translate_style then default = i end
    end
    input.select({
        prompt = input.core_tr("번역 말투:"),
        items = items,
        default_item = default,
        submit = function(i)
            if STYLES[i].key == "custom" then
                mp.add_timeout(0.1, ask_style_text)
            else
                set_style(STYLES[i].key)
                reopen_menu()
            end
        end,
    })
end

-- Applies at once: the player starts / stops the secondary pipeline.
local function set_secondary(on)
    opts.secondary = on
    save_settings()
    if set_opt_soft("nanum-secondary", on and "yes" or "no") then
        notify(on and input.core_tr("원어 음성으로도 자막을 만듭니다 (기본 자막이 충분히 앞선 뒤에 작업 · 자막 메뉴에서 선택)")
            or input.core_tr("원어 음성 자막을 만들지 않습니다"), 4, "ok")
    else
        notify(input.core_tr("이 엔진 버전은 원어 음성 자막을 지원하지 않습니다 (nanum 갱신 필요)"), 5, "error")
    end
end

----------------------------------------------------------------------------
-- Glossary (characters / proper nouns of the film): edited as a text file
----------------------------------------------------------------------------


-- The lines the player should see: no BOM / CR, no comment or blank lines. -> text, count
local function glossary_clean(text)
    text = (text or ""):gsub("^\239\187\191", ""):gsub("\r\n?", "\n")
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then lines[#lines + 1] = line end
    end
    return table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""), #lines
end

local function sanitize_name(s)
    s = tostring(s or ""):gsub('[%c\\/:*?"<>|]', "_"):gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    s = ellipsize(s, 60, "")
    return s ~= "" and s or "glossary"
end

local function utf8_chars(s)
    local t = {}
    for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
    return t
end

-- Words of s (lower-cased unless keep_case).
local function word_list(s, keep_case)
    local w = {}
    for x in (keep_case and s or s:lower()):gmatch("%S+") do w[#w + 1] = x end
    return w
end

-- The words of `part` are a run of words inside `whole`, which has more words.
local function words_within(part, whole)
    local p, w = word_list(part), word_list(whole)
    if #p == 0 or #p >= #w then return false end
    for i = 0, #w - #p do
        local ok = true
        for j = 1, #p do
            if w[i + j] ~= p[j] then ok = false break end
        end
        if ok then return true end
    end
    return false
end

-- "원문 => 번역" -> src, tgt (nil unless both sides are non-empty and there is exactly one "=>")
local function glossary_entry_parse(text)
    local src, tgt = (text or ""):match("^%s*(.-)%s*=>%s*(.-)%s*$")
    if not src or src == "" or tgt == "" or tgt:find("=>", 1, true) then return nil end
    return src, tgt
end

-- Glossary text -> list of { src=, tgt= } in the published order (comments and malformed lines dropped).
local function glossary_parse(text)
    local list = {}
    for line in glossary_clean(text):gmatch("[^\n]+") do
        local src, tgt = glossary_entry_parse(line)
        if src then list[#list + 1] = { src = src, tgt = tgt } end
    end
    return list
end

local function glossary_format(list)
    local lines = {}
    for i, e in ipairs(list) do lines[i] = e.src .. " => " .. e.tgt end
    return table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
end

-- Entries of the same character as list[idx] that should follow when its translation becomes
-- new_tgt (the Korean form is changed in place):
--   * full-name entries that contain this name as a part, and the part entries of a full name;
--     a part is a run of whole words, or for CJK keys any substring of >= 2 characters;
--   * entries that share the old Korean value (other spellings / scripts of the same name), and
--     the full names / parts related to those.
-- -> { { index=, tgt= }, ... } in list order; { index=, manual=true } where the Korean part cannot be
-- located unambiguously, so the user has to edit that entry by hand.
local function glossary_related(list, idx, new_tgt)
    local e = list[idx]
    local old = e.tgt
    local a, b = utf8_chars(old), utf8_chars(new_tgt)
    local pre = 0
    while pre < #a and pre < #b and a[pre + 1] == b[pre + 1] do pre = pre + 1 end
    local suf = 0
    while suf < #a - pre and suf < #b - pre and a[#a - suf] == b[#b - suf] do suf = suf + 1 end

    local function count_of(s, sub)
        local n, pos = 0, 1
        while true do
            local f = s:find(sub, pos, true)
            if not f then return n end
            n, pos = n + 1, f + #sub
        end
    end
    local function has_cjk(s)
        for _, ch in ipairs(utf8_chars(s)) do
            if #ch == 3 then
                local cp = (ch:byte(1) % 16) * 4096 + (ch:byte(2) % 64) * 64 + (ch:byte(3) % 64)
                if (cp >= 0x3040 and cp <= 0x30FF) or (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0x4E00 and cp <= 0x9FFF)
                    or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFF66 and cp <= 0xFF9F) then
                    return true
                end
            end
        end
        return false
    end
    local function is_part(part, whole)
        if words_within(part, whole) then return true end
        return #whole > #part and #utf8_chars(part) >= 2 and has_cjk(part) and whole:find(part, 1, true) ~= nil
    end

    -- sources whose Korean form changes: the entry itself and the spellings sharing its old value
    local res, fixed = {}, { [idx] = true }
    local sources = { e.src }
    for i, o in ipairs(list) do
        if i ~= idx and o.tgt == old and not is_part(e.src, o.src) and not is_part(o.src, e.src) then
            fixed[i] = true
            res[i] = { index = i, tgt = new_tgt }
            sources[#sources + 1] = o.src
        end
    end
    local function put(i, r)
        local cur = res[i]
        if not cur or (cur.manual and not r.manual) then res[i] = r end
    end
    for _, src in ipairs(sources) do
        for i, o in ipairs(list) do
            if not fixed[i] then
                if is_part(src, o.src) then
                    -- `src` is a part of the full name o: its old Korean form is replaced inside o's
                    if count_of(o.tgt, old) == 1 then
                        local s, f = o.tgt:find(old, 1, true)
                        put(i, { index = i, tgt = o.tgt:sub(1, s - 1) .. new_tgt .. o.tgt:sub(f + 1) })
                    else
                        put(i, { index = i, manual = true })
                    end
                elseif is_part(o.src, src) then
                    -- o is a part of the full name `src`: same number of Korean words, the part's words
                    -- map one to one; else the changed characters decide whether the change lies inside it
                    local ow, nw, pw = word_list(old, true), word_list(new_tgt, true), word_list(o.tgt, true)
                    local at
                    for j = 0, #ow - #pw do
                        local same = #ow == #nw and #pw > 0
                        for m = 1, #pw do
                            if ow[j + m] ~= pw[m] then same = false break end
                        end
                        if same then at = j break end
                    end
                    local n = count_of(old, o.tgt)
                    local tgt
                    if at then
                        tgt = table.concat(nw, " ", at + 1, at + #pw)
                    elseif n == 1 then
                        local s = old:find(o.tgt, 1, true)
                        local oc = utf8_chars(o.tgt)
                        local from = #utf8_chars(old:sub(1, s - 1))
                        if from <= pre and #a - suf <= from + #oc then
                            tgt = table.concat(oc, "", 1, pre - from) .. table.concat(b, "", pre + 1, #b - suf)
                                .. table.concat(oc, "", #a - suf - from + 1, #oc)
                        end
                    end
                    if tgt and tgt ~= "" then
                        if tgt ~= o.tgt then put(i, { index = i, tgt = tgt }) end
                    elseif n > 1 then
                        put(i, { index = i, manual = true })
                    end
                end
            end
        end
    end
    local out = {}
    for i = 1, #list do
        if res[i] then out[#out + 1] = res[i] end
    end
    return out
end

-- Request for the player's glossary (regenerate | file:<path>); it is cleared again shortly after,
-- like nanum-library-action. false: the engine does not know the option.
local gloss_req_timer = nil
local function glossary_request(value)
    if gloss_req_timer then gloss_req_timer:kill() end
    local ok = set_opt_soft("nanum-glossary-request", value)
    gloss_req_timer = mp.add_timeout(0.3, function()
        gloss_req_timer = nil
        set_opt_soft("nanum-glossary-request", "")
    end)
    return ok
end

local gloss_edit = nil      -- { path=, applied=, mtime=, size=, started=, deadline=, timer=, dirty=, changed_at= }

function cancel_glossary_edit()
    if gloss_edit and gloss_edit.timer then gloss_edit.timer:kill() end
    gloss_edit = nil
end

local function glossary_unsupported()
    notify(input.core_tr("이 엔진 버전은 용어집을 지원하지 않습니다 (nanum 갱신 필요)"), 5, "error")
end

-- ~~/glossary (created on demand); nil with a message when that is impossible.
local function glossary_dir()
    local dir = mp.command_native({ "expand-path", "~~/glossary" })
    if type(dir) ~= "string" or dir == "" or dir:sub(1, 2) == "~~" then
        notify(input.core_tr("용어집 폴더를 만들 수 없습니다 (설정 폴더를 찾을 수 없음)"), 5, "error")
        return nil
    end
    dir = dir:gsub("/", "\\")
    if not require('mp.utils').file_info(dir) then
        mp.command_native({ name = "subprocess", args = { "cmd", "/c", "mkdir", dir }, playback_only = false })
    end
    return dir
end

-- The editable file of the current media and the cleaned copy that is sent to the player.
local function glossary_files(st, dir)
    local work = tostring(st["nanum-profile-work"] or "")
    local base = dir .. "\\" .. sanitize_name(work ~= "" and work or mp.get_property("media-title"))
    return base .. ".txt", base .. ".applied.txt"
end

-- The cache state when a file is playing and the player publishes a glossary, else nil (with a message).
local function glossary_state()
    local st = cache_state()
    if not (file_active and file_loaded) then
        notify(input.core_tr("영상을 재생한 뒤에 용어집을 사용할 수 있습니다"), 4, "warn")
    elseif not st or st["nanum-glossary"] == nil then
        glossary_unsupported()
    else
        return st
    end
    return nil
end

-- Writes the cleaned glossary to `out` and hands it to the player.
local function submit_glossary(clean, n, out)
    local w, err = io.open(out, "wb")
    if not w then
        notify(input.core_tr("용어집 적용 실패: %s", tostring(err)), 5, "error")
        return false
    end
    w:write(clean)
    w:close()
    if not glossary_request("file:" .. out) then
        glossary_unsupported()
        return false
    end
    notify(input.core_tr("용어집을 전달했습니다 (%d개) · 바뀐 이름이 들어간 자막은 다시 번역됩니다", n), 4, "ok", "glossary")
    return true
end

-- Sends the edited file (comments removed) to the player unless it equals what was sent last.
local function send_glossary(g)
    local f = io.open(g.path, "rb")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    local clean, n = glossary_clean(raw)
    if clean == g.applied then return end
    if submit_glossary(clean, n, g.out) then g.applied = clean end
end

local function glossary_tick(final)
    local g = gloss_edit
    if not g then return end
    local info = require('mp.utils').file_info(g.path)
    local now = mp.get_time()
    if info and (info.mtime ~= g.mtime or info.size ~= g.size) then
        g.mtime, g.size, g.changed_at, g.dirty = info.mtime, info.size, now, true
    end
    if final or (g.dirty and now - g.changed_at >= 1) then
        g.dirty = false
        send_glossary(g)
    end
    if final or now > g.deadline then cancel_glossary_edit() end
end

-- Writes the current glossary to ~~/glossary/<name>.txt and opens it in Notepad. Saved edits are
-- sent to the player while the editor is open and once more when it closes.
local function edit_glossary()
    local st = glossary_state()
    if not st then return end
    local utils = require 'mp.utils'
    local dir = glossary_dir()
    if not dir then return end
    local path, out = glossary_files(st, dir)
    local text = tostring(st["nanum-glossary"]):gsub("\r\n?", "\n")
    local content = input.core_tr("# NanumPlayer 용어집 — 이 영상의 인물·고유명사를 항상 같은 번역으로 옮기기 위한 표입니다.\n# 한 줄에 하나씩 '원문 => 번역' 형식으로 적습니다. 예)  Hikari => 히카리\n# 음성 인식이 잘못 받아적는 철자도 같은 번역으로 적어 두면 효과적입니다.\n# '#'으로 시작하는 줄과 빈 줄은 무시됩니다.\n# 저장하면 바로 적용되고, 메모장을 닫을 때 마지막으로 한 번 더 적용됩니다.") .. "\n\n" .. text .. (text ~= "" and text:sub(-1) ~= "\n" and "\n" or "")
    local f, err = io.open(path, "wb")
    if not f then
        notify(input.core_tr("용어집 파일을 만들 수 없습니다: %s", tostring(err)), 5, "error")
        return
    end
    f:write(content)
    f:close()
    cancel_glossary_edit()
    local info = utils.file_info(path) or {}
    local now = mp.get_time()
    local g = { path = path, out = out, applied = (glossary_clean(content)), mtime = info.mtime, size = info.size,
        started = now, deadline = now + 1800 }
    gloss_edit = g
    g.timer = mp.add_periodic_timer(1, function() glossary_tick(false) end)
    notify(input.core_tr("용어집을 메모장으로 엽니다 — 저장하면 적용됩니다\n%s", path), 6, "info", "glossary")
    mp.command_native_async({ name = "subprocess", args = { "notepad.exe", path }, playback_only = false },
        function()
            if gloss_edit ~= g then return end          -- replaced or the file changed meanwhile
            -- Notepad with tabs hands the file to a running window and exits at once: keep watching.
            if mp.get_time() - g.started >= 2 then glossary_tick(true) end
        end)
end

local function regenerate_glossary()
    if not (file_active and file_loaded) then
        notify(input.core_tr("영상을 재생한 뒤에 사용할 수 있습니다"), 4, "warn")
        return
    end
    if glossary_request("regenerate") then
        gloss_wait, gloss_pending = "requested", nil
        notify(input.core_tr("AI가 작품 정보와 용어집을 다시 만드는 중입니다 (시간이 걸릴 수 있습니다)"), 5, "busy", "glossary")
    else
        glossary_unsupported()
    end
end

-- n: number of entries shown (default: what the player published)
local function glossary_label(st, n)
    n = n or (st and st["nanum-glossary-count"])
    if type(n) ~= "number" then return input.core_tr("용어집: 영상을 재생하면 사용할 수 있습니다") end
    local s = input.core_tr("용어집 (%d개)", n)
    local work = tostring(st["nanum-profile-work"] or "")
    if st["nanum-profile-state"] == "running" then return input.core_tr("%s: AI가 작품 정보 조회 중", s) end
    return work ~= "" and input.core_tr("%s: %s", s, work) or s
end

local open_glossary_menu

-- The editor below lives in its own scope: the main chunk is close to Lua's limit of 200 locals.
do

local function reopen_glossary(focus_src)
    mp.add_timeout(0.1, function() open_glossary_menu(focus_src) end)
end

-- The list as shown: an edit the player has not published yet wins for a few seconds.
local function glossary_entries(st)
    local text = st["nanum-glossary"]
    if type(text) ~= "string" then return nil end
    local p = gloss_pending
    if p then
        if text == p.base and mp.get_time() < p.expires then return p.entries end
        gloss_pending = nil
    end
    return glossary_parse(text)
end

-- Sends the new list to the player; it retranslates the subtitle lines that use the changed names.
local function commit_glossary(list)
    local st = glossary_state()
    if not st then return false end
    local dir = glossary_dir()
    if not dir then return false end
    local _, out = glossary_files(st, dir)
    if not submit_glossary(glossary_format(list), #list, out) then return false end
    gloss_pending = { entries = list, base = tostring(st["nanum-glossary"]), expires = mp.get_time() + 10 }
    return true
end

local function copy_list(list)
    local n = {}
    for i, e in ipairs(list) do n[i] = e end
    return n
end

-- The current list and the position of the entry with this source (nil if it vanished).
local function find_entry(src)
    local st = cache_state()
    local list = st and glossary_entries(st)
    for i, e in ipairs(list or {}) do
        if e.src == src then return list, i end
    end
    return list, nil
end

-- Text prompt of the editor; Esc returns to the list (back_src: entry to focus there).
local function ask_glossary_text(prompt, default, back_src, cb)
    local submitted = false
    input.get({
        prompt = prompt,
        default_text = default or "",
        submit = function(text)
            submitted = true
            input.terminate()
            cb((text or ""):match("^%s*(.-)%s*$"))
        end,
        closed = function()
            if not submitted and not fluent.modal_busy() then reopen_glossary(back_src) end
        end,
    })
end

-- Offer to change the related entries of the same character too. apply(true|false); Esc cancels.
local function ask_related_update(list, rel, back_src, apply)
    local chosen, again = false, false
    local function show()
        local autos = 0
        for _, r in ipairs(rel) do
            if not r.manual then autos = autos + 1 end
        end
        local items = { input.core_tr("예 — 같은 인물의 관련 항목 %d개도 함께 수정", autos), input.core_tr("아니오 — 이 항목만 수정") }
        for _, r in ipairs(rel) do
            items[#items + 1] = "    " .. (r.manual
                and input.core_tr("%s: %s — 번역어 부분을 찾지 못해 직접 수정 필요", list[r.index].src, list[r.index].tgt)
                or (list[r.index].src .. ": " .. list[r.index].tgt .. " → " .. r.tgt))
        end
        input.select({
            prompt = input.core_tr("같은 인물의 다른 항목도 바꿀까요?"),
            items = items,
            submit = function(i)
                if i <= 2 then
                    chosen = true
                    apply(i == 1)
                else
                    again = true                -- a row that only shows a change: ask again
                    mp.add_timeout(0.1, function()
                        again = false
                        show()
                    end)
                end
            end,
            closed = function()
                if not chosen and not again and not fluent.modal_busy() then reopen_glossary(back_src) end
            end,
        })
    end
    show()
end

local function edit_glossary_target(src)
    local list, idx = find_entry(src)
    if not idx then return reopen_glossary() end
    local e = list[idx]
    ask_glossary_text(input.core_tr("'%s'의 번역:", e.src), e.tgt, e.src, function(text)
        if text == "" then
            notify(input.core_tr("번역이 비어 있어 바꾸지 않았습니다"), 3, "warn")
            return reopen_glossary(e.src)
        elseif text == e.tgt then
            return reopen_glossary(e.src)
        end
        local rel = glossary_related(list, idx, text)
        local function apply(with_related)
            local n = copy_list(list)
            n[idx] = { src = e.src, tgt = text }
            if with_related then
                for _, r in ipairs(rel) do
                    if not r.manual then n[r.index] = { src = list[r.index].src, tgt = r.tgt } end
                end
            end
            commit_glossary(n)
            reopen_glossary(e.src)
        end
        local autos, manual = 0, {}
        for _, r in ipairs(rel) do
            if r.manual then manual[#manual + 1] = list[r.index].src else autos = autos + 1 end
        end
        if autos == 0 then
            if #manual > 0 then
                notify(input.core_tr("번역어 부분을 자동으로 찾지 못한 관련 항목은 직접 수정하세요: %s", table.concat(manual, ", ")), 7, "warn", "glossary-edit")
            end
            return apply(false)
        end
        ask_related_update(list, rel, e.src, apply)
    end)
end

local function edit_glossary_source(src)
    local list, idx = find_entry(src)
    if not idx then return reopen_glossary() end
    local e = list[idx]
    ask_glossary_text(input.core_tr("원문 수정 ('%s'로 번역되는 원문):", e.tgt), e.src, e.src, function(text)
        if text == "" or text:find("=>", 1, true) then
            notify(input.core_tr("원문이 비어 있거나 '=>'가 들어 있어 바꾸지 않았습니다"), 4, "warn")
            return reopen_glossary(e.src)
        elseif text == e.src then
            return reopen_glossary(e.src)
        end
        for i, o in ipairs(list) do
            if i ~= idx and o.src:lower() == text:lower() then
                notify(input.core_tr("이미 있는 원문입니다: %s", o.src), 4, "warn")
                return reopen_glossary(e.src)
            end
        end
        local n = copy_list(list)
        n[idx] = { src = text, tgt = e.tgt }
        commit_glossary(n)
        reopen_glossary(text)
    end)
end

local function delete_glossary_entry(src)
    local list, idx = find_entry(src)
    if idx then
        local n = copy_list(list)
        table.remove(n, idx)
        if commit_glossary(n) then notify(input.core_tr("용어집에서 삭제했습니다: %s", src), 3, "ok", "glossary-edit") end
    end
    reopen_glossary()
end

local function add_glossary_entry()
    ask_glossary_text(input.core_tr("추가할 항목 (원문 => 번역):"), "", nil, function(text)
        local src, tgt = glossary_entry_parse(text)
        if not src then
            notify(input.core_tr("'원문 => 번역' 형식으로 입력하세요 (양쪽 모두 필요)"), 4, "warn")
            return reopen_glossary()
        end
        local st = cache_state()
        local n = copy_list(st and glossary_entries(st) or {})
        local at
        for i, o in ipairs(n) do
            if o.src:lower() == src:lower() then at = i end
        end
        if at then
            n[at] = { src = n[at].src, tgt = tgt }
            notify(input.core_tr("이미 있는 원문이라 번역만 바꿨습니다: %s", n[at].src), 4, "info", "glossary-edit")
        else
            n[#n + 1] = { src = src, tgt = tgt }
        end
        commit_glossary(n)
        reopen_glossary(at and n[at].src or src)
    end)
end

local function open_entry_menu(src)
    local list, idx = find_entry(src)
    if not idx then return reopen_glossary() end
    local chosen = false
    local function go(fn)
        chosen = true
        mp.add_timeout(0.1, fn)
    end
    input.select({
        prompt = list[idx].src .. " => " .. list[idx].tgt,
        items = { input.core_tr("번역 수정"), input.core_tr("원문 수정"), input.core_tr("삭제"), input.core_tr("목록으로 돌아가기") },
        submit = function(i)
            if i == 1 then go(function() edit_glossary_target(src) end)
            elseif i == 2 then go(function() edit_glossary_source(src) end)
            elseif i == 3 then go(function() delete_glossary_entry(src) end)
            else go(function() open_glossary_menu(src) end) end
        end,
        closed = function()
            if not chosen and not fluent.modal_busy() then reopen_glossary(src) end
        end,
    })
end

local GM = { actions = {}, timer = nil, seen = false, sig = nil }    -- rows of the open glossary menu

-- -> items, actions, keys, progress
local function glossary_menu_rows(st)
    local list = glossary_entries(st) or {}
    local items, actions, keys, progress = {}, {}, {}, {}
    local function add(key, text, fn)
        items[#items + 1] = text
        actions[#actions + 1] = fn
        keys[#keys + 1] = key
    end
    local nothing = function() end              -- information rows
    local ps = st["nanum-profile-state"]
    local info = original_text(st) or input.core_tr("AI가 식별한 작품 정보 없음")
    if ps == "running" then
        info = input.core_tr("AI가 작품 정보를 조회하는 중…")
    elseif ps == "error" then
        info = input.core_tr("AI 작품 정보 조회 실패 — 다시 만들기로 재시도할 수 있습니다")
    end
    add("label", glossary_label(st, #list), nothing)
    add("info", info, nothing)
    local ga = glossary_apply_text(st)
    if ga then
        add("apply", ga, nothing)
        if st["nanum-glossary-apply-state"] == "running" then
            progress.apply = math.max(0, math.min(1, tonumber(st["nanum-glossary-apply-progress"]) or 0))
        end
    end
    add("add", input.core_tr("항목 추가"), function() mp.add_timeout(0.1, add_glossary_entry) end)
    add("notepad", input.core_tr("메모장에서 한꺼번에 편집"), edit_glossary)
    add("regen", input.core_tr("AI로 다시 만들기 (직접 편집한 내용은 대체됩니다)"), function()
        local chosen = false
        input.select({
            prompt = input.core_tr("용어집을 AI로 다시 만들까요?"),
            items = { input.core_tr("다시 만들기"), input.core_tr("취소") },
            default_item = 2,
            submit = function(i)
                chosen = true
                if i == 1 then regenerate_glossary() end
                reopen_glossary()
            end,
            closed = function()
                if not chosen and not fluent.modal_busy() then reopen_glossary() end
            end,
        })
    end)
    add("back", input.core_tr("설정 메뉴로 돌아가기"), reopen_menu)
    for _, e in ipairs(list) do
        add("e:" .. e.src, e.src .. " => " .. e.tgt, function()
            mp.add_timeout(0.1, function() open_entry_menu(e.src) end)
        end)
    end
    return items, actions, keys, progress
end

-- Keeps the open glossary menu in step with the player (apply progress, republished list).
local function glossary_menu_tick()
    if fluent.open_id() ~= "nanum-glossary" then
        if GM.seen and GM.timer then
            GM.timer:kill()
            GM.timer = nil
        end
        return
    end
    GM.seen = true
    local st = cache_state()
    if not st then return end
    local items, actions, keys, progress = glossary_menu_rows(st)
    local sig = table.concat(items, "\n") .. "|" .. tostring(progress.apply)
    if sig == GM.sig then return end
    GM.sig, GM.actions = sig, actions
    fluent.update_select("nanum-glossary", items, { keys = keys, progress = progress })
end

function open_glossary_menu(focus_src)
    local st = glossary_state()
    if not st then return reopen_menu() end
    local items, actions, keys, progress = glossary_menu_rows(st)
    GM.actions, GM.seen, GM.sig = actions, false, nil
    local default = 1
    for i, k in ipairs(keys) do
        if k == (focus_src and ("e:" .. focus_src) or "add") then default = i end
    end
    if GM.timer then GM.timer:kill() end
    GM.timer = mp.add_periodic_timer(1, glossary_menu_tick)
    input.select({
        id = "nanum-glossary",
        prompt = input.core_tr("용어집:"),
        keep_open = true,
        items = items,
        keys = keys,
        progress = progress,
        default_item = default,
        submit = function(i)
            local fn = GM.actions[i]
            if fn then fn() end
        end,
    })
end
end

----------------------------------------------------------------------------
-- Online subtitles (OpenSubtitles / Jimaku) and subtitle files. The app only OPENS the search page in
-- the default browser; the user downloads by hand, the Downloads folder is watched for the new file,
-- and the file is handed to the player (`nanum-import-sub=<path>|<lang>|<origin>`), which aligns its
-- timing to the speech, translates it and publishes the track (nanum-track-import).
-- Disc image subtitles (PGS) are read by OCR in the player: only the nanum-pgs toggle lives here.
----------------------------------------------------------------------------

SUBS.EXT = { srt = true, ass = true, ssa = true, vtt = true, sub = true }       -- text subtitle files (zip is unpacked)
SUBS.SITES = {
    { site = "OpenSubtitles", label = "OpenSubtitles · 영어", lang = "en", code = "eng" },
    { site = "OpenSubtitles", label = "OpenSubtitles · 일본어", lang = "ja", code = "jpn" },
    { site = "OpenSubtitles", label = "OpenSubtitles · 한국어", lang = "ko", code = "kor" },
    { site = "Jimaku", label = "Jimaku · 일본어 (애니메이션)", lang = "ja" },
}
local TITLE_STOP = {
    ["480p"] = true, ["720p"] = true, ["1080p"] = true, ["2160p"] = true, ["4k"] = true, bluray = true, bdrip = true,
    brrip = true, ["web-dl"] = true, webrip = true, webdl = true, x264 = true, x265 = true, hevc = true, remux = true,
    dvdrip = true, hdtv = true, uhd = true, av1 = true,
}

function SUBS.reset()
    SUBS.cancel_watch(true)
    SUBS.import_prev, SUBS.ext_seen, SUBS.last_text = nil, nil, nil
    SUBS.server_down, SUBS.probe_at = false, nil
end

-- Percent-encoding of the UTF-8 bytes.
function SUBS.urlencode(s)
    return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- "[Group] Movie.Name.2010.1080p.BluRay.x264.mkv" -> "Movie Name"
function SUBS.clean_title(s)
    s = tostring(s or ""):gsub("%.[mM][kK][vV]$", ""):gsub("%.[mM][pP]4$", ""):gsub("%.[aA][vV][iI]$", "")
        :gsub("%.[mM]2[tT][sS]$", ""):gsub("%.[iI][sS][oO]$", "")
    s = s:gsub("%b[]", " "):gsub("[%._]", " ")
    local words = {}
    for w in s:gmatch("%S+") do
        local lw = w:lower()
        if TITLE_STOP[lw] or (#words > 0 and (lw:match("^%(?19%d%d%)?$") or lw:match("^%(?20%d%d%)?$"))) then break end
        words[#words + 1] = (w:gsub("[%(%)]", ""))
    end
    local r = table.concat(words, " ")
    return r ~= "" and r or (s:match("^%s*(.-)%s*$"))
end

-- Search text: typed by the user, else the work the AI identified, else the disc / file title.
function SUBS.query_text()
    if SUBS.query and SUBS.query ~= "" then return SUBS.query end
    local st = cache_state()
    local work = st and st["nanum-profile-work"]
    if type(work) == "string" and work ~= "" then return work end
    local disc = mp.get_property("disc-title")
    if type(disc) == "string" and disc ~= "" then return SUBS.clean_title(disc) end
    return SUBS.clean_title(mp.get_property("media-title"))
end

-- Jimaku's search box is filled in the page itself (no URL parameter): its home page is opened and the
-- query goes to the clipboard.
function SUBS.search_url(site, q)
    if site.site == "Jimaku" then return "https://jimaku.cc/" end
    return "https://www.opensubtitles.org/en/search/sublanguageid-" .. site.code .. "/moviename-" .. SUBS.urlencode(q)
end

-- Puts text on the Windows clipboard (mpv's clipboard property, else PowerShell). -> true if it is there.
function SUBS.copy_text(text)
    local ok = pcall(mp.set_property, "clipboard/text", text)
    if ok and mp.get_property("clipboard/text") == text then return true end
    local res = mp.command_native({ name = "subprocess", playback_only = false, args = {
        "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "Set-Clipboard -Value '" .. text:gsub("'", "''") .. "'" } })
    return res ~= nil and res.status == 0
end

function SUBS.open_url(url)
    mp.command_native_async({ name = "subprocess", args = { "explorer.exe", url }, playback_only = false, detach = true },
        function() end)
end

-- Request for the player (nanum-import-sub / nanum-import-adjust): the idle value first so that the same
-- value again still triggers, and again 0.3 s later like nanum-library-action ("" for text options,
-- "0" for the numeric nanum-import-adjust). false: the option is unknown.
function SUBS.request(name, value, idle)
    idle = idle or ""
    if SUBS.req_timers[name] then SUBS.req_timers[name]:kill() end
    set_opt_soft(name, idle)
    local ok = set_opt_soft(name, value)
    SUBS.req_timers[name] = mp.add_timeout(0.3, function()
        SUBS.req_timers[name] = nil
        set_opt_soft(name, idle)
    end)
    return ok
end

-- The Downloads folder: the one chosen in the menu, else the Windows known folder (it may be moved).
function SUBS.downloads_dir()
    if opts.downloads_dir ~= "" then return opts.downloads_dir end
    if not SUBS.dir_auto then
        local res = mp.command_native({ name = "subprocess", playback_only = false, capture_stdout = true, args = {
            "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
            "(New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path" } })
        local p = res and res.status == 0 and (res.stdout or ""):gsub("^\239\187\191", ""):match("^%s*(.-)%s*$") or ""
        SUBS.dir_auto = p ~= "" and p or ((os.getenv("USERPROFILE") or "") .. "\\Downloads")
    end
    return SUBS.dir_auto
end

function SUBS.cancel_watch(silent)
    local w = SUBS.watch
    if not w then return end
    w.timer:kill()
    SUBS.watch = nil
    if not silent then notify(input.core_tr("다운로드 감시를 중단했습니다"), 3, "info", "subs") end
end

-- Files of the watched folder that can be a subtitle, with their time stamps.
function SUBS.candidates(dir)
    local u, r = require 'mp.utils', {}
    for _, f in ipairs(u.readdir(dir, "files") or {}) do
        local ext = f:lower():match("%.(%w+)$")
        if ext and (SUBS.EXT[ext] or ext == "zip") then
            local info = u.file_info(dir .. "\\" .. f)
            if info then r[f] = info end
        end
    end
    return r
end

function SUBS.watch_tick()
    local w = SUBS.watch
    if not w then return end
    if mp.get_time() > w.deadline then
        SUBS.cancel_watch(true)
        notify(input.core_tr("20분 동안 새 자막 파일이 내려받아지지 않아 다운로드 감시를 끝냈습니다"), 6, "warn", "subs")
        return
    end
    local c = w.cand
    if c then
        local info = require('mp.utils').file_info(c.path)
        if not info then
            w.cand = nil
        elseif info.size > 0 and info.size == c.size then
            SUBS.cancel_watch(true)                 -- one download per request
            SUBS.handle(c.path, w.origin, w.lang)
        else
            c.size = info.size                      -- still being written
        end
        return
    end
    for f, info in pairs(SUBS.candidates(w.dir)) do
        if w.known[f] == nil or info.mtime > w.known[f] then
            w.cand = { path = w.dir .. "\\" .. f, size = info.size }
            return
        end
    end
end

-- Starts watching the Downloads folder for a NEW subtitle / zip file. false: no such folder.
function SUBS.begin_watch(origin, lang)
    SUBS.cancel_watch(true)
    local dir = SUBS.downloads_dir()
    local info = require('mp.utils').file_info(dir)
    if not (info and info.is_dir) then
        notify(input.core_tr("다운로드 폴더를 찾을 수 없습니다: %s\nCtrl+N → 온라인 자막 찾기에서 폴더를 지정하세요", dir), 7, "error", "subs")
        return false
    end
    local known = {}
    for f, i in pairs(SUBS.candidates(dir)) do known[f] = i.mtime end
    SUBS.watch = { dir = dir, known = known, origin = origin, lang = lang, deadline = mp.get_time() + 1200,
        timer = mp.add_periodic_timer(2, SUBS.watch_tick) }
    return true
end

function SUBS.start_search(site)
    if not (file_active and file_loaded) then
        notify(input.core_tr("영상을 재생한 뒤에 사용할 수 있습니다"), 4, "warn")
        return
    end
    local q = SUBS.query_text()
    if q == "" then
        notify(input.core_tr("검색어를 알 수 없습니다 — 메뉴의 '검색어'에서 직접 입력하세요"), 5, "warn")
        return
    end
    -- English is told to the player (Latin scripts are ambiguous); Japanese / Korean it detects from the characters
    if not SUBS.begin_watch(site.site, site.lang == "en" and "en" or "") then return end
    SUBS.open_url(SUBS.search_url(site, q))
    if site.site == "Jimaku" then
        local copied = SUBS.copy_text(q)
        notify(copied and input.core_tr("%s를 열었습니다 — 검색창에 붙여넣으세요 (Ctrl+V): %s\n(%s 폴더를 최대 20분 지켜봅니다 · 내려받으면 자동으로 가져옵니다)",
            input.core_tr(site.label), q, SUBS.watch.dir)
            or input.core_tr("%s를 열었습니다 — 검색창에 '%s'를 입력하세요\n(%s 폴더를 최대 20분 지켜봅니다 · 내려받으면 자동으로 가져옵니다)",
            input.core_tr(site.label), q, SUBS.watch.dir), 10, "busy", "subs")
        return
    end
    notify(input.core_tr("%s에서 '%s'를 찾는 중 — 브라우저에서 자막을 내려받으면 자동으로 가져옵니다\n(%s 폴더를 최대 20분 지켜봅니다)",
        input.core_tr(site.label), q, SUBS.watch.dir), 9, "busy", "subs")
end

-- Is the translation server answering? Asked once (at most every 30 s) when the player's first query failed, so that
-- the status chip can say why lines show their original text.
function SUBS.probe_server()
    if SUBS.probing or mp.get_time() - (SUBS.probe_at or -100) < 30 then return end
    local endpoint = get_opt("nanum-translate-endpoint") or ""
    if endpoint == "" then return end
    SUBS.probing, SUBS.probe_at = true, mp.get_time()
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "curl.exe", "-s", "--max-time", "3", (endpoint:gsub("/+$", "")) .. "/api/tags" } }, function(ok, res)
        SUBS.probing = false
        SUBS.server_down = not (ok and res and res.status == 0 and (res.stdout or "") ~= "")
        publish_status()
    end)
end

-- Hands a subtitle file to the player: show it as it is, or have the AI align and translate it.
function SUBS.send(path, origin, lang)
    if not (file_active and file_loaded) then
        notify(input.core_tr("영상을 재생한 뒤에 사용할 수 있습니다"), 4, "warn")
        return
    end
    if SUBS.ux then return SUBS.ux.import(path:gsub("/", "\\"), origin, lang) end
    SUBS.translate_import(path, origin, lang)
end

-- The AI path: the player aligns the file to the speech, translates it and publishes the track (nanum-track-import).
function SUBS.translate_import(path, origin, lang)
    if not (file_active and file_loaded) then
        notify(input.core_tr("영상을 재생한 뒤에 사용할 수 있습니다"), 4, "warn")
        return
    end
    path = path:gsub("/", "\\")
    SUBS.import_prev = nil
    local target = SUBS.ux and SUBS.ux.target().label or input.core_tr("한국어")
    if SUBS.request("nanum-import-sub", path .. "|" .. (lang or "") .. "|" .. origin) then
        notify(input.core_tr("자막을 가져옵니다: %s\n영상 음성에 시간을 맞춘 뒤 %s로 번역합니다", path:match("([^\\]*)$") or path, target), 6, "busy", "subs")
    else
        notify(input.core_tr("이 엔진 버전은 자막 가져오기를 지원하지 않습니다 (nanum 갱신 필요)"), 5, "error", "subs")
    end
end

function SUBS.clean_tmp()
    if SUBS.tmp then
        mp.command_native({ name = "subprocess", playback_only = false, args = { "cmd", "/c", "rmdir", "/s", "/q", SUBS.tmp } })
        SUBS.tmp = nil
    end
end

-- Subtitle files below dir (3 levels), sorted by path. -> { { path=, name=, size= }, ... }
function SUBS.find_subs(dir, depth, out)
    local u = require 'mp.utils'
    out = out or {}
    for _, f in ipairs(u.readdir(dir, "files") or {}) do
        local ext = f:lower():match("%.(%w+)$")
        if ext and SUBS.EXT[ext] then
            local info = u.file_info(dir .. "\\" .. f)
            out[#out + 1] = { path = dir .. "\\" .. f, name = f, size = info and info.size or 0 }
        end
    end
    if (depth or 0) < 3 then
        for _, d in ipairs(u.readdir(dir, "dirs") or {}) do SUBS.find_subs(dir .. "\\" .. d, (depth or 0) + 1, out) end
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

-- One file goes straight in; several (a season pack, several languages) are chosen from a list.
function SUBS.choose(files, origin, lang)
    if #files == 1 then return SUBS.send(files[1].path, origin, lang) end
    local items = {}
    for i, f in ipairs(files) do items[i] = string.format("%s  (%.0f KB)", f.name, f.size / 1024) end
    input.select({
        prompt = input.core_tr("자막 파일 선택 (%d개):", #files),
        items = items,
        submit = function(i) SUBS.send(files[i].path, origin, lang) end,
    })
end

function SUBS.handle(path, origin, lang)
    local ext = path:lower():match("%.(%w+)$")
    if ext ~= "zip" then return SUBS.send(path, origin, lang) end
    SUBS.clean_tmp()
    local base = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Windows\\Temp"
    local dir = string.format("%s\\NanumPlayer-subs-%d", base, os.time())
    mp.command_native({ name = "subprocess", playback_only = false, args = { "cmd", "/c", "mkdir", dir } })
    SUBS.tmp = dir
    notify(input.core_tr("내려받은 압축 파일을 풀고 있습니다: %s", path:match("([^\\/]*)$") or path), 5, "busy", "subs")
    local root = os.getenv("SystemRoot") or "C:\\Windows"
    local tar = require('mp.utils').file_info(root .. "\\System32\\tar.exe") and (root .. "\\System32\\tar.exe") or "tar.exe"
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stderr = true,
        args = { tar, "-xf", path, "-C", dir } }, function(ok, res)
        local files = SUBS.find_subs(dir)
        if #files == 0 then
            local why = (ok and res and res.status ~= 0) and "압축을 풀지 못했습니다: %s" or "압축 파일에 자막 파일이 없습니다: %s"
            notify(input.core_tr(why, path:match("([^\\/]*)$") or path), 6, "error", "subs")
            return
        end
        SUBS.choose(files, origin, lang)
    end)
end

-- Windows "Open" dialog (PowerShell) for a subtitle file or zip; the player's own pickers only load media.
function SUBS.pick_file()
    if not (file_active and file_loaded) then
        notify(input.core_tr("영상을 재생한 뒤에 사용할 수 있습니다"), 4, "warn")
        return
    end
    if package.config:sub(1, 1) ~= "\\" then return end
    local dir = SUBS.downloads_dir():gsub("'", "''")
    local script = table.concat({
        "Add-Type -AssemblyName System.Windows.Forms;",
        "[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false);",
        "$o=New-Object System.Windows.Forms.Form;$o.TopMost=$true;",
        "$d=New-Object System.Windows.Forms.OpenFileDialog;",
        "$d.Title='" .. input.core_tr("가져올 자막 파일 선택"):gsub("'", "''") .. "';",
        "$d.Filter='" .. input.core_tr("자막 파일 (srt, ass, ssa, vtt, sub, zip)|*.srt;*.ass;*.ssa;*.vtt;*.sub;*.zip|모든 파일|*.*"):gsub("'", "''") .. "';",
        "$d.InitialDirectory='" .. dir .. "';",
        "if($d.ShowDialog($o) -eq 'OK'){$d.FileName}",
    })
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-Command", script } }, function(ok, res)
        local p = ok and res and res.status == 0 and (res.stdout or ""):gsub("^\239\187\191", ""):match("^%s*(.-)%s*$") or ""
        if p ~= "" then SUBS.handle(p, "파일", "") end
    end)
end

-- Windows OCR language packs (capability "Language.OCR~~~<tag>~0.0.1.0") by ISO 639-1 code.
SUBS.OCR_PACKS = { en = "en-US", ja = "ja-JP", ko = "ko-KR", zh = "zh-CN", fr = "fr-FR", de = "de-DE", es = "es-ES", it = "it-IT",
    ru = "ru-RU", pt = "pt-BR" }

-- Command line that installs the pack: an elevated PowerShell (the user confirms the Windows UAC prompt).
function SUBS.ocr_install_args(lang)
    local tag = SUBS.OCR_PACKS[lang]
    if not tag then return nil end
    local inner = "Add-WindowsCapability -Online -Name Language.OCR~~~" .. tag .. "~0.0.1.0; cmd /c pause"
    return { "powershell.exe", "-NoProfile", "-Command",
        "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-Command','" .. inner .. "'" }
end

-- Only ever started from the explicit confirmation below.
function SUBS.run_elevated(args)
    mp.command_native_async({ name = "subprocess", playback_only = false, args = args }, function() end)
end

function SUBS.open_ocr_install(lang)
    local args = SUBS.ocr_install_args(lang)
    if not args then return reopen_menu() end
    input.select({
        prompt = input.core_tr("'%s' OCR 언어 팩을 설치할까요?", lang_name(lang) or lang),
        items = { input.core_tr("설치 (Windows가 관리자 권한을 묻습니다)"), input.core_tr("취소") },
        default_item = 2,
        submit = function(i)
            if i == 1 then
                SUBS.run_elevated(args)
                notify(input.core_tr("OCR 언어 팩 설치 창을 열었습니다 — 허용하면 설치가 진행되고, 다음에 여는 파일부터 적용됩니다"), 8, "busy", "subs")
            else
                reopen_menu()
            end
        end,
    })
end

function SUBS.set_pgs(on)
    opts.pgs = on
    save_settings()
    if set_opt_soft("nanum-pgs", on and "yes" or "no") then
        notify(on and input.core_tr("디스크 자막(이미지)을 문자 인식으로 읽어 자막을 만듭니다 (기본 자막이 앞선 뒤에 작업 · 자막 메뉴에서 선택)")
            or input.core_tr("디스크 자막 문자 인식을 끕니다"), 4, "ok")
    else
        notify(input.core_tr("이 엔진 버전은 디스크 자막 문자 인식을 지원하지 않습니다 (nanum 갱신 필요)"), 5, "error")
    end
end

-- Progress and result toasts of an import (state changes only; saved results found on opening stay quiet).
function SUBS.on_state(st)
    local s = st["nanum-import-state"]
    if s == nil then return end
    local prev = SUBS.import_prev
    SUBS.import_prev = s
    local now = mp.get_time()
    if s == "aligning" or s == "translating" then
        local text = SUBS.import_text(st)
        if prev ~= s or (text ~= SUBS.last_text and now - (SUBS.last_at or 0) >= 1.5) then
            SUBS.last_text, SUBS.last_at = text, now
            notify(text, 4, "busy", "subs")
        end
    elseif s == "done" and (prev == "aligning" or prev == "translating") then
        local msg = input.core_tr("가져온 자막이 준비되었습니다 — 자막 메뉴에서 선택하세요") .. SUBS.alignment_text(st)
        local low = st["nanum-import-low-confidence"] == true
        local note = tostring(st["nanum-import-note"] or "")
        if low then
            msg = msg .. "\n" .. input.core_tr("시간 맞춤을 확신할 수 없어 보정하지 않았습니다 — Ctrl+N → 가져온 자막 → 시간 미세 조정")
        elseif note ~= "" then
            msg = msg .. "\n" .. note
        end
        notify(msg, 8, low and "warn" or "ok", "subs")
    elseif s == "error" and prev ~= "error" then
        notify(SUBS.import_text(st), 8, "error", "subs")
    end
end

-- Offer to import an external subtitle file the user dropped onto the window.
function SUBS.baseline()
    SUBS.ext_seen = {}
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "sub" and t.external then SUBS.ext_seen[t.id] = true end
    end
end

function SUBS.on_tracks(tracks)
    local seen = SUBS.ext_seen
    if not (seen and file_loaded and tracks) then return end
    for _, t in ipairs(tracks) do
        if t.type == "sub" and t.external and not seen[t.id] then
            seen[t.id] = true
            local path = t["external-filename"]
            local ext = type(path) == "string" and path:lower():match("%.(%w+)$") or nil
            if ai_role(t) ~= "full" and ext and SUBS.EXT[ext] and mp.get_time() - loaded_at > 2.5 then
                queue_prompt("dropsub", function()
                    return {
                        prompt = input.core_tr("자막 파일을 추가했습니다: %s", path:match("([^\\/]*)$") or path),
                        items = { input.core_tr("그대로 외부 자막으로 사용"),
                            input.core_tr("AI로 시간 맞추고 %s로 번역", SUBS.ux and SUBS.ux.target().label or input.core_tr("한국어")) },
                        default_item = 1,
                        submit = function(i)
                            if i == 2 then SUBS.translate_import(path, "파일", "") end
                        end,
                    }
                end)
                pump_prompts()
            end
        end
    end
end

-- Search menu: site / language, the search text, the folder that is watched.
function SUBS.open_search_menu()
    local items, actions = {}, {}
    local function add(text, fn)
        items[#items + 1] = text
        actions[#actions + 1] = fn
    end
    local function again() mp.add_timeout(0.1, SUBS.open_search_menu) end
    local q = SUBS.query_text()
    for _, site in ipairs(SUBS.SITES) do
        add(input.core_tr("브라우저에서 찾기: %s", input.core_tr(site.label)), function() SUBS.start_search(site) end)
    end
    add(input.core_tr(SUBS.query and "검색어: %s [직접 입력] — 바꾸기" or "검색어: %s — 바꾸기", q ~= "" and q or input.core_tr("(없음)")), function()
        input.get({
            prompt = input.core_tr("검색어 (비우면 작품/파일 이름 사용):"),
            default_text = q,
            submit = function(text)
                input.terminate()
                SUBS.query = text:match("^%s*(.-)%s*$")
                if SUBS.query == "" then SUBS.query = nil end
                again()
            end,
        })
    end)
    local dir = SUBS.downloads_dir()
    add(input.core_tr(opts.downloads_dir ~= "" and "다운로드 폴더: %s [직접 지정] — 바꾸기" or "다운로드 폴더: %s [자동] — 바꾸기", dir), function()
        input.get({
            prompt = input.core_tr("자막을 내려받는 폴더 (비우면 Windows 다운로드 폴더):"),
            default_text = dir,
            submit = function(text)
                input.terminate()
                text = text:match("^%s*(.-)%s*$")
                local info = text ~= "" and require('mp.utils').file_info(text) or nil
                if text ~= "" and not (info and info.is_dir) then
                    notify(input.core_tr("폴더를 찾을 수 없습니다: %s", text), 4, "warn")
                else
                    opts.downloads_dir = text:gsub("[/\\]+$", "")
                    save_settings()
                    if SUBS.watch then SUBS.cancel_watch(true) end
                end
                again()
            end,
        })
    end)
    add(input.core_tr("자막 파일 직접 고르기…"), function() SUBS.pick_file() end)
    if SUBS.watch then
        add(input.core_tr("다운로드 기다리는 중 — 감시 중단"), function()
            SUBS.cancel_watch(false)
            again()
        end)
    end
    add(input.core_tr("설정 메뉴로 돌아가기"), reopen_menu)
    input.select({
        prompt = input.core_tr("온라인 자막 찾기 (브라우저에서 직접 내려받습니다):"),
        items = items,
        submit = function(i) actions[i]() end,
    })
end

-- Fine adjustment of the imported track's timing: stays open, the shown offset follows the player.
function SUBS.adjust_rows(st)
    local items, actions, keys = {}, {}, {}
    local function add(key, text, fn)
        items[#items + 1] = text
        actions[#actions + 1] = fn
        keys[#keys + 1] = key
    end
    local function nudge(delta)
        return function()
            if not SUBS.request("nanum-import-adjust", string.format("%.1f", delta), "0") then
                notify(input.core_tr("이 엔진 버전은 자막 시간 조정을 지원하지 않습니다 (nanum 갱신 필요)"), 5, "error")
            end
            if SUBS.adj_timer then SUBS.adj_timer:kill() end
            SUBS.adj_timer = mp.add_timeout(0.6, function() SUBS.adj_timer = nil; SUBS.adjust_tick(true) end)
        end
    end
    local off, conf = tonumber(st["nanum-import-offset"]), tonumber(st["nanum-import-confidence"])
    add("info", input.core_tr("현재 시간 보정: %s", off and input.core_tr("%+.1f초", off) or input.core_tr("알 수 없음"))
        .. (conf and input.core_tr(" · 자동 정렬 신뢰도 %d%%", math.floor(conf * 100 + 0.5)) or ""), function() end)
    add("p10", input.core_tr("자막 1초 늦추기 (+1.0)"), nudge(1))
    add("p01", input.core_tr("자막 0.1초 늦추기 (+0.1)"), nudge(0.1))
    add("m01", input.core_tr("자막 0.1초 앞당기기 (−0.1)"), nudge(-0.1))
    add("m10", input.core_tr("자막 1초 앞당기기 (−1.0)"), nudge(-1))
    add("back", input.core_tr("설정 메뉴로 돌아가기"), reopen_menu)
    return items, actions, keys
end

function SUBS.adjust_tick(force)
    if fluent.open_id() ~= "nanum-import-adjust" then return end
    local st = cache_state()
    if not st then return end
    local items, actions, keys = SUBS.adjust_rows(st)
    local sig = table.concat(items, "\n")
    if sig == SUBS.adj_sig and not force then return end
    SUBS.adj_sig, SUBS.adj_actions = sig, actions
    fluent.update_select("nanum-import-adjust", items, { keys = keys })
end

function SUBS.open_adjust_menu()
    local st = cache_state()
    refresh_ai_ids(st)
    if not (st and ai_ids.import and ai_track("import")) then
        notify(input.core_tr("가져온 자막이 없습니다 — Ctrl+N → 온라인 자막 찾기 / 자막 파일 가져오기"), 5, "warn")
        return reopen_menu()
    end
    local items, actions, keys = SUBS.adjust_rows(st)
    SUBS.adj_actions, SUBS.adj_sig = actions, table.concat(items, "\n")
    input.select({
        id = "nanum-import-adjust",
        prompt = input.core_tr("가져온 자막 시간 미세 조정:"),
        keep_open = true,
        items = items,
        keys = keys,
        default_item = 2,
        submit = function(i)
            local fn = SUBS.adj_actions[i]
            if fn then fn() end
        end,
    })
    if SUBS.adj_poll then SUBS.adj_poll:kill() end
    SUBS.adj_poll = mp.add_periodic_timer(1, function()
        if fluent.open_id() ~= "nanum-import-adjust" then
            SUBS.adj_poll:kill()
            SUBS.adj_poll = nil
            return
        end
        SUBS.adjust_tick(false)
    end)
end

mp.register_event("shutdown", function() SUBS.clean_tmp() end)

local function input_label()
    local st = cache_state()
    local active = st and st["nanum-input-active"]
    local m
    if sel_mode == "stt" then
        m = input.core_tr("음성 인식 (STT)")
    elseif sel_mode == "track" then
        m = input.core_tr("자막 트랙")
    else
        m = input.core_tr("자동")
    end
    if active then
        m = m .. " → " .. (active == "sub" and input.core_tr("자막") or "STT")
    end
    return m
end

local function open_input_menu()
    local items, actions = {}, {}
    local function add(text, fn)
        items[#items + 1] = text
        actions[#actions + 1] = fn
    end
    local function chosen()
        reevaluate(false)
        reopen_menu()
    end
    add((sel_mode == "auto" and "● " or "  ") .. input.core_tr("자동 (오디오 언어 자막, 없으면 STT)"), function()
        sel_mode = "auto"
        opts.input_mode = "auto"
        save_settings()
        chosen()
    end)
    add((sel_mode == "stt" and "● " or "  ") .. input.core_tr("음성 인식 (STT)"), function()
        sel_mode = "stt"
        opts.input_mode = "stt"
        save_settings()
        chosen()
    end)
    for _, t in ipairs(usable_subs(mp.get_property_native("track-list"))) do
        add((sel_mode == "track" and sel_track_id == t.id and "● " or "  ") .. input.core_tr("자막: %s", track_label(t)), function()
            sel_mode = "track"
            sel_track_id = t.id
            chosen()
        end)
    end
    input.select({
        prompt = input.core_tr("AI 자막 입력 소스:"),
        items = items,
        submit = function(i) actions[i]() end,
    })
end

-- `omp models --json` -> list of { selector, label }
local function parse_omp_models(text)
    local utils = require 'mp.utils'
    local data = utils.parse_json(text or "")
    local list = {}
    if type(data) == "table" and type(data.models) == "table" then
        for _, m in ipairs(data.models) do
            local sel = m.selector or (m.provider and m.id and (m.provider .. "/" .. m.id))
            if sel then
                local label = sel
                if m.name and m.name ~= "" and m.name ~= m.id then label = label .. "  " .. m.name end
                list[#list + 1] = { selector = sel, label = label }
            end
        end
    end
    return list
end

local fetching_omp = false
local function open_omp_picker()
    if fetching_omp then return end
    fetching_omp = true
    notify(input.core_tr("불러오는 중..."), 30, "busy", "omp-load")
    local args = { "omp", "models", "--json" }
    if package.config:sub(1, 1) == "\\" then
        args = { "cmd", "/c", "omp", "models", "--json" }      -- finds omp.cmd shims too
    end
    mp.command_native_async({
        name = "subprocess", args = args, capture_stdout = true, capture_stderr = true,
        playback_only = false,
    }, function(success, res)
        fetching_omp = false
        notify_clear("omp-load")
        local list = (success and res and res.status == 0) and parse_omp_models(res.stdout) or {}
        if #list == 0 then
            notify(input.core_tr("omp 모델 목록을 가져오지 못했습니다 (omp 설치/로그인 확인)"), 4, "error")
            reopen_menu()
            return
        end
        local items = {}
        for i, m in ipairs(list) do
            items[i] = ((m.selector == opts.omp_model) and "● " or "  ") .. m.label
        end
        input.select({
            prompt = input.core_tr("oh-my-pi 모델:"),
            items = items,
            submit = function(i)
                opts.omp_model = list[i].selector
                full_settings_changed()
                reopen_menu()
            end,
        })
    end)
end

-- Ollama /api/tags -> list of { name, label }: local models first, then cloud.
local function parse_ollama_models(text, current)
    local data = require('mp.utils').parse_json(text or "")
    local locals, clouds, seen = {}, {}, {}
    if type(data) ~= "table" or type(data.models) ~= "table" then return nil end
    for _, m in ipairs(data.models) do
        local name = m.name or m.model
        local caps = type(m.capabilities) == "table" and m.capabilities or nil
        local chat = not caps
        for _, c in ipairs(caps or {}) do
            if c == "completion" then chat = true end
        end
        if name and chat and not seen[name] then
            seen[name] = true
            local cloud = (m.remote_host or "") ~= ""
            local params = type(m.details) == "table" and m.details.parameter_size or ""
            local info = cloud and input.core_tr("클라우드")
                or input.core_tr("로컬 %.1f GB", (tonumber(m.size) or 0) / 1e9)
            if params ~= "" then info = info .. " · " .. params end
            local e = { name = name,
                        label = (name == current and "● " or "  ") .. name .. "   " .. info }
            table.insert(cloud and clouds or locals, e)
        end
    end
    local by_name = function(a, b) return a.name < b.name end
    table.sort(locals, by_name)
    table.sort(clouds, by_name)
    for _, e in ipairs(clouds) do locals[#locals + 1] = e end
    return locals
end

local fetching_ollama = false
local function open_ollama_picker(e, standalone)
    if fetching_ollama then return end
    local endpoint = mp.get_property("options/nanum-translate-endpoint") or ""
    if endpoint == "" then
        notify(input.core_tr("번역 서버 주소가 비어 있어 모델 목록을 가져올 수 없습니다"), 4, "warn")
        ask_text(e, standalone)
        return
    end
    fetching_ollama = true
    notify(input.core_tr("Ollama 모델 목록을 불러오는 중..."), 10, "busy", "ollama-load")
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { "curl.exe", "-s", "--max-time", "5", endpoint:gsub("/+$", "") .. "/api/tags" },
    }, function(success, res)
        fetching_ollama = false
        notify_clear("ollama-load")
        local current = mp.get_property("options/" .. e.opt) or ""
        local list = (success and res and res.status == 0) and parse_ollama_models(res.stdout, current)
        if not list then
            notify(input.core_tr("Ollama에 연결하지 못했습니다 (%s) — 모델 이름을 직접 입력하세요", endpoint), 5, "error")
            ask_text(e, standalone)
            return
        end
        local items, default = {}, nil
        for i, m in ipairs(list) do
            items[i] = m.label
            if m.name == current then default = i end
        end
        items[#items + 1] = input.core_tr("  직접 입력...")
        input.select({
            prompt = input.core_tr("번역 모델 (Ollama에 설치된 모델):"),
            items = items,
            default_item = default,
            submit = function(i)
                if i > #list then
                    mp.add_timeout(0.1, function() ask_text(e, standalone) end)
                    return
                end
                engine_vals[e.key] = list[i].name
                mp.set_property("options/" .. e.opt, list[i].name)
                save_settings()
                notify(input.core_tr("번역 모델: %s (다음에 여는 파일부터 적용)", list[i].name), 3, "ok")
                if not standalone then reopen_menu() end
            end,
        })
    end)
end

----------------------------------------------------------------------------
-- Interface preferences and the AI info tags above the playback bar (drawn by nanum-fluent.lua; this script
-- publishes user-data/nanum-ui/prefs and user-data/nanum-ui/tags for it).
----------------------------------------------------------------------------

local TAGS = { ps = nil, ps_at = -100, ps_busy = false, sig = nil, bar_vis = 0, endpoint = nil }

TAGS.BAR_HIDE = {
    { key = "short", label = "짧게 (1.2초)" },
    { key = "normal", label = "보통 (2초)" },
    { key = "long", label = "길게 (3초)" },
}

function TAGS.bar_hide_label()
    for _, b in ipairs(TAGS.BAR_HIDE) do
        if b.key == opts.bar_hide then return input.core_tr(b.label) end
    end
    return opts.bar_hide
end

function TAGS.publish_prefs()
    pcall(mp.set_property_native, "user-data/nanum-ui/prefs", { bar_hide = opts.bar_hide, ai_tags = opts.ai_tags })
end

-- Next auto-hide delay; applies at once.
function TAGS.cycle_bar_hide()
    for i, b in ipairs(TAGS.BAR_HIDE) do
        if b.key == opts.bar_hide then
            opts.bar_hide = TAGS.BAR_HIDE[i % #TAGS.BAR_HIDE + 1].key
            break
        end
    end
    save_settings()
    TAGS.publish_prefs()
    notify(input.core_tr("재생 바 자동 숨김: %s", TAGS.bar_hide_label()), 2, "ok")
end

function TAGS.set_ai_tags(on)
    opts.ai_tags = on
    save_settings()
    TAGS.publish_prefs()
    TAGS.update()
end

-- "ggml-large-v3-turbo-q5_0.bin" -> "large-v3-turbo"
function TAGS.model_short(path)
    local b = tostring(path or ""):match("([^/\\]*)$") or ""
    b = b:gsub("%.bin$", ""):gsub("^ggml%-", ""):gsub("%-q%d[%w_]*$", "")
    return b
end

-- "gemma4" and "gemma4:latest" are the same Ollama model.
local function model_key(n)
    return (tostring(n or ""):gsub(":latest$", ""))
end

-- Cloud model by name, or a server that is not this PC.
function TAGS.is_cloud(model, endpoint)
    local m = model:lower()
    if m:find(":cloud$") or m:find("%-cloud$") then return true end
    local hostport = endpoint:lower():match("^%a[%w+.-]*://([^/]+)") or endpoint:lower()
    local host = hostport:match("^%[([^%]]+)%]") or (hostport:gsub(":%d+$", ""))
    return not (host == "127.0.0.1" or host == "localhost" or host == "::1" or host == "0.0.0.0")
end

-- Where a local model runs, from Ollama's /api/ps: -> text, kind
function TAGS.where(model, endpoint)
    if TAGS.is_cloud(model, endpoint) then return input.core_tr("클라우드"), "info" end
    local entry
    for _, m in ipairs(TAGS.ps or {}) do
        if model_key(m.name or m.model) == model_key(model) then
            entry = m
            break
        end
    end
    if not entry then return input.core_tr("로컬"), "info" end            -- not loaded (yet)
    local size, vram = tonumber(entry.size) or 0, tonumber(entry.size_vram) or 0
    if size > 0 and vram >= size * 0.95 then return input.core_tr("로컬 GPU"), "ok" end
    if vram > 0 then return input.core_tr("로컬 GPU 일부"), "info" end
    return input.core_tr("로컬 CPU"), "warn"
end

function TAGS.poll(endpoint)
    if TAGS.ps_busy then return end
    TAGS.ps_busy = true
    TAGS.ps_at = mp.get_time()
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { "curl.exe", "-s", "--max-time", "3", (endpoint:gsub("/+$", "")) .. "/api/ps" } }, function(ok, res)
        TAGS.ps_busy = false
        local data = ok and res and res.status == 0 and require('mp.utils').parse_json(res.stdout or "") or nil
        TAGS.ps = (type(data) == "table" and type(data.models) == "table") and data.models or nil
        TAGS.update()
    end)
end

-- Language of the audio the speech recognition works on (like AIM.needed).
local function stt_language(tracks)
    local lang = get_opt("nanum-language")
    if lang and lang ~= "" and lang ~= "auto" then return norm_lang(lang) end
    return ai_audio_language(tracks)
end

function TAGS.stt_model(lang)
    local english = lang == "en"
    local s = TAGS.model_short(get_opt(english and "nanum-stt-model" or "nanum-stt-model-multilingual"))
    if s ~= "" then return s end
    if english then return "small.en" end
    local large = AIM.by_id("multilingual_large")
    return (large and large.installed == true) and "large-v3-turbo" or "small"
end

-- Tags of the selected AI subtitle track: { { text, kind = ok|info|warn, tip, action }, ... }
function TAGS.compute()
    if not (opts.ai_tags and file_active and file_loaded) or ai_disabled or not AIM.engine_enabled() then return {} end
    local st = cache_state()
    if not st then return {} end
    refresh_ai_ids(st)
    local tracks = mp.get_property_native("track-list") or {}
    local role
    for _, t in ipairs(tracks) do
        if t.type == "sub" and t.selected then
            role = ai_role(t)
            break
        end
    end
    if not role then return {} end
    local tags = {}
    local function add(text, kind, tip, action)
        tags[#tags + 1] = { text = text, kind = kind, tip = tip, action = action }
    end
    local active = st["nanum-input-active"]
    if role == "primary" and active == nil then active = resolve_choice(tracks).input end
    local stt = (role == "primary" and active ~= "sub") or role == "secondary"

    -- 1: where the speech recognition runs
    local backend = st["nanum-ai-backend"]
    if stt and (backend == "cuda" or backend == "cpu") then
        if backend == "cuda" then
            add(input.core_tr("음성 인식 · GPU"), "ok", input.core_tr("음성 인식을 GPU(CUDA)로 처리하고 있습니다 — 눌러서 AI 구성 요소 관리"), "nanum-models")
        elseif (AIM.file_mode or AIM.mode()) ~= "cpu" and AIM.has_driver() then
            add(input.core_tr("음성 인식 · CPU ⚠"), "warn", input.core_tr("GPU를 쓸 수 있는 PC인데 CPU로 인식 중입니다 — 눌러서 원인 확인"), "nanum-models")
        else
            add(input.core_tr("음성 인식 · CPU"), "info", input.core_tr("음성 인식을 CPU로 처리하고 있습니다 — 눌러서 AI 구성 요소 관리"), "nanum-models")
        end
    end

    -- 2: what the AI subtitles are made from
    if role == "primary" and not stt then
        add(input.core_tr("자막 기반"), "info", input.core_tr("영상의 자막 트랙을 번역한 자막입니다 — 눌러서 AI 구성 요소 관리"), "nanum-models")
    elseif role == "primary" or role == "secondary" then
        local lang = role == "secondary" and norm_lang(st["nanum-secondary-language"]) or stt_language(tracks)
        local m = TAGS.stt_model(lang)
        add(m, "info", input.core_tr("음성 인식 모델: %s — 눌러서 AI 구성 요소 관리", m), "nanum-models")
    elseif role == "pgs" then
        add(input.core_tr("디스크 자막 OCR"), "info", input.core_tr("디스크의 그림 자막을 문자 인식한 자막입니다"), "nanum-models")
    elseif role == "import" then
        local origin = tostring(st["nanum-import-origin"] or "")
        add(origin ~= "" and input.core_tr(origin) or input.core_tr("가져온 자막"), "info", input.core_tr("직접 가져온 자막 파일입니다"), "nanum-models")
    elseif role == "full" then
        add(input.core_tr("전체 번역"), "info", input.core_tr("영상 전체를 미리 번역한 자막입니다"), "nanum-models")
    end

    -- 3: the translation model and where it runs
    local endpoint = get_opt("nanum-translate-endpoint") or ""
    TAGS.endpoint = nil
    if role == "import" and tostring(st["nanum-import-language"] or "") == "ko" then
        return tags                                  -- a Korean file needs no translation
    elseif endpoint == "" then
        add(input.core_tr("번역 끔"), "info", input.core_tr("번역 서버 주소가 비어 있어 번역하지 않습니다"), "nanum-ollama-models")
    elseif role == "full" and opts.full_engine == "omp" then
        local m = opts.omp_model ~= "" and opts.omp_model or "omp"
        add(input.core_tr("번역 · %s · %s", ellipsize(m, 30), input.core_tr("클라우드")), "info", input.core_tr("전체 번역 모델(oh-my-pi): %s", m), "nanum-ollama-models")
    else
        local model = get_opt("nanum-translate-model") or ""
        local where, kind = TAGS.where(model, endpoint)
        if not TAGS.is_cloud(model, endpoint) then TAGS.endpoint = endpoint end
        add(input.core_tr("번역 · %s · %s", ellipsize(model, 30), where), kind, input.core_tr("번역 모델: %s — 눌러서 모델 바꾸기", model), "nanum-ollama-models")
    end
    return tags
end

function TAGS.update()
    local tags = TAGS.compute()
    local sig = ""
    for _, t in ipairs(tags) do sig = sig .. t.text .. "|" .. t.kind .. "|" .. t.tip .. "\n" end
    if sig == TAGS.sig then return end
    TAGS.sig = sig
    pcall(mp.set_property_native, "user-data/nanum-ui/tags", tags)
end

-- Every second; /api/ps is asked only while the bar is shown, at most every 10 s.
function TAGS.tick()
    TAGS.update()
    if TAGS.endpoint and TAGS.bar_vis >= 0.5 and not TAGS.ps_busy and mp.get_time() - TAGS.ps_at >= 10 then
        TAGS.poll(TAGS.endpoint)
    end
end

TAGS.publish_prefs()
mp.add_periodic_timer(1, TAGS.tick)
mp.observe_property("sid", "native", function() TAGS.update() end)
mp.observe_property("user-data/fluent/bar-vis", "native", function(_, v) TAGS.bar_vis = tonumber(v) or 0 end)
mp.add_key_binding(nil, "nanum-ollama-models", function()
    for _, e in ipairs(ENGINE) do
        if e.key == "translate_model" then open_ollama_picker(e, true) end
    end
end)


local SM = { actions = {}, keys = {} }      -- rows of the open settings menu (replaced by live updates)

-- Interface language (the display language only: the AI source / target languages are separate options).
-- The native player owns the saved choice: `nanum-ui-language <auto|code>` stores it and publishes
-- user-data/nanum/ui-language (resolved code) and user-data/nanum/ui-language-mode (chosen value).
-- Language names stay in their own language (i18n-ignore); only "automatic" is translated.
SM.LANGUAGES = {
    { code = "auto" },
    { code = "ko", label = "한국어" }, -- i18n-ignore
    { code = "en", label = "English" },
    { code = "ja", label = "日本語" }, -- i18n-ignore
    { code = "zh-CN", label = "简体中文" }, -- i18n-ignore
    { code = "zh-TW", label = "繁體中文" }, -- i18n-ignore
    { code = "es", label = "Español" },
}

function SM.language_mode()
    local mode = mp.get_property_native("user-data/nanum/ui-language-mode")
    return (type(mode) == "string" and mode ~= "") and mode or "auto"
end

function SM.language_label(code)
    if code == "auto" then return input.core_tr("자동 (Windows 언어)") end
    for _, l in ipairs(SM.LANGUAGES) do
        if l.code == code then return l.label end
    end
    return tostring(code)
end

-- "Automatic — English" while following Windows, else the language's own name.
function SM.language_summary()
    local mode = SM.language_mode()
    if mode == "auto" then
        return input.core_tr("자동 — %s", SM.language_label(input.i18n.language()))
    end
    return SM.language_label(mode)
end

-- from_menu: opened from the settings menu, which comes back in the new language.
function SM.open_language_menu(from_menu)
    local mode = SM.language_mode()
    local items, default = {}, 1
    for i, l in ipairs(SM.LANGUAGES) do
        items[i] = (l.code == mode and "● " or "  ") .. SM.language_label(l.code)
        if l.code == mode then default = i end
    end
    input.select({
        prompt = input.core_tr("인터페이스 언어:"),
        items = items,
        default_item = default,
        submit = function(i)
            local code = SM.LANGUAGES[i].code
            if code ~= mode and not mp.commandv("nanum-ui-language", code) then
                -- the player applies the language for this session even when saving failed and says why
                local why = mp.get_property_native("user-data/nanum/ui-language-error")
                if type(why) == "string" and why ~= "" then
                    notify(why, 6, "warn")
                else
                    notify(input.core_tr("이 엔진 버전은 인터페이스 언어 선택을 지원하지 않습니다 (nanum 갱신 필요)"), 5, "error")
                end
            end
            if from_menu then
                menu_keep = true
                menu_last_key = "language"
                mp.add_timeout(0.3, open_menu)
            end
        end,
    })
end

----------------------------------------------------------------------------
-- Video upscale (scripts/nanum-upscale.lua controller). Only user-chosen shader files are used; none are bundled.
----------------------------------------------------------------------------
local UPS = { MODES = { "default", "quality", "rtx", "shader" }, SCALES = { "auto", "1.5", "2", "3" } }

function UPS.state()
    local st
    if UPS.ctl then
        local ok, r = pcall(UPS.ctl.get_state)
        if ok and type(r) == "table" then st = r end
    end
    st = st or UPS.last or { mode = "default", scale = "auto", shaders = {}, status = "default", detail = "" }
    st.shaders = type(st.shaders) == "table" and st.shaders or {}
    return st
end

function UPS.mode_label(m)
    if m == "quality" then return input.core_tr("고품질 크기 조정") end
    if m == "shader" then return input.core_tr("사용자 셰이더") end
    return input.core_tr("기본")
end

function UPS.scale_label(s)
    if s == "auto" then return input.core_tr("자동") end
    return tostring(s) .. "x"
end

function UPS.status_text(st)
    local s, d = st.status, tostring(st.detail or "")
    local t
    if s == "waiting" then t = input.core_tr("대기 중 — 영상이 재생되면 적용합니다")
    elseif s == "quality" then t = input.core_tr("고품질 크기 조정 적용 중")
    elseif s == "rtx_requested" then
        t = input.core_tr("RTX %sx 요청됨 — AI 처리 여부는 드라이버에서 확인", string.format("%g", st.factor or 1))
    elseif s == "shader" then t = input.core_tr("사용자 셰이더 %d개 적용 중", #st.shaders)
    elseif s == "not_needed" then t = input.core_tr("필요 없음 — 영상이 이미 화면 크기 이상입니다")
    elseif s == "error" then t = input.core_tr("오류")
    else t = input.core_tr("기본 — 추가 업스케일 없음") end
    if d ~= "" then t = t .. " (" .. d .. ")" end
    return t
end

function UPS.summary()
    local st = UPS.state()
    local t = st.mode == "rtx" and input.core_tr("RTX %s", UPS.scale_label(st.scale)) or UPS.mode_label(st.mode)
    if st.status == "error" then t = t .. " · " .. input.core_tr("오류") end
    return t
end

-- Run a controller setter; failures go to notify with the raw detail.
function UPS.call(name, arg)
    if not UPS.ctl then
        notify(input.core_tr("업스케일 도우미(scripts/nanum-upscale.lua)를 불러오지 못했습니다"), 6, "error")
        return false
    end
    local ok, a, b = pcall(UPS.ctl[name], arg)
    if ok and a == true then return true end
    notify(input.core_tr("영상 업스케일 설정 실패: %s", tostring(ok and b or a)), 6, "error")
    return false
end

-- The unified picture menu (PIC.open) shows the state: a change of the upscale controller refreshes it.
function UPS.refresh()
    if UPS.refresh_ui then UPS.refresh_ui() end
end

function UPS.base(p) return tostring(p):match("([^/\\]+)$") or tostring(p) end

function UPS.set_list(list, reopen_at)
    UPS.call("set_shaders", list)
    mp.add_timeout(0.1, function() UPS.open_shaders(reopen_at) end)
end

function UPS.copy_list()
    local out = {}
    for i, p in ipairs(UPS.state().shaders) do out[i] = p end
    return out
end

-- Windows "Open" dialog (PowerShell) for one shader file; files are appended in the order they are picked.
function UPS.pick_shader()
    if package.config:sub(1, 1) ~= "\\" then return end
    local script = table.concat({
        "Add-Type -AssemblyName System.Windows.Forms;",
        "[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false);",
        "$o=New-Object System.Windows.Forms.Form;$o.TopMost=$true;",
        "$d=New-Object System.Windows.Forms.OpenFileDialog;",
        "$d.Title='" .. input.core_tr("추가할 셰이더 파일 선택"):gsub("'", "''") .. "';",
        "$d.Filter='" .. input.core_tr("셰이더 파일 (glsl, hook, frag)|*.glsl;*.hook;*.frag|모든 파일|*.*"):gsub("'", "''") .. "';",
        "if($d.ShowDialog($o) -eq 'OK'){$d.FileName}",
    })
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-Command", script } }, function(ok, res)
        local p = ok and res and res.status == 0 and (res.stdout or ""):gsub("^\239\187\191", ""):match("^%s*(.-)%s*$") or ""
        if p == "" then
            mp.add_timeout(0.1, function() UPS.open_shaders() end)
            return
        end
        local list = UPS.copy_list()
        for _, q in ipairs(list) do
            if q:lower() == p:lower() then
                notify(input.core_tr("이미 목록에 있는 셰이더입니다: %s", UPS.base(p)), 4, "warn")
                mp.add_timeout(0.1, function() UPS.open_shaders() end)
                return
            end
        end
        list[#list + 1] = p
        UPS.set_list(list, #list)
    end)
end

function UPS.open_shaders(at)
    local list = UPS.state().shaders
    local items = {}
    for i, p in ipairs(list) do
        items[#items + 1] = string.format("%d. %s", i, UPS.base(p))
    end
    local n = #items
    items[#items + 1] = input.core_tr("+ 셰이더 파일 추가… (고른 순서대로 적용)")
    items[#items + 1] = input.core_tr("목록 모두 비우기")
    items[#items + 1] = input.core_tr("← 영상 화질로 돌아가기")
    input.select({
        prompt = input.core_tr("사용자 셰이더 (위에서부터 순서대로 적용):"),
        items = items,
        default_item = at or (n + 1),
        submit = function(i)
            if i <= n then
                mp.add_timeout(0.1, function() UPS.open_shader_item(i) end)
            elseif i == n + 1 then
                UPS.pick_shader()
            elseif i == n + 2 then
                if n > 0 then UPS.set_list({}) else UPS.open_shaders() end
            else
                mp.add_timeout(0.1, UPS.open)
            end
        end,
    })
end

function UPS.open_shader_item(i)
    local list = UPS.copy_list()
    if not list[i] then return UPS.open_shaders() end
    input.select({
        prompt = UPS.base(list[i]),
        items = { input.core_tr("위로 이동"), input.core_tr("아래로 이동"), input.core_tr("목록에서 제거"), input.core_tr("← 뒤로") },
        submit = function(k)
            if k == 1 and i > 1 then
                list[i], list[i - 1] = list[i - 1], list[i]
                UPS.set_list(list, i - 1)
            elseif k == 2 and i < #list then
                list[i], list[i + 1] = list[i + 1], list[i]
                UPS.set_list(list, i + 1)
            elseif k == 3 then
                table.remove(list, i)
                UPS.set_list(list, math.max(1, math.min(i, #list)))
            else
                mp.add_timeout(0.1, function() UPS.open_shaders(i) end)
            end
        end,
    })
end

do
    local factory = load_helper("nanum-upscale.lua", "function")
    if factory then
        local ok, ctl = pcall(factory, { changed = function(st)
            if type(st) == "table" then UPS.last = st end
            UPS.refresh()
        end })
        if ok and type(ctl) == "table" then
            UPS.ctl = ctl
        else
            mp.msg.error("nanum-upscale.lua: " .. tostring(ctl))
        end
    end
end

----------------------------------------------------------------------------
-- Video picture correction (scripts/nanum-picture.lua controller). Built-in lightweight filters; no model files.
----------------------------------------------------------------------------
local PIC = {
    PRESETS = { "original", "anime", "oldanime", "compressed" },
    FILTERS = { "denoise", "deband", "lines", "sharpen", "color" },
}

function PIC.state()
    local st
    if PIC.ctl then
        local ok, r = pcall(PIC.ctl.get_state)
        if ok and type(r) == "table" then st = r end
    end
    return st or PIC.last or { preset = "original", denoise = 0, deband = 0, lines = 0, sharpen = 0, color = 0,
        comparing = false, rtx = false, status = "original", detail = "" }
end

function PIC.preset_label(p)
    if p == "anime" then return input.core_tr("애니 선명하게") end
    if p == "oldanime" then return input.core_tr("옛날 애니 부드럽게") end
    if p == "compressed" then return input.core_tr("압축 영상 보정") end
    if p == "custom" then return input.core_tr("사용자 지정") end
    return input.core_tr("원본")
end

function PIC.filter_label(f)
    if f == "denoise" then return input.core_tr("노이즈 줄이기") end
    if f == "deband" then return input.core_tr("색 띠 완화") end
    if f == "lines" then return input.core_tr("선 강조") end
    if f == "sharpen" then return input.core_tr("선명도") end
    return input.core_tr("색 보정")
end

function PIC.level_label(n)
    n = tonumber(n) or 0
    if n <= 0 then return input.core_tr("끔") end
    if n == 1 then return input.core_tr("약함") end
    if n == 2 then return input.core_tr("중간") end
    return input.core_tr("강함")
end

function PIC.suppressed(st, f)
    return st.rtx and (f == "lines" or f == "sharpen") and (tonumber(st[f]) or 0) > 0
end

function PIC.status_text(st)
    local s, d = st.status, tostring(st.detail or "")
    local t
    if s == "comparing" then t = input.core_tr("보정 전 화면 비교 중 (임시)")
    elseif s == "active" then t = input.core_tr("영상 화질 보정 적용 중")
    elseif s == "waiting" then t = input.core_tr("대기 중 — 영상이 재생되면 적용합니다")
    elseif s == "error" then t = input.core_tr("오류")
    else t = input.core_tr("원본") end
    if d ~= "" then t = t .. " (" .. d .. ")" end
    return t
end

-- What is switched on, for the settings row, the bar tooltip and the bar dot ("기본" when nothing is).
function PIC.parts()
    local u, p = UPS.state(), PIC.state()
    local parts = {}
    if u.mode ~= "default" then parts[#parts + 1] = UPS.summary() end
    if p.preset ~= "original" then
        parts[#parts + 1] = PIC.preset_label(p.preset) .. (p.status == "error" and (" · " .. input.core_tr("오류")) or "")
    end
    return parts, (u.status == "error" or p.status == "error")
end

function PIC.summary()
    local parts = PIC.parts()
    return #parts > 0 and table.concat(parts, " · ") or input.core_tr("기본")
end

-- user-data/nanum-ui/picture for the picture button of the playback bar (scripts/nanum-fluent.lua).
function PIC.publish()
    local parts, err = PIC.parts()
    pcall(mp.set_property_native, "user-data/nanum-ui/picture", { tip = table.concat(parts, " · "), on = #parts > 0, err = err })
end

function PIC.call(name, arg)
    if not PIC.ctl then
        notify(input.core_tr("영상 화질 도우미(scripts/nanum-picture.lua)를 불러오지 못했습니다"), 6, "error")
        return false
    end
    local ok, a, b = pcall(PIC.ctl[name], arg)
    if ok and a == true then return true end
    notify(input.core_tr("영상 화질 설정 실패: %s", tostring(ok and b or a)), 6, "error")
    return false
end

-- One quick menu for both features: upscale choices and picture presets (picture button of the bar, Ctrl+I,
-- the Ctrl+N row). It stays open after a choice and is refreshed from the controllers' state.
PIC.CHOICES = {
    { mode = "default" }, { mode = "quality" },
    { mode = "rtx", scale = "auto" }, { mode = "rtx", scale = "1.5" }, { mode = "rtx", scale = "2" }, { mode = "rtx", scale = "3" },
    { mode = "shader" },
}

function PIC.choice_label(c)
    if c.mode == "rtx" then return input.core_tr("RTX %s", UPS.scale_label(c.scale)) end
    return UPS.mode_label(c.mode)
end

function PIC.choice_current(c, st)
    if st.mode ~= c.mode then return false end
    if c.mode ~= "rtx" then return true end
    return tostring(st.scale) == c.scale or (tonumber(st.scale) ~= nil and tonumber(st.scale) == tonumber(c.scale))
end

function PIC.pick_upscale(c)
    local st = UPS.state()
    if c.mode == "rtx" then
        -- the factor first: the mode switch then applies it once
        if UPS.call("set_scale", c.scale) and st.mode ~= "rtx" then UPS.call("set_mode", "rtx") end
    else
        UPS.call("set_mode", c.mode)
    end
end

function PIC.status_line()
    local u, p = UPS.state(), PIC.state()
    if u.status == "error" then return UPS.status_text(u) end
    if p.status == "error" then return PIC.status_text(p) end
    if u.mode ~= "default" then return UPS.status_text(u) end
    return PIC.status_text(p)
end

function PIC.build()
    local ust, st = UPS.state(), PIC.state()
    local items, acts, keys = {}, {}, {}
    local default = 2
    local function add(key, text, fn, mark)
        items[#items + 1] = (mark and "● " or "  ") .. text
        acts[#acts + 1] = fn or function() end
        keys[#keys + 1] = key
    end
    add("status", input.core_tr("상태: %s", PIC.status_line()))
    add("h_up", input.core_tr("업스케일: %s", UPS.summary()))
    for i, c in ipairs(PIC.CHOICES) do
        local cur = PIC.choice_current(c, ust)
        if cur then default = #items + 1 end
        add("up" .. i, PIC.choice_label(c), function() PIC.pick_upscale(c) end, cur)
    end
    add("h_pic", input.core_tr("보정: %s", PIC.preset_label(st.preset)))
    for _, p in ipairs(PIC.PRESETS) do
        add("p_" .. p, PIC.preset_label(p), function() PIC.call("set_preset", p) end, st.preset == p)
    end
    if st.preset == "custom" then add("p_custom", PIC.preset_label("custom"), nil, true) end
    add("compare", input.core_tr("보정 전 화면 비교 (임시): %s", input.core_tr(st.comparing and "켬" or "끔")), function()
        PIC.call("set_compare", not PIC.state().comparing)
    end)
    if st.comparing then add("note_compare", input.core_tr("비교 중에도 업스케일 유지 · 비교 상태는 저장 안 함")) end
    if ust.mode == "rtx" then add("note_rtx_gpu", input.core_tr("RTX — NVIDIA GPU와 드라이버 VSR 필요")) end
    if st.rtx then add("note_rtx", input.core_tr("RTX 사용 중 — 선 강조·선명도 일시 중지")) end
    if ust.mode == "shader" then add("note_shader", input.core_tr("사용자 셰이더 — 선명화 중복 적용 주의")) end
    add("detail", input.core_tr("세부 설정…"), function() mp.add_timeout(0.1, PIC.open_detail) end)
    if PIC.from_settings then add("back", input.core_tr("← 설정으로 돌아가기"), function() reopen_menu() end) end
    return items, acts, keys, default
end

function PIC.refresh()
    if PIC.refresh_pending then return end
    PIC.refresh_pending = true
    mp.add_timeout(0.05, function()
        PIC.refresh_pending = false
        PIC.publish()
        local id = fluent.open_id()
        if id == "nanum-picture" then
            local items, acts, keys = PIC.build()
            PIC.acts = acts
            fluent.update_select("nanum-picture", items, { keys = keys })
        elseif id == "nanum-picture-detail" then
            local items, acts, keys = PIC.build_detail()
            PIC.detail_acts = acts
            fluent.update_select("nanum-picture-detail", items, { keys = keys })
        elseif id == "nanum-settings" and UPS.refresh_settings then
            UPS.refresh_settings()
        end
    end)
end

function PIC.open(anchor, from_settings)
    PIC.anchor, PIC.from_settings = anchor, from_settings
    local items, acts, keys, default = PIC.build()
    PIC.acts = acts
    input.select({
        id = "nanum-picture",
        prompt = input.core_tr("영상 화질:"),
        marks = true,
        style = "settings",
        keep_open = true,
        items = items,
        keys = keys,
        default_item = default,
        anchor = anchor,
        submit = function(i)
            local fn = PIC.acts[i]
            if fn then fn() end
        end,
    })
end

function PIC.reopen() PIC.open(PIC.anchor, PIC.from_settings) end

-- "세부 설정…": the five filter levels and the user shader list.
function PIC.build_detail()
    local st = PIC.state()
    local items, acts, keys = {}, {}, {}
    local function add(key, text, fn)
        items[#items + 1] = text
        acts[#acts + 1] = fn
        keys[#keys + 1] = key
    end
    local function again() mp.add_timeout(0.1, PIC.open_detail) end
    for _, f in ipairs(PIC.FILTERS) do
        local lv = PIC.level_label(st[f])
        if PIC.suppressed(st, f) then lv = lv .. " · " .. input.core_tr("RTX 사용 중 — 일시 중지") end
        add(f, input.core_tr("%s: %s", PIC.filter_label(f), lv), function() mp.add_timeout(0.1, function() PIC.open_level(f) end) end)
    end
    add("shaders", input.core_tr("사용자 셰이더 목록 관리: %d개", #UPS.state().shaders), function() mp.add_timeout(0.1, UPS.open_shaders) end)
    if st.rtx then add("note_rtx", input.core_tr("RTX 사용 중 — 선 강조·선명도 일시 중지"), again) end
    if UPS.state().mode == "shader" then add("note_shader", input.core_tr("사용자 셰이더 — 선명화 중복 적용 주의"), again) end
    add("back", input.core_tr("← 뒤로"), function() mp.add_timeout(0.1, PIC.reopen) end)
    return items, acts, keys
end

function PIC.open_detail()
    local items, acts, keys = PIC.build_detail()
    PIC.detail_acts = acts
    input.select({
        id = "nanum-picture-detail",
        prompt = input.core_tr("영상 화질 세부 설정:"),
        items = items,
        keys = keys,
        submit = function(i)
            local fn = PIC.detail_acts[i]
            if fn then fn() end
        end,
    })
end

function PIC.open_level(f)
    local st = PIC.state()
    local cur = tonumber(st[f]) or 0
    local items = {}
    for n = 0, 3 do items[n + 1] = (n == cur and "● " or "  ") .. PIC.level_label(n) end
    items[#items + 1] = input.core_tr("← 뒤로")
    input.select({
        prompt = PIC.filter_label(f) .. ":",
        items = items,
        default_item = cur + 1,
        submit = function(i)
            if i <= 4 then PIC.call("set_filter", { name = f, level = i - 1 }) end
            mp.add_timeout(0.1, PIC.open_detail)
        end,
    })
end

do
    local factory = load_helper("nanum-picture.lua", "function")
    if factory then
        local ok, ctl = pcall(factory, { changed = function(st)
            if type(st) == "table" then PIC.last = st end
            PIC.refresh()
        end })
        if ok and type(ctl) == "table" then
            PIC.ctl = ctl
        else
            mp.msg.error("nanum-picture.lua: " .. tostring(ctl))
        end
    end
end

UPS.refresh_ui = PIC.refresh
function UPS.open() PIC.reopen() end
PIC.refresh()

-- Subtitle list (the subtitle button and Ctrl+N), target language, subtitle files: scripts/nanum-subtitles.lua.
-- Hooks it needs from this script (the module cannot see the locals of this file).
do
    local function primary_is_text()
        local st = cache_state()
        local active = st and st["nanum-input-active"]
        if active then return active == "sub" end
        return resolve_choice(mp.get_property_native("track-list") or {}).input == "sub"
    end
    local factory = load_helper("nanum-subtitles.lua", "function")
    if factory then
        local ok, ux = pcall(factory, {
            input = input, notify = notify, opts = opts, save_settings = save_settings,
            norm_lang = norm_lang, track_lang = track_lang, lang_name = lang_name, ai_role = ai_role,
            get_display = function() return opts.display end,
            set_display = set_display,
            file_ready = function() return file_active and file_loaded end,
            loaded_at = function() return loaded_at end,
            primary_is_text = primary_is_text,
            -- the text subtitle track the AI reads (nil when it works from speech)
            input_track = function()
                if not primary_is_text() then return nil end
                return resolve_choice(mp.get_property_native("track-list") or {}).track
            end,
            primary_source_lang = function()
                local tracks = mp.get_property_native("track-list") or {}
                if primary_is_text() then
                    local c = resolve_choice(tracks)
                    return c.track and norm_lang(track_lang(c.track)) or nil
                end
                return stt_language(tracks)
            end,
            pgs_language = function()
                local st = cache_state()
                return st and norm_lang(st["nanum-pgs-language"]) or nil
            end,
            -- AI work switched off by the user ("이 파일은 AI 자막 끄기") rather than by the original-subtitle policy
            ai_off_by_user = function() return ai_disabled and not (SUBS.ux and SUBS.ux.skip) end,
            ai_off_by_skip = function() return ai_disabled end,
            -- on: stop the AI work of this file (live input, disc OCR, original-language audio) while an original
            -- subtitle is shown; off: take it up again. silent: only put the player options back (new file).
            skip_ai = function(on, silent)
                if on then
                    SUBS.skip_prev = SUBS.skip_prev or { pgs = get_opt("nanum-pgs"), secondary = get_opt("nanum-secondary") }
                    set_opt_soft("nanum-pgs", "no")
                    set_opt_soft("nanum-secondary", "no")
                    library_action("disable", { quiet = true })
                    return
                end
                local prev = SUBS.skip_prev
                SUBS.skip_prev = nil
                if prev then
                    if prev.pgs then set_opt_soft("nanum-pgs", prev.pgs) end
                    if prev.secondary then set_opt_soft("nanum-secondary", prev.secondary) end
                end
                if not silent then library_action("ask", { quiet = true, keep_selection = true }) end
            end,
            pick_file = function() SUBS.pick_file() end,
            translate_import = function(path, origin, lang) SUBS.translate_import(path, origin, lang) end,
        })
        if ok and type(ux) == "table" then
            SUBS.ux = ux
            mp.set_property_native("user-data/nanum/sub-menu", true)
        else
            mp.msg.error("nanum-subtitles.lua: " .. tostring(ux))
        end
    end
    -- Whole-movie subtitle generation without playback: scripts/nanum-generate.lua (may be missing in old builds).
    local generate = load_helper("nanum-generate.lua", "function")
    if generate then
        local ok, g = pcall(generate, { input = input, notify = notify, reopen_menu = reopen_menu })
        if ok and type(g) == "table" and type(g.open) == "function" then
            SUBS.gen = g
        else
            mp.msg.error("nanum-generate.lua: " .. tostring(g))
        end
    end
end

local function build_settings()
    local items, actions, keys = {}, {}, {}
    local function add(key, text, fn)
        items[#items + 1] = text
        actions[#actions + 1] = fn
        keys[#keys + 1] = key
    end
    local st = cache_state()
    local status = full_status_text(st)
    if status then
        add("full_status", status, function() reopen_menu() end)
    end
    add("language", input.core_tr("인터페이스 언어: %s", SM.language_summary()), function() mp.add_timeout(0.1, function() SM.open_language_menu(true) end) end)
    add("models", input.core_tr("AI 구성 요소 관리: %s", AIM.components_summary()), function() mp.add_timeout(0.1, AIM.open_menu) end)
    if SUBS.ux then
        add("subtitles", input.core_tr("자막 선택: %s", SUBS.ux.summary()), function() mp.add_timeout(0.1, function() SUBS.ux.open() end) end)
        add("original_first", input.core_tr("목표 언어 원본 자막이 있으면 바로 표시: %s", input.core_tr(opts.original_first and "켬" or "끔")), function()
            opts.original_first = not opts.original_first
            save_settings()
            reopen_menu()
        end)
    end
    add("picture", input.core_tr("영상 화질: %s", PIC.summary()), function() mp.add_timeout(0.1, function() PIC.open(nil, true) end) end)
    if SUBS.disc and SUBS.disc.ctl then
        add("disc", input.core_tr("Blu-ray/DVD 복호화 구성 요소: %s", SUBS.disc.ctl.summary()), function() mp.add_timeout(0.1, SUBS.disc.ctl.open) end)
    end
    add("bar_hide", input.core_tr("재생 바 자동 숨김: %s", TAGS.bar_hide_label()), function()
        TAGS.cycle_bar_hide()
        reopen_menu()
    end)
    add("ai_tags", input.core_tr("AI 정보 태그 표시: %s", input.core_tr(opts.ai_tags and "켬" or "끔")), function()
        TAGS.set_ai_tags(not opts.ai_tags)
        reopen_menu()
    end)
    add("style", input.core_tr("번역 말투: %s", style_label()), function() mp.add_timeout(0.1, open_style_menu) end)
    local sec = secondary_text(st)
    add("secondary", input.core_tr("원어 음성으로도 자막 만들기: %s", input.core_tr(opts.secondary and "켬" or "끔")
        .. ((opts.secondary and sec) and (" · " .. sec) or "")), function()
        set_secondary(not opts.secondary)
        reopen_menu()
    end)
    local work, lang = tostring(st and st["nanum-profile-work"] or ""), lang_name(st and st["nanum-original-language"])
    if work ~= "" or lang then
        add("original", input.core_tr("식별된 작품·원어: %s", (work ~= "" and lang) and (work .. " · " .. lang) or (work ~= "" and work or lang)),
            reopen_menu)
    end
    add("pgs", input.core_tr("디스크 자막(이미지) 문자 인식으로도 자막 만들기: %s", input.core_tr(opts.pgs and "켬" or "끔")), function()
        SUBS.set_pgs(not opts.pgs)
        reopen_menu()
    end)
    local pgs = opts.pgs and SUBS.pgs_text(st)
    if pgs then add("pgs_state", pgs, reopen_menu) end
    -- The pack of the track's language is missing: the player either gives up (unavailable) or reads with another
    -- language's recognizer and says so in nanum-pgs-reason (running / done / waiting).
    local pgs_lang = st and norm_lang(st["nanum-pgs-language"]) or nil
    local pgs_state = st and st["nanum-pgs-state"]
    local fallback = pgs_state ~= "unavailable" and tostring(st and st["nanum-pgs-reason"] or "") ~= ""
    if opts.pgs and pgs_lang and SUBS.OCR_PACKS[pgs_lang] and (pgs_state == "unavailable" or (fallback and pgs_state ~= "off")) then
        add("pgs_pack", input.core_tr(fallback and "%s OCR 언어 팩 설치 (관리자 권한, 인식 정확도 향상)" or "%s OCR 언어 팩 설치 (관리자 권한)",
            lang_name(pgs_lang) or pgs_lang), function()
            mp.add_timeout(0.1, function() SUBS.open_ocr_install(pgs_lang) end)
        end)
    end
    add("subsearch", input.core_tr(SUBS.watch and "온라인 자막 찾기 · 다운로드 기다리는 중" or "온라인 자막 찾기 (OpenSubtitles · Jimaku)"),
        function() mp.add_timeout(0.1, SUBS.open_search_menu) end)
    add("subfile", input.core_tr("자막 파일 가져오기…"), function() SUBS.pick_file() end)
    add("generate", input.core_tr("전체 자막 생성…"), function()
        if SUBS.gen then
            SUBS.gen.open()
        else
            notify(input.core_tr("이 빌드에는 전체 자막 생성 기능이 없습니다"), 4, "warn")
            reopen_menu()
        end
    end)
    add("youtube_url", input.core_tr("YouTube 주소로 재생…"), function() mp.add_timeout(0.1, SUBS.yt.ask_url) end)
    add("web_url", input.core_tr("웹페이지 영상 주소로 재생… (Ctrl+Shift+Y)"), function() mp.add_timeout(0.1, SUBS.web.ask_url) end)
    add("youtube", input.core_tr("YouTube 창·구성 요소·로그인: %s", SUBS.yt.summary()), function() mp.add_timeout(0.1, SUBS.yt.open_menu) end)
    local imp = SUBS.import_text(st)
    if imp then
        add("subimport", input.core_tr("가져온 자막: %s", imp), function() mp.add_timeout(0.1, SUBS.open_adjust_menu) end)
    end
    add("glossary", glossary_label(st), function() mp.add_timeout(0.1, open_glossary_menu) end)
    local diag = mp.get_property_native("user-data/nanum/diagnostics")
    add("diag", input.core_tr("진단 로그(디스크 읽기 상세): %s", input.core_tr((type(diag) == "table" and diag.enabled == true) and "켬" or "끔")), function()
        local cur = mp.get_property_native("user-data/nanum/diagnostics")
        local on = type(cur) == "table" and cur.enabled == true
        if not mp.commandv("nanum-diagnostics", on and "off" or "on") then
            notify(input.core_tr("이 엔진 버전은 진단 로그를 지원하지 않습니다 (nanum 갱신 필요)"), 4, "error")
        elseif on then
            notify(input.core_tr("진단 로그를 껐습니다. 기본 재생 로그는 저장하지 않습니다"), 4)
        else
            local f = type(cur) == "table" and cur.file or ""
            notify(input.core_tr("진단 로그 켬: 디스크 읽기/탐색을 시간 기록과 함께 저장합니다 (최대 8MiB, 최근 8개 보관, 영상 데이터·키는 기록 안 함)\n%s",
                f ~= "" and f or "%APPDATA%\\NanumPlayer\\diagnostics\\"), 8, "ok")
        end
        reopen_menu()
    end)
    local lstat = lib_status_text()
    if lstat then
        add("lib_status", lstat, function()
            if lib.state == "available" then
                queue_prompt("library", build_library_prompt)
                mp.add_timeout(0.3, pump_prompts)
            else
                reopen_menu()
            end
        end)
    end
    if lib_supported(true) then
        add("lib_ask", input.core_tr("저장 자막 다시 조회"), function() library_action("ask") end)
        if lib.has_translation then
            add("lib_use", input.core_tr("저장된 번역 사용"), function() library_action("use") end)
        end
        if lib.has_source then
            add("lib_retranslate", input.core_tr("저장된 원문으로 다시 번역"), function() library_action("retranslate", { keep_full = true }) end)
        end
        add("lib_regenerate", input.core_tr("음성 인식부터 새로 생성"), function() library_action("regenerate", { keep_full = true }) end)
        if not ai_disabled then
            add("lib_disable", input.core_tr("이 파일은 AI 자막 끄기"), function() library_action("disable") end)
        end
        add("lib_auto", input.core_tr("저장 자막 자동 사용: %s", input.core_tr(opts.library_auto_use and "켬" or "끔")), function()
            set_auto_use(not opts.library_auto_use)
            reopen_menu()
        end)
    end
    if pinned_aud then
        add("audio", input.core_tr("AI 입력 음성: #%s %s (재생 음성으로 변경…)", tostring(pinned_aud.src), pinned_aud.lang or "?"), function()
            if build_audio_prompt() then
                queue_prompt("audio", build_audio_prompt)
                mp.add_timeout(0.3, pump_prompts)
            else
                notify(input.core_tr("재생 중인 음성이 AI 입력 음성과 같습니다"), 3)
                reopen_menu()
            end
        end)
    end
    add("input", input.core_tr("입력 소스: %s", input_label()), function() mp.add_timeout(0.1, open_input_menu) end)
    add("full", input.core_tr("전체 번역 모드: %s", input.core_tr(opts.full and "켬" or "끔")), function()
        opts.full = not opts.full
        full_settings_changed()
        reopen_menu()
    end)
    add("full_engine", input.core_tr("전체 번역 엔진: %s", opts.full_engine == "omp" and "oh-my-pi" or "Ollama"), function()
        opts.full_engine = opts.full_engine == "omp" and "ollama" or "omp"
        full_settings_changed()
        reopen_menu()
    end)
    add("omp_model", input.core_tr("oh-my-pi 모델: %s", opts.omp_model ~= "" and opts.omp_model or input.core_tr("(선택 안 됨)")),
        function() mp.add_timeout(0.1, open_omp_picker) end)
    add("preroll", input.core_tr("시작 프리롤: %d초", opts.preroll), function() ask_number(input.core_tr("시작 프리롤"), "preroll") end)
    add("timeout", input.core_tr("프리롤 최대 대기: %d초", opts.timeout), function() ask_number(input.core_tr("프리롤 최대 대기"), "timeout") end)
    add("auto_select", input.core_tr("AI 자막 자동 선택: %s", input.core_tr(opts.auto_select and "켬" or "끔")), function()
        opts.auto_select = not opts.auto_select
        save_settings()
        reopen_menu()
    end)
    for _, e in ipairs(ENGINE) do
        local open = e.key == "translate_model" and function() mp.add_timeout(0.1, function() open_ollama_picker(e) end) end
            or (e.key == "target_language" and SUBS.ux) and function() SUBS.ux.open_target_menu(reopen_menu) end
            or function() ask_text(e) end
        local shown = mp.get_property("options/" .. e.opt) or ""
        if e.key == "target_language" and SUBS.ux then shown = SUBS.ux.target().label end
        add("engine_" .. e.key, input.core_tr("%s: %s", input.core_tr(e.label), shown), open)
    end
    local ver = mp.get_property_native("user-data/nanum/app-version")
    ver = type(ver) == "string" and ver or ""
    if ver ~= "" then
        local mpv_ver = tostring(mp.get_property("mpv-version") or ""):match("(%d+%.%d+%.?%d*)") or ""
        local backend = cache_state() and cache_state()["nanum-ai-backend"] or (AIM.acc and AIM.acc.backend)
        add("about", input.core_tr("정보: NanumPlayer %s · 엔진 %s", ver .. (mpv_ver ~= "" and (" · mpv " .. mpv_ver) or ""),
            backend == "cuda" and "CUDA" or (backend == "cpu" and "CPU" or "—")), function()
            SUBS.open_url("https://github.com/kimmingul/NanumPlayer/releases")
            reopen_menu()
        end)
    end
    return items, actions, keys
end

local function update_settings_menu()
    if fluent.open_id() ~= "nanum-settings" then return end
    local items, actions, keys = build_settings()
    SM.actions, SM.keys = actions, keys
    fluent.update_select("nanum-settings", items, { keys = keys })
end

function open_menu()
    local items, actions, keys = build_settings()
    SM.actions, SM.keys = actions, keys
    local default = 1
    if menu_keep then
        for i, k in ipairs(keys) do
            if k == menu_last_key then default = i end
        end
    end
    menu_keep = false
    input.select({
        id = "nanum-settings",
        prompt = input.core_tr("NanumPlayer 설정:"),
        style = "settings",
        items = items,
        keys = keys,
        default_item = default,
        submit = function(i)
            menu_last_key = SM.keys[i]
            local fn = SM.actions[i]
            if fn then fn() end
        end,
    })
end

mp.add_key_binding("ctrl+n", "nanum-settings", open_menu)
mp.add_key_binding("ctrl+alt+l", "nanum-language", function() SM.open_language_menu(false) end)
mp.add_key_binding(nil, "nanum-subtitles", function() if SUBS.ux then SUBS.ux.open() end end)
-- The subtitle button of the playback bar (scripts/nanum-fluent.lua) opens the same list above itself.
mp.register_script_message("nanum-subtitles-open", function(x, y)
    if not SUBS.ux then return end
    local ax, ay = tonumber(x), tonumber(y)
    SUBS.ux.open((ax and ay) and { x = ax, y = ay } or nil)
end)
-- script-message nanum-subtitle-file <path> [language]: the same choice as "자막 파일 불러오기…" for a known file.
mp.register_script_message("nanum-subtitle-file", function(path, lang)
    if path and path ~= "" then SUBS.send(path, "파일", lang or "") end
end)
-- script-message nanum-subtitle-show <path> [language]: show the file as it is (an already loaded one is just selected).
mp.register_script_message("nanum-subtitle-show", function(path, lang)
    if SUBS.ux and path and path ~= "" then SUBS.ux.add_file(path, lang) end
end)
mp.observe_property("user-data/nanum/diagnostics", "native", function() update_settings_menu() end)
-- Picture quality: upscale and picture correction in one menu (Ctrl+I, Ctrl+N row, picture button of the bar).
mp.add_key_binding("ctrl+i", "nanum-picture", function() PIC.open() end)
mp.add_key_binding(nil, "nanum-upscale", function() PIC.open() end)
mp.register_script_message("nanum-picture-open", function(x, y)
    local ax, ay = tonumber(x), tonumber(y)
    PIC.open((ax and ay) and { x = ax, y = ay } or nil)
end)
mp.add_key_binding(nil, "nanum-picture-compare", function()
    PIC.call("set_compare", not PIC.state().comparing)
end)
UPS.refresh_settings = update_settings_menu

----------------------------------------------------------------------------
-- YouTube: the browser helper (nanum_youtube.exe) is used to choose a video and to log in; playback is
-- done by this player through mpv's ytdl_hook with the managed yt-dlp. The helper sends
-- `script-message nanum-youtube-open <url>` over the player's IPC pipe (also `nanumplayer://open?url=`).
-- The yt-dlp / deno components are managed like the models: user-data/nanum/youtube + commands
--   nanum-youtube-refresh, nanum-download-youtube-tools, nanum-cancel-youtube-download.
----------------------------------------------------------------------------

do
local YT = SUBS.yt

YT.BOOKMARKLET = "javascript:location.href='nanumplayer://open?url='+encodeURIComponent(location.href)"
YT.COMP_NAME = { ["yt-dlp"] = "yt-dlp", deno = "JavaScript 런타임(deno)" }

function YT.name(id)
    return input.core_tr(YT.COMP_NAME[id] or tostring(id or ""))
end

-- Only YouTube pages are accepted (a web page can trigger nanumplayer:// links): https, youtube.com /
-- youtu.be (with m. / www. / music.), an 11 character video id. -> canonical URL, start seconds | nil
function YT.parse(url)
    url = tostring(url or ""):match("^%s*(.-)%s*$")
    local host, path, query = url:match("^[hH][tT][tT][pP][sS]://([^/%?#]+)([^%?#]*)%??([^#]*)")
    if not host then return nil end
    host = host:lower():gsub("^www%.", ""):gsub("^m%.", ""):gsub("^music%.", "")
    local id
    if host == "youtu.be" then
        id = path:match("^/([^/]+)")
    elseif host == "youtube.com" then
        id = path:match("^/shorts/([^/]+)") or path:match("^/live/([^/]+)") or path:match("^/embed/([^/]+)")
            or path:match("^/v/([^/]+)")
        if not id and path == "/watch" then id = query:match("^v=([^&]+)") or query:match("&v=([^&]+)") end
    end
    if not id or #id ~= 11 or id:find("[^%w_%-]") then return nil end
    local t = query:match("^t=([^&]+)") or query:match("&t=([^&]+)") or query:match("^start=([^&]+)") or query:match("&start=([^&]+)")
    local start
    if t then
        local h, m, s = t:match("^(%d+)h"), t:match("(%d+)m"), t:match("(%d+)s?$")
        start = tonumber(t:match("^%d+$")) or ((tonumber(h) or 0) * 3600 + (tonumber(m) or 0) * 60 + (tonumber(s) or 0))
        if start <= 0 then start = nil end
    end
    return "https://www.youtube.com/watch?v=" .. id, start
end

function YT.list()
    local d = YT.data
    return d and type(d.components) == "table" and d.components or {}
end

function YT.active()
    local d = YT.data
    return d ~= nil and (d.status == "downloading" or d.status == "verifying" or d.status == "extracting" or d.status == "checking")
end

function YT.downloading()
    local d = YT.data
    return d ~= nil and (d.status == "downloading" or d.status == "verifying" or d.status == "extracting")
end

function YT.fraction()
    local d = YT.data
    local total = d and tonumber(d.total) or 0
    if total <= 0 then return nil end
    return math.max(0, math.min(1, (tonumber(d.received) or 0) / total))
end

-- false: components are known to be missing. nil: not known yet (old engine / no state).
function YT.installed()
    local d = YT.data
    if not d then return nil end
    return d.installed == true
end

-- Bytes still to fetch.
function YT.missing_bytes()
    local sum = 0
    for _, c in ipairs(YT.list()) do
        if c.installed ~= true then sum = sum + (tonumber(c.size) or 0) end
    end
    return sum
end

function YT.progress_text()
    local d = YT.data
    if not d then return nil end
    local name = YT.name(d.current)
    if d.status == "checking" then return input.core_tr("최신 버전 확인 중…") end
    if d.status == "verifying" then return input.core_tr("%s 무결성 검증 중", name) end
    if d.status == "extracting" then return input.core_tr("%s 압축 푸는 중", name) end
    local f = YT.fraction()
    if f then
        return input.core_tr("%s 내려받는 중 %d%% (%s / %s)", name, math.floor(f * 100 + 0.5), AIM.fmt_size(d.received), AIM.fmt_size(d.total))
    end
    return input.core_tr("%s 내려받는 중", name)
end

-- Short form for the settings row.
function YT.summary()
    local d = YT.data
    if not d then return YT.cmd_ok == false and input.core_tr("지원 안 됨") or input.core_tr("확인 중…") end
    if YT.active() then
        local f = YT.fraction()
        return d.status == "checking" and input.core_tr("최신 버전 확인 중…")
            or (input.core_tr("%s 내려받는 중", YT.name(d.current)) .. (f and (" " .. math.floor(f * 100 + 0.5) .. "%") or ""))
    end
    if d.installed ~= true then
        local bytes = YT.missing_bytes()
        return bytes > 0 and input.core_tr("구성 요소 미설치 · %s", AIM.fmt_size(bytes)) or input.core_tr("구성 요소 미설치")
    end
    local v = tostring(d.version or "")
    local s = "yt-dlp " .. (v ~= "" and v or input.core_tr("설치됨"))
    if d.update_available == true then s = s .. " · " .. input.core_tr("업데이트 있음") end
    return s
end

function YT.status_text()
    local d = YT.data
    if not d then return YT.cmd_ok == false and input.core_tr("이 엔진 버전은 YouTube 구성 요소 관리를 지원하지 않습니다") or input.core_tr("확인 중…") end
    if YT.active() then return YT.progress_text() end
    if d.status == "done" then return input.core_tr("완료") end
    if d.status == "cancelled" then return input.core_tr("취소됨") end
    if d.status == "error" then
        local e = tostring(d.error or "")
        return input.core_tr("오류 — %s", e ~= "" and e or input.core_tr("알 수 없는 오류"))
    end
    if d.installed ~= true then return input.core_tr("YouTube 재생에 필요한 구성 요소가 없습니다") end
    if d.update_available == true then return input.core_tr("새 버전이 있습니다") end
    return tostring(d.latest or "") ~= "" and input.core_tr("최신 버전입니다") or input.core_tr("설치됨 (최신 버전 여부는 '업데이트 확인'으로 확인)")
end

function YT.refresh()
    YT.cmd_ok = mp.commandv("nanum-youtube-refresh") == true
    return YT.cmd_ok
end

function YT.download()
    local t = mp.get_time()
    if t - (YT.last_cmd or -10) < 0.7 then return false end        -- double click
    YT.last_cmd = t
    if YT.active() then
        notify(input.core_tr("이미 내려받는 중입니다 — 끝나거나 취소한 뒤 다시 선택하세요"), 4, "warn")
        return false
    end
    if not mp.commandv("nanum-download-youtube-tools") then
        notify(YT.data and input.core_tr("내려받기를 시작하지 못했습니다 (다른 작업이 진행 중일 수 있습니다)")
            or input.core_tr("이 엔진 버전은 YouTube 구성 요소를 지원하지 않습니다 (nanum 갱신 필요)"), 5, "error")
        return false
    end
    YT.toast_at = 0
    local bytes = YT.missing_bytes()
    local updating = YT.data and YT.data.installed == true
    local text
    if updating then
        text = bytes > 0 and input.core_tr("YouTube 구성 요소 업데이트를 시작합니다 (%s)", AIM.fmt_size(bytes))
            or input.core_tr("YouTube 구성 요소 업데이트를 시작합니다")
    else
        text = bytes > 0 and input.core_tr("YouTube 구성 요소 내려받기를 시작합니다 (%s)", AIM.fmt_size(bytes))
            or input.core_tr("YouTube 구성 요소 내려받기를 시작합니다")
    end
    notify(text, 4, "busy", "yt-dl")
    return true
end

function YT.cancel()
    if YT.downloading() then
        mp.commandv("nanum-cancel-youtube-download")
        notify(input.core_tr("YouTube 구성 요소 내려받기를 취소하는 중..."), 3, "busy", "yt-dl")
    else
        notify(input.core_tr("진행 중인 내려받기가 없습니다"), 3)
    end
end

-- Progress toast that survives closing the menu (text changes at most once per second, refreshed every 3 s).
function YT.heartbeat()
    if not YT.downloading() or fluent.open_id() == "nanum-youtube" then return end
    local text = input.core_tr("YouTube 구성 요소: %s", YT.progress_text())
    local t = mp.get_time()
    if (text ~= YT.toast_text and t - (YT.toast_at or 0) >= 1) or t - (YT.toast_at or 0) >= 3 then
        YT.toast_text, YT.toast_at = text, t
        notify(text, 4, "busy", "yt-dl")
    end
end

function YT.on_change(_, v)
    local prev = YT.data
    local d = type(v) == "table" and v or nil
    YT.data = d
    local sig = d and (tostring(d.status) .. "|" .. tostring(d.error or "")) or nil
    local changed = sig ~= YT.sig
    YT.sig = sig
    if d and prev and changed then
        if d.status == "done" then
            notify((tostring(d.version or "") ~= "") and input.core_tr("YouTube 구성 요소 준비 완료 · yt-dlp %s", d.version) or input.core_tr("YouTube 구성 요소 준비 완료"), 5, "ok", "yt-dl")
            if d.installed == true and YT.after then
                local fn = YT.after
                YT.after = nil
                mp.add_timeout(0.3, fn)
            end
        elseif d.status == "error" then
            YT.after = nil
            local e = tostring(d.error or "")
            notify(input.core_tr("YouTube 구성 요소 내려받기 실패") .. (e ~= "" and (": " .. e) or "")
                .. "\n" .. input.core_tr("Ctrl+N → YouTube에서 다시 시도할 수 있습니다"), 9, "error", "yt-dl")
        elseif d.status == "cancelled" then
            YT.after = nil
            notify(input.core_tr("YouTube 구성 요소 내려받기를 취소했습니다"), 3, "info", "yt-dl")
        end
    end
    if d then YT.heartbeat() end
    YT.update_menu()
    update_settings_menu()
end

-- Runs fn when the components are there: at once, or after the download the user agrees to.
function YT.ensure(fn)
    if YT.installed() ~= false then return fn() end
    local bytes = YT.missing_bytes()
    input.select({
        prompt = input.core_tr("YouTube 구성 요소가 필요합니다"),
        items = {
            bytes > 0 and input.core_tr("내려받고 계속 (%s)", AIM.fmt_size(bytes)) or input.core_tr("내려받고 계속"),
            input.core_tr("구성 요소 없이 계속 (재생이 실패할 수 있습니다)"),
            input.core_tr("취소"),
        },
        default_item = 1,
        submit = function(i)
            if i == 1 then
                if YT.download() then YT.after = fn end
            elseif i == 2 then
                fn()
            end
        end,
    })
end

-- A file next to NanumPlayer.exe. This build does not expand "~~exe_dir", so the
-- app folder is taken from this script's location (<app>\scripts\nanum.lua).
function YT.app_path(name)
    local script = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local dir = script:match("^(.*)[/\\]scripts[/\\][^/\\]+$")
    if dir then return dir .. "\\" .. name end
    local ok, p = pcall(mp.command_native, { "expand-path", "~~exe_dir/" .. name })
    return ok and type(p) == "string" and p or ""
end

-- Starts / shows the browser helper. extra: more helper arguments (the page mode passes --url <page>);
-- text: the toast that tells the user what happens next.
function YT.launch_helper(extra, text)
    local exe = YT.app_path("nanum_youtube.exe")
    if exe == "" or not require('mp.utils').file_info(exe) then
        notify(input.core_tr("YouTube 브라우저(nanum_youtube.exe)를 찾을 수 없습니다 — NanumPlayer를 다시 설치하세요"), 7, "error", "yt")
        return false
    end
    local args = { exe }
    for _, a in ipairs(type(extra) == "table" and extra or {}) do args[#args + 1] = a end
    args[#args + 1] = "--language"          -- also forwarded to an already running helper, which relabels its window
    args[#args + 1] = input.i18n.language()
    -- A bare name (--input-ipc-server=foo) is stored as "foo": the pipe is \\.\pipe\foo. No pipe in this window:
    -- the helper falls back to the player's default name.
    local pipe = mp.get_property("input-ipc-server")
    if type(pipe) == "string" and pipe ~= "" then
        if not pipe:lower():find("^\\\\%.\\pipe\\") then pipe = "\\\\.\\pipe\\" .. pipe end
        args[#args + 1] = "--pipe"
        args[#args + 1] = pipe
    end
    mp.command_native_async({ name = "subprocess", args = args, playback_only = false, detach = true }, function() end)
    notify(type(text) == "string" and text or input.core_tr("YouTube 창을 엽니다 — 영상을 고르면 NanumPlayer에서 재생합니다"), 5, "busy", "yt")
    return true
end

function YT.open_browser()
    YT.ensure(YT.launch_helper)
end

-- Window to the front after a request from the helper / the protocol handler (best effort).
function YT.raise()
    mp.set_property_bool("window-minimized", false)
    if not mp.get_property_bool("ontop") then
        mp.set_property_bool("ontop", true)
        mp.add_timeout(0.15, function() mp.set_property_bool("ontop", false) end)
    end
end

function YT.play(url)
    local canon, start = YT.parse(url)
    if not canon then
        notify(input.core_tr("YouTube 영상 주소가 아닙니다: %s\n(https://www.youtube.com/watch?v=… 또는 https://youtu.be/… 형식)", tostring(url):sub(1, 80)), 6, "warn", "yt")
        return false
    end
    YT.ensure(function()
        -- Uploader subtitles (never the automatic captions: write-subs without write-auto-subs) in the target language
        -- and English become external tracks through ytdl_hook; the subtitle list shows them as originals.
        local code = SUBS.ux and SUBS.ux.target().code or nil
        local langs = (code and code ~= "en") and ("(" .. code .. "|en).*") or "en.*"
        local o = { ["ytdl-raw-options-append"] = "sub-langs=" .. langs }
        if start then o.start = tostring(start) end
        mp.command_native({ name = "loadfile", url = canon, flags = "replace", index = -1, options = o })
        YT.raise()
        notify(start and input.core_tr("YouTube 영상을 불러오는 중… (%d초부터)", start) or input.core_tr("YouTube 영상을 불러오는 중…"), 6, "busy", "yt")
    end)
    return true
end

function YT.clipboard_url()
    local c = mp.get_property("clipboard/text")
    c = type(c) == "string" and c:match("^%s*(.-)%s*$") or ""
    return YT.parse(c) and c or ""
end

function YT.ask_url()
    input.get({
        prompt = input.core_tr("YouTube 주소 (복사한 주소를 붙여넣으세요):"),
        default_text = YT.clipboard_url(),
        submit = function(text)
            input.terminate()
            if text:match("%S") then YT.play(text) end
        end,
    })
end

-- Errors of yt-dlp as ytdl_hook logs them -> { key=, text=, hint= }
function YT.classify(text)
    local t = tostring(text or ""):lower()
    local function has(...)
        for _, p in ipairs({ ... }) do
            if t:find(p, 1, true) then return true end
        end
        return false
    end
    if has("not found or not enough permissions") then
        return { key = "missing", text = input.core_tr("yt-dlp 구성 요소를 찾을 수 없습니다"), hint = input.core_tr("Ctrl+N → YouTube에서 구성 요소를 내려받으세요") }
    elseif has("not a bot") then
        return { key = "login", text = input.core_tr("YouTube가 로봇이 아닌지 확인을 요구합니다"), hint = input.core_tr("YouTube 창에서 로그인 후 다시 시도하세요") }
    elseif has("sign in", "log in", "login required", "private video", "members-only", "members only", "confirm your age", "age-restricted", "age restricted") then
        return { key = "login", text = input.core_tr("로그인이 필요한 영상입니다"), hint = input.core_tr("YouTube 창에서 로그인 후 다시 시도하세요") }
    elseif has("requested format is not available", "no video formats found", "no formats") then
        return { key = "update", text = input.core_tr("재생할 수 있는 영상 형식을 찾지 못했습니다"), hint = input.core_tr("구성 요소를 업데이트한 뒤 다시 시도하세요 (Ctrl+N → YouTube)") }
    elseif has("unable to extract", "nsig", "signature", "http error 403", "javascript runtime", "js runtime", "player response", "po token", "challenge") then
        return { key = "update", text = input.core_tr("yt-dlp가 YouTube의 변경을 따라가지 못했습니다"), hint = input.core_tr("구성 요소를 업데이트한 뒤 다시 시도하세요 (Ctrl+N → YouTube)") }
    elseif has("video unavailable", "has been removed", "no longer available", "this video is not available", "copyright", "not made this video available", "geo") then
        return { key = "gone", text = input.core_tr("재생할 수 없는 영상입니다 (삭제·비공개·지역 제한)"), hint = input.core_tr("로그인하면 볼 수 있는 영상일 수 있습니다 — YouTube 창에서 로그인해 보세요") }
    elseif has("unable to download", "urlopen error", "timed out", "getaddrinfo", "network is unreachable", "connection reset") then
        return { key = "net", text = input.core_tr("네트워크 오류로 YouTube에 연결하지 못했습니다"), hint = input.core_tr("인터넷 연결을 확인한 뒤 다시 시도하세요") }
    end
    local first = tostring(text or ""):match("[Ee][Rr][Rr][Oo][Rr]:%s*([^\r\n]+)") or ""
    return { key = "other", text = first ~= "" and input.core_tr("YouTube 재생에 실패했습니다: %s", first:sub(1, 140)) or input.core_tr("YouTube 재생에 실패했습니다"),
        hint = input.core_tr("구성 요소를 업데이트하거나 YouTube 창에서 로그인한 뒤 다시 시도하세요") }
end

-- Collects what ytdl_hook says while a file loads (the failure itself arrives as end-file).
function YT.on_log(e)
    if e.prefix ~= "ytdl_hook" or (e.level ~= "error" and e.level ~= "fatal" and e.level ~= "warn") then return end
    local log = YT.log
    log[#log + 1] = tostring(e.text or "")
    while #log > 12 do table.remove(log, 1) end
end

-- A load failure that ytdl_hook explained: Korean toast + what to do next. -> true if handled
function YT.on_play_error()
    if #YT.log == 0 then return false end
    local r = YT.classify(table.concat(YT.log, "\n"))
    YT.log = {}
    mp.set_property_native("user-data/nanum/error-handled", true)
    mp.msg.error("YouTube 재생 실패 (" .. r.key .. ")")
    notify(r.text .. "\n" .. r.hint, 12, "error", "yt")
    local items, actions = {}, {}
    local function add(text, fn)
        items[#items + 1] = text
        actions[#actions + 1] = fn
    end
    if r.key == "missing" then
        add(input.core_tr("YouTube 구성 요소 내려받기"), function() YT.download() end)
    elseif r.key == "login" or r.key == "gone" then
        add(input.core_tr("YouTube 창 열기 (로그인)"), function() YT.open_browser() end)
    elseif r.key == "update" or r.key == "other" then
        add(input.core_tr("구성 요소 업데이트"), function() YT.refresh(); YT.download() end)
        add(input.core_tr("YouTube 창 열기 (로그인)"), function() YT.open_browser() end)
    end
    if #items > 0 then
        add(input.core_tr("닫기"), function() end)
        mp.add_timeout(0.6, function()
            if fluent.modal_busy() then return end
            input.select({ prompt = input.core_tr("YouTube 재생에 실패했습니다"), items = items, submit = function(i) actions[i]() end })
        end)
    end
    return true
end

-- The helper owns the private session and waits for its profile cleanup on --quit.
function YT.delete_login()
    local exe = YT.app_path("nanum_youtube.exe")
    if exe == "" or not require('mp.utils').file_info(exe) then
        notify(input.core_tr("웹 도우미를 찾을 수 없습니다"), 6, "error", "yt")
        return
    end
    notify(input.core_tr("시크릿 웹 세션을 종료하는 중…"), 6, "busy", "yt")
    mp.command_native_async({ name = "subprocess", playback_only = false,
        args = { exe, "--quit" } }, function(ok, res)
        if ok and res and res.status == 0 then
            notify(input.core_tr("시크릿 웹 세션을 종료했습니다. 다음 창에서는 다시 로그인해야 합니다"), 6, "ok", "yt")
        else
            notify(input.core_tr("시크릿 세션 정리를 완료하지 못했습니다. 웹 창을 닫고 다시 시도하세요"), 8, "error", "yt")
        end
    end)
end

function YT.open_delete_confirm()
    local chosen = false
    input.select({
        prompt = input.core_tr("시크릿 웹 세션을 종료할까요?"),
        items = { input.core_tr("종료 및 로그아웃 (YouTube·웹페이지)"), input.core_tr("취소") },
        default_item = 2,
        submit = function(i)
            chosen = true
            if i == 1 then YT.delete_login() end
        end,
        closed = function()
            if not chosen and not fluent.modal_busy() then mp.add_timeout(0.1, YT.open_menu) end
        end,
    })
end

function YT.open_bookmarklet()
    local copied = SUBS.copy_text(YT.BOOKMARKLET)
    input.select({
        prompt = copied and input.core_tr("북마클릿을 클립보드에 복사했습니다") or input.core_tr("북마클릿 (복사하지 못했습니다 — 아래 줄을 직접 복사하세요)"),
        items = {
            input.core_tr("1. 브라우저 북마크 표시줄에서 '새 북마크'(또는 즐겨찾기 추가)를 만듭니다"),
            input.core_tr("2. 이름: NanumPlayer로 열기 / 주소(URL): 복사한 내용을 붙여넣습니다 (Ctrl+V)"),
            input.core_tr("3. 브라우저에서 YouTube 영상을 연 뒤 그 북마크를 누르면 NanumPlayer에서 재생됩니다"),
            YT.BOOKMARKLET,
            input.core_tr("다시 복사"),
            input.core_tr("뒤로"),
        },
        default_item = 5,
        submit = function(i)
            if i == 5 then
                notify(input.core_tr(SUBS.copy_text(YT.BOOKMARKLET) and "북마클릿을 복사했습니다" or "복사하지 못했습니다"), 3, "ok")
            end
        end,
        closed = function()
            if not fluent.modal_busy() then mp.add_timeout(0.1, YT.open_menu) end
        end,
    })
end

function YT.build_menu()
    local items, actions, keys, progress = {}, {}, {}, {}
    local function add(key, text, fn)
        items[#items + 1] = text
        actions[#actions + 1] = fn
        keys[#keys + 1] = key
    end
    local d = YT.data
    add("status", input.core_tr("구성 요소 상태: %s", YT.status_text()), function()
        local cur = YT.data
        if cur and cur.status == "error" and tostring(cur.error or "") ~= "" then
            notify(input.core_tr("YouTube 구성 요소 오류: %s", cur.error), 9, "error")
        end
    end)
    if d then
        for _, c in ipairs(YT.list()) do
            local key = "c_" .. tostring(c.id)
            local val
            if YT.downloading() and d.current == c.id then
                if d.status == "verifying" then
                    val, progress[key] = input.core_tr("무결성 검증 중"), 1
                elseif d.status == "extracting" then
                    val, progress[key] = input.core_tr("압축 푸는 중"), 1
                else
                    local f = YT.fraction()
                    val = input.core_tr("내려받는 중 %s · %s / %s", f and (math.floor(f * 100 + 0.5) .. "%") or "…",
                        AIM.fmt_size(d.received), AIM.fmt_size(d.total))
                    progress[key] = f or 0
                end
            elseif c.installed then
                val = tostring(c.version or "") ~= "" and input.core_tr("설치됨 · %s", c.version) or input.core_tr("설치됨")
            else
                val = input.core_tr("미설치 · %s", AIM.fmt_size(c.size))
            end
            add(key, (c.installed and "● " or "  ") .. input.core_tr("%s: %s", tostring(c.label or YT.name(c.id)), val), function()
                if not c.installed then YT.download() end
            end)
        end
        local need = d.installed ~= true
        local upd = d.update_available == true
        add("download", input.core_tr(need and "구성 요소 내려받기: %s" or "구성 요소 업데이트: %s",
            YT.active() and input.core_tr("진행 중") or (need and AIM.fmt_size(YT.missing_bytes())
            or (upd and input.core_tr("새 버전 %s", tostring(d.latest or "")) or input.core_tr("최신 버전입니다")))), function()
            if not need and not upd then
                notify(input.core_tr("최신 버전입니다 — '업데이트 확인'으로 새 버전이 있는지 먼저 확인하세요"), 4, "info")
            else
                YT.download()
            end
        end)
        add("check", input.core_tr("업데이트 확인: %s", tostring(d.latest or "") ~= "" and input.core_tr("최신 %s", d.latest) or input.core_tr("아직 확인하지 않음")), function()
            if YT.active() then return end
            YT.refresh()
            notify(input.core_tr("최신 버전을 확인합니다"), 3)
        end)
        add("cancel", input.core_tr("내려받기 취소: %s", input.core_tr(YT.downloading() and "진행 중인 작업 중단" or "진행 중인 작업 없음")), YT.cancel)
    end
    add("browser", input.core_tr("YouTube 시크릿 창 열기 (로그인은 이번 세션에서만 유지)"), function() mp.add_timeout(0.1, YT.open_browser) end)
    add("url", input.core_tr("YouTube 주소로 재생…"), function() mp.add_timeout(0.1, YT.ask_url) end)
    add("web", input.core_tr("웹페이지 영상 주소로 재생… (Ctrl+Shift+Y)"), function() mp.add_timeout(0.1, SUBS.web.ask_url) end)
    add("bookmarklet", input.core_tr("'NanumPlayer로 열기' 북마클릿 복사 (다른 브라우저용)"), function() mp.add_timeout(0.1, YT.open_bookmarklet) end)
    add("logout", input.core_tr("시크릿 웹 세션 종료 (로그아웃)"), function() mp.add_timeout(0.1, YT.open_delete_confirm) end)
    add("back", input.core_tr("설정 메뉴로 돌아가기"), function()
        menu_keep = true
        mp.add_timeout(0.1, open_menu)
    end)
    return items, actions, keys, progress
end

function YT.update_menu()
    if fluent.open_id() ~= "nanum-youtube" then return end
    local items, actions, keys, progress = YT.build_menu()
    YT.actions = actions
    fluent.update_select("nanum-youtube", items, { keys = keys, progress = progress })
end

function YT.open_menu()
    local items, actions, keys, progress = YT.build_menu()
    YT.actions = actions
    input.select({
        id = "nanum-youtube",
        prompt = input.core_tr("YouTube · 시크릿 웹:"),
        style = "settings",
        marks = true,
        keep_open = true,
        items = items,
        keys = keys,
        progress = progress,
        submit = function(i)
            local fn = YT.actions[i]
            if fn then fn() end
        end,
    })
end

----------------------------------------------------------------------------
-- Any web page (not only YouTube): `nanum_youtube.exe --url <page> --pipe <pipe>` opens the page in the browser
-- helper, which finds the media the page really plays and sends ONE json string
--   script-message nanum-web-open {"url","origin","referer","user_agent","title","cookie_jar"?}
-- url: http(s) media / manifest, origin: top-level page, referer: the frame that holds the player, cookie_jar:
-- in-memory Netscape cookies for that media URL, retaining domain/path/secure scope. Everything is applied as
-- per-file loadfile options, so nothing of it reaches the next file. Playback / AI subtitles are the normal
-- ones; no yt-dlp is involved. (Named SUBS.web, no new main-chunk local: the chunk is near the 200-local limit.)
----------------------------------------------------------------------------
SUBS.web = {}

-- http(s) URL without whitespace / control characters / quotes / userinfo -> the URL | nil
function SUBS.web.http_url(s, max)
    if type(s) ~= "string" or s == "" or #s > (max or 8192) then return nil end
    if s:find("[%c%s\127\"]") then return nil end
    local auth = s:match("^[hH][tT][tT][pP][sS]?://([^/%?#]*)")
    if not auth or auth == "" or auth:find("@", 1, true) or auth:find("^:") then return nil end
    return s
end

-- A value that goes into an HTTP header: no CR / LF / other control characters.
function SUBS.web.header(s, max)
    if type(s) ~= "string" or #s > (max or 1024) or s:find("[%c\127]") then return nil end
    s = s:match("^%s*(.-)%s*$")
    return s ~= "" and s or nil
end

-- Single-line title, at most 200 bytes (never cut inside a UTF-8 sequence).
function SUBS.web.clean_title(s)
    s = s:gsub("[%c\127]+", " "):match("^%s*(.-)%s*$")
    if #s > 200 then
        local cut = 200
        while cut > 0 do
            local b = s:byte(cut + 1)
            if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end
        end
        s = s:sub(1, cut)
    end
    return s ~= "" and s or nil
end

-- JSON payload -> { url, origin, referer, user_agent, title, cookie_jar } | nil, reason
function SUBS.web.parse(payload)
    if type(payload) ~= "string" or payload == "" or #payload > 65536 then return nil, "요청 형식이 올바르지 않습니다" end
    local d = require('mp.utils').parse_json(payload)
    if type(d) ~= "table" then return nil, "요청 형식이 올바르지 않습니다" end
    local req = {}
    req.url = SUBS.web.http_url(d.url)
    if not req.url then return nil, "영상 주소가 올바른 http(s) 주소가 아닙니다" end
    req.origin = SUBS.web.http_url(d.origin)
    if not req.origin then return nil, "웹페이지 주소(origin)가 올바르지 않습니다" end
    if d.referer ~= nil and d.referer ~= "" then
        req.referer = SUBS.web.http_url(d.referer)
        if not req.referer then return nil, "Referer가 올바르지 않습니다" end
    end
    if d.user_agent ~= nil and d.user_agent ~= "" then
        req.user_agent = SUBS.web.header(d.user_agent)
        if not req.user_agent then return nil, "User-Agent가 올바르지 않습니다" end
    end
    if d.title ~= nil then
        if type(d.title) ~= "string" then return nil, "제목이 올바르지 않습니다" end
        req.title = SUBS.web.clean_title(d.title)
    end
    if d.cookie_jar ~= nil and d.cookie_jar ~= "" then
        if type(d.cookie_jar) ~= "string" or #d.cookie_jar > 60000 or d.cookie_jar:find("\0", 1, true) then
            return nil, "메모리 쿠키 형식이 올바르지 않습니다"
        end
        req.cookie_jar = d.cookie_jar
    end
    return req
end

-- script-message nanum-web-open <json>
function SUBS.web.play(payload)
    local req, why = SUBS.web.parse(payload)
    if not req then
        mp.msg.warn("웹페이지 영상 요청 거부: " .. tostring(why))
        notify(input.core_tr("웹페이지 영상을 열지 못했습니다: %s", input.core_tr(tostring(why))), 7, "error", "web")
        return false
    end
    -- File-local only (a map, so commas in values are safe): ytdl_hook / headers / cookies end with this file.
    local o = { ytdl = "no", ["nanum-origin-url"] = req.origin }
    if req.referer then o.referrer = req.referer end
    if req.user_agent then o["user-agent"] = req.user_agent end
    if req.cookie_jar then
        o.cookies = "yes"
        o["cookies-file"] = "memory://" .. req.cookie_jar
    end
    if req.title then o["force-media-title"] = req.title end
    local res = mp.command_native({ name = "loadfile", url = req.url, flags = "replace", index = -1, options = o })
    if res == nil then
        mp.msg.error("웹페이지 영상을 불러오지 못했습니다 (loadfile 거부)")
        notify(input.core_tr("웹페이지 영상을 불러오지 못했습니다"), 7, "error", "web")
        return false
    end
    SUBS.yt.raise()
    notify(req.title and input.core_tr("웹페이지 영상을 불러오는 중…\n%s", req.title:sub(1, 60)) or input.core_tr("웹페이지 영상을 불러오는 중…"), 6, "busy", "web")
    return true
end

-- Opens the page in the helper's browser window. The 'NanumPlayer에서 재생' button is always there; the helper looks for the media when it is clicked.
function SUBS.web.open(url)
    url = tostring(url or ""):match("^%s*(.-)%s*$")
    if not SUBS.web.http_url(url, 2048) then
        notify(input.core_tr("웹페이지 주소가 아닙니다 (http:// 또는 https:// 로 시작하는 주소)"), 6, "warn", "web")
        return false
    end
    return SUBS.yt.launch_helper({ "--url", url },
        input.core_tr("웹페이지 창을 엽니다 — 페이지에서 영상을 재생한 뒤 'NanumPlayer에서 재생'을 누르세요"))
end

function SUBS.web.clipboard_url()
    local c = mp.get_property("clipboard/text")
    c = type(c) == "string" and c:match("^%s*(.-)%s*$") or ""
    return SUBS.web.http_url(c, 2048) and c or ""
end

function SUBS.web.ask_url()
    input.get({
        prompt = input.core_tr("시크릿 웹페이지 주소 (영상이 있는 페이지):"),
        default_text = SUBS.web.clipboard_url(),
        submit = function(text)
            input.terminate()
            if text:match("%S") then SUBS.web.open(text) end
        end,
    })
end

-- Ctrl+Shift+Y (mpv names that chord ctrl+Y); a script-message with a page url starts the page window at once.
mp.add_key_binding("ctrl+Y", "nanum-web", SUBS.web.ask_url)
mp.add_key_binding(nil, "nanum-web-url", SUBS.web.ask_url)
mp.register_script_message("nanum-web-url", function(url)
    if url and url:match("%S") then SUBS.web.open(url) else SUBS.web.ask_url() end
end)
mp.register_script_message("nanum-web-open", SUBS.web.play)
-- Readiness for the helper: it waits for this property before it sends nanum-web-open.
mp.set_property_native("user-data/nanum/web-ready", true)
mp.register_event("shutdown", function() mp.set_property_native("user-data/nanum/web-ready", false) end)

mp.add_key_binding("ctrl+y", "nanum-youtube", YT.open_browser)
mp.add_key_binding(nil, "nanum-youtube-menu", YT.open_menu)
mp.add_key_binding(nil, "nanum-youtube-url", YT.ask_url)
mp.register_script_message("nanum-youtube-open", function(url) YT.play(url) end)
mp.observe_property("user-data/nanum/youtube", "native", YT.on_change)
mp.enable_messages("warn")
mp.register_event("log-message", YT.on_log)
mp.add_periodic_timer(1, YT.heartbeat)
end

----------------------------------------------------------------------------
-- Encrypted-disc failures. Own scope: the main chunk is near Lua's 200-local limit.
-- Decryption is an optional component (scripts/nanum-disc.lua): it explains what is missing and offers
-- the verified install; the failed disc is opened again once it is there.
----------------------------------------------------------------------------
do
local DISC = { log = {}, path = nil }
SUBS.disc = DISC

local function disc_log(e)
    if e.level ~= "error" and e.level ~= "fatal" then return end
    local text = tostring(e.text or "")
    if e.prefix ~= "bd" and e.prefix ~= "dvdnav" and e.prefix ~= "dvd"
        and not text:find("Disc decryption component", 1, true) then return end
    local log = DISC.log
    log[#log + 1] = text
    while #log > 8 do table.remove(log, 1) end
end
DISC.on_log = disc_log

do
    local factory = load_helper("nanum-disc.lua", "function")
    if factory then
        local ok, ctl = pcall(factory, {
            notify = notify,
            tr = input.core_tr,
            select = function(spec) input.select(spec) end,
            busy = function() return fluent.modal_busy() end,
            back = function() reopen_menu() end,
        })
        if ok and type(ctl) == "table" then
            DISC.ctl = ctl
        else
            mp.msg.error("nanum-disc.lua: " .. tostring(ctl))
        end
    end
end

mp.add_key_binding(nil, "nanum-disc", function() if DISC.ctl then DISC.ctl.open() end end)

-- -> true if the failure was an encrypted-disc one and has been explained.
function DISC.on_play_error()
    local text, path = table.concat(DISC.log, "\n"), DISC.path
    DISC.log = {}
    return DISC.ctl ~= nil and DISC.ctl.on_play_error(path, text)
end

mp.register_event("start-file", function()
    DISC.log = {}
    DISC.path = mp.get_property("path")
end)
mp.register_event("log-message", disc_log)
end

----------------------------------------------------------------------------
-- AI component manager (Ctrl+N -> "AI 구성 요소 관리", or `script-binding nanum-models`):
-- Bundled CPU/CUDA engines, optional cuBLAS/reused CUDA Toolkit, and speech models.
-- Stays open while downloading; rows, percentages and the progress bar follow
-- user-data/nanum/models and user-data/nanum/accelerator in place (no reopening).
-- Closing it does not stop a download: progress continues in toasts / the status chip.
----------------------------------------------------------------------------

function AIM.open_dir(dir)
    if type(dir) ~= "string" or dir == "" then
        notify(input.core_tr("저장 위치를 알 수 없습니다"), 3, "warn")
        return
    end
    notify(dir, 5)
    if package.config:sub(1, 1) ~= "\\" then return end
    dir = (dir:gsub("/", "\\"))
    mp.command_native_async({ name = "subprocess", args = { "cmd", "/c", "mkdir", dir },
        playback_only = false, capture_stdout = true, capture_stderr = true }, function()
        mp.command_native_async({ name = "subprocess", args = { "explorer.exe", dir },
            playback_only = false, detach = true }, function() end)
    end)
end

-- A model that is already installed: keep it, or have the engine verify it again.
function AIM.open_reinstall(m)
    input.select({
        prompt = input.core_tr("이미 설치됨: %s", tostring(m.label or AIM.name(m.id))),
        items = { input.core_tr("유지"), input.core_tr("파일을 검증하고 필요하면 다시 내려받기") },
        submit = function(i)
            if i == 2 then AIM.download(m.id) end
        end,
        closed = function()
            if not fluent.modal_busy() then mp.add_timeout(0.1, AIM.open_menu) end
        end,
    })
end

function AIM.open_mode_menu()
    local items, default = {}, 1
    for i, m in ipairs(AIM.MODES) do
        items[i] = (m == AIM.mode() and "● " or "  ") .. input.core_tr(AIM.MODE_DESC[m])
        if m == AIM.mode() then default = i end
    end
    input.select({
        prompt = input.core_tr("AI 가속 모드 (다음에 여는 파일부터 적용):"),
        items = items,
        default_item = default,
        submit = function(i) AIM.set_mode(AIM.MODES[i]) end,
        closed = function()
            if not fluent.modal_busy() then mp.add_timeout(0.1, AIM.open_menu) end
        end,
    })
end

-- NVIDIA CUDA license: bundled as LICENSE-NVIDIA-CUDA.txt next to the player (and cached with the components).
function AIM.license_path()
    local utils = require 'mp.utils'
    local cands = {}
    local p = SUBS.yt.app_path("LICENSE-NVIDIA-CUDA.txt")
    if p ~= "" then cands[#cands + 1] = p end
    local a = AIM.acc
    if a and type(a.directory) == "string" and a.directory ~= "" then
        cands[#cands + 1] = a.directory .. "/LICENSE-NVIDIA-CUDA.txt"
    end
    for _, c in ipairs(cands) do
        if utils.file_info(c) then return c end
    end
    return nil
end

-- Accepted here once, or earlier: by the installer's CUDA task (it caches the license with the
-- components) or by a download that already happened.
function AIM.license_accepted()
    if opts.cuda_license then return true end
    local a = AIM.acc
    if not a then return false end
    for _, c in ipairs(AIM.acc_list()) do
        if c.installed == true and (c.source == "user" or c.source == "reused") then return true end
    end
    if type(a.directory) == "string" and a.directory ~= "" then
        return require('mp.utils').file_info(a.directory .. "/LICENSE-NVIDIA-CUDA.txt") ~= nil
    end
    return false
end

function AIM.open_license_file()
    local path = AIM.license_path()
    if not path then
        notify(input.core_tr("라이선스 파일을 찾을 수 없습니다 (앱 폴더의 LICENSE-NVIDIA-CUDA.txt)"), 5, "warn")
        return false
    end
    if package.config:sub(1, 1) == "\\" then path = (path:gsub("/", "\\")) end
    mp.command_native_async({ name = "subprocess", args = { "notepad.exe", path },
        playback_only = false, detach = true }, function() end)
    return true
end

-- Keep a copy of the accepted license next to the cached components (best effort).
function AIM.cache_license()
    local src, a = AIM.license_path(), AIM.acc
    if not (src and a and type(a.directory) == "string" and a.directory ~= "") then return end
    local dir = (a.directory:gsub("/", "\\"))
    mp.command_native({ name = "subprocess", args = { "cmd", "/c", "mkdir", dir }, playback_only = false })
    local f = io.open(src, "rb")
    if not f then return end
    local data = f:read("*a")
    f:close()
    local out = io.open(dir .. "\\LICENSE-NVIDIA-CUDA.txt", "wb")
    if out then
        out:write(data)
        out:close()
    end
end

function AIM.open_license_dialog()
    local t = mp.get_time()
    if t - (AIM.license_at or -10) < 0.5 then return end        -- double click
    AIM.license_at = t
    input.select({
        prompt = input.core_tr("NVIDIA CUDA 라이선스에 동의해야 내려받을 수 있습니다"),
        items = {
            input.core_tr("라이선스 보기 (LICENSE-NVIDIA-CUDA.txt)"),
            input.core_tr("동의하고 CUDA 구성 요소 내려받기 (%s)", AIM.fmt_size(AIM.acc_bytes())),
            input.core_tr("취소"),
        },
        default_item = 1,
        submit = function(i)
            if i == 1 then
                AIM.open_license_file()
                AIM.license_again = true
            elseif i == 2 then
                opts.cuda_license = true
                save_settings()
                AIM.cache_license()
                mp.add_timeout(0.1, AIM.acc_download)
            end
        end,
        closed = function()
            if AIM.license_again then
                AIM.license_again = false
                mp.add_timeout(0.3, AIM.open_license_dialog)
            elseif not fluent.modal_busy() then
                mp.add_timeout(0.1, AIM.open_menu)
            end
        end,
    })
end

-- No NVIDIA driver was detected: installing CUDA components is probably useless, ask first.
function AIM.open_nodriver_confirm()
    input.select({
        prompt = input.core_tr("NVIDIA 드라이버를 찾을 수 없습니다"),
        items = { input.core_tr("취소"), input.core_tr("그래도 CUDA 구성 요소 내려받기 (%s)", AIM.fmt_size(AIM.acc_bytes())) },
        submit = function(i)
            if i == 2 then AIM.acc_download() end
        end,
        closed = function()
            if not fluent.modal_busy() then mp.add_timeout(0.1, AIM.open_menu) end
        end,
    })
end

function AIM.cuda_row_value()
    local a = AIM.acc
    if a.cuda_available == true then
        if a.toolkit == true then return input.core_tr("사용 가능 · cuBLAS: CUDA Toolkit %s 사용", AIM.toolkit_label()) end
        return input.core_tr("사용 가능")
    end
    if AIM.engine_reinstall_needed() then return input.core_tr("앱의 CUDA 엔진 복구 필요 · NanumPlayer 재설치") end
    local cause = AIM.cuda_cause()
    if cause == "nodriver" then return input.core_tr("사용 불가 · NVIDIA 드라이버를 찾을 수 없음") end
    if cause == "nocatalog" then return input.core_tr("미설치 · 구성 요소 목록을 읽을 수 없음") end
    if cause == "missing" then return input.core_tr("미설치 · 내려받기 %s", AIM.fmt_size(AIM.acc_bytes())) end
    local r = tostring(a.reason or "")
    return input.core_tr("사용 불가 · %s", r ~= "" and r or input.core_tr("GPU/드라이버가 CUDA 13 엔진을 지원하지 않음"))
end

function AIM.build_menu()
    local items, actions, keys, progress = {}, {}, {}, {}
    local function add(key, text, fn)
        items[#items + 1] = text
        actions[#actions + 1] = fn
        keys[#keys + 1] = key
    end
    local d, a = AIM.data, AIM.acc
    add("status", input.core_tr("모델 상태: %s", AIM.status_text()), function()
        local cur = AIM.data
        if cur and cur.status == "error" and tostring(cur.error or "") ~= "" then
            notify(input.core_tr("AI 모델 오류: %s", cur.error), 9, "error")
        end
        AIM.refresh()
    end)
    add("acc_status", input.core_tr("가속기 상태: %s", AIM.acc_status_text()), function()
        local cur = AIM.acc
        if cur and cur.status == "error" and tostring(cur.error or "") ~= "" then
            notify(input.core_tr("CUDA 구성 요소 오류: %s", cur.error), 9, "error")
        end
        AIM.refresh()
    end)
    local custom = AIM.custom_dll()
    if custom then
        add("custom", input.core_tr("사용자 지정 AI DLL 사용 중: %s", custom), function()
            notify(input.core_tr("--nanum-ai-dll로 지정한 엔진을 그대로 사용합니다 (자동 교체 없음)"), 5)
        end)
    end
    add("accel_mode", input.core_tr(AIM.accel_opt_ok == false and "AI 가속 모드: %s (이 엔진은 적용 불가)" or "AI 가속 모드: %s", AIM.mode_text()),
        AIM.open_mode_menu)
    if a then
        local cpu_ok = a.cpu_available ~= false
        add("cpu", (cpu_ok and "● " or "  ") .. input.core_tr("CPU 엔진: %s", input.core_tr(cpu_ok and "사용 가능 (앱에 포함)"
            or "사용 불가 — nanum_ai_cpu.dll을 불러오지 못함")),
            function()
                if not cpu_ok then notify(input.core_tr("NanumPlayer를 다시 설치해 CPU 엔진을 복구하세요"), 5, "warn") end
                AIM.refresh()
            end)
        add("cuda", (a.cuda_available == true and "● " or "  ") .. input.core_tr("CUDA 가속: %s", AIM.cuda_row_value()), function()
            if a.cuda_available ~= true and AIM.cuda_cause() == "incompatible" then
                notify(input.core_tr("CUDA 구성 요소를 다시 받아도 해결되지 않습니다. 가속 모드를 자동/CPU만으로 쓰세요"), 6, "warn")
            end
            AIM.refresh()
        end)
        local missing = AIM.acc_missing()
        local cause = a.cuda_available ~= true and AIM.cuda_cause() or nil
        local val
        if AIM.acc_active() then
            val = input.core_tr("진행 중")
        elseif cause == "nocatalog" then
            val = input.core_tr("내려받기 불가 · 구성 요소 목록(catalog.json)을 읽을 수 없음")
        elseif cause == "bundled" then
            val = input.core_tr("앱의 CUDA 엔진 복구 필요 · NanumPlayer 재설치")
        elseif #missing > 0 or cause == "missing" then
            val = (#missing > 0 and input.core_tr("필요 %d개 · %s", #missing, AIM.fmt_size(AIM.acc_bytes()))
                or input.core_tr("필요 구성 요소 · %s", AIM.fmt_size(AIM.acc_bytes())))
                .. (cause == "nodriver" and (" " .. input.core_tr("(NVIDIA 드라이버 미감지)")) or "")
        elseif a.toolkit == true and a.cuda_available == true then
            val = input.core_tr("필요 없음 · CUDA Toolkit %s 사용", AIM.toolkit_label())
        elseif a.cuda_available == true then
            val = input.core_tr("설치됨 · 사용 가능")
        else
            val = input.core_tr("설치됨 · 이 PC에서는 사용 불가 (다시 받아도 해결되지 않음)")
        end
        add("acc_install", input.core_tr("cuBLAS 내려받기: %s", val), function()
            local cur = AIM.acc
            if not cur or AIM.acc_active() then
                if cur then notify(input.core_tr("이미 내려받는 중입니다"), 3, "warn") end
                return
            end
            local miss = AIM.acc_missing()
            local c = cur.cuda_available ~= true and AIM.cuda_cause() or nil
            if c == "bundled" then
                notify(AIM.toolkit_hint(), 7, "error")
                return
            end
            if #miss == 0 and c ~= "missing" and c ~= "nocatalog" then
                if cur.cuda_available == true then
                    notify(cur.toolkit == true and input.core_tr("CUDA 구성 요소가 이미 설치되어 있습니다 (cuBLAS는 CUDA Toolkit %s 사용)", AIM.toolkit_label())
                        or input.core_tr("CUDA 구성 요소가 이미 설치되어 있습니다"), 4, "ok")
                else
                    notify(input.core_tr("구성 요소는 설치되어 있지만 이 PC의 GPU/드라이버에서 CUDA를 쓸 수 없습니다. 다시 받아도 해결되지 않습니다"), 6, "warn")
                end
            elseif c == "nocatalog" then
                notify(input.core_tr("CUDA 구성 요소 목록(components\\catalog.json)을 읽을 수 없습니다%s\nNanumPlayer를 다시 설치하세요",
                    tostring(cur.catalog_error or "") ~= "" and (": " .. cur.catalog_error) or ""), 7, "warn")
            elseif c == "nodriver" then
                mp.add_timeout(0.1, AIM.open_nodriver_confirm)
            else
                AIM.acc_download()
            end
        end)
        if AIM.cublas_missing() or a.toolkit ~= true then
            add("license", input.core_tr("NVIDIA CUDA 라이선스 (cuBLAS 내려받기용): %s", input.core_tr(AIM.license_accepted() and "동의함 · 보기" or "동의 필요 · 보기")),
                AIM.open_license_file)
        end
        for _, c in ipairs(AIM.acc_list()) do
            local key = "acc_" .. tostring(c.id)
            local cval
            if AIM.acc_active() and a.current == c.id then
                if a.status == "verifying" then
                    cval = input.core_tr("무결성 검증 중")
                    progress[key] = 1
                else
                    local pct = AIM.acc_pct()
                    cval = input.core_tr("내려받는 중 %s · %s / %s", pct and (pct .. "%") or "…",
                        AIM.fmt_size(a.received), AIM.fmt_size(a.total))
                    progress[key] = AIM.acc_fraction() or 0
                end
            elseif c.installed then
                cval = (c.source == "toolkit" and input.core_tr("CUDA Toolkit %s 사용", AIM.toolkit_label()))
                    or input.core_tr("설치됨 · %s · %s", AIM.fmt_size(c.size),
                        AIM.COMP_SOURCE[c.source] and input.core_tr(AIM.COMP_SOURCE[c.source]) or tostring(c.source or ""))
            else
                cval = input.core_tr("미설치 · %s", AIM.fmt_size(c.size))
            end
            add(key, (c.installed and "● " or "  ") .. input.core_tr("%s: %s", tostring(c.label or AIM.acc_name(c.id)), cval), function()
                if c.installed then
                    notify(tostring(c.path or c.filename or ""), 5)
                else
                    AIM.acc_download()
                end
            end)
        end
        local tk = a.toolkit == true and type(a.toolkit_directory) == "string" and a.toolkit_directory ~= ""
        add("toolkit", (tk and "● " or "  ") .. (tk and input.core_tr("CUDA Toolkit %s: 감지 · %s", AIM.toolkit_label(), a.toolkit_directory)
            or input.core_tr("CUDA Toolkit 13: 설치되어 있지 않음 (설치하면 cuBLAS를 받지 않아도 GPU 사용)")), function()
            if tk then
                notify(input.core_tr("%s\n설치된 Toolkit은 읽기만 하며 변경하지 않습니다", a.toolkit_directory), 6)
            else
                notify(AIM.toolkit_hint() .. "\n" .. AIM.TOOLKIT_URL, 8)
                SUBS.open_url(AIM.TOOLKIT_URL)
            end
        end)
    else
        add("acc_unknown", input.core_tr("CPU / CUDA 가속 정보: %s", AIM.acc_cmd_ok == false and input.core_tr("이 엔진 버전은 지원하지 않음 (nanum 갱신 필요)")
            or input.core_tr("확인 중…")), function() AIM.refresh() end)
    end
    if d then
        local miss, bytes = AIM.missing(), 0
        for _, m in ipairs(miss) do bytes = bytes + (tonumber(m.size) or 0) end
        local all_val = AIM.active() and input.core_tr("진행 중")
            or (#miss == 0 and input.core_tr("모두 설치됨") or input.core_tr("미설치 %d개 · %s", #miss, AIM.fmt_size(bytes)))
        add("all", input.core_tr("모든 모델 내려받기: %s", all_val), function()
            if not AIM.active() and #AIM.missing() == 0 then
                notify(input.core_tr("모든 모델이 이미 설치되어 있습니다"), 3, "ok")
            else
                AIM.download("all")
            end
        end)
        local vad = AIM.by_id("vad")
        for _, m in ipairs(AIM.list()) do
            local val
            if AIM.active() and d.current == m.id then
                if d.status == "verifying" then
                    val = input.core_tr("무결성 검증 중")
                    progress[m.id] = 1
                else
                    local pct = AIM.pct()
                    val = input.core_tr("내려받는 중 %s · %s / %s", pct and (pct .. "%") or "…",
                        AIM.fmt_size(d.received), AIM.fmt_size(d.total))
                    progress[m.id] = AIM.fraction() or 0
                end
            elseif m.installed then
                val = input.core_tr("설치됨 · %s", AIM.fmt_size(m.size))
            else
                local size, with_vad = tonumber(m.size) or 0, false
                if m.id ~= "vad" and vad and vad.installed ~= true then
                    size = size + (tonumber(vad.size) or 0)
                    with_vad = true
                end
                val = input.core_tr(with_vad and "미설치 · %s (VAD 포함)" or "미설치 · %s", AIM.fmt_size(size))
            end
            add(m.id, (m.installed and "● " or "  ") .. input.core_tr("%s: %s", tostring(m.label or m.id)
                .. (AIM.OPTIONAL[m.id] and (" " .. input.core_tr("(선택)")) or ""), val), function()
                if m.installed and not (AIM.active() and AIM.data.current == m.id) then
                    AIM.open_reinstall(m)
                else
                    AIM.download(m.id)
                end
            end)
        end
    end
    add("cancel", input.core_tr("내려받기 취소: %s", input.core_tr(AIM.any_active() and "진행 중인 작업 중단" or "진행 중인 작업 없음")), AIM.cancel)
    if d then
        add("dir", input.core_tr("모델 저장 위치: %s", (type(d.directory) == "string" and d.directory ~= "") and d.directory or input.core_tr("(알 수 없음)")),
            function() AIM.open_dir(AIM.data and AIM.data.directory) end)
    end
    if a and type(a.directory) == "string" and a.directory ~= "" then
        add("acc_dir", input.core_tr("CUDA 구성 요소 저장 위치: %s", a.directory), function() AIM.open_dir(AIM.acc and AIM.acc.directory) end)
    end
    add("refresh", input.core_tr("설치 상태 새로 확인: 파일 검사"), function()
        AIM.refresh()
        notify(input.core_tr("설치 상태를 확인합니다"), 2)
    end)
    add("prompt", input.core_tr("모델 없음 안내 팝업: %s", input.core_tr(opts.model_prompt and "켬" or "끔")), function()
        opts.model_prompt = not opts.model_prompt
        save_settings()
        AIM.update_menu()
    end)
    add("accel_prompt", input.core_tr("CUDA/엔진 안내 팝업: %s", input.core_tr(opts.accel_prompt and "켬" or "끔")), function()
        opts.accel_prompt = not opts.accel_prompt
        save_settings()
        AIM.update_menu()
    end)
    add("back", input.core_tr("설정 메뉴로 돌아가기"), function()
        menu_keep = true
        mp.add_timeout(0.1, open_menu)
    end)
    return items, actions, keys, progress
end

function AIM.update_menu()
    if fluent.open_id() ~= "nanum-models" then return end
    local items, actions, keys, progress = AIM.build_menu()
    AIM.menu.actions, AIM.menu.keys = actions, keys
    fluent.update_select("nanum-models", items, { keys = keys, progress = progress })
end

-- Events arrive often while downloading: coalesce into <= 5 redraws/s.
function AIM.schedule_menu_update()
    if AIM.update_timer then return end
    AIM.update_timer = mp.add_timeout(0.2, function()
        AIM.update_timer = nil
        AIM.update_menu()
        update_settings_menu()
    end)
end

function AIM.open_menu()
    AIM.refresh()
    local items, actions, keys, progress = AIM.build_menu()
    AIM.menu.actions, AIM.menu.keys = actions, keys
    -- start on what needs attention: missing speech models, else the engine choice
    local want = "accel_mode"
    if #AIM.missing() > 0 then want = "all" end
    local default = 1
    for i, k in ipairs(keys) do
        if k == want then default = i end
    end
    input.select({
        id = "nanum-models",
        prompt = input.core_tr("AI 구성 요소 관리:"),
        style = "settings",
        marks = true,
        keep_open = true,
        items = items,
        keys = keys,
        progress = progress,
        default_item = default,
        submit = function(i)
            local fn = AIM.menu.actions[i]
            if fn then fn() end
        end,
    })
end

mp.add_key_binding(nil, "nanum-models", AIM.open_menu)
mp.observe_property("user-data/nanum/models", "native", AIM.on_change)
mp.observe_property("user-data/nanum/accelerator", "native", AIM.on_acc_change)
mp.add_periodic_timer(1, AIM.heartbeat)
AIM.refresh()

----------------------------------------------------------------------------
-- Native Blu-ray/DVD ripping. The module uses in-process commands and receives
-- progress through user-data/nanum/rip; Ctrl+B opens the drive/title picker.
----------------------------------------------------------------------------
;(function() -- Keep loader locals outside the main chunk's 200-local limit.
    -- This build does not expand ~~exe_dir, and a single-file script has no
    -- script directory. The module sits next to this file.
    local script = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local dir = script:match("^(.*)[/\\]")
    local f = dir and loadfile(dir .. "/nanum-rip.lua")
    if f then
        local okr, RIP = pcall(f)
        if okr and type(RIP) == "table" then
            RIP.mount({
                notify = notify,
                select = function(prompt, items, on_submit)
                    local texts, values = {}, {}
                    for i, it in ipairs(items) do
                        texts[i], values[i] = it.text, it.value
                    end
                    input.select({
                        id = "nanum-rip", prompt = prompt, items = texts,
                        submit = function(i) on_submit(values[i]) end,
                    })
                end,
            })
        else
            mp.msg.error("nanum-rip.lua: " .. tostring(RIP))
        end
    end
end)()

-- A live interface-language change: an open panel still shows the old language, so it is closed and the same
-- panel is opened again; the status chip and the AI tags are recomputed.
input.i18n.on_change(function()
    local id = fluent.open_id()
    if id then input.terminate() end
    last_status = nil
    TAGS.sig = nil
    TAGS.update()
    PIC.publish()
    publish_status()
    local reopen = ({
        ["nanum-settings"] = open_menu,
        ["nanum-models"] = AIM.open_menu,
        ["nanum-youtube"] = SUBS.yt.open_menu,
        ["nanum-glossary"] = function() open_glossary_menu() end,
        ["nanum-subtitles"] = function() if SUBS.ux then SUBS.ux.open() end end,
        ["nanum-picture"] = function() PIC.reopen() end,
        ["nanum-picture-detail"] = function() PIC.open_detail() end,
    })[id]
    if reopen then mp.add_timeout(0.2, reopen) end
end)

-- Test hook (throwaway scripts run through mpv).
if rawget(_G, "NANUM_TEST") then
    _G.NANUM_TEST = {
        norm_lang = norm_lang, select_input = select_input, usable_sub = usable_sub,
        audio_language = audio_language, parse_omp_models = parse_omp_models,
        full_status_text = full_status_text, track_label = track_label,
        open_input_menu = open_input_menu, open_omp_picker = open_omp_picker, reevaluate = reevaluate,
        library_action = library_action, build_library_prompt = build_library_prompt,
        build_audio_prompt = build_audio_prompt, on_library = on_library, open_menu = open_menu,
        set_display = set_display, pin_audio = pin_audio, ai_audio_language = ai_audio_language,
        ai_role = ai_role, refresh_ai_ids = refresh_ai_ids, secondary_text = secondary_text,
        original_text = original_text, glossary_clean = glossary_clean, sanitize_name = sanitize_name,
        compute_status = compute_status, style_label = style_label, AIM = AIM, SUBS = SUBS, TAGS = TAGS,
        glossary_parse = glossary_parse, glossary_format = glossary_format, glossary_related = glossary_related,
        glossary_entry_parse = glossary_entry_parse, glossary_apply_text = glossary_apply_text,
        set_style = set_style, set_secondary = set_secondary, edit_glossary = edit_glossary,
        override_set_opt_soft = function(f) set_opt_soft = f end,
        regenerate_glossary = regenerate_glossary, open_glossary_menu = open_glossary_menu,
        open_style_menu = open_style_menu,
        -- pretend a file is playing and the player published this demuxer-cache-state
        fake_playback = function(st)
            cache_state = function() return st end
            local real_refresh = refresh_ai_ids
            refresh_ai_ids = function() return real_refresh(st) end
            file_active, file_loaded = true, true
            on_cache_state(nil, st)
        end,
        opts = opts,
    }
end
