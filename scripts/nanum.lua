-- NanumPlayer control script.
--
--  * Pre-roll: pauses at start (and after seeks) until the AI engine has
--    recognised and translated enough audio ahead of the playback position.
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
--   seek_preroll  same, after a seek or track change (0: off)
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

local mp = require 'mp'
local options = require 'mp.options'

-- Fluent UI supplies the select/get popup API.
local function load_fluent()
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
        if f then
            local okf, mod = pcall(f)
            if okf and type(mod) == "table" then return mod end
            mp.msg.error("fluent-input.lua: " .. tostring(mod))
        end
    end
    return nil
end
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
    seek_preroll = 8,
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
    library_auto_use = false,
    model_prompt = true,
    accel_prompt = true,
    cuda_license = false,
    cuda_update_prompted = "",      -- app version for which the "CUDA engine update" prompt was shown
    acceleration = "auto",
    translate_style = "natural",
    translate_style_text = "",
    secondary = true,
    pgs = true,
    downloads_dir = "",
}
options.read_options(opts, "nanum")
if opts.input_mode ~= "stt" then opts.input_mode = "auto" end
if opts.full_engine ~= "omp" then opts.full_engine = "ollama" end
if opts.display ~= "bilingual" and opts.display ~= "source" then opts.display = "translation" end
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

local FULL_TITLE = "ko (AI full)"

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
    if t.title == FULL_TITLE then return "full" end
    local s = t["src-id"]
    if t.external or type(s) ~= "number" then return nil end
    if s == ai_ids.primary then return "primary" end
    if s == ai_ids.secondary then return "secondary" end
    if s == ai_ids.pgs then return "pgs" end
    if s == ai_ids.import then return "import" end
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

-- Korean language name of an ISO code (nil if unknown/empty).
local function lang_ko(l)
    l = norm_lang(l)
    return l and (LANG_KO[l] or l) or nil
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
    if t.external then parts[#parts + 1] = "[외부]" end
    return table.concat(parts, " ")
end

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

local waiting = nil         -- active pre-roll: {timer=, deadline=}
local we_paused = false     -- we paused playback for the pre-roll
local resuming = false      -- ignore the pause change caused by our own resume
local file_started = false  -- first playback-restart of the file seen
local selected_once = false
local last_aid = nil
local file_loaded = false

local sel_mode = opts.input_mode    -- "auto" | "stt" | "track" (session only)
local sel_track_id = nil
local hint_until = nil
local hint_shown = false
local HINT = "Ctrl+N: AI 자막 설정"

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
    if hint_until and mp.get_time() < hint_until then return HINT end
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
                local msg = string.format("AI 자막 준비 중... %.0f / %d초", have, lead)
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
    if not t.selected then mp.set_property_number("sid", t.id) end
end

local function select_full_track(path)
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "sub" and t.title == FULL_TITLE and t["external-filename"] == path then
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
    if s == "scanning" then return string.format("전체 번역: 원문 수집 중 %d%%", pct) end
    if s == "translating" then return string.format("전체 번역: 번역 중 %d%%", pct) end
    if s == "done" then return "전체 번역: 완료" end
    if s == "error" then
        local e = st["nanum-full-error"]
        return "전체 번역 오류" .. ((e and e ~= "") and (": " .. e) or "")
    end
    return nil
end

----------------------------------------------------------------------------
-- Saved library: prompts, actions, state
----------------------------------------------------------------------------

local function lib_key()
    return lib.sid ~= "" and lib.sid or "-"
end

local function lib_supported()
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
        notify("이 엔진 버전은 저장 자막 라이브러리를 지원하지 않습니다 (nanum 갱신 필요)", 4, "error")
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
    notify(messages[action] or action, 3)
    local function finish()
        lib_action_timer = nil
        if action ~= "ask" and not set_opt_soft("nanum-library-action", action) then
            notify("저장 자막 작업을 시작하지 못했습니다 (nanum 갱신 필요)", 4, "error")
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
        if action ~= "disable" then
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
    local s = "저장 자막: " .. (LIB_STATE_TEXT[lib.state] or lib.state)
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
        add("저장된 번역 사용", function() library_action("use") end)
        add("저장된 번역 사용 + 이 선택 기억 (다음부터 묻지 않음)", function()
            set_auto_use(true)
            library_action("use")
        end)
    end
    if lib.has_source then
        add("저장된 원문으로 다시 번역", function() library_action("retranslate", { keep_full = true }) end)
    end
    add("음성 인식부터 새로 생성", function() library_action("regenerate", { keep_full = true }) end)
    add("이 파일은 AI 자막 사용 안 함", function() library_action("disable") end)
    local chosen = false
    return {
        prompt = "저장된 AI 자막이 있습니다" .. (lib.summary ~= "" and (" (" .. lib.summary .. ")") or "") .. ":",
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
                notify("저장된 자막은 사용하지 않았습니다 (Ctrl+N 에서 선택 가능)", 4)
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
    return {
        prompt = "재생 음성이 AI 입력 음성과 다릅니다:",
        items = {
            "유지 — AI 자막은 기존 입력 유지 (" .. audio_label(old) .. ")",
            "현재 음성 (" .. audio_label(cur) .. ") 으로 AI 자막 새로 생성",
            "현재 음성의 저장된 AI 자막 사용 (조회)",
        },
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
    elseif ls == "none" then
        local p = pending_saved
        if p and (lib.sid ~= p.old_sid or p.saw_loading) then
            pending_saved = nil
            notify("현재 음성에 저장된 AI 자막이 없어 새로 생성합니다", 4, "warn")
        end
    elseif ls == "using" then
        if prev ~= "using" then
            notify("저장된 AI 자막 사용 중" .. (lib.summary ~= "" and (": " .. lib.summary) or ""), 3, "ok")
        end
    elseif ls == "error" then
        pending_saved = nil
        if lib_error_shown ~= lib.error then
            lib_error_shown = lib.error
            local hint = lib.has_source and "\nCtrl+N → 저장된 원문으로 다시 번역"
                or "\nCtrl+N → 저장 자막 다시 조회 / 새로 생성"
            notify("AI 자막 라이브러리 오류" .. (lib.error ~= "" and (": " .. lib.error) or "") .. hint, 7, "error")
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
    return MODEL_SHORT[id] or tostring(id or "")
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
    return { "vad", (lang == nil or lang == "en") and "english" or "multilingual" }
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
        notify("AI 모델을 내려받는 중입니다 · 재생은 그대로 진행되며 완료 후 다음에 여는 파일부터 AI 자막이 켜집니다", 6, "busy")
        return
    end
    local names = {}
    for _, id in ipairs(info or {}) do names[#names + 1] = AIM.name(id) end
    notify("AI 모델 없음 (" .. table.concat(names, " · ") .. ") — 음성 자막 없이 재생합니다\nCtrl+N → AI 구성 요소에서 모델을 내려받을 수 있습니다", 8, "warn")
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
        notify("이미 내려받는 중입니다 — 끝나거나 취소한 뒤 다시 선택하세요", 4, "warn")
        return false
    end
    if not mp.commandv("nanum-download-models", which) then
        notify(AIM.data and "내려받기를 시작하지 못했습니다 (다른 작업이 진행 중일 수 있습니다)"
            or "이 엔진 버전은 모델 내려받기를 지원하지 않습니다 (nanum 갱신 필요)", 5, "error")
        return false
    end
    AIM.toast_at = 0
    notify(which == "all" and "AI 모델 내려받기를 시작합니다 (VAD · 영어 · 다국어)"
        or (AIM.name(which) .. " 모델 내려받기를 시작합니다" .. (which ~= "vad" and " (VAD 포함)" or "")),
        4, "busy", "model-dl")
    return true
end

function AIM.cancel()
    if AIM.active() then
        mp.commandv("nanum-cancel-model-download")
        notify("내려받기를 취소하는 중...", 3, "busy", "model-dl")
    elseif AIM.acc_active() then
        mp.commandv("nanum-cancel-accelerator-download")
        notify("CUDA 구성 요소 내려받기를 취소하는 중...", 3, "busy", "accel-dl")
    else
        notify("진행 중인 내려받기가 없습니다", 3)
    end
end

function AIM.progress_text()
    local d = AIM.data
    if not d then return nil end
    local name = AIM.name(d.current)
    if d.status == "verifying" then return name .. " 무결성 검증 중" end
    local s = name .. " 내려받는 중"
    local pct = AIM.pct()
    if pct then
        s = s .. string.format(" %d%% (%s / %s)", pct, AIM.fmt_size(d.received), AIM.fmt_size(d.total))
    end
    return s
end

function AIM.status_text()
    local d = AIM.data
    if not d then
        return AIM.cmd_ok == false and "이 엔진 버전은 모델 관리를 지원하지 않습니다" or "확인 중…"
    end
    local s = d.status
    if s == "downloading" or s == "verifying" then return AIM.progress_text() end
    if s == "checking" then return "설치된 파일 확인 중…" end
    if s == "done" then return "내려받기 완료 · 다음에 여는 파일부터 사용" end
    if s == "cancelled" then return "취소됨" end
    if s == "error" then
        local e = tostring(d.error or "")
        return "오류 — " .. (e ~= "" and e or "알 수 없는 오류")
    end
    if #AIM.list() > 0 and #AIM.missing() == 0 then return "모든 모델 설치됨" end
    return "대기 중"
end

-- Short form for the settings menu row.
function AIM.summary()
    local d = AIM.data
    if not d then return AIM.cmd_ok == false and "지원 안 됨" or "확인 중…" end
    if AIM.active() then
        local pct = AIM.pct()
        return AIM.name(d.current) .. (d.status == "verifying" and " 검증 중" or " 내려받는 중")
            .. (pct and (" " .. pct .. "%") or "")
    end
    if #AIM.list() == 0 then return "목록 없음" end
    local miss, bytes = AIM.missing(), 0
    if #miss == 0 then return "모두 설치됨" end
    for _, m in ipairs(miss) do bytes = bytes + (tonumber(m.size) or 0) end
    return string.format("미설치 %d개 · %s", #miss, AIM.fmt_size(bytes))
end

-- Progress toast that survives closing the menu: refreshed when the text
-- changed (at most once per second) and at least every 3 seconds.
function AIM.heartbeat()
    local text, id
    if AIM.active() then
        text, id = "AI 모델 " .. AIM.progress_text(), "model-dl"
    elseif AIM.acc_active() then
        text, id = "CUDA 구성 요소 " .. AIM.acc_progress_text(), "accel-dl"
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
            notify("AI 모델 내려받기 완료 · 다음에 여는 파일부터 AI 자막을 만듭니다", 6, "ok", "model-dl")
        elseif d.status == "error" then
            local e = tostring(d.error or "")
            notify("AI 모델 내려받기 실패" .. (e ~= "" and (": " .. e) or "")
                .. "\nCtrl+N → AI 구성 요소에서 다시 시도할 수 있습니다", 9, "error", "model-dl")
        elseif d.status == "cancelled" then
            notify("AI 모델 내려받기를 취소했습니다", 3, "info", "model-dl")
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
        prompt = "AI 모델 없음",
        items = {
            "AI 구성 요소 관리 열기",
            "미설치 모델 모두 내려받기 (" .. AIM.fmt_size(bytes) .. ")",
            "나중에",
            "다시 묻지 않음",
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
-- AI engine: CPU (bundled) and CUDA (optional download)
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
AIM.COMP_SOURCE = { user = "내려받은 파일", reused = "이전 버전에서 복사", toolkit = "CUDA Toolkit 사용", app = "앱 폴더" }
AIM.TOOLKIT_URL = "https://developer.nvidia.com/cuda-downloads"

-- "v13.4" of the installed CUDA Toolkit, "" if unknown.
function AIM.toolkit_label()
    local a = AIM.acc
    local v = a and tostring(a.toolkit_version or "") or ""
    if v == "" and a then v = tostring(a.toolkit_directory or ""):match("[\\/][vV](%d+%.%d+)[\\/]") or "" end
    return v ~= "" and ("v" .. v) or ""
end

-- Components the CUDA path still needs: the engine (optional download) and the cuBLAS runtimes (an installed
-- CUDA 13 Toolkit provides them without a download, else the cuBLAS download). -> engine bytes | nil, cuBLAS bytes | nil
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
    if engine and runtimes then
        return "CUDA 엔진(약 " .. AIM.fmt_size(engine) .. ")과 cuBLAS(약 " .. AIM.fmt_size(runtimes)
            .. ")를 받으면 GPU를 사용합니다 (CUDA 13 Toolkit이 있으면 엔진만)"
    elseif engine then
        return "CUDA 엔진(약 " .. AIM.fmt_size(engine) .. ")을 받으면 GPU를 사용합니다"
    end
    return "CUDA 13 Toolkit을 설치하면 다운로드 없이 GPU를 사용합니다 (또는 cuBLAS 약 "
        .. AIM.fmt_size(runtimes or AIM.acc_bytes()) .. " 받기)"
end

-- The player's own notice for "CPU only, GPU would work after a download / the Toolkit" (auto mode) or
-- "engine update needed", else nil.
function AIM.acc_notice()
    local a = AIM.acc
    local r = a and tostring(a.reason or "") or ""
    if a and a.cuda_available ~= true and a.busy ~= true and AIM.mode() == "auto" and not AIM.custom_dll()
        and (r:find("^CUDA 가속:") or r:find("^CUDA 엔진 업데이트 필요")) then
        return r
    end
    return nil
end

-- A CUDA engine exists but is not this version's and no verified copy could be migrated.
function AIM.cuda_update_needed()
    local a = AIM.acc
    return a ~= nil and a.update_required == true and AIM.mode() ~= "cpu" and not AIM.custom_dll()
end

function AIM.mode()
    return session_accel or opts.acceleration
end

function AIM.mode_text()
    local s = AIM.MODE_DESC[AIM.mode()] or AIM.mode()
    if session_accel then s = s .. " [명령줄 지정]" end
    return s
end

function AIM.acc_name(id)
    return AIM.COMP_NAME[id] or tostring(id or "")
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
        if c.installed ~= true then r[#r + 1] = c end
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

-- Why CUDA is not usable: "nodriver" | "missing" (engine and / or cuBLAS not downloaded, no Toolkit) |
-- "nocatalog" | "incompatible" (installed but the GPU/driver is not suitable).
function AIM.cuda_cause()
    local a = AIM.acc
    if not AIM.has_driver() then return "nodriver" end
    local listed = #AIM.acc_list() > 0
    local needs = (listed and #AIM.acc_missing() > 0) or (not listed and (tonumber(a and a.download_size) or 0) > 0)
    -- the shipped component catalogue is unreadable: nothing can be downloaded
    if a and a.catalog == false and (needs or not listed) then return "nocatalog" end
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
            and "Ctrl+N → AI 구성 요소에서 '자동' 모드로 바꾸면 CUDA로 만들 수 있습니다"
            or "NanumPlayer를 다시 설치하세요 (nanum_ai_cpu.dll 확인)"
        return "CPU AI 엔진을 사용할 수 없어 AI 자막 없이 재생합니다" .. rs .. "\n" .. tail
    end
    if info.cause == "engine" then
        return "AI 엔진을 사용할 수 없어 AI 자막 없이 재생합니다" .. rs
            .. ((info.mode == "cuda" and info.cpu) and "\nCtrl+N → AI 구성 요소에서 CPU 모드로 바꿀 수 있습니다" or "")
    end
    local head = info.mode == "cuda" and "CUDA 필수 모드: " or "사용할 AI 엔진이 없습니다 (CPU 엔진 불가) · "
    local alt = info.cpu and "\nCtrl+N → AI 구성 요소에서 CPU 모드로 바꿀 수 있습니다" or ""
    if info.cause == "nodriver" then
        return head .. "NVIDIA 드라이버를 찾을 수 없어 CUDA를 쓸 수 없습니다 — AI 자막 없이 재생합니다\nNVIDIA 드라이버를 설치하세요" .. alt
    elseif info.cause == "nocatalog" then
        return head .. "CUDA 구성 요소 목록(components\\catalog.json)을 읽을 수 없어 내려받을 수 없습니다"
            .. ((info.catalog_error or "") ~= "" and (" (" .. info.catalog_error .. ")") or "")
            .. " — AI 자막 없이 재생합니다\nNanumPlayer를 다시 설치하세요" .. alt
    elseif info.cause == "missing" then
        return head .. AIM.toolkit_hint() .. " — AI 자막 없이 재생합니다\nCtrl+N → AI 구성 요소에서 받을 수 있습니다"
            .. (info.cpu and " (또는 CPU 모드로 바꾸세요)" or "")
    end
    return head .. "이 PC의 GPU/드라이버에서는 CUDA를 사용할 수 없습니다" .. rs
        .. " — AI 자막 없이 재생합니다\n구성 요소를 다시 받아도 해결되지 않습니다" .. alt
end

function AIM.note_accel_blocked(info)
    AIM.file_accel = AIM.file_accel or info
    publish_status()
    if AIM.notified_accel then return end
    AIM.notified_accel = true
    if AIM.acc_active() then
        notify("CUDA 구성 요소를 내려받는 중입니다 · 재생은 그대로 진행되며 완료 후 다음에 여는 파일부터 적용됩니다", 6, "busy")
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
        notify("GPU 가속 없이 CPU로 AI 자막을 만듭니다\n" .. AIM.toolkit_hint(), 8, "info")
    else
        AIM.fallback_noted = true
        local r = tostring(a.reason or "")
        notify("이 PC에서는 CUDA를 사용할 수 없어 CPU로 AI 자막을 만듭니다" .. (r ~= "" and (": " .. r) or "")
            .. "\n구성 요소를 다시 받아도 해결되지 않습니다", 8, "warn")
    end
end

function AIM.set_mode(mode)
    session_accel = nil
    opts.acceleration = mode
    save_settings()
    if set_opt_soft("nanum-acceleration", mode) then
        AIM.accel_opt_ok = true
        notify("AI 가속 모드: " .. AIM.MODE_LABEL[mode] .. " · 다음에 여는 파일부터 적용", 4, "ok")
    else
        AIM.accel_opt_ok = false
        notify("이 엔진 버전은 가속 모드 선택을 지원하지 않습니다 (nanum 갱신 필요)", 5, "error")
    end
    mp.commandv("nanum-accelerator-refresh")
    publish_status()
    AIM.schedule_menu_update()
end

function AIM.acc_download()
    if AIM.cublas_missing() and not AIM.license_accepted() then      -- the NVIDIA CUDA license comes before the cuBLAS download
        mp.add_timeout(0.1, AIM.open_license_dialog)
        return false
    end
    local t = mp.get_time()
    if t - AIM.last_cmd < 0.7 then return false end        -- double click
    AIM.last_cmd = t
    if AIM.any_active() then
        notify("이미 내려받는 중입니다 — 끝나거나 취소한 뒤 다시 선택하세요", 4, "warn")
        return false
    end
    if AIM.acc and AIM.acc.catalog == false and AIM.cuda_cause() == "nocatalog" then
        notify("CUDA 구성 요소 목록을 읽을 수 없어 내려받을 수 없습니다 — NanumPlayer를 다시 설치하세요", 6, "warn")
        return false
    end
    if not mp.commandv("nanum-download-accelerator") then
        notify(AIM.acc and "내려받기를 시작하지 못했습니다 (다른 작업이 진행 중일 수 있습니다)"
            or "이 엔진 버전은 CUDA 가속 내려받기를 지원하지 않습니다 (nanum 갱신 필요)", 5, "error")
        return false
    end
    AIM.toast_at = 0
    notify("CUDA 가속 구성 요소 " .. (AIM.cuda_update_needed() and "업데이트를" or "내려받기를") .. " 시작합니다 (" .. AIM.fmt_size(AIM.acc_bytes()) .. ")", 4, "busy", "accel-dl")
    return true
end

function AIM.acc_progress_text()
    local a = AIM.acc
    if not a then return nil end
    local name = AIM.acc_name(a.current)
    if a.status == "verifying" then return name .. " 무결성 검증 중" end
    local s = name .. " 내려받는 중"
    local pct = AIM.acc_pct()
    if pct then
        s = s .. string.format(" %d%% (%s / %s)", pct, AIM.fmt_size(a.received), AIM.fmt_size(a.total))
    end
    return s
end

function AIM.acc_status_text()
    local a = AIM.acc
    if not a then
        return AIM.acc_cmd_ok == false and "이 엔진 버전은 CUDA 가속 관리를 지원하지 않습니다" or "확인 중…"
    end
    local s = a.status
    if s == "downloading" or s == "verifying" then return AIM.acc_progress_text() end
    if s == "checking" then return "구성 요소 확인 중…" end
    if s == "cancelled" then return "취소됨" end
    if s == "error" then
        local e = tostring(a.error or "")
        return "오류 — " .. (e ~= "" and e or "알 수 없는 오류")
    end
    if s == "done" then
        if a.cuda_available == true then return "내려받기 완료 · 다음에 여는 파일부터 GPU 사용" end
        return "내려받기 완료 · 그러나 이 PC에서는 CUDA를 쓸 수 없음"
    end
    if AIM.cuda_update_needed() then return (AIM.acc_notice() or "CUDA 엔진 업데이트 필요") .. " — 눌러서 내려받기" end
    local eff = AIM.effective(AIM.mode())
    if eff == "cuda" then return "다음 파일: CUDA(GPU)로 AI 자막" end
    if eff == "cpu" then return "다음 파일: CPU로 AI 자막" .. (AIM.acc_notice() and (" · " .. AIM.acc_notice()) or "") end
    return "다음 파일: AI 자막 사용 불가 (선택한 엔진 없음)"
end

function AIM.components_summary()
    local models = AIM.summary()
    if AIM.acc_active() then
        local pct = AIM.acc_pct()
        return "CUDA " .. AIM.acc_name(AIM.acc.current) .. (pct and (" " .. pct .. "%") or " 내려받는 중")
    end
    return "가속 " .. (AIM.MODE_LABEL[AIM.mode()] or AIM.mode()) .. " · " .. models
end

-- Once per app version: offer the engine for this version.
function AIM.build_cuda_update_prompt()
    if not AIM.cuda_update_needed() or AIM.acc.busy == true or AIM.any_active() then return nil end
    return {
        prompt = "새 버전용 CUDA 엔진을 받아야 GPU 가속을 계속 사용합니다 (약 " .. AIM.fmt_size(AIM.acc_bytes()) .. ")",
        items = { "받기", "나중에" },
        default_item = 1,
        submit = function(i)
            if i == 1 then AIM.acc_download() end
        end,
    }
end

function AIM.maybe_prompt_cuda_update()
    local a = AIM.acc
    if not (AIM.cuda_update_needed() and a.busy ~= true) then return end
    local version = tostring(a.version or "")
    if version == "" or opts.cuda_update_prompted == version then return end
    opts.cuda_update_prompted = version
    save_settings()
    queue_prompt("cudaupdate", AIM.build_cuda_update_prompt)
    mp.add_timeout(1.5, pump_prompts)
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
            notify("CUDA 구성 요소 내려받기 실패" .. (e ~= "" and (": " .. e) or "")
                .. "\nCtrl+N → AI 구성 요소에서 다시 시도할 수 있습니다 (받은 파일은 유지됩니다)", 9, "error", "accel-dl")
        elseif d.status == "cancelled" then
            notify("CUDA 구성 요소 내려받기를 취소했습니다 (받은 파일은 유지됩니다)", 3, "info", "accel-dl")
        end
    end
    if d then
        AIM.heartbeat()
        AIM.note_fallback()
        AIM.maybe_prompt_cuda_update()
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
        local s = "CUDA 가속 구성 요소 설치 완료 · 다음에 여는 파일부터 적용됩니다"
        if mode == "cpu" then s = s .. "\n현재 가속 모드는 'CPU만'입니다 — Ctrl+N → AI 구성 요소에서 바꿀 수 있습니다" end
        notify(s, 7, "ok", "accel-dl")
    else
        local r = tostring(a.reason or "")
        local s = "CUDA 구성 요소를 설치했지만 이 PC에서는 CUDA를 사용할 수 없습니다" .. (r ~= "" and (": " .. r) or "")
        if mode == "cuda" then
            s = s .. "\nCUDA 필수 모드에서는 AI 자막이 꺼집니다 — Ctrl+N → AI 구성 요소에서 CPU 모드로 바꾸세요"
        else
            s = s .. "\nCPU로 계속 사용합니다"
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
        add("CUDA 가속 구성 요소 내려받기 (" .. AIM.fmt_size(info.size) .. ")", function() AIM.acc_download() end)
        if AIM.cublas_missing() then
            add("CUDA 13 Toolkit 받는 곳 열기 (설치하면 cuBLAS 다운로드 불필요)", function() SUBS.open_url(AIM.TOOLKIT_URL) end)
        end
    end
    if info.mode == "cuda" and info.cpu then
        add("CPU 모드로 전환 (다음 파일부터)", function() AIM.set_mode("cpu") end)
    end
    add("AI 구성 요소 관리 열기", function() mp.add_timeout(0.1, AIM.open_menu) end)
    add("나중에", function() end)
    add("다시 묻지 않음", function()
        opts.accel_prompt = false
        save_settings()
    end)
    return {
        prompt = info.mode == "cuda" and "CUDA를 사용할 수 없음" or "GPU 가속 구성 요소가 필요합니다",
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
        if t.type == "sub" and t.title == FULL_TITLE and t["external-filename"] == path then return t end
    end
    return nil
end

-- Drop superseded full tracks once the current one is loaded.
local function prune_full_tracks()
    local keep = applied_path and find_full_track(applied_path)
    if not keep then return end
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "sub" and t.title == FULL_TITLE and t.id ~= keep.id and not t.selected then
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
        mp.commandv("sub-add", path, select and "select" or "auto", FULL_TITLE, "ko")
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
        if ahead and ahead > 1 then return string.format("%s 준비 중 · %.0f초 앞", label, ahead) end
        return label .. " 분석 중"
    end
    if running_only then return nil end
    if s == "waiting" then return label .. " 대기 중 (기본 자막이 앞서가면 시작)" end
    if s == "done" then return label .. " 준비 완료" end
    if s == "unavailable" then
        local why = tostring(st["nanum-" .. key .. "-reason"] or "")
        return label .. " 사용 불가" .. (why ~= "" and (" (" .. why .. ")") or "")
    end
    return nil
end

-- Secondary (original-language audio) input.
local function secondary_text(st, running_only)
    local name = lang_ko(st and st["nanum-secondary-language"])
    return input_state_text(st, "secondary", name and (name .. " 기반") or "원어 기반", running_only)
end

-- Disc image subtitles read by OCR.
function SUBS.pgs_text(st, running_only)
    local name = lang_ko(st and st["nanum-pgs-language"])
    local text = input_state_text(st, "pgs", name and (name .. " 디스크 자막 기반") or "디스크 자막 기반", running_only)
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
    if s == "aligning" then return string.format("가져온 자막 시간 맞추는 중 %d%%", pct) end
    if s == "translating" then return string.format("가져온 자막 번역 중 %d%%", pct) end
    if s == "done" then return "가져온 자막 준비 완료" .. SUBS.alignment_text(st) end
    if s == "error" then
        local e = tostring(st["nanum-import-error"] or "")
        return "가져온 자막 오류" .. (e ~= "" and (": " .. e) or "")
    end
    return nil
end

-- " (시간 +1.2초 · 속도 보정 ×1.0427 · 정렬 신뢰도 80%)" from the alignment fields; "" if none.
function SUBS.alignment_text(st)
    local parts = {}
    local off, scale, conf = tonumber(st["nanum-import-offset"]), tonumber(st["nanum-import-scale"]), tonumber(st["nanum-import-confidence"])
    if off then parts[#parts + 1] = string.format("시간 %+.1f초", off) end
    if scale and math.abs(scale - 1) > 0.0005 then parts[#parts + 1] = string.format("속도 보정 ×%.4f", scale) end
    if conf then parts[#parts + 1] = string.format("정렬 신뢰도 %d%%", math.floor(conf * 100 + 0.5)) end
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
    local lang = lang_ko(st and st["nanum-original-language"])
    local parts = {}
    if type(work) == "string" and work ~= "" then parts[#parts + 1] = "작품: " .. work end
    if lang then parts[#parts + 1] = "원어: " .. lang end
    return #parts > 0 and table.concat(parts, " · ") or nil
end

-- Progress / result of applying a glossary edit (the player retranslates the lines that use the changed names).
local function glossary_apply_text(st)
    local s = st and st["nanum-glossary-apply-state"]
    if s == "running" then
        return string.format("용어집 반영 중 %d%%", math.floor((tonumber(st["nanum-glossary-apply-progress"]) or 0) * 100 + 0.5))
    elseif s == "done" then
        local n = tonumber(st["nanum-glossary-apply-changed"]) or 0
        return n > 0 and string.format("용어집 반영 완료 (자막 %d줄 다시 번역)", n) or "용어집 반영 완료 (바뀐 자막 없음)"
    elseif s == "error" then
        local e = tostring(st["nanum-glossary-apply-error"] or "")
        return "용어집 반영 실패" .. (e ~= "" and (": " .. e) or "")
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
        local text = glossary_apply_text(st):gsub(" 중 ", " 중… ")
        if prev ~= "running" or (text ~= gloss_apply_text and now - gloss_apply_at >= 1) then
            gloss_apply_text, gloss_apply_at = text, now
            notify(text, 4, "busy", "glossary")
        end
    elseif s == "done" and prev == "running" then
        local n = tonumber(st["nanum-glossary-apply-changed"]) or 0
        notify(n > 0 and string.format("용어집을 반영해 자막 %d줄을 다시 번역했습니다", n)
            or "용어집을 반영했습니다 (바뀐 자막은 없습니다)", 5, "ok", "glossary")
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
            notify("용어집을 AI로 다시 만들었습니다" .. (work ~= "" and (" · " .. work) or "")
                .. (type(n) == "number" and string.format(" · %d개", n) or ""), 5, "ok", "glossary")
        else
            notify("AI 용어집 생성에 실패했습니다 (번역 서버 확인) — 기존 용어집을 유지합니다", 6, "error", "glossary")
        end
    end
end

local last_status, last_status_at = nil, 0

-- -> text, kind (ok | busy | error | info); "" clears the chip
local function compute_status()
    if not (file_active and file_loaded) then return "", "info" end
    if mp.get_property_bool("paused-for-cache") and (mp.get_property("path") or ""):lower():find("^https?://") then
        return "네트워크에서 미리 받는 중", "busy"
    end
    if not AIM.engine_enabled() then return "", "info" end
    if ai_disabled then return "AI 자막 꺼짐", "info" end
    local reason, info = AIM.block_reason()
    if reason == "models" then
        if AIM.active() then
            local pct = AIM.pct()
            return "AI 모델 내려받는 중" .. (pct and (" " .. pct .. "%") or ""), "busy", "models"
        end
        if #AIM.missing() > 0 then return "AI 모델 없음 · 눌러서 설치", "warn", "models" end
        return "AI 모델 설치됨 · 다음 파일부터 적용", "info", "models"
    elseif reason == "accel" then
        if AIM.acc_active() then
            local pct = AIM.acc_pct()
            return "CUDA 구성 요소 내려받는 중" .. (pct and (" " .. pct .. "%") or ""), "busy", "models"
        end
        if info.mode ~= AIM.mode() then return "AI 가속 모드 변경됨 · 다음 파일부터 적용", "info", "models" end
        if info.cause ~= "engine" and AIM.effective(info.mode) ~= "unavailable" then
            return "AI 엔진 사용 가능 · 다음 파일부터 적용", "info", "models"
        end
        if info.cause == "missing" and info.mode ~= "cpu" then return "CUDA 필요 · AI 꺼짐 · 눌러서 설치", "warn", "models" end
        return "AI 엔진 사용 불가 · 눌러서 확인", "warn", "models"
    end
    local st = cache_state()
    if waiting then
        local ready = ready_until()
        local have = ready and math.max(0, ready - abs_pos()) or 0
        return string.format("AI 자막 준비 중 %.0f / %d초", have, waiting.lead or opts.preroll), "busy"
    end
    local fs = st and st["nanum-full-state"]
    if fs == "error" then
        local e = st["nanum-full-error"]
        return "AI 전체 번역 오류" .. ((e and e ~= "") and (": " .. e) or ""), "error"
    end
    if lib.state == "error" then
        return "AI 자막 라이브러리 오류" .. (lib.error ~= "" and (": " .. lib.error) or ""), "error"
    end
    local pct = st and math.floor((st["nanum-full-progress"] or 0) * 100 + 0.5) or 0
    if fs == "scanning" then return string.format("AI 원문 수집 중 %d%%", pct), "busy" end
    if fs == "translating" then return string.format("AI 전체 번역 중 %d%%", pct), "busy" end
    if lib.state == "loading" then return "저장된 AI 자막 확인 중", "busy" end
    if fs == "done" then return "AI 전체 번역 완료", "ok" end
    if lib.state == "using" then return "저장된 AI 자막 사용 중", "ok" end
    if st and st["nanum-glossary-apply-state"] == "running" then return glossary_apply_text(st), "busy" end
    local its = st and st["nanum-import-state"]
    if its == "aligning" or its == "translating" then return SUBS.import_text(st), "busy" end
    local r = ready_until()
    if r then
        local ahead = r - abs_pos()
        if ahead > 1 then return with_secondary(string.format("AI 자막 준비됨 · %.0f초 앞", ahead), st), "ok" end
        return with_secondary("AI 자막 분석 중", st), "busy"
    end
    if st and st["nanum-input-active"] then return with_secondary("AI 자막 분석 중", st), "busy" end
    return "AI 자막 엔진 대기 중", "info"
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
                    notify("AI 전체 번역 자막을 적용했습니다", 3, "ok")
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
            local hint = lib_supported() and "\nCtrl+N → 저장 자막 다시 조회 / 새로 생성" or ""
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
    file_started = false
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
        local detail = event.file_error or "알 수 없는 오류"
        mp.msg.error("재생 실패: " .. detail)
        notify("재생 실패: " .. detail ..
            "\nBlu-ray는 MakeMKV 설치/활성화를 확인하세요." ..
            "\n상세 로그: %APPDATA%\\NanumPlayer\\last-playback.log", 12, "error")
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
        notify(HINT, 4)
    end
    wait_for_ai(opts.preroll)
end)

mp.register_event("playback-restart", function()
    if not file_started then
        file_started = true     -- the restart that belongs to loading the file
        return
    end
    wait_for_ai(opts.seek_preroll)
end)

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
        notify("현재 음성에 저장된 AI 자막을 찾지 못했습니다", 4, "warn")
    end
    if deferred and not decision_outstanding() then
        local d = deferred
        deferred = nil
        -- a long wait means playback is already well in: only a short pre-roll
        local lead = (mp.get_time() - d.since > 5) and math.min(d.lead, opts.seek_preroll) or d.lead
        wait_for_ai(lead)
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
        line = string.format("AI 자막: %.0f초 앞까지 준비됨 (재생 %.0f초)", r - now, now)
    else
        line = "AI 자막: 분석 중이거나 사용 불가"
    end
    local active = st and st["nanum-input-active"]
    if active then
        line = line .. (active == "sub" and " [입력: 자막]" or " [입력: 음성 인식]")
    end
    local ai_backend = st and st["nanum-ai-backend"]
    if ai_backend == "cpu" or ai_backend == "cuda" then
        line = line .. " [엔진: " .. (ai_backend == "cuda" and "CUDA" or "CPU") .. "]"
    end
    local full = full_status_text(st)
    if full then
        line = line .. "\n" .. full
    elseif opts.full and st and st["nanum-full-state"] == nil then
        line = line .. "\n전체 번역: 이 엔진 버전은 지원하지 않습니다"
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
        notify("설정 저장 실패: " .. tostring(err), 4, "error")
        return
    end
    f:write(string.format("preroll=%d\nseek_preroll=%d\ntimeout=%d\nauto_select=%s\n",
        opts.preroll, opts.seek_preroll, opts.timeout, opts.auto_select and "yes" or "no"))
    f:write(string.format("input_mode=%s\nfull=%s\nfull_engine=%s\n",
        opts.input_mode, opts.full and "yes" or "no", opts.full_engine))
    f:write(string.format("display=%s\nlibrary_auto_use=%s\nmodel_prompt=%s\n", opts.display,
        opts.library_auto_use and "yes" or "no", opts.model_prompt and "yes" or "no"))
    f:write(string.format("acceleration=%s\naccel_prompt=%s\n", opts.acceleration, opts.accel_prompt and "yes" or "no"))
    f:write(string.format("translate_style=%s\nsecondary=%s\n", opts.translate_style, opts.secondary and "yes" or "no"))
    f:write("pgs=" .. (opts.pgs and "yes" or "no") .. "\n")
    if opts.downloads_dir ~= "" then f:write("downloads_dir=" .. opts.downloads_dir .. "\n") end
    if opts.translate_style_text ~= "" then f:write("translate_style_text=" .. opts.translate_style_text .. "\n") end
    if opts.cuda_license then f:write("cuda_license=yes\n") end
    if opts.cuda_update_prompted ~= "" then f:write("cuda_update_prompted=" .. opts.cuda_update_prompted .. "\n") end
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

local DISPLAYS = {
    { key = "translation", label = "번역만" },
    { key = "bilingual", label = "번역+원문" },
    { key = "source", label = "원문만" },
}

local function display_label(key)
    for _, d in ipairs(DISPLAYS) do
        if d.key == key then return d.label end
    end
    return key
end

-- Presentation only: the engine re-renders without any reprocessing.
local function set_display(key)
    opts.display = key
    save_settings()
    if set_opt_soft("nanum-display", key) then
        notify("자막 표시: " .. display_label(key), 2, "ok")
    else
        notify("이 엔진 버전은 자막 표시 방식 전환을 지원하지 않습니다 (nanum 갱신 필요)", 4, "error")
    end
end

local function open_display_menu(standalone)
    local items, default = {}, 1
    for i, d in ipairs(DISPLAYS) do
        items[i] = (d.key == opts.display and "● " or "  ") .. d.label
        if d.key == opts.display then default = i end
    end
    input.select({
        prompt = "자막 표시 방식:",
        items = items,
        default_item = default,
        submit = function(i)
            set_display(DISPLAYS[i].key)
            if not standalone then reopen_menu() end
        end,
    })
end

-- Apply changed full-mode settings; the engine restarts, so resync.
local function full_settings_changed()
    save_settings()
    local changed = apply_full_options()
    if engine_old then
        notify("이 엔진 버전은 전체 번역을 지원하지 않습니다 (nanum 갱신 필요)", 4, "error")
    elseif changed then
        resync()
        mp.add_timeout(1.0, function()
            if last_full_state ~= "done" then select_live() end
        end)
    end
end

local function ask_number(label, key)
    input.get({
        prompt = label .. " (초):",
        default_text = tostring(opts[key]),
        submit = function(text)
            input.terminate()
            local n = tonumber(text)
            if n and n >= 0 then
                opts[key] = math.floor(n)
                save_settings()
            else
                notify("숫자가 아닙니다: " .. text, 3, "warn")
            end
            reopen_menu()
        end,
    })
end

local function ask_text(e)
    input.get({
        prompt = e.label .. ":",
        default_text = engine_vals[e.key] ~= "" and engine_vals[e.key]
            or mp.get_property("options/" .. e.opt) or "",
        submit = function(text)
            input.terminate()
            engine_vals[e.key] = text
            mp.set_property("options/" .. e.opt, text)
            save_settings()
            notify(e.label .. ": 다음에 여는 파일부터 적용", 3, "ok")
            reopen_menu()
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
            if s.key == "custom" then return "직접 입력 — " .. ellipsize(opts.translate_style_text, 24) end
            return s.label
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
        notify("번역 말투: " .. style_label() .. "\n지금부터 번역되는 자막에 바로 적용됩니다 (이미 만든 자막은 그대로)", 4, "ok")
    else
        notify("이 엔진 버전은 번역 말투 선택을 지원하지 않습니다 (nanum 갱신 필요)", 5, "error")
    end
end

local function ask_style_text()
    input.get({
        prompt = "번역 말투 지시문 (예: 아이에게 말하듯 다정하게):",
        default_text = opts.translate_style_text,
        submit = function(text)
            input.terminate()
            text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
            if text == "" then
                notify("지시문이 비어 있어 말투를 바꾸지 않았습니다", 3, "warn")
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
        items[i] = (s.key == opts.translate_style and "● " or "  ") .. s.label
        if s.key == opts.translate_style then default = i end
    end
    input.select({
        prompt = "번역 말투:",
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
        notify(on and "원어 음성으로도 자막을 만듭니다 (기본 자막이 충분히 앞선 뒤에 작업 · 자막 메뉴에서 선택)"
            or "원어 음성 자막을 만들지 않습니다", 4, "ok")
    else
        notify("이 엔진 버전은 원어 음성 자막을 지원하지 않습니다 (nanum 갱신 필요)", 5, "error")
    end
end

----------------------------------------------------------------------------
-- Glossary (characters / proper nouns of the film): edited as a text file
----------------------------------------------------------------------------

local GLOSSARY_HEADER = table.concat({
    "# NanumPlayer 용어집 — 이 영상의 인물·고유명사를 항상 같은 번역으로 옮기기 위한 표입니다.",
    "# 한 줄에 하나씩 '원문 => 번역' 형식으로 적습니다. 예)  Hikari => 히카리",
    "# 음성 인식이 잘못 받아적는 철자도 같은 번역으로 적어 두면 효과적입니다.",
    "# '#'으로 시작하는 줄과 빈 줄은 무시됩니다.",
    "# 저장하면 바로 적용되고, 메모장을 닫을 때 마지막으로 한 번 더 적용됩니다.",
}, "\n") .. "\n\n"

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
    notify("이 엔진 버전은 용어집을 지원하지 않습니다 (nanum 갱신 필요)", 5, "error")
end

-- ~~/glossary (created on demand); nil with a message when that is impossible.
local function glossary_dir()
    local dir = mp.command_native({ "expand-path", "~~/glossary" })
    if type(dir) ~= "string" or dir == "" or dir:sub(1, 2) == "~~" then
        notify("용어집 폴더를 만들 수 없습니다 (설정 폴더를 찾을 수 없음)", 5, "error")
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
        notify("영상을 재생한 뒤에 용어집을 사용할 수 있습니다", 4, "warn")
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
        notify("용어집 적용 실패: " .. tostring(err), 5, "error")
        return false
    end
    w:write(clean)
    w:close()
    if not glossary_request("file:" .. out) then
        glossary_unsupported()
        return false
    end
    notify(string.format("용어집을 전달했습니다 (%d개) · 바뀐 이름이 들어간 자막은 다시 번역됩니다", n), 4, "ok", "glossary")
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
    local content = GLOSSARY_HEADER .. text .. (text ~= "" and text:sub(-1) ~= "\n" and "\n" or "")
    local f, err = io.open(path, "wb")
    if not f then
        notify("용어집 파일을 만들 수 없습니다: " .. tostring(err), 5, "error")
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
    notify("용어집을 메모장으로 엽니다 — 저장하면 적용됩니다\n" .. path, 6, "info", "glossary")
    mp.command_native_async({ name = "subprocess", args = { "notepad.exe", path }, playback_only = false },
        function()
            if gloss_edit ~= g then return end          -- replaced or the file changed meanwhile
            -- Notepad with tabs hands the file to a running window and exits at once: keep watching.
            if mp.get_time() - g.started >= 2 then glossary_tick(true) end
        end)
end

local function regenerate_glossary()
    if not (file_active and file_loaded) then
        notify("영상을 재생한 뒤에 사용할 수 있습니다", 4, "warn")
        return
    end
    if glossary_request("regenerate") then
        gloss_wait, gloss_pending = "requested", nil
        notify("AI가 작품 정보와 용어집을 다시 만드는 중입니다 (시간이 걸릴 수 있습니다)", 5, "busy", "glossary")
    else
        glossary_unsupported()
    end
end

-- n: number of entries shown (default: what the player published)
local function glossary_label(st, n)
    n = n or (st and st["nanum-glossary-count"])
    if type(n) ~= "number" then return "용어집: 영상을 재생하면 사용할 수 있습니다" end
    local s = string.format("용어집 (%d개)", n)
    local work = tostring(st["nanum-profile-work"] or "")
    if st["nanum-profile-state"] == "running" then return s .. ": AI가 작품 정보 조회 중" end
    return work ~= "" and (s .. ": " .. work) or s
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
        local items = { string.format("예 — 같은 인물의 관련 항목 %d개도 함께 수정", autos), "아니오 — 이 항목만 수정" }
        for _, r in ipairs(rel) do
            items[#items + 1] = "    " .. list[r.index].src .. ": " .. list[r.index].tgt
                .. (r.manual and " — 한국어 부분을 찾지 못해 직접 수정 필요" or (" → " .. r.tgt))
        end
        input.select({
            prompt = "같은 인물의 다른 항목도 바꿀까요?",
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
    ask_glossary_text("'" .. e.src .. "'의 번역:", e.tgt, e.src, function(text)
        if text == "" then
            notify("번역이 비어 있어 바꾸지 않았습니다", 3, "warn")
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
                notify("한국어 부분을 자동으로 찾지 못한 관련 항목은 직접 수정하세요: " .. table.concat(manual, ", "), 7, "warn", "glossary-edit")
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
    ask_glossary_text("원문 수정 ('" .. e.tgt .. "'로 번역되는 원문):", e.src, e.src, function(text)
        if text == "" or text:find("=>", 1, true) then
            notify("원문이 비어 있거나 '=>'가 들어 있어 바꾸지 않았습니다", 4, "warn")
            return reopen_glossary(e.src)
        elseif text == e.src then
            return reopen_glossary(e.src)
        end
        for i, o in ipairs(list) do
            if i ~= idx and o.src:lower() == text:lower() then
                notify("이미 있는 원문입니다: " .. o.src, 4, "warn")
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
        if commit_glossary(n) then notify("용어집에서 삭제했습니다: " .. src, 3, "ok", "glossary-edit") end
    end
    reopen_glossary()
end

local function add_glossary_entry()
    ask_glossary_text("추가할 항목 (원문 => 번역):", "", nil, function(text)
        local src, tgt = glossary_entry_parse(text)
        if not src then
            notify("'원문 => 번역' 형식으로 입력하세요 (양쪽 모두 필요)", 4, "warn")
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
            notify("이미 있는 원문이라 번역만 바꿨습니다: " .. n[at].src, 4, "info", "glossary-edit")
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
        items = { "번역 수정", "원문 수정", "삭제", "목록으로 돌아가기" },
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
    local info = original_text(st) or "AI가 식별한 작품 정보 없음"
    if ps == "running" then
        info = "AI가 작품 정보를 조회하는 중…"
    elseif ps == "error" then
        info = "AI 작품 정보 조회 실패 — 다시 만들기로 재시도할 수 있습니다"
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
    add("add", "항목 추가", function() mp.add_timeout(0.1, add_glossary_entry) end)
    add("notepad", "메모장에서 한꺼번에 편집", edit_glossary)
    add("regen", "AI로 다시 만들기 (직접 편집한 내용은 대체됩니다)", function()
        local chosen = false
        input.select({
            prompt = "용어집을 AI로 다시 만들까요?",
            items = { "다시 만들기", "취소" },
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
    add("back", "설정 메뉴로 돌아가기", reopen_menu)
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
        prompt = "용어집:",
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
    if not silent then notify("다운로드 감시를 중단했습니다", 3, "info", "subs") end
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
        notify("20분 동안 새 자막 파일이 내려받아지지 않아 다운로드 감시를 끝냈습니다", 6, "warn", "subs")
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
        notify("다운로드 폴더를 찾을 수 없습니다: " .. dir .. "\nCtrl+N → 온라인 자막 찾기에서 폴더를 지정하세요", 7, "error", "subs")
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
        notify("영상을 재생한 뒤에 사용할 수 있습니다", 4, "warn")
        return
    end
    local q = SUBS.query_text()
    if q == "" then
        notify("검색어를 알 수 없습니다 — 메뉴의 '검색어'에서 직접 입력하세요", 5, "warn")
        return
    end
    -- English is told to the player (Latin scripts are ambiguous); Japanese / Korean it detects from the characters
    if not SUBS.begin_watch(site.site, site.lang == "en" and "en" or "") then return end
    SUBS.open_url(SUBS.search_url(site, q))
    if site.site == "Jimaku" then
        local copied = SUBS.copy_text(q)
        notify(string.format("%s를 열었습니다 — %s\n(%s 폴더를 최대 20분 지켜봅니다 · 내려받으면 자동으로 가져옵니다)", site.label,
            copied and ("검색창에 붙여넣으세요 (Ctrl+V): " .. q) or ("검색창에 '" .. q .. "'를 입력하세요"), SUBS.watch.dir), 10, "busy", "subs")
        return
    end
    notify(string.format("%s에서 '%s'를 찾는 중 — 브라우저에서 자막을 내려받으면 자동으로 가져옵니다\n(%s 폴더를 최대 20분 지켜봅니다)",
        site.label, q, SUBS.watch.dir), 9, "busy", "subs")
end

-- Hands a subtitle file to the player.
function SUBS.send(path, origin, lang)
    if not (file_active and file_loaded) then
        notify("영상을 재생한 뒤에 사용할 수 있습니다", 4, "warn")
        return
    end
    path = path:gsub("/", "\\")
    SUBS.import_prev = nil
    if SUBS.request("nanum-import-sub", path .. "|" .. (lang or "") .. "|" .. origin) then
        notify("자막을 가져옵니다: " .. (path:match("([^\\]*)$") or path) .. "\n영상 음성에 시간을 맞춘 뒤 한국어로 번역합니다", 6, "busy", "subs")
    else
        notify("이 엔진 버전은 자막 가져오기를 지원하지 않습니다 (nanum 갱신 필요)", 5, "error", "subs")
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
        prompt = string.format("자막 파일 선택 (%d개):", #files),
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
    notify("내려받은 압축 파일을 풀고 있습니다: " .. (path:match("([^\\/]*)$") or path), 5, "busy", "subs")
    local root = os.getenv("SystemRoot") or "C:\\Windows"
    local tar = require('mp.utils').file_info(root .. "\\System32\\tar.exe") and (root .. "\\System32\\tar.exe") or "tar.exe"
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stderr = true,
        args = { tar, "-xf", path, "-C", dir } }, function(ok, res)
        local files = SUBS.find_subs(dir)
        if #files == 0 then
            local why = (ok and res and res.status ~= 0) and "압축을 풀지 못했습니다" or "압축 파일에 자막 파일이 없습니다"
            notify(why .. ": " .. (path:match("([^\\/]*)$") or path), 6, "error", "subs")
            return
        end
        SUBS.choose(files, origin, lang)
    end)
end

-- Windows "Open" dialog (PowerShell) for a subtitle file or zip; the player's own pickers only load media.
function SUBS.pick_file()
    if not (file_active and file_loaded) then
        notify("영상을 재생한 뒤에 사용할 수 있습니다", 4, "warn")
        return
    end
    if package.config:sub(1, 1) ~= "\\" then return end
    local dir = SUBS.downloads_dir():gsub("'", "''")
    local script = table.concat({
        "Add-Type -AssemblyName System.Windows.Forms;",
        "[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false);",
        "$o=New-Object System.Windows.Forms.Form;$o.TopMost=$true;",
        "$d=New-Object System.Windows.Forms.OpenFileDialog;",
        "$d.Title='가져올 자막 파일 선택';",
        "$d.Filter='자막 파일 (srt, ass, ssa, vtt, sub, zip)|*.srt;*.ass;*.ssa;*.vtt;*.sub;*.zip|모든 파일|*.*';",
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
        prompt = "'" .. (lang_ko(lang) or lang) .. "' OCR 언어 팩을 설치할까요?",
        items = { "설치 (Windows가 관리자 권한을 묻습니다)", "취소" },
        default_item = 2,
        submit = function(i)
            if i == 1 then
                SUBS.run_elevated(args)
                notify("OCR 언어 팩 설치 창을 열었습니다 — 허용하면 설치가 진행되고, 다음에 여는 파일부터 적용됩니다", 8, "busy", "subs")
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
        notify(on and "디스크 자막(이미지)을 문자 인식으로 읽어 자막을 만듭니다 (기본 자막이 앞선 뒤에 작업 · 자막 메뉴에서 선택)"
            or "디스크 자막 문자 인식을 끕니다", 4, "ok")
    else
        notify("이 엔진 버전은 디스크 자막 문자 인식을 지원하지 않습니다 (nanum 갱신 필요)", 5, "error")
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
        local msg = "가져온 자막이 준비되었습니다 — 자막 메뉴에서 선택하세요" .. SUBS.alignment_text(st)
        local low = st["nanum-import-low-confidence"] == true
        local note = tostring(st["nanum-import-note"] or "")
        if low then
            msg = msg .. "\n시간 맞춤을 확신할 수 없어 보정하지 않았습니다 — Ctrl+N → 가져온 자막 → 시간 미세 조정"
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
            if t.title ~= FULL_TITLE and ext and SUBS.EXT[ext] and mp.get_time() - loaded_at > 2.5 then
                queue_prompt("dropsub", function()
                    return {
                        prompt = "자막 파일을 추가했습니다: " .. (path:match("([^\\/]*)$") or path),
                        items = { "AI로 가져오기 (영상에 시간을 맞추고 한국어로 번역)", "그대로 외부 자막으로 사용" },
                        default_item = 1,
                        submit = function(i)
                            if i == 1 then SUBS.send(path, "파일", "") end
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
        add("브라우저에서 찾기: " .. site.label, function() SUBS.start_search(site) end)
    end
    add("검색어: " .. (q ~= "" and q or "(없음)") .. (SUBS.query and " [직접 입력]" or "") .. " — 바꾸기", function()
        input.get({
            prompt = "검색어 (비우면 작품/파일 이름 사용):",
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
    add("다운로드 폴더: " .. dir .. (opts.downloads_dir ~= "" and " [직접 지정]" or " [자동]") .. " — 바꾸기", function()
        input.get({
            prompt = "자막을 내려받는 폴더 (비우면 Windows 다운로드 폴더):",
            default_text = dir,
            submit = function(text)
                input.terminate()
                text = text:match("^%s*(.-)%s*$")
                local info = text ~= "" and require('mp.utils').file_info(text) or nil
                if text ~= "" and not (info and info.is_dir) then
                    notify("폴더를 찾을 수 없습니다: " .. text, 4, "warn")
                else
                    opts.downloads_dir = text:gsub("[/\\]+$", "")
                    save_settings()
                    if SUBS.watch then SUBS.cancel_watch(true) end
                end
                again()
            end,
        })
    end)
    add("자막 파일 직접 고르기…", function() SUBS.pick_file() end)
    if SUBS.watch then
        add("다운로드 기다리는 중 — 감시 중단", function()
            SUBS.cancel_watch(false)
            again()
        end)
    end
    add("설정 메뉴로 돌아가기", reopen_menu)
    input.select({
        prompt = "온라인 자막 찾기 (브라우저에서 직접 내려받습니다):",
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
                notify("이 엔진 버전은 자막 시간 조정을 지원하지 않습니다 (nanum 갱신 필요)", 5, "error")
            end
            if SUBS.adj_timer then SUBS.adj_timer:kill() end
            SUBS.adj_timer = mp.add_timeout(0.6, function() SUBS.adj_timer = nil; SUBS.adjust_tick(true) end)
        end
    end
    local off, conf = tonumber(st["nanum-import-offset"]), tonumber(st["nanum-import-confidence"])
    add("info", "현재 시간 보정: " .. (off and string.format("%+.1f초", off) or "알 수 없음")
        .. (conf and string.format(" · 자동 정렬 신뢰도 %d%%", math.floor(conf * 100 + 0.5)) or ""), function() end)
    add("p10", "자막 1초 늦추기 (+1.0)", nudge(1))
    add("p01", "자막 0.1초 늦추기 (+0.1)", nudge(0.1))
    add("m01", "자막 0.1초 앞당기기 (−0.1)", nudge(-0.1))
    add("m10", "자막 1초 앞당기기 (−1.0)", nudge(-1))
    add("back", "설정 메뉴로 돌아가기", reopen_menu)
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
        notify("가져온 자막이 없습니다 — Ctrl+N → 온라인 자막 찾기 / 자막 파일 가져오기", 5, "warn")
        return reopen_menu()
    end
    local items, actions, keys = SUBS.adjust_rows(st)
    SUBS.adj_actions, SUBS.adj_sig = actions, table.concat(items, "\n")
    input.select({
        id = "nanum-import-adjust",
        prompt = "가져온 자막 시간 미세 조정:",
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
        m = "음성 인식 (STT)"
    elseif sel_mode == "track" then
        m = "자막 트랙"
    else
        m = "자동"
    end
    if active then
        m = m .. " → " .. (active == "sub" and "자막" or "STT")
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
    add((sel_mode == "auto" and "● " or "  ") .. "자동 (오디오 언어 자막, 없으면 STT)", function()
        sel_mode = "auto"
        opts.input_mode = "auto"
        save_settings()
        chosen()
    end)
    add((sel_mode == "stt" and "● " or "  ") .. "음성 인식 (STT)", function()
        sel_mode = "stt"
        opts.input_mode = "stt"
        save_settings()
        chosen()
    end)
    for _, t in ipairs(usable_subs(mp.get_property_native("track-list"))) do
        add((sel_mode == "track" and sel_track_id == t.id and "● " or "  ") .. "자막: " .. track_label(t), function()
            sel_mode = "track"
            sel_track_id = t.id
            chosen()
        end)
    end
    input.select({
        prompt = "AI 자막 입력 소스:",
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
    notify("불러오는 중...", 30, "busy", "omp-load")
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
            notify("omp 모델 목록을 가져오지 못했습니다 (omp 설치/로그인 확인)", 4, "error")
            reopen_menu()
            return
        end
        local items = {}
        for i, m in ipairs(list) do
            items[i] = ((m.selector == opts.omp_model) and "● " or "  ") .. m.label
        end
        input.select({
            prompt = "oh-my-pi 모델:",
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
            local info = cloud and "클라우드"
                or string.format("로컬 %.1f GB", (tonumber(m.size) or 0) / 1e9)
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
local function open_ollama_picker(e)
    if fetching_ollama then return end
    local endpoint = mp.get_property("options/nanum-translate-endpoint") or ""
    if endpoint == "" then
        notify("번역 서버 주소가 비어 있어 모델 목록을 가져올 수 없습니다", 4, "warn")
        ask_text(e)
        return
    end
    fetching_ollama = true
    notify("Ollama 모델 목록을 불러오는 중...", 10, "busy", "ollama-load")
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { "curl.exe", "-s", "--max-time", "5", endpoint:gsub("/+$", "") .. "/api/tags" },
    }, function(success, res)
        fetching_ollama = false
        notify_clear("ollama-load")
        local current = mp.get_property("options/" .. e.opt) or ""
        local list = (success and res and res.status == 0) and parse_ollama_models(res.stdout, current)
        if not list then
            notify("Ollama에 연결하지 못했습니다 (" .. endpoint .. ") — 모델 이름을 직접 입력하세요", 5, "error")
            ask_text(e)
            return
        end
        local items, default = {}, nil
        for i, m in ipairs(list) do
            items[i] = m.label
            if m.name == current then default = i end
        end
        items[#items + 1] = "  직접 입력..."
        input.select({
            prompt = "번역 모델 (Ollama에 설치된 모델):",
            items = items,
            default_item = default,
            submit = function(i)
                if i > #list then
                    mp.add_timeout(0.1, function() ask_text(e) end)
                    return
                end
                engine_vals[e.key] = list[i].name
                mp.set_property("options/" .. e.opt, list[i].name)
                save_settings()
                notify("번역 모델: " .. list[i].name .. " (다음에 여는 파일부터 적용)", 3, "ok")
                reopen_menu()
            end,
        })
    end)
end


local SM = { actions = {}, keys = {} }      -- rows of the open settings menu (replaced by live updates)

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
    add("models", "AI 구성 요소 관리: " .. AIM.components_summary(), function() mp.add_timeout(0.1, AIM.open_menu) end)
    add("display", "자막 표시: " .. display_label(opts.display), function() mp.add_timeout(0.1, open_display_menu) end)
    add("style", "번역 말투: " .. style_label(), function() mp.add_timeout(0.1, open_style_menu) end)
    local sec = secondary_text(st)
    add("secondary", "원어 음성으로도 자막 만들기: " .. (opts.secondary and "켬" or "끔")
        .. ((opts.secondary and sec) and (" · " .. sec) or ""), function()
        set_secondary(not opts.secondary)
        reopen_menu()
    end)
    local work, lang = tostring(st and st["nanum-profile-work"] or ""), lang_ko(st and st["nanum-original-language"])
    if work ~= "" or lang then
        add("original", "식별된 작품·원어: " .. ((work ~= "" and lang) and (work .. " · " .. lang) or (work ~= "" and work or lang)),
            reopen_menu)
    end
    add("pgs", "디스크 자막(이미지) 문자 인식으로도 자막 만들기: " .. (opts.pgs and "켬" or "끔"), function()
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
        add("pgs_pack", fallback and string.format("%s OCR 언어 팩 설치 (관리자 권한, 인식 정확도 향상)", lang_ko(pgs_lang) or pgs_lang)
            or string.format("%s OCR 언어 팩 설치 (관리자 권한)", lang_ko(pgs_lang) or pgs_lang), function()
            mp.add_timeout(0.1, function() SUBS.open_ocr_install(pgs_lang) end)
        end)
    end
    add("subsearch", "온라인 자막 찾기" .. (SUBS.watch and " · 다운로드 기다리는 중" or " (OpenSubtitles · Jimaku)"),
        function() mp.add_timeout(0.1, SUBS.open_search_menu) end)
    add("subfile", "자막 파일 가져오기…", function() SUBS.pick_file() end)
    add("youtube_url", "YouTube 주소로 재생…", function() mp.add_timeout(0.1, SUBS.yt.ask_url) end)
    add("youtube", "YouTube 창·구성 요소·로그인: " .. SUBS.yt.summary(), function() mp.add_timeout(0.1, SUBS.yt.open_menu) end)
    local imp = SUBS.import_text(st)
    if imp then
        add("subimport", "가져온 자막: " .. imp, function() mp.add_timeout(0.1, SUBS.open_adjust_menu) end)
    end
    add("glossary", glossary_label(st), function() mp.add_timeout(0.1, open_glossary_menu) end)
    local diag = mp.get_property_native("user-data/nanum/diagnostics")
    add("diag", "진단 로그(디스크 읽기 상세): " .. ((type(diag) == "table" and diag.enabled == true) and "켬" or "끔"), function()
        local cur = mp.get_property_native("user-data/nanum/diagnostics")
        local on = type(cur) == "table" and cur.enabled == true
        if not mp.commandv("nanum-diagnostics", on and "off" or "on") then
            notify("이 엔진 버전은 진단 로그를 지원하지 않습니다 (nanum 갱신 필요)", 4, "error")
        elseif on then
            notify("진단 로그를 껐습니다 (읽기 오류/매우 느린 읽기만 last-playback.log에 남습니다)", 4)
        else
            local f = type(cur) == "table" and cur.file or ""
            notify("진단 로그 켬: 디스크 읽기/탐색을 시간 기록과 함께 저장합니다 (최대 8MiB, 최근 8개 보관, 영상 데이터·키는 기록 안 함)"
                .. (f ~= "" and ("\n" .. f) or "\n%APPDATA%\\NanumPlayer\\diagnostics\\"), 8, "ok")
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
    if lib_supported() then
        add("lib_ask", "저장 자막 다시 조회", function() library_action("ask") end)
        if lib.has_translation then
            add("lib_use", "저장된 번역 사용", function() library_action("use") end)
        end
        if lib.has_source then
            add("lib_retranslate", "저장된 원문으로 다시 번역", function() library_action("retranslate", { keep_full = true }) end)
        end
        add("lib_regenerate", "음성 인식부터 새로 생성", function() library_action("regenerate", { keep_full = true }) end)
        if not ai_disabled then
            add("lib_disable", "이 파일은 AI 자막 끄기", function() library_action("disable") end)
        end
        add("lib_auto", "저장 자막 자동 사용: " .. (opts.library_auto_use and "켬" or "끔"), function()
            set_auto_use(not opts.library_auto_use)
            reopen_menu()
        end)
    end
    if pinned_aud then
        add("audio", "AI 입력 음성: #" .. tostring(pinned_aud.src) .. " " .. (pinned_aud.lang or "?") .. " (재생 음성으로 변경…)", function()
            if build_audio_prompt() then
                queue_prompt("audio", build_audio_prompt)
                mp.add_timeout(0.3, pump_prompts)
            else
                notify("재생 중인 음성이 AI 입력 음성과 같습니다", 3)
                reopen_menu()
            end
        end)
    end
    add("input", "입력 소스: " .. input_label(), function() mp.add_timeout(0.1, open_input_menu) end)
    add("full", "전체 번역 모드: " .. (opts.full and "켬" or "끔"), function()
        opts.full = not opts.full
        full_settings_changed()
        reopen_menu()
    end)
    add("full_engine", "전체 번역 엔진: " .. (opts.full_engine == "omp" and "oh-my-pi" or "Ollama"), function()
        opts.full_engine = opts.full_engine == "omp" and "ollama" or "omp"
        full_settings_changed()
        reopen_menu()
    end)
    add("omp_model", "oh-my-pi 모델: " .. (opts.omp_model ~= "" and opts.omp_model or "(선택 안 됨)"),
        function() mp.add_timeout(0.1, open_omp_picker) end)
    add("preroll", string.format("시작 프리롤: %d초", opts.preroll), function() ask_number("시작 프리롤", "preroll") end)
    add("seek_preroll", string.format("탐색 후 프리롤: %d초", opts.seek_preroll), function() ask_number("탐색 후 프리롤", "seek_preroll") end)
    add("timeout", string.format("프리롤 최대 대기: %d초", opts.timeout), function() ask_number("프리롤 최대 대기", "timeout") end)
    add("auto_select", "AI 자막 자동 선택: " .. (opts.auto_select and "켬" or "끔"), function()
        opts.auto_select = not opts.auto_select
        save_settings()
        reopen_menu()
    end)
    for _, e in ipairs(ENGINE) do
        local open = e.key == "translate_model" and function() mp.add_timeout(0.1, function() open_ollama_picker(e) end) end
            or function() ask_text(e) end
        add("engine_" .. e.key, string.format("%s: %s", e.label, mp.get_property("options/" .. e.opt) or ""), open)
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
        prompt = "NanumPlayer 설정:",
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
mp.add_key_binding(nil, "nanum-display", function() open_display_menu(true) end)
mp.observe_property("user-data/nanum/diagnostics", "native", function() update_settings_menu() end)

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
    return YT.COMP_NAME[id] or tostring(id or "")
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
    if d.status == "checking" then return "최신 버전 확인 중…" end
    if d.status == "verifying" then return name .. " 무결성 검증 중" end
    if d.status == "extracting" then return name .. " 압축 푸는 중" end
    local s = name .. " 내려받는 중"
    local f = YT.fraction()
    if f then s = s .. string.format(" %d%% (%s / %s)", math.floor(f * 100 + 0.5), AIM.fmt_size(d.received), AIM.fmt_size(d.total)) end
    return s
end

-- Short form for the settings row.
function YT.summary()
    local d = YT.data
    if not d then return YT.cmd_ok == false and "지원 안 됨" or "확인 중…" end
    if YT.active() then
        local f = YT.fraction()
        return (d.status == "checking" and "최신 버전 확인 중…" or (YT.name(d.current) .. " 내려받는 중" .. (f and (" " .. math.floor(f * 100 + 0.5) .. "%") or "")))
    end
    if d.installed ~= true then
        local bytes = YT.missing_bytes()
        return "구성 요소 미설치" .. (bytes > 0 and (" · " .. AIM.fmt_size(bytes)) or "")
    end
    local v = tostring(d.version or "")
    local s = "yt-dlp " .. (v ~= "" and v or "설치됨")
    if d.update_available == true then s = s .. " · 업데이트 있음" end
    return s
end

function YT.status_text()
    local d = YT.data
    if not d then return YT.cmd_ok == false and "이 엔진 버전은 YouTube 구성 요소 관리를 지원하지 않습니다" or "확인 중…" end
    if YT.active() then return YT.progress_text() end
    if d.status == "done" then return "완료" end
    if d.status == "cancelled" then return "취소됨" end
    if d.status == "error" then
        local e = tostring(d.error or "")
        return "오류 — " .. (e ~= "" and e or "알 수 없는 오류")
    end
    if d.installed ~= true then return "YouTube 재생에 필요한 구성 요소가 없습니다" end
    if d.update_available == true then return "새 버전이 있습니다" end
    return tostring(d.latest or "") ~= "" and "최신 버전입니다" or "설치됨 (최신 버전 여부는 '업데이트 확인'으로 확인)"
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
        notify("이미 내려받는 중입니다 — 끝나거나 취소한 뒤 다시 선택하세요", 4, "warn")
        return false
    end
    if not mp.commandv("nanum-download-youtube-tools") then
        notify(YT.data and "내려받기를 시작하지 못했습니다 (다른 작업이 진행 중일 수 있습니다)"
            or "이 엔진 버전은 YouTube 구성 요소를 지원하지 않습니다 (nanum 갱신 필요)", 5, "error")
        return false
    end
    YT.toast_at = 0
    local bytes = YT.missing_bytes()
    notify("YouTube 구성 요소 " .. ((YT.data and YT.data.installed == true) and "업데이트를" or "내려받기를") .. " 시작합니다"
        .. (bytes > 0 and (" (" .. AIM.fmt_size(bytes) .. ")") or ""), 4, "busy", "yt-dl")
    return true
end

function YT.cancel()
    if YT.downloading() then
        mp.commandv("nanum-cancel-youtube-download")
        notify("YouTube 구성 요소 내려받기를 취소하는 중...", 3, "busy", "yt-dl")
    else
        notify("진행 중인 내려받기가 없습니다", 3)
    end
end

-- Progress toast that survives closing the menu (text changes at most once per second, refreshed every 3 s).
function YT.heartbeat()
    if not YT.downloading() or fluent.open_id() == "nanum-youtube" then return end
    local text = "YouTube 구성 요소 " .. YT.progress_text()
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
            notify("YouTube 구성 요소 준비 완료" .. ((tostring(d.version or "") ~= "") and (" · yt-dlp " .. d.version) or ""), 5, "ok", "yt-dl")
            if d.installed == true and YT.after then
                local fn = YT.after
                YT.after = nil
                mp.add_timeout(0.3, fn)
            end
        elseif d.status == "error" then
            YT.after = nil
            local e = tostring(d.error or "")
            notify("YouTube 구성 요소 내려받기 실패" .. (e ~= "" and (": " .. e) or "")
                .. "\nCtrl+N → YouTube에서 다시 시도할 수 있습니다", 9, "error", "yt-dl")
        elseif d.status == "cancelled" then
            YT.after = nil
            notify("YouTube 구성 요소 내려받기를 취소했습니다", 3, "info", "yt-dl")
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
        prompt = "YouTube 구성 요소가 필요합니다",
        items = {
            "내려받고 계속" .. (bytes > 0 and (" (" .. AIM.fmt_size(bytes) .. ")") or ""),
            "구성 요소 없이 계속 (재생이 실패할 수 있습니다)",
            "취소",
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

-- Starts / shows the browser helper where the user picks a video and logs in.
function YT.launch_helper()
    local exe = YT.app_path("nanum_youtube.exe")
    if exe == "" or not require('mp.utils').file_info(exe) then
        notify("YouTube 브라우저(nanum_youtube.exe)를 찾을 수 없습니다 — NanumPlayer를 다시 설치하세요", 7, "error", "yt")
        return false
    end
    -- A bare name (--input-ipc-server=foo) is stored as "foo": the pipe is \\.\pipe\foo. No pipe in this window:
    -- the helper falls back to the player's default name.
    local pipe = mp.get_property("input-ipc-server")
    local args = { exe }
    if type(pipe) == "string" and pipe ~= "" then
        if not pipe:lower():find("^\\\\%.\\pipe\\") then pipe = "\\\\.\\pipe\\" .. pipe end
        args[#args + 1] = "--pipe"
        args[#args + 1] = pipe
    end
    mp.command_native_async({ name = "subprocess", args = args, playback_only = false, detach = true }, function() end)
    notify("YouTube 창을 엽니다 — 영상을 고르면 NanumPlayer에서 재생합니다", 5, "busy", "yt")
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
        notify("YouTube 영상 주소가 아닙니다: " .. tostring(url):sub(1, 80) ..
            "\n(https://www.youtube.com/watch?v=… 또는 https://youtu.be/… 형식)", 6, "warn", "yt")
        return false
    end
    YT.ensure(function()
        local args = { "loadfile", canon, "replace", "-1" }
        if start then args[#args + 1] = "start=" .. start end
        mp.commandv((table.unpack or unpack)(args))
        YT.raise()
        notify("YouTube 영상을 불러오는 중…" .. (start and string.format(" (%d초부터)", start) or ""), 6, "busy", "yt")
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
        prompt = "YouTube 주소 (복사한 주소를 붙여넣으세요):",
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
        return { key = "missing", text = "yt-dlp 구성 요소를 찾을 수 없습니다", hint = "Ctrl+N → YouTube에서 구성 요소를 내려받으세요" }
    elseif has("not a bot") then
        return { key = "login", text = "YouTube가 로봇이 아닌지 확인을 요구합니다", hint = "YouTube 창에서 로그인 후 다시 시도하세요" }
    elseif has("sign in", "log in", "login required", "private video", "members-only", "members only", "confirm your age", "age-restricted", "age restricted") then
        return { key = "login", text = "로그인이 필요한 영상입니다", hint = "YouTube 창에서 로그인 후 다시 시도하세요" }
    elseif has("requested format is not available", "no video formats found", "no formats") then
        return { key = "update", text = "재생할 수 있는 영상 형식을 찾지 못했습니다", hint = "구성 요소를 업데이트한 뒤 다시 시도하세요 (Ctrl+N → YouTube)" }
    elseif has("unable to extract", "nsig", "signature", "http error 403", "javascript runtime", "js runtime", "player response", "po token", "challenge") then
        return { key = "update", text = "yt-dlp가 YouTube의 변경을 따라가지 못했습니다", hint = "구성 요소를 업데이트한 뒤 다시 시도하세요 (Ctrl+N → YouTube)" }
    elseif has("video unavailable", "has been removed", "no longer available", "this video is not available", "copyright", "not made this video available", "geo") then
        return { key = "gone", text = "재생할 수 없는 영상입니다 (삭제·비공개·지역 제한)", hint = "로그인하면 볼 수 있는 영상일 수 있습니다 — YouTube 창에서 로그인해 보세요" }
    elseif has("unable to download", "urlopen error", "timed out", "getaddrinfo", "network is unreachable", "connection reset") then
        return { key = "net", text = "네트워크 오류로 YouTube에 연결하지 못했습니다", hint = "인터넷 연결을 확인한 뒤 다시 시도하세요" }
    end
    local first = tostring(text or ""):match("[Ee][Rr][Rr][Oo][Rr]:%s*([^\r\n]+)") or ""
    return { key = "other", text = "YouTube 재생에 실패했습니다" .. (first ~= "" and (": " .. first:sub(1, 140)) or ""),
        hint = "구성 요소를 업데이트하거나 YouTube 창에서 로그인한 뒤 다시 시도하세요" }
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
        add("YouTube 구성 요소 내려받기", function() YT.download() end)
    elseif r.key == "login" or r.key == "gone" then
        add("YouTube 창 열기 (로그인)", function() YT.open_browser() end)
    elseif r.key == "update" or r.key == "other" then
        add("구성 요소 업데이트", function() YT.refresh(); YT.download() end)
        add("YouTube 창 열기 (로그인)", function() YT.open_browser() end)
    end
    if #items > 0 then
        add("닫기", function() end)
        mp.add_timeout(0.6, function()
            if fluent.modal_busy() then return end
            input.select({ prompt = "YouTube 재생에 실패했습니다", items = items, submit = function(i) actions[i]() end })
        end)
    end
    return true
end

-- Windows tasklist: is the helper running? cb(true|false)
function YT.helper_running(cb)
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "tasklist", "/FI", "IMAGENAME eq nanum_youtube.exe", "/FO", "CSV", "/NH" } }, function(ok, res)
        cb(ok and res and (res.stdout or ""):lower():find("nanum_youtube.exe", 1, true) ~= nil)
    end)
end

-- <root>\profile and <root>\cookies.txt of the helper (never anything else).
function YT.login_paths()
    local root = YT.data and type(YT.data.directory) == "string" and YT.data.directory ~= "" and YT.data.directory
        or os.getenv("NANUMPLAYER_YOUTUBE_DIR")
        or ((os.getenv("LOCALAPPDATA") or "") .. "\\NanumPlayer\\youtube")
    root = root:gsub("/", "\\"):gsub("\\+$", "")
    return root .. "\\profile", root .. "\\cookies.txt"
end

function YT.delete_login_now()
    local profile, cookies = YT.login_paths()
    local utils = require 'mp.utils'
    local had = utils.file_info(profile) ~= nil or utils.file_info(cookies) ~= nil
    if utils.file_info(profile) then
        mp.command_native({ name = "subprocess", playback_only = false, args = { "cmd", "/c", "rmdir", "/s", "/q", profile } })
    end
    if utils.file_info(cookies) then os.remove(cookies) end
    if utils.file_info(profile) or utils.file_info(cookies) then
        notify("로그인 정보를 모두 지우지 못했습니다 — YouTube 창을 닫고 다시 시도하세요", 7, "error", "yt")
    elseif had then
        notify("YouTube 로그인 정보를 삭제했습니다 (다음에 YouTube 창을 열면 다시 로그인해야 합니다)", 6, "ok", "yt")
    else
        notify("삭제할 YouTube 로그인 정보가 없습니다", 4, "info", "yt")
    end
end

-- The helper keeps the profile open: ask it to quit (nanum_youtube.exe --quit), wait, then delete.
function YT.delete_login()
    YT.helper_running(function(running)
        if not running then return YT.delete_login_now() end
        local exe = YT.app_path("nanum_youtube.exe")
        if exe ~= "" and require('mp.utils').file_info(exe) then
            mp.command_native_async({ name = "subprocess", playback_only = false, args = { exe, "--quit" } }, function() end)
        end
        notify("열려 있는 YouTube 창을 닫는 중…", 6, "busy", "yt")
        local tries = 0
        local timer
        timer = mp.add_periodic_timer(1, function()
            tries = tries + 1
            YT.helper_running(function(still)
                if not timer then return end
                if not still then
                    timer:kill()
                    timer = nil
                    mp.add_timeout(1.0, YT.delete_login_now)         -- the profile stays locked for a moment
                elseif tries >= 8 then
                    timer:kill()
                    timer = nil
                    notify("YouTube 창이 닫히지 않았습니다 — 창을 직접 닫은 뒤 다시 시도하세요", 8, "warn", "yt")
                end
            end)
        end)
    end)
end

function YT.open_delete_confirm()
    local chosen = false
    input.select({
        prompt = "YouTube 로그인 정보를 삭제할까요?",
        items = { "삭제 (이 PC의 YouTube 창 로그인 정보와 쿠키)", "취소" },
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
        prompt = copied and "북마클릿을 클립보드에 복사했습니다" or "북마클릿 (복사하지 못했습니다 — 아래 줄을 직접 복사하세요)",
        items = {
            "1. 브라우저 북마크 표시줄에서 '새 북마크'(또는 즐겨찾기 추가)를 만듭니다",
            "2. 이름: NanumPlayer로 열기 / 주소(URL): 복사한 내용을 붙여넣습니다 (Ctrl+V)",
            "3. 브라우저에서 YouTube 영상을 연 뒤 그 북마크를 누르면 NanumPlayer에서 재생됩니다",
            YT.BOOKMARKLET,
            "다시 복사",
            "뒤로",
        },
        default_item = 5,
        submit = function(i)
            if i == 5 then
                notify(SUBS.copy_text(YT.BOOKMARKLET) and "북마클릿을 복사했습니다" or "복사하지 못했습니다", 3, "ok")
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
    add("status", "구성 요소 상태: " .. YT.status_text(), function()
        local cur = YT.data
        if cur and cur.status == "error" and tostring(cur.error or "") ~= "" then
            notify("YouTube 구성 요소 오류: " .. cur.error, 9, "error")
        end
    end)
    if d then
        for _, c in ipairs(YT.list()) do
            local key = "c_" .. tostring(c.id)
            local val
            if YT.downloading() and d.current == c.id then
                if d.status == "verifying" then
                    val, progress[key] = "무결성 검증 중", 1
                elseif d.status == "extracting" then
                    val, progress[key] = "압축 푸는 중", 1
                else
                    local f = YT.fraction()
                    val = string.format("내려받는 중 %s · %s / %s", f and (math.floor(f * 100 + 0.5) .. "%") or "…",
                        AIM.fmt_size(d.received), AIM.fmt_size(d.total))
                    progress[key] = f or 0
                end
            elseif c.installed then
                val = "설치됨" .. (tostring(c.version or "") ~= "" and (" · " .. c.version) or "")
            else
                val = "미설치 · " .. AIM.fmt_size(c.size)
            end
            add(key, (c.installed and "● " or "  ") .. tostring(c.label or YT.name(c.id)) .. ": " .. val, function()
                if not c.installed then YT.download() end
            end)
        end
        local need = d.installed ~= true
        local upd = d.update_available == true
        add("download", (need and "구성 요소 내려받기: " or (upd and "구성 요소 업데이트: " or "구성 요소 업데이트: "))
            .. (YT.active() and "진행 중" or (need and AIM.fmt_size(YT.missing_bytes())
            or (upd and ("새 버전 " .. tostring(d.latest or "")) or "최신 버전입니다"))), function()
            if not need and not upd then
                notify("최신 버전입니다 — '업데이트 확인'으로 새 버전이 있는지 먼저 확인하세요", 4, "info")
            else
                YT.download()
            end
        end)
        add("check", "업데이트 확인: " .. (tostring(d.latest or "") ~= "" and ("최신 " .. d.latest) or "아직 확인하지 않음"), function()
            if YT.active() then return end
            YT.refresh()
            notify("최신 버전을 확인합니다", 3)
        end)
        add("cancel", "내려받기 취소: " .. (YT.downloading() and "진행 중인 작업 중단" or "진행 중인 작업 없음"), YT.cancel)
    end
    add("browser", "YouTube 창 열기 (영상 선택·로그인)", function() mp.add_timeout(0.1, YT.open_browser) end)
    add("url", "YouTube 주소로 재생…", function() mp.add_timeout(0.1, YT.ask_url) end)
    add("bookmarklet", "'NanumPlayer로 열기' 북마클릿 복사 (다른 브라우저용)", function() mp.add_timeout(0.1, YT.open_bookmarklet) end)
    add("logout", "YouTube 로그인 정보 삭제", function() mp.add_timeout(0.1, YT.open_delete_confirm) end)
    add("back", "설정 메뉴로 돌아가기", function()
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
        prompt = "YouTube:",
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
-- AI component manager (Ctrl+N -> "AI 구성 요소 관리", or `script-binding nanum-models`):
-- CPU engine, optional CUDA engine / cuBLAS / reused CUDA Toolkit, and the speech models.
-- Stays open while downloading; rows, percentages and the progress bar follow
-- user-data/nanum/models and user-data/nanum/accelerator in place (no reopening).
-- Closing it does not stop a download: progress continues in toasts / the status chip.
----------------------------------------------------------------------------

function AIM.open_dir(dir)
    if type(dir) ~= "string" or dir == "" then
        notify("저장 위치를 알 수 없습니다", 3, "warn")
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
        prompt = "이미 설치됨: " .. tostring(m.label or AIM.name(m.id)),
        items = { "유지", "파일을 검증하고 필요하면 다시 내려받기" },
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
        items[i] = (m == AIM.mode() and "● " or "  ") .. AIM.MODE_DESC[m]
        if m == AIM.mode() then default = i end
    end
    input.select({
        prompt = "AI 가속 모드 (다음에 여는 파일부터 적용):",
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
        notify("라이선스 파일을 찾을 수 없습니다 (앱 폴더의 LICENSE-NVIDIA-CUDA.txt)", 5, "warn")
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
        prompt = "NVIDIA CUDA 라이선스에 동의해야 내려받을 수 있습니다",
        items = {
            "라이선스 보기 (LICENSE-NVIDIA-CUDA.txt)",
            "동의하고 CUDA 구성 요소 내려받기 (" .. AIM.fmt_size(AIM.acc_bytes()) .. ")",
            "취소",
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
        prompt = "NVIDIA 드라이버를 찾을 수 없습니다",
        items = { "취소", "그래도 CUDA 구성 요소 내려받기 (" .. AIM.fmt_size(AIM.acc_bytes()) .. ")" },
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
        if a.toolkit == true then return "사용 가능 · cuBLAS: CUDA Toolkit " .. AIM.toolkit_label() .. " 사용" end
        return "사용 가능"
    end
    if AIM.cuda_update_needed() then return "엔진 업데이트 필요 · 내려받기 " .. AIM.fmt_size(AIM.acc_bytes()) end
    local cause = AIM.cuda_cause()
    if cause == "nodriver" then return "사용 불가 · NVIDIA 드라이버를 찾을 수 없음" end
    if cause == "nocatalog" then return "미설치 · 구성 요소 목록을 읽을 수 없음" end
    if cause == "missing" then return "미설치 · 내려받기 " .. AIM.fmt_size(AIM.acc_bytes()) end
    local r = tostring(a.reason or "")
    return "사용 불가 · " .. (r ~= "" and r or "GPU/드라이버가 CUDA 13 엔진을 지원하지 않음")
end

function AIM.build_menu()
    local items, actions, keys, progress = {}, {}, {}, {}
    local function add(key, text, fn)
        items[#items + 1] = text
        actions[#actions + 1] = fn
        keys[#keys + 1] = key
    end
    local d, a = AIM.data, AIM.acc
    add("status", "모델 상태: " .. AIM.status_text(), function()
        local cur = AIM.data
        if cur and cur.status == "error" and tostring(cur.error or "") ~= "" then
            notify("AI 모델 오류: " .. cur.error, 9, "error")
        end
        AIM.refresh()
    end)
    add("acc_status", "가속기 상태: " .. AIM.acc_status_text(), function()
        local cur = AIM.acc
        if cur and cur.status == "error" and tostring(cur.error or "") ~= "" then
            notify("CUDA 구성 요소 오류: " .. cur.error, 9, "error")
        end
        AIM.refresh()
    end)
    local custom = AIM.custom_dll()
    if custom then
        add("custom", "사용자 지정 AI DLL 사용 중: " .. custom, function()
            notify("--nanum-ai-dll로 지정한 엔진을 그대로 사용합니다 (자동 교체 없음)", 5)
        end)
    end
    add("accel_mode", "AI 가속 모드: " .. AIM.mode_text() .. (AIM.accel_opt_ok == false and " (이 엔진은 적용 불가)" or ""),
        AIM.open_mode_menu)
    if a then
        local cpu_ok = a.cpu_available ~= false
        add("cpu", (cpu_ok and "● " or "  ") .. "CPU 엔진: " .. (cpu_ok and "사용 가능 (앱에 포함)"
            or "사용 불가 — nanum_ai_cpu.dll을 불러오지 못함"),
            function()
                if not cpu_ok then notify("NanumPlayer를 다시 설치해 CPU 엔진을 복구하세요", 5, "warn") end
                AIM.refresh()
            end)
        add("cuda", (a.cuda_available == true and "● " or "  ") .. "CUDA 가속: " .. AIM.cuda_row_value(), function()
            if a.cuda_available ~= true and AIM.cuda_cause() == "incompatible" then
                notify("CUDA 구성 요소를 다시 받아도 해결되지 않습니다. 가속 모드를 자동/CPU만으로 쓰세요", 6, "warn")
            end
            AIM.refresh()
        end)
        local missing = AIM.acc_missing()
        local cause = a.cuda_available ~= true and AIM.cuda_cause() or nil
        local val
        if AIM.acc_active() then
            val = "진행 중"
        elseif cause == "nocatalog" then
            val = "내려받기 불가 · 구성 요소 목록(catalog.json)을 읽을 수 없음"
        elseif #missing > 0 or cause == "missing" then
            local engine, runtimes = AIM.missing_parts()
            val = string.format("필요 %s · %s", #missing > 0 and (#missing .. "개") or "구성 요소", AIM.fmt_size(AIM.acc_bytes()))
                .. ((engine and runtimes) and " (CUDA 13 Toolkit이 있으면 엔진만)" or "")
                .. (cause == "nodriver" and " (NVIDIA 드라이버 미감지)" or "")
        elseif a.toolkit == true and a.cuda_available == true then
            val = "필요 없음 · CUDA Toolkit " .. AIM.toolkit_label() .. " 사용"
        elseif a.cuda_available == true then
            val = "설치됨 · 사용 가능"
        else
            val = "설치됨 · 이 PC에서는 사용 불가 (다시 받아도 해결되지 않음)"
        end
        add("acc_install", "CUDA 가속 구성 요소 " .. (AIM.cuda_update_needed() and "업데이트: " or "내려받기: ") .. val, function()
            local cur = AIM.acc
            if not cur or AIM.acc_active() then
                if cur then notify("이미 내려받는 중입니다", 3, "warn") end
                return
            end
            local miss = AIM.acc_missing()
            local c = cur.cuda_available ~= true and AIM.cuda_cause() or nil
            if #miss == 0 and c ~= "missing" and c ~= "nocatalog" then
                if cur.cuda_available == true then
                    notify("CUDA 구성 요소가 이미 설치되어 있습니다" .. (cur.toolkit == true and (" (cuBLAS는 CUDA Toolkit " .. AIM.toolkit_label() .. " 사용)") or ""), 4, "ok")
                else
                    notify("구성 요소는 설치되어 있지만 이 PC의 GPU/드라이버에서 CUDA를 쓸 수 없습니다. 다시 받아도 해결되지 않습니다", 6, "warn")
                end
            elseif c == "nocatalog" then
                notify("CUDA 구성 요소 목록(components\\catalog.json)을 읽을 수 없습니다"
                    .. (tostring(cur.catalog_error or "") ~= "" and (": " .. cur.catalog_error) or "")
                    .. "\nNanumPlayer를 다시 설치하세요", 7, "warn")
            elseif c == "nodriver" then
                mp.add_timeout(0.1, AIM.open_nodriver_confirm)
            else
                AIM.acc_download()
            end
        end)
        if AIM.cublas_missing() or a.toolkit ~= true then
            add("license", "NVIDIA CUDA 라이선스 (cuBLAS 내려받기용): " .. (AIM.license_accepted() and "동의함 · 보기" or "동의 필요 · 보기"),
                AIM.open_license_file)
        end
        for _, c in ipairs(AIM.acc_list()) do
            local key = "acc_" .. tostring(c.id)
            local cval
            if AIM.acc_active() and a.current == c.id then
                if a.status == "verifying" then
                    cval = "무결성 검증 중"
                    progress[key] = 1
                else
                    local pct = AIM.acc_pct()
                    cval = string.format("내려받는 중 %s · %s / %s", pct and (pct .. "%") or "…",
                        AIM.fmt_size(a.received), AIM.fmt_size(a.total))
                    progress[key] = AIM.acc_fraction() or 0
                end
            elseif c.installed then
                cval = (c.source == "toolkit" and ("CUDA Toolkit " .. AIM.toolkit_label() .. " 사용"))
                    or ("설치됨 · " .. AIM.fmt_size(c.size) .. " · " .. (AIM.COMP_SOURCE[c.source] or tostring(c.source or "")))
            else
                cval = "미설치 · " .. AIM.fmt_size(c.size)
            end
            add(key, (c.installed and "● " or "  ") .. tostring(c.label or AIM.acc_name(c.id)) .. ": " .. cval, function()
                if c.installed then
                    notify(tostring(c.path or c.filename or ""), 5)
                else
                    AIM.acc_download()
                end
            end)
        end
        local tk = a.toolkit == true and type(a.toolkit_directory) == "string" and a.toolkit_directory ~= ""
        add("toolkit", (tk and "● " or "  ") .. "CUDA Toolkit " .. (tk and (AIM.toolkit_label() .. ": 감지 · " .. a.toolkit_directory)
            or "13: 설치되어 있지 않음 (설치하면 cuBLAS를 받지 않아도 GPU 사용)"), function()
            if tk then
                notify(a.toolkit_directory .. "\n설치된 Toolkit은 읽기만 하며 변경하지 않습니다", 6)
            else
                notify(AIM.toolkit_hint() .. "\n" .. AIM.TOOLKIT_URL, 8)
                SUBS.open_url(AIM.TOOLKIT_URL)
            end
        end)
    else
        add("acc_unknown", "CPU / CUDA 가속 정보: " .. (AIM.acc_cmd_ok == false and "이 엔진 버전은 지원하지 않음 (nanum 갱신 필요)"
            or "확인 중…"), function() AIM.refresh() end)
    end
    if d then
        local miss, bytes = AIM.missing(), 0
        for _, m in ipairs(miss) do bytes = bytes + (tonumber(m.size) or 0) end
        local all_val = AIM.active() and "진행 중"
            or (#miss == 0 and "모두 설치됨" or string.format("미설치 %d개 · %s", #miss, AIM.fmt_size(bytes)))
        add("all", "모든 모델 내려받기: " .. all_val, function()
            if not AIM.active() and #AIM.missing() == 0 then
                notify("모든 모델이 이미 설치되어 있습니다", 3, "ok")
            else
                AIM.download("all")
            end
        end)
        local vad = AIM.by_id("vad")
        for _, m in ipairs(AIM.list()) do
            local val
            if AIM.active() and d.current == m.id then
                if d.status == "verifying" then
                    val = "무결성 검증 중"
                    progress[m.id] = 1
                else
                    local pct = AIM.pct()
                    val = string.format("내려받는 중 %s · %s / %s", pct and (pct .. "%") or "…",
                        AIM.fmt_size(d.received), AIM.fmt_size(d.total))
                    progress[m.id] = AIM.fraction() or 0
                end
            elseif m.installed then
                val = "설치됨 · " .. AIM.fmt_size(m.size)
            else
                local size, extra = tonumber(m.size) or 0, ""
                if m.id ~= "vad" and vad and vad.installed ~= true then
                    size = size + (tonumber(vad.size) or 0)
                    extra = " (VAD 포함)"
                end
                val = "미설치 · " .. AIM.fmt_size(size) .. extra
            end
            add(m.id, (m.installed and "● " or "  ") .. tostring(m.label or m.id) .. (AIM.OPTIONAL[m.id] and " (선택)" or "") .. ": " .. val, function()
                if m.installed and not (AIM.active() and AIM.data.current == m.id) then
                    AIM.open_reinstall(m)
                else
                    AIM.download(m.id)
                end
            end)
        end
    end
    add("cancel", "내려받기 취소: " .. (AIM.any_active() and "진행 중인 작업 중단" or "진행 중인 작업 없음"), AIM.cancel)
    if d then
        add("dir", "모델 저장 위치: " .. ((type(d.directory) == "string" and d.directory ~= "") and d.directory or "(알 수 없음)"),
            function() AIM.open_dir(AIM.data and AIM.data.directory) end)
    end
    if a and type(a.directory) == "string" and a.directory ~= "" then
        add("acc_dir", "CUDA 구성 요소 저장 위치: " .. a.directory, function() AIM.open_dir(AIM.acc and AIM.acc.directory) end)
    end
    add("refresh", "설치 상태 새로 확인: 파일 검사", function()
        AIM.refresh()
        notify("설치 상태를 확인합니다", 2)
    end)
    add("prompt", "모델 없음 안내 팝업: " .. (opts.model_prompt and "켬" or "끔"), function()
        opts.model_prompt = not opts.model_prompt
        save_settings()
        AIM.update_menu()
    end)
    add("accel_prompt", "CUDA/엔진 안내 팝업: " .. (opts.accel_prompt and "켬" or "끔"), function()
        opts.accel_prompt = not opts.accel_prompt
        save_settings()
        AIM.update_menu()
    end)
    add("back", "설정 메뉴로 돌아가기", function()
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
        prompt = "AI 구성 요소 관리:",
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
        compute_status = compute_status, style_label = style_label, AIM = AIM, SUBS = SUBS,
        glossary_parse = glossary_parse, glossary_format = glossary_format, glossary_related = glossary_related,
        glossary_entry_parse = glossary_entry_parse, glossary_apply_text = glossary_apply_text,
        set_style = set_style, set_secondary = set_secondary, edit_glossary = edit_glossary,
        override_set_opt_soft = function(f) set_opt_soft = f end,
        regenerate_glossary = regenerate_glossary, open_glossary_menu = open_glossary_menu,
        open_style_menu = open_style_menu, open_display_menu = open_display_menu,
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
