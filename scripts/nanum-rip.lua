-- In-process Blu-ray/DVD title selection and lossless Matroska export.
-- The native commands own disc access, automatic key lookup, muxing and cleanup.
local mp = require 'mp'
local RIP = {}
local M = { notify = function() end }
local active

-- Translations (locales/fluent.json) through the shared loader that sits next to this script.
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
            if okf and type(mod) == 'table' then return mod.translator('fluent') end
            mp.msg.error('nanum-i18n.lua: ' .. tostring(mod))
        end
    end
    mp.msg.error('nanum-rip: scripts/nanum-i18n.lua not found; messages stay in their source language')
    return function(key, ...)
        if select('#', ...) > 0 then return string.format(key, ...) end
        return key
    end
end
local tr = load_translator()

local function notify(text, seconds, level)
    M.notify(text, seconds or 4, level or 'info', 'nanum-rip')
end

local function cancel()
    if not active or active.cancelling then return end
    active.cancelling = true
    mp.abort_async_command(active.handle)
    notify(tr('취소 중... 현재 저장 중인 임시 파일을 정리합니다.'), 4)
end

local function request(command, callback)
    if active then
        notify(tr('이미 디스크 작업이 진행 중입니다. Ctrl+C로 취소할 수 있습니다.'), 4)
        return
    end
    local job = { op = command.name == 'nanum-disc-rip' and 'rip' or 'list' }
    active = job
    mp.add_forced_key_binding('ctrl+c', 'nanum-rip-cancel', cancel)
    job.handle = mp.command_native_async(command, function(success, result, err)
        if active ~= job then return end
        active = nil
        mp.remove_key_binding('nanum-rip-cancel')
        if type(result) == 'table' and result.status == 'cancelled' then
            local completed = #(result.outputs or {})
            notify(tr('취소됨 — 이미 완료된 파일 %d개는 유지됩니다.', completed), 5)
            return
        end
        if not success or type(result) ~= 'table' or not result.ok then
            if job.cancelling and not result then
                notify(tr('디스크 작업이 취소되었습니다.'), 4)
            else
                local message = type(result) == 'table' and result.error or err
                notify(tr('디스크 작업 실패: %s', tostring(message or tr('알 수 없는 오류'))), 8, 'error')
            end
            return
        end
        callback(result)
    end)
end

local function on_progress(_, state)
    if not active or active.cancelling or type(state) ~= 'table' or not state.busy then return end
    if state.op ~= active.op then return end
    if state.op == 'rip' then
        local fraction = math.max(0, math.min(1, tonumber(state.progress) or 0))
        notify(tr('%s\n제목 %d/%d — %d%% (Ctrl+C로 취소)',
            state.disc_label or tr('디스크 저장'), state.title_index or 0,
            state.title_count or 0, math.floor(fraction * 100)), 2)
    else
        notify(tr('디스크·제목 확인 중... (처음에는 키 DB를 자동으로 받을 수 있습니다)\nCtrl+C로 취소'), 3)
    end
end

local function duration(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    return ('%d:%02d:%02d'):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

local function rip(disc, title)
    local profile = os.getenv('USERPROFILE') or ''
    if profile == '' then
        notify(tr('기본 동영상 폴더를 찾을 수 없습니다.'), 5, 'error')
        return
    end
    local destination = profile .. '\\Videos\\NanumPlayer'
    request({ name = 'nanum-disc-rip', device = disc.device, title = tostring(title),
              destination = destination, expected_disc_id = disc.id }, function(result)
        notify(tr('저장 완료 — %d개 파일\n%s', #(result.outputs or {}), result.destination or destination), 8)
    end)
end

local function list_titles(drive)
    notify(tr('제목을 분석 중입니다...'), 4)
    request({ name = 'nanum-disc-list', device = drive.device }, function(result)
        local disc = result.disc
        if not disc or not disc.titles or #disc.titles == 0 then
            notify(tr('저장 가능한 제목이 없습니다.'), 5)
            return
        end
        local items = { { text = tr('모든 제목'), value = 'all' } }
        for _, title in ipairs(disc.titles) do
            items[#items + 1] = {
                text = tr('%d. %s  %s  %.2f GiB  (%d 챕터)',
                    title.id + 1, title.name or tr('제목'), duration(title.duration),
                    (title.size or 0) / 1073741824, title.chapters or 0),
                value = tostring(title.id),
            }
        end
        M.select(tr('저장할 제목: %s', disc.label or drive.device), items, function(title)
            rip(disc, title)
        end)
    end)
end

function RIP.pick_and_rip()
    if not M.select then
        notify(tr('NanumPlayer 화면에서 디스크 저장을 실행하세요.'), 5, 'error')
        return
    end
    if active then
        notify(tr('이미 디스크 작업이 진행 중입니다. Ctrl+C로 취소할 수 있습니다.'), 4)
        return
    end
    notify(tr('디스크 드라이브 확인 중...'), 3)
    request({ name = 'nanum-disc-list' }, function(result)
        local items = {}
        for _, drive in ipairs(result.drives or {}) do
            if drive.has_media then
                local label = drive.label ~= '' and drive.label or tr('디스크')
                items[#items + 1] = { text = drive.device .. '  ' .. label, value = drive }
            end
        end
        if #items == 0 then
            notify(tr('미디어가 들어 있는 광학 드라이브가 없습니다.'), 5)
            return
        end
        M.select(tr('드라이브 선택:'), items, list_titles)
    end)
end

function RIP.mount(env)
    M = env or M
    M.notify = M.notify or function() end
    mp.register_event('shutdown', function()
        if active and active.handle then mp.abort_async_command(active.handle) end
    end)
    mp.add_key_binding('ctrl+b', 'nanum-bd-rip', RIP.pick_and_rip)
    mp.register_script_message('nanum-rip', RIP.pick_and_rip)
    mp.observe_property('user-data/nanum/rip', 'native', on_progress)
end

return RIP
