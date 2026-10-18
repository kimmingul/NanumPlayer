-- Subtitle file generation without playback (the "nanum-generate" command of the player, see
-- osdep/nanum-generate.h). scripts/nanum.lua loads this file and calls the factory it returns:
--
--   local gen = factory({ input = <fluent input>, notify = notify, reopen_menu = function() end })
--   gen.open()               the menu: source track, target languages, output folder, start / cancel
--   gen.start(request)       start a job without the menu; request: { url, source, track, source_lang,
--                            targets = { { code, name } }, directory, name, title, glossary, limit,
--                            write_source }  (the spec of the command). true, or nil + reason
--   gen.cancel()             stops the running job; files that were already finished stay
--   gen.state()              the last user-data/nanum/generate table (busy, status, progress, outputs, ...)
--
-- Also reachable by script messages (sent to the script that loaded this file):
--   nanum-generate-start <json request>      nanum-generate-cancel      nanum-generate-open
--
-- The job runs in the player's native code on a thread of its own: it opens its own demuxer on the file or the
-- disc title, reads the one stream it needs as fast as the source delivers it (speech recognition of an audio
-- track, the text of a subtitle track, or OCR of an image subtitle track) and writes <name>.<language>.srt files:
-- the source language first, then one translation per chosen language. Nothing is written unless the user starts
-- a job here, files are never overwritten (a taken name gets .2, .3, ...), and nothing is remembered afterwards.

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local WIN = package.config:sub(1, 1) == '\\'
local ASS_SOURCE_ID = 0x4e414e          -- demuxer ids of the AI's virtual tracks (nanum.c)
local NO_ID_BASE = 0x40000000           -- track key of a stream without a demuxer id (nanum.c stream_key())
local PREVIEW_SECONDS = 600

local TEXT_CODECS = {
    subrip = true, srt = true, ass = true, ssa = true, mov_text = true, webvtt = true, text = true,
    microdvd = true, subviewer = true, subviewer1 = true, vplayer = true, pjs = true, mpl2 = true,
    stl = true, realtext = true, jacosub = true, sami = true,
}
local IMAGE_CODECS = { hdmv_pgs_subtitle = true, dvd_subtitle = true }

-- The languages the menu offers (any other language can be typed). name is what the translator is told.
local LANGS = {
    { code = 'ko', name = 'Korean', label = '한국어' },
    { code = 'en', name = 'English', label = '영어' },
    { code = 'ja', name = 'Japanese', label = '일본어' },
    { code = 'zh-CN', name = 'Simplified Chinese', label = '중국어 간체' },
    { code = 'zh-TW', name = 'Traditional Chinese', label = '중국어 번체' },
    { code = 'es', name = 'Spanish', label = '스페인어' },
    { code = 'fr', name = 'French', label = '프랑스어' },
    { code = 'de', name = 'German', label = '독일어' },
    { code = 'it', name = 'Italian', label = '이탈리아어' },
    { code = 'pt', name = 'Portuguese', label = '포르투갈어' },
    { code = 'ru', name = 'Russian', label = '러시아어' },
    { code = 'vi', name = 'Vietnamese', label = '베트남어' },
    { code = 'th', name = 'Thai', label = '태국어' },
    { code = 'id', name = 'Indonesian', label = '인도네시아어' },
    { code = 'ar', name = 'Arabic', label = '아랍어' },
    { code = 'hi', name = 'Hindi', label = '힌디어' },
    { code = 'tr', name = 'Turkish', label = '터키어' },
    { code = 'pl', name = 'Polish', label = '폴란드어' },
    { code = 'nl', name = 'Dutch', label = '네덜란드어' },
}

-- ISO 639-2 (what track-list reports) -> ISO 639-1
local ISO3 = {
    eng = 'en', jpn = 'ja', kor = 'ko', zho = 'zh', chi = 'zh', fra = 'fr', fre = 'fr', deu = 'de', ger = 'de',
    spa = 'es', ita = 'it', por = 'pt', rus = 'ru', vie = 'vi', tha = 'th', ind = 'id', ara = 'ar', hin = 'hi',
    tur = 'tr', pol = 'pl', nld = 'nl', dut = 'nl',
}

local function load_translator()
    local dirs = {}
    local info = debug and debug.getinfo and debug.getinfo(1, 'S')
    local src = info and info.source or ''
    if src:sub(1, 1) == '@' then
        local d = src:sub(2):match('^(.*)[/\\][^/\\]*$')
        if d then dirs[#dirs + 1] = d end
    end
    local sd = mp.get_script_directory and mp.get_script_directory()
    if sd then dirs[#dirs + 1] = sd end
    local ok, ed = pcall(mp.command_native, { 'expand-path', '~~exe_dir/scripts' })
    if ok and type(ed) == 'string' and ed ~= '' then dirs[#dirs + 1] = ed end
    for _, d in ipairs(dirs) do
        local f = loadfile(d .. '/nanum-i18n.lua')
        if f then
            local okf, mod = pcall(f)
            if okf and type(mod) == 'table' then return mod.translator('generate') end
            msg.error('nanum-i18n.lua: ' .. tostring(mod))
        end
    end
    msg.error('nanum-generate: scripts/nanum-i18n.lua not found; messages stay in their source language')
    return function(key, ...)
        if select('#', ...) > 0 then return string.format(key, ...) end
        return key
    end
end
local tr = load_translator()

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function lang_code(l)
    l = tostring(l or ''):lower()
    if l == '' or l == 'und' then return '' end
    if ISO3[l] then return ISO3[l] end
    if #l == 2 then return l end
    return ''
end

local function lang_entry(code, name)
    code, name = tostring(code or ''), tostring(name or ''):lower()
    for _, l in ipairs(LANGS) do
        if (code ~= '' and l.code:lower() == code:lower()) or (name ~= '' and l.name:lower() == name) then return l end
    end
    -- "Chinese" and a bare "zh" mean simplified Chinese
    if code:lower() == 'zh' or name == 'chinese' then return LANGS[4] end
    return nil
end

local function lang_label(l)
    local e = lang_entry(l.code, l.name)
    if e then return tr(e.label) end
    return l.name ~= '' and l.name or l.code
end

local function seconds_text(sec)
    sec = math.floor(tonumber(sec) or 0)
    if sec < 0 then sec = 0 end
    local h, m, s = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
    if h > 0 then return ('%d:%02d:%02d'):format(h, m, s) end
    return ('%d:%02d'):format(m, s)
end

local function basename(p)
    return (tostring(p):match('([^/\\]+)$')) or tostring(p)
end

local function win_path(p)
    if WIN then return (tostring(p):gsub('/', '\\')) end
    return tostring(p)
end

local function is_absolute(p)
    return p:match('^%a:[/\\]') ~= nil or p:match('^[/\\][/\\]') ~= nil or (not WIN and p:sub(1, 1) == '/')
end

local function dirname(p)
    return (tostring(p):match('^(.*)[/\\][^/\\]*$'))
end

local function strip_ext(name)
    return (tostring(name):gsub('%.[^.]*$', ''))
end

return function(env)
    env = env or {}
    local input = env.input
    local notify = env.notify or function() end
    local GEN = {}
    local S = {
        job = nil,              -- { handle, request, cancelling }
        last = nil,             -- the result of the last job
        state = nil,            -- user-data/nanum/generate
        sel = {                 -- the menu's choices (kept in memory only)
            source = nil,       -- index into the source list, nil: the default
            targets = nil,      -- { { code, name } }, nil: the target language of the player
            where = nil,        -- 'next' | 'videos' | 'custom'
            custom_dir = '',
            keep_source = true,
            preview = false,
            url = nil,          -- a media the user typed instead of the current one
        },
        last_toast = 0,
    }

    local function say(text, secs, kind, id)
        notify(text, secs or 4, kind or 'info', id or 'nanum-generate')
    end

    ----------------------------------------------------------------------------
    -- The media

    local function disc_device()
        local d = mp.get_property('options/bluray-device') or mp.get_property('bluray-device') or ''
        return trim(d)
    end

    -- { url, kind = 'file'|'disc', name } of what the job reads; nil, reason
    local function media()
        local typed = S.sel.url
        local path = typed or mp.get_property('path')
        if not path or path == '' then return nil, tr('먼저 영상을 열거나 대상 파일을 지정하세요') end
        local lower = path:lower()
        if lower:match('^bd://') or lower:match('^bluray://') or lower:match('^br://') then
            local url = path
            -- bd://longest has no drive: the player's --bluray-device is it (bd://longest/E:)
            if not url:match('^%a+://[^/]*/.+') and disc_device() ~= '' and not typed then
                url = url .. '/' .. disc_device()
            end
            local title = trim(mp.get_property('media-title') or '')
            if title == '' or title:lower():match('^bd://') then title = tr('디스크') end
            return { url = url, kind = 'disc', name = title }
        end
        if path:match('^%a[%w+.-]*://') and not lower:match('^file://') then
            return nil, tr('파일이나 Blu-ray 디스크만 처리할 수 있습니다 (웹 영상은 재생 중 AI 자막을 사용하세요)')
        end
        if not is_absolute(path) and not typed then
            local wd = mp.get_property('working-directory') or ''
            if wd ~= '' then path = utils.join_path(wd, path) end
        end
        path = win_path(path)
        return { url = path, kind = 'file', name = strip_ext(basename(path)) }
    end

    local function same_as_playing(m)
        local path = mp.get_property('path') or ''
        return m and not S.sel.url and path ~= ''
    end

    ----------------------------------------------------------------------------
    -- Sources: what the subtitles can be made from

    local function track_key(t)
        local id = t['src-id']
        if type(id) == 'number' and id >= 0 then return id end
        local ff = t['ff-index']
        if type(ff) == 'number' then return NO_ID_BASE + ff end
        return -1
    end

    local function audio_language()
        for _, t in ipairs(mp.get_property_native('track-list') or {}) do
            if t.type == 'audio' and t.selected then return lang_code(t.lang) end
        end
        for _, t in ipairs(mp.get_property_native('track-list') or {}) do
            if t.type == 'audio' then return lang_code(t.lang) end
        end
        return ''
    end

    local function describe_lang(code)
        if code == '' then return tr('언어 미상') end
        local e = lang_entry(code)
        return e and tr(e.label) or code
    end

    -- The choices, best first: { kind = 'stt'|'text'|'ocr', track, lang, url, label }
    local function sources()
        local m = media()
        local list = {}
        if not m or not same_as_playing(m) then
            -- a file the user typed: its tracks are not known here, so the audio is read
            if m then
                list[1] = { kind = 'stt', track = -1, lang = '', label = tr('음성 인식 — 자동으로 고른 음성 트랙') }
                list[2] = { kind = 'text', track = -1, lang = '', label = tr('텍스트 자막 — 자동으로 고른 트랙') }
                if m.kind == 'disc' then
                    list[3] = { kind = 'ocr', track = -1, lang = '', label = tr('이미지 자막(OCR) — 자동으로 고른 트랙') }
                end
            end
            return list
        end
        local alang = audio_language()
        local audio, text, image = {}, {}, {}
        for _, t in ipairs(mp.get_property_native('track-list') or {}) do
            local id = t['src-id']
            local virtual = type(id) == 'number' and id >= ASS_SOURCE_ID and id < ASS_SOURCE_ID + 8
            if not virtual then
                local lang = lang_code(t.lang)
                local title = trim(t.title or '')
                local extra = title ~= '' and (' · ' .. title) or ''
                if t.forced then extra = extra .. ' · ' .. tr('강제') end
                if t.type == 'audio' then
                    audio[#audio + 1] = { kind = 'stt', track = track_key(t), lang = lang, selected = t.selected,
                        label = tr('음성 인식 — %s 음성%s', describe_lang(lang), extra) }
                elseif t.type == 'sub' then
                    if t.external and t['external-filename'] then
                        text[#text + 1] = { kind = 'text', track = -1, lang = lang, forced = t.forced,
                            url = t['external-filename'],
                            label = tr('외부 자막 파일 — %s · %s', describe_lang(lang), basename(t['external-filename'])) }
                    elseif TEXT_CODECS[t.codec or ''] then
                        text[#text + 1] = { kind = 'text', track = track_key(t), lang = lang, forced = t.forced,
                            label = tr('텍스트 자막 — %s%s', describe_lang(lang), extra) }
                    elseif IMAGE_CODECS[t.codec or ''] then
                        image[#image + 1] = { kind = 'ocr', track = track_key(t), lang = lang, forced = t.forced,
                            label = tr('이미지 자막(OCR) — %s%s', describe_lang(lang), extra) }
                    end
                end
            end
        end
        -- Order: a text track in the audio language, an image track in it, the audio itself, then the rest.
        local function pick(group, want_lang)
            local out = {}
            for _, s in ipairs(group) do
                if not s.forced and (want_lang == nil or s.lang == want_lang) then out[#out + 1] = s end
            end
            return out
        end
        local used = {}
        local function add(s)
            if not used[s] then used[s] = true; list[#list + 1] = s end
        end
        if alang ~= '' then
            for _, s in ipairs(pick(text, alang)) do add(s) end
            for _, s in ipairs(pick(image, alang)) do add(s) end
        end
        table.sort(audio, function(a, b)
            if (a.selected and 1 or 0) ~= (b.selected and 1 or 0) then return a.selected end
            return false
        end)
        for _, s in ipairs(audio) do add(s) end
        for _, s in ipairs(pick(text)) do add(s) end
        for _, s in ipairs(pick(image)) do add(s) end
        for _, s in ipairs(text) do add(s) end
        for _, s in ipairs(image) do add(s) end
        return list
    end

    local function chosen_source(list)
        local i = S.sel.source
        if i and list[i] then return list[i], i end
        return list[1], 1
    end

    ----------------------------------------------------------------------------
    -- Targets and output

    local function default_targets()
        local name = trim(mp.get_property('options/nanum-target-language') or '')
        if name == '' then name = 'Korean' end
        local e = lang_entry(name, name)
        if e then return { { code = e.code, name = e.name } } end
        return { { code = '', name = name } }
    end

    local function targets()
        return S.sel.targets or default_targets()
    end

    local function targets_text(list)
        if #list == 0 then return tr('번역 안 함 (원문만)') end
        local t = {}
        for _, l in ipairs(list) do t[#t + 1] = lang_label(l) end
        return table.concat(t, ', ')
    end

    local function target_index(list, l)
        for i, x in ipairs(list) do
            if (l.code ~= '' and x.code == l.code) or (l.code == '' and x.name:lower() == l.name:lower()) then return i end
        end
        return nil
    end

    local function videos_dir()
        local profile = os.getenv('USERPROFILE') or ''
        if profile == '' then return nil end
        return profile .. '\\Videos\\NanumPlayer'
    end

    local function where_default(m)
        if S.sel.where then return S.sel.where end
        return (m and m.kind == 'disc') and 'videos' or 'next'
    end

    -- The folder the files go to; nil, reason
    local function output_dir(m)
        local w = where_default(m)
        if w == 'custom' then
            if S.sel.custom_dir == '' then return nil, tr('저장할 폴더를 지정하세요') end
            return S.sel.custom_dir
        end
        if w == 'videos' then
            local d = videos_dir()
            if not d then return nil, tr('기본 동영상 폴더를 찾을 수 없습니다') end
            return d
        end
        if m.kind ~= 'file' then return nil, tr('디스크는 영상 옆에 저장할 수 없습니다. 저장 위치를 고르세요') end
        return dirname(m.url) or ''
    end

    local function where_text(m)
        local w = where_default(m)
        if w == 'custom' then return S.sel.custom_dir ~= '' and S.sel.custom_dir or tr('(지정 안 됨)') end
        if w == 'videos' then return tr('동영상\\NanumPlayer 폴더') end
        return tr('영상과 같은 폴더')
    end

    ----------------------------------------------------------------------------
    -- Running

    local function phase_text(st)
        local s = st.status
        if s == 'opening' then return tr('영상 여는 중') end
        if s == 'scanning' then
            if st.source == 'stt' then return tr('음성 인식 중') end
            if st.source == 'ocr' then return tr('이미지 자막 OCR 중') end
            return tr('자막 읽는 중')
        end
        if s == 'glossary' then return tr('작품 용어집 준비 중') end
        if s == 'translating' then
            local name = st.target_name ~= '' and lang_label({ code = '', name = st.target_name }) or '?'
            return tr('%s로 번역 중', name)
        end
        return tostring(s or '')
    end

    local function progress_text(st)
        local pct = math.floor(math.max(0, math.min(1, tonumber(st.progress) or 0)) * 100)
        local t = tr('%s — %d%%', phase_text(st), pct)
        if st.status == 'scanning' and (st.duration or 0) > 0 then
            t = t .. ' (' .. seconds_text(st.position) .. ' / ' .. seconds_text(st.duration) .. ')'
        end
        if (st.lines or 0) > 0 and st.status == 'scanning' and st.source ~= 'stt' then
            t = t .. ' · ' .. tr('%d줄', st.lines)
        end
        return t
    end

    local function file_list(outputs)
        local t = {}
        for _, o in ipairs(outputs or {}) do t[#t + 1] = basename(o.file) end
        return table.concat(t, ', ')
    end

    local function on_state(_, st)
        if type(st) ~= 'table' then return end
        S.state = st
        if not S.job then return end
        local now = mp.get_time()
        if st.busy and now - S.last_toast >= 1 then
            S.last_toast = now
            say(progress_text(st) .. '\n' .. tr('Ctrl+N → 자막 파일 만들기에서 취소할 수 있습니다'), 3, 'busy')
        end
        if input and input.open_id and input.open_id() == 'nanum-generate' and GEN.refresh then GEN.refresh() end
    end

    local function finish(result, err)
        local job = S.job
        S.job = nil
        S.last = type(result) == 'table' and result or { ok = false, error = tostring(err or '') }
        local r = S.last
        local outputs = r.outputs or {}
        if r.status == 'cancelled' or (job and job.cancelling and not r.ok) then
            say(tr('취소됨 — 이미 저장된 파일 %d개는 유지됩니다', #outputs), 6, 'warn')
        elseif r.ok then
            local text = tr('자막 파일 저장 완료 (%d개)\n%s', #outputs, r.directory or '')
            if (r.warning or '') ~= '' then text = text .. '\n' .. tr('참고: %s', r.warning) end
            say(text, 10, 'ok')
        else
            local reason = trim(r.error or '')
            if reason == '' then reason = tostring(err or tr('알 수 없는 오류')) end
            local text = tr('자막 생성 실패: %s', reason)
            if #outputs > 0 then text = text .. '\n' .. tr('저장된 파일: %s', file_list(outputs)) end
            say(text, 12, 'error')
        end
        if input and input.open_id and input.open_id() == 'nanum-generate' and GEN.refresh then GEN.refresh() end
    end

    -- request: the spec of the command. true, or nil + reason.
    function GEN.start(request)
        if S.job then return nil, tr('이미 자막 생성이 진행 중입니다') end
        if type(request) ~= 'table' then return nil, 'bad request' end
        local handle
        local job = { request = request }
        S.job = job
        S.last = nil
        S.last_toast = 0
        handle = mp.command_native_async({ name = 'nanum-generate', spec = utils.format_json(request) },
            function(success, result, error)
                if S.job ~= job then return end
                finish(success and result or nil, error)
            end)
        job.handle = handle
        say(tr('자막 생성을 시작합니다 — 재생과는 별개로 처리합니다'), 4, 'busy')
        return true
    end

    function GEN.cancel()
        local job = S.job
        if not job or job.cancelling then return false end
        job.cancelling = true
        if job.handle then mp.abort_async_command(job.handle) end
        say(tr('취소하는 중... 이미 저장된 파일은 유지됩니다'), 4, 'busy')
        return true
    end

    function GEN.state()
        return S.state
    end

    -- Starts from the menu's choices. true, or nil + reason.
    local function start_from_menu()
        local m, why = media()
        if not m then return nil, why end
        local list = sources()
        local src = chosen_source(list)
        if not src then return nil, tr('원본으로 쓸 음성이나 자막 트랙이 없습니다') end
        local dir, dwhy = output_dir(m)
        if not dir then return nil, dwhy end
        local tg = {}
        for _, l in ipairs(targets()) do tg[#tg + 1] = { code = l.code, name = l.name } end
        local request = {
            url = src.url or m.url,
            source = src.kind,
            track = src.track,
            source_lang = src.lang ~= '' and src.lang or nil,
            targets = tg,
            directory = dir,
            name = m.name,
            title = m.name,
            write_source = S.sel.keep_source,
            limit = S.sel.preview and PREVIEW_SECONDS or nil,
        }
        if src.url then request.name = strip_ext(basename(src.url)) end
        -- The glossary of what is playing, when it is for the language that is asked for.
        if same_as_playing(m) and #tg == 1 then
            local cs = mp.get_property_native('demuxer-cache-state')
            local current = default_targets()[1]
            if type(cs) == 'table' and type(cs['nanum-glossary']) == 'string' and cs['nanum-glossary'] ~= ''
                and (current.code == tg[1].code or current.name:lower() == tg[1].name:lower()) then
                request.glossary = cs['nanum-glossary']
            end
        end
        return GEN.start(request)
    end

    ----------------------------------------------------------------------------
    -- Menu

    local MENU_ID = 'nanum-generate'

    local function build_menu()
        local items, acts, keys, progress = {}, {}, {}, {}
        local function add(key, text, fn)
            items[#items + 1] = text
            acts[#acts + 1] = fn or function() end
            keys[#keys + 1] = key
        end
        local m, why = media()
        local again = function() GEN.open() end
        local st = S.state
        if S.job then
            add('status', st and st.busy and progress_text(st) or tr('시작하는 중...'), again)
            progress.status = st and st.busy and tonumber(st.progress) or 0
            if st and st.num_targets and st.num_targets > 1 and st.status == 'translating' then
                add('lang', tr('언어 %d/%d: %s', (st.target or 0) + 1, st.num_targets, st.target_name or ''), again)
            end
            add('elapsed', tr('경과 시간: %s', seconds_text(st and st.elapsed or 0)), again)
            if st and #(st.outputs or {}) > 0 then
                add('done', tr('저장됨: %s', file_list(st.outputs)), again)
            end
            add('cancel', tr('■ 취소 (저장된 파일은 유지)'), function() GEN.cancel(); mp.add_timeout(0.1, GEN.open) end)
        else
            add('media', tr('대상: %s', m and (m.kind == 'disc' and (m.name .. ' (' .. tr('디스크') .. ')') or basename(m.url)) or (why or '-')),
                function() mp.add_timeout(0.1, GEN.pick_media) end)
            local list = sources()
            local src = chosen_source(list)
            add('source', tr('원본: %s', src and src.label or tr('없음')), function() mp.add_timeout(0.1, GEN.pick_source) end)
            add('targets', tr('번역 언어: %s', targets_text(targets())), function() mp.add_timeout(0.1, GEN.pick_targets) end)
            add('keep', tr('원문 자막 파일도 저장: %s', S.sel.keep_source and tr('켬') or tr('끔')), function()
                S.sel.keep_source = not S.sel.keep_source
                mp.add_timeout(0.1, GEN.open)
            end)
            add('where', tr('저장 위치: %s', m and where_text(m) or '-'), function() mp.add_timeout(0.1, GEN.pick_where) end)
            add('range', tr('범위: %s', S.sel.preview and tr('처음 10분만 (미리보기)') or tr('전체')), function()
                S.sel.preview = not S.sel.preview
                mp.add_timeout(0.1, GEN.open)
            end)
            add('start', tr('▶ 시작'), function()
                local ok, reason = start_from_menu()
                if not ok then say(reason or '?', 6, 'warn') end
                mp.add_timeout(0.1, GEN.open)
            end)
            local r = S.last
            if r then
                if r.ok then
                    add('result', tr('최근 결과: 완료 — %s', file_list(r.outputs)), again)
                elseif r.status == 'cancelled' then
                    add('result', tr('최근 결과: 취소됨 (저장된 파일 %d개)', #(r.outputs or {})), again)
                else
                    add('result', tr('최근 결과: 실패 — %s', trim(r.error or '')), again)
                end
                for i, o in ipairs(r.outputs or {}) do
                    if WIN then
                        add('show' .. i, tr('탐색기에서 보기: %s', basename(o.file)), function()
                            mp.command_native_async({ name = 'subprocess', args = { 'explorer.exe', '/select,' .. o.file },
                                detach = true, playback_only = false }, function() end)
                        end)
                    end
                    if same_as_playing(m) and not S.sel.url then
                        add('load' .. i, tr('재생 중인 영상에 불러오기: %s', basename(o.file)), function()
                            -- nanum.lua shows the file as it is and selects it (no second copy of a file the player already loaded)
                            mp.commandv('script-message-to', 'nanum', 'nanum-subtitle-show', o.file, o.language or '')
                        end)
                    end
                end
            end
        end
        add('back', tr('← 설정으로 돌아가기'), function() if env.reopen_menu then env.reopen_menu() end end)
        return items, acts, keys, progress
    end

    function GEN.refresh()
        local items, acts, keys, progress = build_menu()
        S.acts = acts
        input.update_select(MENU_ID, items, { keys = keys, progress = progress })
    end

    function GEN.open()
        if not input or not input.select then
            say(tr('메뉴를 열 수 없습니다'), 4, 'error')
            return
        end
        local items, acts, keys, progress = build_menu()
        S.acts = acts
        input.select({
            id = MENU_ID,
            prompt = tr('자막 파일 만들기:'),
            items = items,
            keys = keys,
            progress = progress,
            submit = function(i)
                local fn = S.acts and S.acts[i]
                if fn then fn() end
            end,
        })
    end

    function GEN.pick_source()
        local list = sources()
        if #list == 0 then
            say(tr('원본으로 쓸 음성이나 자막 트랙이 없습니다'), 5, 'warn')
            mp.add_timeout(0.1, GEN.open)
            return
        end
        local _, current = chosen_source(list)
        local items = {}
        for i, s in ipairs(list) do
            items[i] = (i == current and '● ' or '  ') .. s.label
        end
        input.select({
            prompt = tr('원본을 고르세요:'),
            items = items,
            default_item = current,
            submit = function(i)
                S.sel.source = i
                mp.add_timeout(0.1, GEN.open)
            end,
        })
    end

    function GEN.pick_media()
        local m = media()
        input.get({
            prompt = tr('영상 파일 경로 (또는 bd://longest/E: 같은 디스크 주소):'),
            default_text = m and m.url or '',
            submit = function(text)
                input.terminate()
                text = trim(text)
                S.sel.url = text ~= '' and text or nil
                S.sel.source = nil
                mp.add_timeout(0.1, GEN.open)
            end,
        })
    end

    function GEN.pick_where()
        local m = media()
        local w = where_default(m)
        local rows = {
            { id = 'next', text = tr('영상과 같은 폴더') },
            { id = 'videos', text = tr('동영상\\NanumPlayer 폴더') },
            { id = 'custom', text = tr('다른 폴더 직접 입력…') },
        }
        local items, current = {}, 1
        for i, r in ipairs(rows) do
            items[i] = (r.id == w and '● ' or '  ') .. r.text
            if r.id == w then current = i end
        end
        input.select({
            prompt = tr('저장 위치:'),
            items = items,
            default_item = current,
            submit = function(i)
                local id = rows[i].id
                if id ~= 'custom' then
                    S.sel.where = id
                    mp.add_timeout(0.1, GEN.open)
                    return
                end
                input.get({
                    prompt = tr('자막을 저장할 폴더:'),
                    default_text = S.sel.custom_dir ~= '' and S.sel.custom_dir or (videos_dir() or ''),
                    submit = function(text)
                        input.terminate()
                        text = trim(text):gsub('[/\\]+$', '')
                        if text ~= '' then
                            S.sel.where, S.sel.custom_dir = 'custom', win_path(text)
                        end
                        mp.add_timeout(0.1, GEN.open)
                    end,
                })
            end,
        })
    end

    function GEN.pick_targets()
        local list = {}
        for _, l in ipairs(targets()) do list[#list + 1] = { code = l.code, name = l.name } end
        local function rows()
            local items, keys = {}, {}
            local function row(key, text) items[#items + 1] = text; keys[#keys + 1] = key end
            for _, l in ipairs(LANGS) do
                row(l.code, (target_index(list, l) and '● ' or '  ') .. tr(l.label))
            end
            for i, l in ipairs(list) do      -- languages typed by the user
                if not lang_entry(l.code, l.name) then row('custom' .. i, '● ' .. l.name) end
            end
            row('other', '  ' .. tr('기타 언어 직접 입력…'))
            row('none', '  ' .. tr('번역 안 함 (원문만)'))
            row('done', tr('← 완료'))
            return items, keys
        end
        local function show()
            local items, keys = rows()
            return items, keys
        end
        local items, keys = show()
        input.select({
            id = 'nanum-generate-langs',
            prompt = tr('번역할 언어 (여러 개 선택 가능):'),
            items = items,
            keys = keys,
            keep_open = true,
            submit = function(i)
                local key = keys[i]
                if key == 'done' then
                    S.sel.targets = list
                    input.terminate()
                    mp.add_timeout(0.1, GEN.open)
                    return
                end
                if key == 'none' then
                    list = {}
                elseif key == 'other' then
                    input.get({
                        prompt = tr('언어 이름 (영어로, 예: Vietnamese):'),
                        submit = function(text)
                            input.terminate()
                            text = trim(text)
                            if text ~= '' then
                                local e = lang_entry('', text)
                                local entry = e and { code = e.code, name = e.name } or { code = '', name = text }
                                if not target_index(list, entry) then list[#list + 1] = entry end
                            end
                            S.sel.targets = list
                            mp.add_timeout(0.1, GEN.pick_targets)
                        end,
                    })
                    return
                elseif key:match('^custom') then
                    local n = tonumber(key:match('%d+'))
                    table.remove(list, n)
                else
                    for _, l in ipairs(LANGS) do
                        if l.code == key then
                            local at = target_index(list, l)
                            if at then table.remove(list, at) else list[#list + 1] = { code = l.code, name = l.name } end
                        end
                    end
                end
                local it, ks = rows()
                keys = ks
                input.update_select('nanum-generate-langs', it, { keys = ks })
            end,
        })
    end

    ----------------------------------------------------------------------------
    -- Messages and hookup

    mp.register_script_message('nanum-generate-start', function(json)
        local request = utils.parse_json(json or '')
        if type(request) ~= 'table' then
            say(tr('요청을 읽을 수 없습니다'), 5, 'error')
            return
        end
        local ok, why = GEN.start(request)
        if not ok then say(why or '?', 5, 'warn') end
    end)
    mp.register_script_message('nanum-generate-cancel', function() GEN.cancel() end)
    mp.register_script_message('nanum-generate-open', function() GEN.open() end)
    mp.add_key_binding(nil, 'nanum-generate', function() GEN.open() end)
    mp.add_key_binding(nil, 'nanum-generate-cancel', function() GEN.cancel() end)
    mp.observe_property('user-data/nanum/generate', 'native', on_state)
    mp.register_event('shutdown', function()
        if S.job and S.job.handle then mp.abort_async_command(S.job.handle) end
    end)

    return GEN
end
