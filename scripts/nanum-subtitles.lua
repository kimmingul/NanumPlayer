-- Subtitle selection for NanumPlayer. scripts/nanum.lua loads this file and calls the factory it returns:
--
--   local ux = factory(ctx)              ctx: the hooks of nanum.lua (see the list below)
--   ux.open(anchor)                      the one subtitle list (subtitle button and Ctrl+N)
--   ux.summary()                         what is shown now, for the settings row
--   ux.open_target_menu(back)            translation target language (Windows language by default)
--   ux.import(path, origin, lang)        a subtitle file the user picked: show as-is or translate
--   ux.file_loaded() / ux.reset()        per-file policy: show a subtitle that already is in the target language
--   ux.status()                          -> text, kind | nil   (status chip)
--
-- One list, every entry says where it comes from:
--   [AI]           the player's own translation (shown translated, or translated + original)
--   [원본 자막]    a subtitle of the media (disc / file / YouTube uploader): always shown as it is
--   [파일]         a subtitle file next to the video or loaded by the user: shown as it is
--   [OCR]          disc image subtitles read by text recognition
-- The display mode (translation / translation + original) belongs to the AI entries only.
--
-- A subtitle that already is in the target language is selected and the AI work of the file is skipped while
-- the user stays on it (YouTube automatic captions do not count as originals). Choosing an AI entry resumes it.

local mp = require 'mp'
local utils = require 'mp.utils'

return function(ctx)
    local input, notify, opts = ctx.input, ctx.notify, ctx.opts
    local function tr(key, ...) return input.core_tr(key, ...) end

    local M = { skip = nil }

    ----------------------------------------------------------------------------
    -- Languages: LLM language name <-> ISO 639-1 code <-> name in the interface language
    ----------------------------------------------------------------------------

    -- { code, name the model is told, Korean key of the interface name, variant }
    local LANGS = {
        { "ko", "Korean", "한국어" }, { "en", "English", "영어" }, { "ja", "Japanese", "일본어" },
        { "zh", "Simplified Chinese", "중국어 (간체)", "hans" }, { "zh", "Traditional Chinese", "중국어 (번체)", "hant" },
        { "es", "Spanish", "스페인어" }, { "fr", "French", "프랑스어" }, { "de", "German", "독일어" },
        { "it", "Italian", "이탈리아어" }, { "pt", "Portuguese", "포르투갈어" }, { "ru", "Russian", "러시아어" },
        { "ar", "Arabic", "아랍어" }, { "hi", "Hindi", "힌디어" }, { "th", "Thai", "태국어" },
        { "vi", "Vietnamese", "베트남어" }, { "id", "Indonesian", "인도네시아어" }, { "ms", "Malay", "말레이어" },
        { "tl", "Filipino", "필리핀어" }, { "bn", "Bengali", "벵골어" }, { "nl", "Dutch", "네덜란드어" },
        { "pl", "Polish", "폴란드어" }, { "tr", "Turkish", "튀르키예어" }, { "sv", "Swedish", "스웨덴어" },
        { "da", "Danish", "덴마크어" }, { "no", "Norwegian", "노르웨이어" }, { "fi", "Finnish", "핀란드어" },
        { "cs", "Czech", "체코어" }, { "el", "Greek", "그리스어" }, { "he", "Hebrew", "히브리어" },
        { "hu", "Hungarian", "헝가리어" }, { "ro", "Romanian", "루마니아어" }, { "uk", "Ukrainian", "우크라이나어" },
        { "fa", "Persian", "페르시아어" },
    }
    M.LANGS = LANGS

    local BY_NAME, BY_CODE = {}, {}
    for _, l in ipairs(LANGS) do
        BY_NAME[l[2]:lower()] = l
        BY_CODE[l[1]] = BY_CODE[l[1]] or l
    end
    BY_NAME["chinese"] = BY_CODE["zh"]          -- plain "Chinese" (older setting): either script

    local function lookup(name)
        name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if name == "" then return nil end
        return BY_NAME[name]
    end

    -- Interface-language name of a language row, or the text the user typed.
    local function display_name(row, raw)
        if row then return tr(row[3]) end
        return raw
    end

    local function option_target()
        local v = mp.get_property("options/nanum-target-language")
        return (type(v) == "string" and v ~= "") and v or "Korean"
    end

    -- The target language in effect: { name = "Korean", code = "ko" | nil, variant = nil | "hans" | "hant", label = "한국어" }
    function M.target()
        local name = option_target()
        local row = lookup(name)
        return { name = name, code = row and row[1] or nil, variant = row and row[4] or nil,
                 label = display_name(row, name), chinese_any = name:lower() == "chinese" }
    end

    -- The Windows display language as the model names it (published by the player at startup).
    function M.os_language()
        local name = mp.get_property("user-data/nanum/os-language-name")
        if type(name) == "string" and name ~= "" then
            return { name = name, code = mp.get_property("user-data/nanum/os-language"),
                     label = display_name(lookup(name), name) }
        end
        return { name = "Korean", code = "ko", label = display_name(BY_CODE["ko"], "Korean") }
    end

    ----------------------------------------------------------------------------
    -- Language of a subtitle track
    ----------------------------------------------------------------------------

    local function utf8_cp(s, i)
        local c = s:byte(i)
        if not c then return nil end
        if c < 0x80 then return c, 1 end
        local n = c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 0
        if n == 0 then return nil end
        local cp = c % (2 ^ (7 - n))
        for k = 1, n - 1 do
            local b = s:byte(i + k)
            if not b or b < 0x80 or b > 0xBF then return nil end
            cp = cp * 64 + (b % 64)
        end
        return cp, n
    end

    -- Language of a text subtitle file by its characters: ko / ja / zh / ru / ar / th / el / he, "en" when the
    -- Latin text is plainly English, nil when it cannot tell (other Latin languages, legacy code pages).
    local sniffed = {}
    function M.sniff(path)
        if type(path) ~= "string" then return nil end
        if sniffed[path] ~= nil then return sniffed[path] or nil end
        local result = false
        local f = io.open(path, "rb")
        if f then
            local s = f:read(16384) or ""
            f:close()
            s = s:gsub("^\239\187\191", ""):gsub("<[^>]*>", " "):gsub("{[^}]*}", " ")
            local cnt = { hangul = 0, kana = 0, han = 0, cyr = 0, arabic = 0, thai = 0, greek = 0, hebrew = 0, latin = 0, letters = 0 }
            local words, hits, i, bad = 0, 0, 1, 0
            local STOP = { the = 1, ["and"] = 1, you = 1, that = 1, ["is"] = 1, ["to"] = 1, ["of"] = 1, it = 1, ["in"] = 1, i = 1,
                ["we"] = 1, ["was"] = 1, ["not"] = 1, ["for"] = 1, ["this"] = 1, ["what"] = 1 }
            while i <= #s do
                local cp, n = utf8_cp(s, i)
                if not cp then
                    bad = bad + 1
                    i = i + 1
                else
                    i = i + n
                    if cp >= 0xAC00 and cp <= 0xD7A3 then cnt.hangul = cnt.hangul + 1
                    elseif cp >= 0x3040 and cp <= 0x30FF then cnt.kana = cnt.kana + 1
                    elseif cp >= 0x4E00 and cp <= 0x9FFF then cnt.han = cnt.han + 1
                    elseif cp >= 0x0400 and cp <= 0x04FF then cnt.cyr = cnt.cyr + 1
                    elseif cp >= 0x0600 and cp <= 0x06FF then cnt.arabic = cnt.arabic + 1
                    elseif cp >= 0x0E00 and cp <= 0x0E7F then cnt.thai = cnt.thai + 1
                    elseif cp >= 0x0370 and cp <= 0x03FF then cnt.greek = cnt.greek + 1
                    elseif cp >= 0x0590 and cp <= 0x05FF then cnt.hebrew = cnt.hebrew + 1
                    elseif (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122) or (cp >= 0xC0 and cp <= 0x24F) then cnt.latin = cnt.latin + 1
                    else cp = nil end
                    if cp then cnt.letters = cnt.letters + 1 end
                end
            end
            if bad > 8 then
                result = false          -- not UTF-8: the player's importer decides (it knows CP949 / Shift-JIS)
            elseif cnt.letters >= 20 then
                local L = cnt.letters
                if cnt.kana / L > 0.04 then result = "ja"
                elseif cnt.hangul / L > 0.2 then result = "ko"
                elseif cnt.han / L > 0.2 then result = "zh"
                elseif cnt.cyr / L > 0.3 then result = "ru"
                elseif cnt.arabic / L > 0.3 then result = "ar"
                elseif cnt.thai / L > 0.3 then result = "th"
                elseif cnt.greek / L > 0.3 then result = "el"
                elseif cnt.hebrew / L > 0.3 then result = "he"
                elseif cnt.latin / L > 0.6 then
                    for w in s:lower():gmatch("%a+") do
                        words = words + 1
                        if STOP[w] then hits = hits + 1 end
                    end
                    if words >= 20 and hits / words > 0.14 then result = "en" end
                end
            end
        end
        sniffed[path] = result
        return result or nil
    end

    local function is_local_file(t)
        local f = t["external-filename"]
        return type(f) == "string" and (f:match("^%a:[/\\]") ~= nil or f:match("^[/\\][/\\]") ~= nil)
    end

    local function basename(p) return tostring(p or ""):match("([^\\/]*)$") or tostring(p or "") end

    -- ISO 639-1 code of a track (mpv's language, the file name suffix "movie.en.srt", else the file's characters).
    function M.track_code(t)
        local code = ctx.norm_lang(t.lang)
        if code then return code end
        if t.external and is_local_file(t) then
            local suffix = ctx.norm_lang(ctx.track_lang(t))
            if suffix and BY_CODE[suffix] then return suffix end
            return M.sniff(t["external-filename"])
        end
        return nil
    end

    -- Chinese script of a track: "hans" | "hant" | nil (unmarked).
    local function chinese_variant(t)
        local hay = ((t.lang or "") .. " " .. (t.title or "") .. " " .. basename(t["external-filename"])):lower()
        -- i18n-ignore: track titles come from files in any language; these are match patterns, not UI text
        if hay:find("hant", 1, true) or hay:find("traditional", 1, true) or hay:find("繁", 1, true) -- i18n-ignore
            or hay:find("tw", 1, true) or hay:find("hk", 1, true) or hay:find("번체", 1, true) then return "hant" end -- i18n-ignore
        if hay:find("hans", 1, true) or hay:find("simplified", 1, true) or hay:find("简", 1, true) -- i18n-ignore
            or hay:find("cn", 1, true) or hay:find("간체", 1, true) then return "hans" end -- i18n-ignore
        return nil
    end

    -- true: the track is in the target language
    local function in_target(t, target)
        if not target.code then return false end
        if M.track_code(t) ~= target.code then return false end
        if target.code == "zh" and not target.chinese_any and target.variant then
            local v = chinese_variant(t)
            return v == nil or v == target.variant
        end
        return true
    end

    ----------------------------------------------------------------------------
    -- Tracks and entries
    ----------------------------------------------------------------------------

    -- i18n-ignore: match patterns for auto-caption track titles in every UI language
    local AUTO_MARKS = { "auto-gen", "auto gen", "autogen", "(auto", "automatic", "자동 생성", "자동생성", "자동 자막", "自動生成", "自动生成", "自動字幕", "自动字幕", "generado automáticamente", "automático" }

    local function is_auto_caption(t)
        local title = tostring(t.title or ""):lower()
        for _, m in ipairs(AUTO_MARKS) do
            if title:find(m, 1, true) then return true end
        end
        return false
    end

    local function is_commentary(t)
        local title = tostring(t.title or ""):lower()
        return title:find("commentary", 1, true) ~= nil or title:find("해설", 1, true) ~= nil -- i18n-ignore: title pattern
    end

    local CODEC = { hdmv_pgs_subtitle = "PGS", dvd_subtitle = "VobSub", subrip = "SRT", srt = "SRT", ass = "ASS", ssa = "SSA",
        webvtt = "WebVTT", mov_text = "MOV", text = "TXT", dvb_subtitle = "DVB" }
    local IMAGE_CODECS = { hdmv_pgs_subtitle = true, dvd_subtitle = true, dvb_subtitle = true, xsub = true }

    -- "primary" | "secondary" | "pgs" | "import" | "full" (ours) | "file" | "orig" | "auto"
    local function kind_of(t)
        local role = ctx.ai_role(t)
        if role then return role end
        if is_auto_caption(t) then return "auto" end
        if t.external and is_local_file(t) then return "file" end
        return "orig"
    end

    local function sub_tracks()
        local r = {}
        for _, t in ipairs(mp.get_property_native("track-list") or {}) do
            if t.type == "sub" then r[#r + 1] = t end
        end
        return r
    end

    local function track_by_id(id)
        for _, t in ipairs(sub_tracks()) do
            if t.id == id then return t end
        end
        return nil
    end

    -- "영어 · SRT" / "영어 · movie.en.srt" / "일본어 · PGS · 강제"
    local function orig_label(t, kind)
        local code = M.track_code(t)
        local row = code and BY_CODE[code] or nil
        local parts = {}
        if row then
            parts[1] = display_name(row)
            if code == "zh" then
                local v = chinese_variant(t)
                if v then parts[1] = tr(v == "hant" and "중국어 (번체)" or "중국어 (간체)") end
            end
        elseif code then
            parts[1] = ctx.lang_name(code) or code
        elseif t.lang and t.lang ~= "" then
            parts[1] = t.lang
        else
            parts[1] = tr("알 수 없음")
        end
        local title = type(t.title) == "string" and t.title or ""
        if kind == "file" then
            parts[#parts + 1] = basename(t["external-filename"])
        else
            if title ~= "" and title:lower() ~= tostring(t.lang or ""):lower() and not (row and title == parts[1]) then
                parts[#parts + 1] = title
            end
            local codec = t.codec and (CODEC[t.codec:lower()] or t.codec:upper()) or nil
            if codec then parts[#parts + 1] = codec end
        end
        if t.forced then parts[#parts + 1] = tr("강제") end
        if kind == "auto" then parts[#parts + 1] = tr("자동 생성") end
        return table.concat(parts, " · ")
    end

    local BADGE = { ai = "AI", orig = "원본 자막", file = "파일", ocr = "OCR" }
    local BADGE_COLOR = { ai = "accent", orig = "ok", file = "warn", ocr = "text2" }

    -- The AI presentation the display preference stands for. "source" (older setting) is not an AI entry of a
    -- subtitle-based track: the original track is the source text.
    local function ai_modes(kind, source_is_text)
        local modes = { "translation", "bilingual" }
        if (kind == "primary" and not source_is_text) or kind == "pgs" then modes[#modes + 1] = "source" end
        return modes
    end

    -- -> list of entries { kind =, id =, mode =, label =, badge =, current = }
    function M.entries()
        local tracks = sub_tracks()
        local target = M.target()
        local list = {}
        local cur_id
        for _, t in ipairs(tracks) do
            if t.selected then cur_id = t.id end
        end
        local display = ctx.get_display()
        local src_lang = ctx.primary_source_lang()
        local same = src_lang ~= nil and target.code ~= nil and src_lang == target.code
        local sub_input = ctx.primary_is_text()

        local function add(e)
            list[#list + 1] = e
        end

        local ai = {}
        for _, t in ipairs(tracks) do
            local k = kind_of(t)
            if k == "primary" or k == "full" or k == "secondary" or k == "import" or k == "pgs" then ai[#ai + 1] = { t = t, k = k } end
        end

        -- AI entries first
        for _, a in ipairs(ai) do
            local t, k = a.t, a.k
            local modes = ai_modes(k, sub_input)
            local has_source_mode = false
            for _, m in ipairs(modes) do if m == "source" then has_source_mode = true end end
            local badge = k == "pgs" and "ocr" or (k == "import" and "file" or "ai")
            if k == "primary" then
                local lang_row = src_lang and BY_CODE[src_lang] or nil
                local src_label = src_lang and display_name(lang_row, ctx.lang_name(src_lang) or src_lang) or nil
                if same then
                    -- nothing to translate: only what is recognised is offered (a subtitle-based input is the original track)
                    if not sub_input then
                        add({ kind = "ai", id = t.id, mode = "source", has_source_mode = true, badge = badge,
                              label = tr("%s (AI 음성 인식)", target.label) })
                    end
                else
                    add({ kind = "ai", id = t.id, mode = "translation", has_source_mode = has_source_mode, badge = badge,
                          label = tr("%s (AI 번역)", target.label) })
                    add({ kind = "ai", id = t.id, mode = "bilingual", has_source_mode = has_source_mode, badge = badge,
                          label = tr("%s + 원문 (AI)", target.label) })
                    if has_source_mode then
                        add({ kind = "ai", id = t.id, mode = "source", has_source_mode = true, badge = badge,
                              label = src_label and tr("%s 원문 (AI 음성 인식)", src_label) or tr("원문 (AI 음성 인식)") })
                    end
                end
            elseif k == "full" then
                add({ kind = "ai", id = t.id, badge = badge, label = tr("%s (AI 전체 번역)", target.label) })
            else
                local title = (type(t.title) == "string" and t.title ~= "") and t.title or target.label
                if k == "pgs" then
                    add({ kind = "ai", id = t.id, mode = "translation", has_source_mode = true, badge = badge, label = title })
                    add({ kind = "ai", id = t.id, mode = "bilingual", has_source_mode = true, badge = badge, label = tr("%s + 원문", title) })
                    local pl = ctx.pgs_language()
                    add({ kind = "ai", id = t.id, mode = "source", has_source_mode = true, badge = badge,
                          label = pl and tr("%s 원문 (디스크 자막 OCR)", display_name(BY_CODE[pl], ctx.lang_name(pl) or pl)) or tr("원문 (디스크 자막 OCR)") })
                else
                    add({ kind = "ai", id = t.id, mode = "translation", has_source_mode = false, badge = badge, label = title })
                    add({ kind = "ai", id = t.id, mode = "bilingual", has_source_mode = false, badge = badge, label = tr("%s + 원문", title) })
                end
            end
        end

        -- originals (disc / file / YouTube uploader), then files
        for _, want in ipairs({ "orig", "auto", "file" }) do
            for _, t in ipairs(tracks) do
                if kind_of(t) == want then
                    add({ kind = want, id = t.id, badge = want == "file" and "file" or "orig", label = orig_label(t, want),
                          lang_target = in_target(t, target) })
                end
            end
        end

        add({ kind = "off", badge = nil, label = tr("끄기") })
        -- the checked entry: the selected track; among the presentations of an AI track the one the display
        -- preference stands for (the first one if it has none of that kind)
        local found = false
        for _, e in ipairs(list) do
            if e.kind == "off" then
                e.current = cur_id == nil
            elseif e.id == cur_id and not found then
                if e.kind == "ai" and e.mode ~= nil then
                    local match
                    for _, o in ipairs(list) do
                        if o.id == cur_id and o.mode == display then match = o end
                    end
                    e.current = (match or e) == e
                else
                    e.current = true
                end
                found = found or e.current
            else
                e.current = false
            end
        end
        return list
    end

    ----------------------------------------------------------------------------
    -- Applying an entry
    ----------------------------------------------------------------------------

    local own_change = 0            -- time of our own track switch: the sid observer ignores the echo

    local function select_track(id)
        own_change = mp.get_time()
        if id then mp.set_property_number("sid", id) else mp.set_property("sid", "no") end
    end

    function M.apply(e)
        if e.kind == "off" then
            select_track(nil)
            return
        end
        if e.kind == "ai" then
            if e.mode then ctx.set_display(e.mode) end
            local t = track_by_id(e.id)
            if t then
                select_track(e.id)
                if M.skip then M.resume() end
            end
            return
        end
        select_track(e.id)
        local t = track_by_id(e.id)
        if t then M.consider(t) end
    end

    ----------------------------------------------------------------------------
    -- Original subtitle in the target language: shown directly, the AI work of the file is skipped
    ----------------------------------------------------------------------------

    -- The best subtitle of the media that already is in the target language: a file next to the video first,
    -- then an embedded text subtitle, then an embedded image subtitle (disc). Never forced / commentary / automatic.
    function M.find_original(tracks)
        local target = M.target()
        if not target.code then return nil end
        local best, best_score
        for _, t in ipairs(tracks or sub_tracks()) do
            local k = kind_of(t)
            if (k == "orig" or k == "file") and not t.forced and not is_commentary(t) and in_target(t, target) then
                local score = (k == "file" and 0 or 10)
                if IMAGE_CODECS[tostring(t.codec or ""):lower()] then score = score + 5 end
                if t.default then score = score - 1 end
                local title = tostring(t.title or ""):lower()
                if title:find("sdh", 1, true) or title:find("hearing", 1, true) or title:find("cc", 1, true) then score = score + 3 end
                if not best or score < best_score then best, best_score = t, score end
            end
        end
        return best
    end

    -- manual: the user picked this original subtitle; the AI work pauses whatever its language
    -- (the automatic choice only takes target-language originals and follows original_first).
    function M.begin_skip(t, manual)
        if ctx.ai_off_by_user() then return end
        if not manual and not opts.original_first then return end
        if M.skip and M.skip.id == t.id then return end
        local was = M.skip ~= nil
        local target = in_target(t, M.target())
        M.skip = { id = t.id, label = orig_label(t, kind_of(t)), file = kind_of(t) == "file", target = target }
        if not was then ctx.skip_ai(true) end
        if target then
            notify(tr("%s 자막이 있어 바로 표시합니다 · AI 작업은 건너뜁니다 (AI 자막을 고르면 다시 시작)", M.target().label), 6, "ok", "sub-original")
        else
            notify(tr("원본 자막을 표시합니다 · AI 작업을 일시 중지합니다 (AI 자막을 고르면 다시 시작)"), 6, "ok", "sub-original")
        end
    end

    function M.resume()
        if not M.skip then return end
        M.skip = nil
        ctx.skip_ai(false)
        notify(tr("AI 자막 작업을 다시 시작합니다"), 3, "info", "sub-original")
    end

    -- A track was chosen (menu, keys, other script): an original subtitle is shown as it is, so the AI work of
    -- the file pauses (forced / commentary tracks only accompany other subtitles and do not pause it).
    function M.consider(t)
        if not ctx.file_ready() then return end
        local k = kind_of(t)
        if k == "orig" or k == "file" then
            if not t.forced and not is_commentary(t) then
                M.begin_skip(t, true)
            end
        elseif k == "primary" or k == "secondary" or k == "pgs" or k == "import" or k == "full" then
            if M.skip then M.resume() end
        end
    end

    -- Once per file, with the tracks of the file: pick the target-language original.
    function M.file_loaded()
        M.skip = nil
        if not opts.original_first then return end
        local t = M.find_original()
        if not t then return end
        select_track(t.id)
        M.begin_skip(t)
    end

    -- Late subtitles (a file added while playing): the same choice, once, if the file has none yet.
    function M.tracks_changed()
        if M.skip or not opts.original_first or not ctx.file_ready() or ctx.ai_off_by_user() then return end
        if mp.get_time() - ctx.loaded_at() > 4 then return end          -- later additions are the user's business
        local t = M.find_original()
        if t then
            select_track(t.id)
            M.begin_skip(t)
        end
    end

    -- The original text track the AI subtitles are made from (nil when they come from speech recognition).
    function M.source_track()
        return ctx.input_track()
    end

    function M.reset()
        if M.skip then
            M.skip = nil
            ctx.skip_ai(false, true)
        end
        sniffed = {}
    end

    mp.observe_property("sid", "native", function(_, sid)
        if sid == nil or sid == false or not ctx.file_ready() then return end
        if mp.get_time() - own_change < 0.3 then return end
        local t = track_by_id(sid)
        if t then M.consider(t) end
    end)

    -- Text for the status chip while the original is shown instead of AI subtitles.
    function M.status()
        if not (M.skip and ctx.ai_off_by_skip()) then return nil end
        local t = track_by_id(M.skip.id)
        if t and t.selected then
            if M.skip.target then return tr("%s 자막 표시 중 · AI 작업 건너뜀", M.target().label), "ok" end
            return tr("원본 자막 표시 중 · AI 작업 일시 중지"), "ok"
        end
        return tr("AI 작업 꺼짐 · 자막 목록에서 AI 자막을 고르면 시작합니다"), "info"
    end

    ----------------------------------------------------------------------------
    -- Menu
    ----------------------------------------------------------------------------

    -- Short description of what is shown now (settings row).
    function M.summary()
        local list = M.entries()
        for _, e in ipairs(list) do
            if e.current and e.kind ~= "off" then return e.label end
        end
        return tr("끄기")
    end

    function M.open(anchor)
        if not ctx.file_ready() then
            -- nothing is playing: the list would only say so
            notify(tr("영상을 재생한 뒤에 사용할 수 있습니다"), 3, "warn")
            return
        end
        local list = M.entries()
        local items, badges, colors, keys, actions = {}, {}, {}, {}, {}
        local default = #list
        for i, e in ipairs(list) do
            items[i] = (e.current and "● " or "  ") .. e.label
            badges[i] = e.badge and tr(BADGE[e.badge]) or false
            colors[i] = e.badge and BADGE_COLOR[e.badge] or false
            keys[i] = e.kind .. ":" .. tostring(e.id or "") .. ":" .. tostring(e.mode or "")
            if e.current then default = i end
        end
        for _, e in ipairs(list) do
            mp.msg.verbose(string.format("subtitle list: %s%s%s", e.current and "* " or "  ", e.label, e.badge and (" [" .. e.badge .. "]") or ""))
        end
        local function extra(text, fn)
            items[#items + 1] = "  " .. text
            badges[#badges + 1] = false
            colors[#colors + 1] = false
            keys[#keys + 1] = "action:" .. #items
            actions[#items] = fn
        end
        local base = #list
        extra(tr("자막 파일 불러오기…"), function() ctx.pick_file() end)
        extra(tr("번역 목표 언어: %s", M.target().label), function() mp.add_timeout(0.1, function() M.open_target_menu(function() M.open(anchor) end) end) end)
        input.select({
            id = "nanum-subtitles",
            prompt = tr("자막:"),
            items = items,
            badges = badges,
            badge_colors = colors,
            keys = keys,
            default_item = default,
            anchor = anchor,
            submit = function(i)
                if i <= base then
                    M.apply(list[i])
                elseif actions[i] then
                    actions[i]()
                end
            end,
        })
    end

    ----------------------------------------------------------------------------
    -- Target language menu
    ----------------------------------------------------------------------------

    local function set_target(name, auto)
        opts.target_language = auto and "" or name
        local value = auto and M.os_language().name or name
        mp.set_property("options/nanum-target-language", value)
        ctx.save_settings()
        notify(tr("번역 목표 언어: %s (다음에 여는 파일부터 적용)", display_name(lookup(value), value)), 4, "ok")
    end

    function M.open_target_menu(back)
        local cur = option_target()
        local os = M.os_language()
        local items, actions = {}, {}
        local function add(text, fn)
            items[#items + 1] = text
            actions[#actions + 1] = fn
        end
        local auto = opts.target_language == ""
        add((auto and "● " or "  ") .. tr("자동 — Windows 표시 언어 (%s)", os.label), function() set_target(nil, true) end)
        local default = auto and 1 or nil
        local known = false
        for _, l in ipairs(LANGS) do
            local is_cur = not auto and cur:lower() == l[2]:lower()
            if is_cur then known = true end
            add((is_cur and "● " or "  ") .. display_name(l) .. "  (" .. l[2] .. ")", function() set_target(l[2], false) end)
            if is_cur then default = #items end
        end
        if not auto and not known then
            add("● " .. cur, function() end)
            default = #items
        end
        add("  " .. tr("직접 입력…"), function()
            mp.add_timeout(0.1, function()
                input.get({
                    prompt = tr("번역 목표 언어 (모델이 알아듣는 언어 이름, 예: Italian):"),
                    default_text = cur,
                    submit = function(text)
                        input.terminate()
                        text = text:gsub("^%s+", ""):gsub("%s+$", "")
                        if text == "" then
                            set_target(nil, true)
                        else
                            local row = lookup(text)
                            set_target(row and row[2] or text, false)
                        end
                        if back then mp.add_timeout(0.1, back) end
                    end,
                })
            end)
        end)
        input.select({
            id = "nanum-target-language",
            prompt = tr("번역 목표 언어 (다음에 여는 파일부터 적용):"),
            items = items,
            default_item = default or 1,
            submit = function(i)
                local fn = actions[i]
                if fn then fn() end
                -- the free-text row opens its own prompt and returns by itself
                if i < #items and back then mp.add_timeout(0.1, back) end
            end,
        })
    end

    ----------------------------------------------------------------------------
    -- Subtitle files: as they are, or translated by the AI
    ----------------------------------------------------------------------------

    local function norm_path(p) return tostring(p or ""):gsub("/", "\\"):lower() end

    -- Adds the file as an ordinary subtitle track and shows it.
    function M.add_file(path, lang)
        for _, t in ipairs(sub_tracks()) do
            if t.external and norm_path(t["external-filename"]) == norm_path(path) then
                select_track(t.id)
                M.consider(t)
                return
            end
        end
        local code = lang and lang ~= "" and lang or M.sniff(path) or ctx.norm_lang(ctx.track_lang({ ["external-filename"] = path })) or ""
        -- the new track is selected by sub-add; the sid observer / consider() then decides about the AI work
        local ok = mp.commandv("sub-add", path, "select", basename(path), code)
        if not ok then
            notify(tr("자막 파일을 불러오지 못했습니다: %s", basename(path)), 5, "error")
            return
        end
        notify(tr("자막 파일을 그대로 표시합니다: %s", basename(path)), 4, "ok")
        mp.add_timeout(0.4, function()
            for _, t in ipairs(sub_tracks()) do
                if t.external and norm_path(t["external-filename"]) == norm_path(path) then
                    M.consider(t)
                    return
                end
            end
        end)
    end

    -- A subtitle file the user picked / downloaded: show as it is, or let the AI align it and translate.
    function M.import(path, origin, lang)
        if not ctx.file_ready() then
            notify(tr("영상을 재생한 뒤에 사용할 수 있습니다"), 4, "warn")
            return
        end
        local code = lang and lang ~= "" and ctx.norm_lang(lang) or M.sniff(path)
        local target = M.target()
        local same = code ~= nil and target.code == code
        local name = basename(path)
        local items = { tr("그대로 표시 (원본 자막 그대로)") }
        if same then
            items[2] = tr("AI로 영상에 시간 맞추기 (이미 %s 자막)", target.label)
        else
            items[2] = tr("AI로 시간 맞추고 %s로 번역", target.label)
        end
        input.select({
            prompt = tr("자막 파일: %s", name),
            items = items,
            default_item = 1,
            submit = function(i)
                if i == 1 then
                    M.add_file(path, code)
                else
                    ctx.translate_import(path, origin, lang)
                end
            end,
        })
    end

    return M
end
