-- Optional Blu-ray/DVD decryption component: user interface. scripts/nanum.lua loads this file and calls the
-- factory it returns:
--
--   local ctl = factory({
--       notify = function(text, seconds, kind, id) end,   -- toast
--       tr = function(key, ...) end,                      -- localized text (Korean source string as the key)
--       select = function(spec) end,                      -- popup list, spec as for mp.input.select
--       busy = function() return false end,               -- another modal popup is open
--       back = function() end,                            -- return to the settings menu (optional)
--   })
--   ctl.state()                -> user-data/nanum/disc-component (table, {} before the engine published it)
--   ctl.summary()              -> one line for the settings menu row
--   ctl.open()                 -> the management popup (install / install from a ZIP / key database consent)
--   ctl.on_play_error(path, log_text) -> true if the failed file was an encrypted disc and has been explained
--   ctl.refresh()              -> asks the engine to publish the current state
--
-- The engine side is osdep/nanum-disc-component-win.c (commands nanum-disc-component-refresh/-install/-cancel,
-- nanum-disc-consent). Nothing is downloaded or installed here without the user choosing it in a popup that
-- shows the notice (optional component, own responsibility for local laws, key database download).
-- Nothing happens until the factory is called, so the file is harmless when mpv auto-loads it from a scripts folder.

local mp = require 'mp'

local PROP = 'user-data/nanum/disc-component'
local WIN = package.config:sub(1, 1) == '\\'
local instance

local function factory(host)
    if instance then return instance end
    host = host or {}
    local function tr(key, ...)
        if host.tr then return host.tr(key, ...) end
        return select('#', ...) > 0 and string.format(key, ...) or key
    end
    local function notify(text, secs, kind, id)
        if host.notify then host.notify(text, secs, kind, id) end
    end

    local ctl = {}
    -- A request of the user that is still running: { path = file to open again when it is done }.
    local pending

    function ctl.state()
        local st = mp.get_property_native(PROP)
        return type(st) == 'table' and st or {}
    end

    function ctl.refresh()
        mp.commandv('nanum-disc-component-refresh')
    end

    local function mib(bytes)
        return string.format('%.0f MiB', (tonumber(bytes) or 0) / 1048576)
    end

    function ctl.summary()
        local st = ctl.state()
        if st.busy then
            local total = tonumber(st.total) or 0
            if st.status == 'downloading' and total > 0 then
                return tr('내려받는 중 %d%%', math.floor(100 * (tonumber(st.received) or 0) / total))
            end
            return tr('설치 중…')
        end
        if st.installed then return tr('설치됨') end
        if st.checked == false then return tr('확인 중…') end
        return tr('설치 안 됨 (선택 사항)')
    end

    -- The notice every install shows; the user chooses with it in front of them.
    local function notice_lines()
        return {
            tr('이 구성 요소는 기본 배포본에 포함되지 않은 선택 사항입니다. 복제 방지가 걸린 Blu-ray(AACS, BD+)와 DVD(CSS)를 읽을 때만 필요합니다.'),
            tr('복제 방지를 우회하는 일은 나라에 따라 법으로 제한되거나 금지됩니다. 거주 국가의 법을 지킬 책임은 사용자에게 있습니다.'),
            tr('설치하면 필요할 때 공개 AACS 키 데이터베이스(FindVUK)를 인터넷에서 내려받는 것에 동의한 것으로 봅니다. Ctrl+N에서 철회할 수 있습니다.'),
            tr('보호되지 않은 디스크는 이 구성 요소 없이도 재생됩니다.'),
        }
    end

    -- Rows of a popup are cut at its width: the notice is wrapped into rows of at most `limit` columns
    -- (a wide character counts two; breaks at spaces, anywhere in text without spaces).
    local function wrap(text, limit)
        local rows, row, width, last_space = {}, {}, 0, nil
        for ch in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
            local w = #ch > 1 and 2 or 1
            if width + w > limit then
                if last_space and ch ~= ' ' then
                    local rest = {}
                    for k = last_space + 1, #row do rest[#rest + 1] = row[k] end
                    for k = #row, last_space, -1 do row[k] = nil end
                    rows[#rows + 1] = table.concat(row)
                    row, width = rest, 0
                    for _, c in ipairs(row) do width = width + (#c > 1 and 2 or 1) end
                else
                    rows[#rows + 1] = table.concat(row)
                    row, width = {}, 0
                end
                last_space = nil
            end
            if ch == ' ' and #row == 0 then
                -- no leading space on a row
            else
                row[#row + 1] = ch
                width = width + w
                if ch == ' ' then last_space = #row end
            end
        end
        if #row > 0 then rows[#rows + 1] = table.concat(row) end
        return rows
    end

    function ctl.show_notice(after)
        local items = {}
        for _, line in ipairs(notice_lines()) do
            for _, row in ipairs(wrap(line, 78)) do items[#items + 1] = row end
        end
        items[#items + 1] = tr('← 뒤로')
        host.select({
            prompt = tr('Blu-ray/DVD 복호화 구성 요소'),
            items = items,
            default_item = #items,
            submit = function() if after then after() end end,
        })
    end

    -- Windows "Open" dialog (PowerShell) for the ZIP the user saved earlier.
    local function pick_zip(done)
        if not WIN then return end
        local script = table.concat({
            'Add-Type -AssemblyName System.Windows.Forms;',
            '[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false);',
            '$o=New-Object System.Windows.Forms.Form;$o.TopMost=$true;',
            '$d=New-Object System.Windows.Forms.OpenFileDialog;',
            "$d.Title='" .. tr('구성 요소 ZIP 파일 선택'):gsub("'", "''") .. "';",
            "$d.Filter='" .. tr('구성 요소 패키지 (zip)|*.zip|모든 파일|*.*'):gsub("'", "''") .. "';",
            "if($d.ShowDialog($o) -eq 'OK'){$d.FileName}",
        })
        mp.command_native_async({ name = 'subprocess', playback_only = false, capture_stdout = true,
            args = { 'powershell.exe', '-NoProfile', '-NonInteractive', '-STA', '-Command', script } }, function(ok, res)
            local p = ok and res and res.status == 0 and (res.stdout or ''):gsub('^\239\187\191', ''):match('^%s*(.-)%s*$') or ''
            if p ~= '' then done(p) end
        end)
    end

    -- Starts the engine's worker. The user chose this entry with the notice in front of them; the
    -- key database consent it includes is stored once the installation has succeeded.
    local function install(zip, path)
        pending = { path = path }
        local ok
        if zip and zip ~= '' then
            ok = mp.commandv('nanum-disc-component-install', zip)
        else
            ok = mp.commandv('nanum-disc-component-install')
        end
        if not ok then
            pending = nil
            local st = ctl.state()
            notify(tr('디스크 구성 요소를 설치하지 못했습니다') .. (st.error and st.error ~= '' and ('\n' .. st.error) or ''), 8, 'error', 'disc-component')
        else
            notify(tr('디스크 구성 요소를 준비하는 중…'), 3, 'busy', 'disc-component')
        end
    end

    local function open_folder(dir)
        if type(dir) ~= 'string' or dir == '' or not WIN then return end
        dir = (dir:gsub('/', '\\'))
        mp.command_native_async({ name = 'subprocess', args = { 'explorer.exe', dir }, playback_only = false,
            detach = true }, function() end)
    end

    -- The install choices; shown when a disc needs the component and from the settings menu.
    function ctl.open_install(path)
        local st = ctl.state()
        local items, acts = {}, {}
        local function add(label, fn)
            items[#items + 1] = label
            acts[#acts + 1] = fn
        end
        if st.catalog == false then
            notify(tr('디스크 구성 요소 정보(components\\catalog.json)를 읽을 수 없습니다: %s', tostring(st.catalog_error or '')), 8, 'error', 'disc-component')
            return
        end
        add(tr('동의하고 내려받아 설치 (%s)', mib(st.size)), function() install(nil, path) end)
        add(tr('동의하고 내려받아 둔 ZIP 파일로 설치…'), function() pick_zip(function(p) install(p, path) end) end)
        add(tr('안내 전문 보기'), function() ctl.show_notice(function() ctl.open_install(path) end) end)
        add(tr('취소'), function() end)
        notify(table.concat(notice_lines(), '\n'), 20, 'warn', 'disc-component-notice')
        host.select({
            prompt = tr('복호화 구성 요소를 설치할까요?'),
            items = items,
            default_item = #items,
            submit = function(i) mp.add_timeout(0.1, function() acts[i]() end) end,
        })
    end

    function ctl.open()
        local st = ctl.state()
        ctl.refresh()
        if st.busy then
            host.select({
                prompt = tr('Blu-ray/DVD 복호화 구성 요소'),
                items = { tr('상태: %s', ctl.summary()), tr('설치 취소'), tr('닫기') },
                default_item = 3,
                submit = function(i)
                    if i == 2 then mp.commandv('nanum-disc-component-cancel') end
                end,
            })
            return
        end
        local items, acts = {}, {}
        local function add(label, fn)
            items[#items + 1] = label
            acts[#acts + 1] = fn
        end
        add(tr('상태: %s', ctl.summary()), function() mp.add_timeout(0.1, ctl.open) end)
        if st.installed then
            add(tr('설치됨 (버전 %s) — 눌러서 폴더 열기', tostring(st.version or '')), function() open_folder(st.directory) end)
        else
            add(tr('내려받아 설치 (%s)…', mib(st.size)), function() ctl.open_install() end)
            add(tr('내려받아 둔 ZIP 파일로 설치…'), function() ctl.open_install() end)
        end
        add(tr('AACS 키 데이터베이스 자동 내려받기: %s', tr(st.consent and '허용' or '허용 안 함')), function()
            mp.commandv('nanum-disc-consent', st.consent and 'no' or 'yes')
            mp.add_timeout(0.1, ctl.open)
        end)
        add(tr('안내 전문 보기'), function() ctl.show_notice(ctl.open) end)
        add(tr('← 설정으로 돌아가기'), function() if host.back then host.back() end end)
        host.select({
            prompt = tr('Blu-ray/DVD 복호화 구성 요소'),
            items = items,
            default_item = 2,
            submit = function(i) mp.add_timeout(0.1, function() acts[i]() end) end,
        })
    end

    -- The key database is only downloaded with the user's one-time agreement.
    local function ask_consent(path)
        notify(tr('이 디스크의 키가 이 PC의 키 데이터베이스에 없습니다. 공개 FindVUK 키 데이터베이스(fvonline-db.bplaced.net, 약 25 MB)를 내려받아야 열 수 있습니다. 복제 방지 우회에 관한 법은 나라마다 다르며, 법을 지킬 책임은 사용자에게 있습니다. 동의는 Ctrl+N에서 철회할 수 있습니다.'), 20, 'warn', 'disc-consent-notice')
        local items = { tr('허용하고 디스크 다시 열기'), tr('허용 안 함') }
        host.select({
            prompt = tr('AACS 키 데이터베이스를 내려받을까요?'),
            items = items,
            default_item = 2,
            submit = function(i)
                if i == 1 then
                    mp.commandv('nanum-disc-consent', 'yes')
                    if path then mp.commandv('loadfile', path, 'replace') end
                end
            end,
        })
    end

    -- Log lines of the failed open -> what to tell the user.
    local function classify(text)
        if text:find('Disc decryption component is not installed', 1, true) then return 'component' end
        if text:find('key database download needs your consent', 1, true) then return 'consent' end
        if text:find('cannot find libaacs', 1, true) or text:find('cannot find libbdplus', 1, true) then
            return 'damaged'
        end
        if text:find('AACS key database unavailable', 1, true) then return 'database' end
        if text:find('AACS error', 1, true) or text:find('Cannot decrypt BD+', 1, true) then return 'failed' end
        return nil
    end
    ctl.classify = classify

    function ctl.on_play_error(path, log_text)
        local kind = classify(log_text or '')
        if not kind then return false end
        mp.set_property_native('user-data/nanum/error-handled', true)
        local function later(fn)
            mp.add_timeout(0.6, function()
                if host.busy and host.busy() then return end
                fn()
            end)
        end
        if kind == 'component' then
            mp.msg.error('Disc decryption component is not installed')
            notify(tr('이 디스크는 복제 방지가 걸려 있어 선택 구성 요소가 필요합니다') .. '\n' ..
                   tr('Blu-ray/DVD 복호화 구성 요소는 기본 배포본에 포함되지 않습니다. 설치하면 이 디스크를 열 수 있습니다.'), 12, 'warn', 'disc')
            later(function() ctl.open_install(path) end)
            return true
        elseif kind == 'consent' then
            mp.msg.error('AACS key database download needs consent')
            later(function() ask_consent(path) end)
            return true
        end
        local title, text
        if kind == 'damaged' then
            title = tr('디스크 복호화 구성 요소를 불러오지 못했습니다')
            text = tr('설치된 구성 요소가 손상되었을 수 있습니다. Ctrl+N > Blu-ray/DVD 복호화 구성 요소에서 다시 설치하세요.')
        elseif kind == 'database' then
            title = tr('자동 키 DB를 준비하지 못했습니다')
            text = tr('키 DB 다운로드 또는 검증에 실패했습니다. 인터넷 연결을 확인한 뒤 다시 시도하세요. 기존 DB는 유지됩니다.')
        else
            title = tr('디스크 암호를 풀지 못했습니다')
            text = tr('자동 키 DB 다운로드의 인터넷 연결을 확인하세요. DB에 키가 없거나 지원되지 않는 AACS·BD+ 보호 방식이면 열 수 없습니다.')
        end
        mp.msg.error(title)
        notify(title .. '\n' .. text, 12, 'error', 'disc')
        local items, actions = {}, {}
        if path then
            items[#items + 1] = tr('다시 시도')
            actions[#actions + 1] = function() mp.commandv('loadfile', path, 'replace') end
        end
        items[#items + 1] = tr('닫기')
        actions[#actions + 1] = function() end
        later(function()
            host.select({ prompt = title, items = items, submit = function(i) actions[i]() end })
        end)
        return true
    end

    -- Progress and result of an install the user started.
    mp.observe_property(PROP, 'native', function(_, st)
        if type(st) ~= 'table' or not pending then return end
        if st.busy then
            local total = tonumber(st.total) or 0
            local text
            if st.status == 'downloading' and total > 0 then
                text = tr('디스크 구성 요소 내려받는 중… %d%%', math.floor(100 * (tonumber(st.received) or 0) / total))
            elseif st.status == 'extracting' then
                text = tr('디스크 구성 요소 설치 중…')
            else
                text = tr('디스크 구성 요소 확인 중…')
            end
            notify(text, 2, 'busy', 'disc-component')
            return
        end
        local done = pending
        if st.status == 'done' and st.installed then
            pending = nil
            mp.commandv('nanum-disc-consent', 'yes')
            if done.path then
                notify(tr('디스크 구성 요소를 설치했습니다 · 디스크를 다시 엽니다'), 5, 'ok', 'disc-component')
                mp.commandv('loadfile', done.path, 'replace')
            else
                notify(tr('디스크 구성 요소를 설치했습니다 · 이제 보호된 디스크를 열 수 있습니다'), 6, 'ok', 'disc-component')
            end
        elseif st.status == 'cancelled' then
            pending = nil
            notify(tr('디스크 구성 요소 설치를 취소했습니다'), 4, 'warn', 'disc-component')
        elseif st.status == 'error' then
            pending = nil
            notify(tr('디스크 구성 요소를 설치하지 못했습니다') .. (st.error and st.error ~= '' and ('\n' .. st.error) or ''), 10, 'error', 'disc-component')
        end
    end)

    ctl.refresh()
    instance = ctl
    return ctl
end

return factory
