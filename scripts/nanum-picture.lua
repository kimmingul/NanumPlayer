-- Picture correction backend for NanumPlayer. scripts/nanum.lua loads this file and calls the factory it returns:
--
--   local ctl = factory({ changed = function(state) end })
--   ctl.get_state()    -> { preset, denoise, deband, lines, sharpen, color, comparing, rtx, status, detail }
--                         (also published as user-data/nanum/picture)
--   ctl.set_preset(id) id: original | anime | oldanime | compressed (custom is only the name of a mix)
--   ctl.set_filter({ name = 'denoise'|'deband'|'lines'|'sharpen'|'color', level = 0..3 })
--   ctl.set_compare(b) true: show the picture without this feature's filters (temporary, never saved)
--
-- Setters return true or nil, <raw error>. Nothing happens until the factory is called, so the file is harmless
-- when mpv auto-loads it from a scripts folder. Choices are kept in ~~/script-opts/nanum-picture.conf
-- (preset, denoise, deband, lines, sharpen, color; the strengths win over the preset name) and are read with
-- mp.options under the namespace "nanum-picture". The comparison state is not saved.
--
-- Strength: 0 off, 1 weak, 2 medium, 3 strong. All filters are small classic algorithms, no model is involved:
--
--   denoise  edge-preserving bilateral filter (shaders/nanum-picture/denoise-N.glsl, MAIN hook, source size)
--   lines    conservative darkening of thin dark lines, never brightens (lines-N.glsl)
--   sharpen  luma unsharp mask, soft-thresholded, limited and confined to the local min/max so it cannot ring
--            (sharpen-N.glsl)
--   deband   mpv's own GPU debander: deband=yes plus deband-iterations/threshold/range/grain
--   color    mild saturation and contrast increase through the player's saturation / contrast properties
--
-- The three shader filters are put at the front of glsl-shaders in the fixed order denoise, lines, sharpen, in
-- front of whatever else is there, so they see the source picture before user upscaling shaders do. Shaders and
-- options that are not ours are never touched. Every option changed here is remembered together with its previous
-- value and put back when the filter is switched off, compared or released, unless somebody else changed it in
-- the meantime. The module never switches the video output: they need vo=gpu-next (or gpu) and anything else is
-- reported as an error.
--
-- The RTX upscale (user-data/nanum/upscale mode "rtx") makes lines and sharpen pause (they stay selected and are
-- applied again when RTX is left); denoise, deband and color keep working. The comparison only removes this
-- feature's own filters; an upscale mode stays as it is.
--
-- Properties are applied when the user chooses something, when the comparison or RTX changes and at start; a
-- file change only re-checks. Nobody is fought: an option (saturation, deband, ...) that something else changed
-- is no longer ours and keeps the other party's value; if our glsl-shaders entries are removed the status
-- becomes "error" and says so. Nothing is re-applied until the next choice.
-- A shader the renderer failed to compile is removed again and reported; the renderer never loads a rejected
-- file a second time, so choosing it again reports an error until the player is restarted.
--
-- Statuses: original (nothing to do), active, comparing, waiting (chosen, no video yet), error (detail holds the
-- raw message; it stays until a setter is called again, a renderer problem gets one new attempt per file).

local mp = require 'mp'
local options = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local NS = 'nanum-picture'
local CONF = '~~/script-opts/nanum-picture.conf'
local SYNC = 'nanum-picture sync '                  -- log marker, see mark()
local WIN = package.config:sub(1, 1) == '\\'

local FILTERS = { 'denoise', 'deband', 'lines', 'sharpen', 'color' }
local SHADER_ORDER = { 'denoise', 'lines', 'sharpen' }  -- order inside glsl-shaders
local PRESETS = {
    original   = { denoise = 0, deband = 0, lines = 0, sharpen = 0, color = 0 },
    anime      = { denoise = 0, deband = 1, lines = 1, sharpen = 1, color = 0 },
    oldanime   = { denoise = 2, deband = 1, lines = 1, sharpen = 0, color = 0 },
    compressed = { denoise = 2, deband = 2, lines = 0, sharpen = 0, color = 0 },
}
local PRESET_IDS = { 'original', 'anime', 'oldanime', 'compressed' }
local DEBAND = {
    { ['deband-iterations'] = 1, ['deband-threshold'] = 24, ['deband-range'] = 16, ['deband-grain'] = 16 },
    { ['deband-iterations'] = 2, ['deband-threshold'] = 40, ['deband-range'] = 16, ['deband-grain'] = 24 },
    { ['deband-iterations'] = 3, ['deband-threshold'] = 56, ['deband-range'] = 24, ['deband-grain'] = 32 },
}
local DEBAND_KEYS = { 'deband-iterations', 'deband-threshold', 'deband-range', 'deband-grain' }
local COLOR = {                                      -- added to the value the player had
    { saturation = 5, contrast = 1 },
    { saturation = 10, contrast = 2 },
    { saturation = 16, contrast = 4 },
}
local COLOR_KEYS = { 'saturation', 'contrast' }
local SHADER_DIR = 'shaders/nanum-picture'
local MODULE_DIR = (function()
    local info = debug and debug.getinfo and debug.getinfo(1, 'S')
    local src = info and info.source or ''
    if src:sub(1, 1) == '@' then return src:sub(2):match('^(.*)[/\\][^/\\]*$') end
    return nil
end)()
local instance

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function errtext(e)
    e = trim(e)
    return e ~= '' and e or 'unknown error'
end

local function norm(p)
    p = tostring(p):gsub('\\', '/')
    return WIN and p:lower() or p
end

local function printable(p)
    return (tostring(p):gsub('%c', '?'))
end

local function is_absolute(p)
    return p:match('^%a:[/\\]') ~= nil or p:match('^[/\\][/\\]') ~= nil or (not WIN and p:sub(1, 1) == '/')
end

local function copy_list(l)
    local out = {}
    for i, v in ipairs(l) do out[i] = v end
    return out
end

local function same_list(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function restart(timer, seconds)
    timer.timeout = seconds
    timer:kill()
    timer:resume()
end

-- A strength: integer 0..3 given as number or digit string.
local function parse_level(v)
    local n = type(v) == 'string' and trim(v):match('^%d+$') and tonumber(v) or v
    if type(n) == 'number' and n == math.floor(n) and n >= 0 and n <= 3 then return n end
    return nil
end

local function match_preset(c)
    for _, id in ipairs(PRESET_IDS) do
        local p, same = PRESETS[id], true
        for _, f in ipairs(FILTERS) do
            if p[f] ~= c[f] then same = false break end
        end
        if same then return id end
    end
    return 'custom'
end

local function new_cfg(levels)
    local c = {}
    for _, f in ipairs(FILTERS) do c[f] = levels[f] end
    c.preset = match_preset(c)
    return c
end

local function first_item(s)
    return (tostring(s or ''):match('^[^,=:]*')) or ''
end

-- Folder with the shader files: next to this module (installed scripts folder or an explicit source path).
local shader_dir_cache
local function shader_dir()
    if shader_dir_cache and utils.file_info(shader_dir_cache .. '/denoise-1.glsl') then return shader_dir_cache end
    shader_dir_cache = nil
    local roots = {}
    if MODULE_DIR then roots[#roots + 1] = MODULE_DIR end
    local sd = mp.get_script_directory and mp.get_script_directory()
    if sd then roots[#roots + 1] = sd end
    local ok, ed = pcall(mp.command_native, { 'expand-path', '~~exe_dir/scripts' })
    if ok and type(ed) == 'string' then roots[#roots + 1] = ed end
    local tried = {}
    for _, r in ipairs(roots) do
        r = r:gsub('\\', '/')
        if not is_absolute(r) then
            local cwd = utils.getcwd()
            if cwd then r = cwd:gsub('\\', '/') .. '/' .. r end
        end
        r = r:gsub('/%./', '/'):gsub('^(.-)/%.$', '%1')
        local dir = r .. '/' .. SHADER_DIR
        if utils.file_info(dir .. '/denoise-1.glsl') then
            shader_dir_cache = dir
            return dir
        end
        tried[#tried + 1] = dir
    end
    return nil, 'picture shader folder not found (' .. (#tried > 0 and table.concat(tried, ', ') or 'module location unknown') .. ')'
end

local function check_shader(p)
    local info = utils.file_info(p)
    if not info or not info.is_file then return nil, 'picture shader not found: ' .. p end
    if info.size <= 0 then return nil, 'picture shader is empty: ' .. p end
    local f, err = io.open(p, 'rb')
    if not f then return nil, 'picture shader is not readable: ' .. p .. ' (' .. tostring(err) .. ')' end
    local head = f:read(1)
    f:close()
    if not head then return nil, 'picture shader is not readable: ' .. p end
    return true
end

local function factory(env)
    if instance then
        if type(env) == 'table' and env.changed then instance.host.changed = env.changed end
        return instance.controller
    end
    local host = { changed = type(env) == 'table' and env.changed or nil }

    local cfg = new_cfg(PRESETS.original)                               -- what the user chose (persisted)
    local st = { status = 'original', detail = '' }                     -- what is actually happening
    local own = { props = {}, shaders = nil, keys = nil }               -- what this module changed in the player
    local rt = {
        comparing = false,          -- temporary, never saved
        rtx = false,                -- the RTX upscale mode is selected
        gen = 0, armed = 0,         -- log synchronisation, see mark()
        file = 0,
        failed = nil,               -- { kind = renderer|shader|external|apply, file = } until the user acts
        window_until = 0,           -- renderer errors are attributed to our shaders until then
        collect = nil,              -- gathers the log lines that follow a shader failure
        bad = {},                   -- shader path (normalised) -> renderer error; the renderer never retries those
    }
    local config_error, persist_error, last_json
    local fail, compose, sync_timer

    local function now() return mp.get_time() end

    ----------------------------------------------------------------------------------------------------
    -- State
    ----------------------------------------------------------------------------------------------------

    local function snapshot()
        local detail = st.detail
        if detail == '' and persist_error then
            detail = 'not saved: ' .. persist_error
        elseif detail == '' and config_error then
            detail = config_error
        end
        return { preset = cfg.preset, denoise = cfg.denoise, deband = cfg.deband, lines = cfg.lines,
                 sharpen = cfg.sharpen, color = cfg.color, comparing = rt.comparing, rtx = rt.rtx,
                 status = st.status, detail = detail }
    end

    local function publish()
        local s = snapshot()
        local key = utils.format_json(s)
        if key == last_json then return end
        last_json = key
        pcall(mp.set_property_native, 'user-data/nanum/picture', s)
        if host.changed then
            local ok, e = pcall(host.changed, snapshot())
            if not ok then msg.warn(NS .. ': changed callback failed: ' .. tostring(e)) end
        end
    end

    local function set_status(status, detail)
        st.status, st.detail = status, detail or ''
        publish()
    end

    -- What would be applied: the choice, minus lines/sharpen under RTX, nothing while comparing.
    local function planned()
        local e = {}
        for _, f in ipairs(FILTERS) do e[f] = cfg[f] end
        if rt.rtx then e.lines, e.sharpen = 0, 0 end
        return e
    end

    local function effective()
        local e = planned()
        if rt.comparing then
            for _, f in ipairs(FILTERS) do e[f] = 0 end
        end
        return e
    end

    local function any_level(e)
        for _, f in ipairs(FILTERS) do
            if e[f] > 0 then return true end
        end
        return false
    end

    ----------------------------------------------------------------------------------------------------
    -- Persistence
    ----------------------------------------------------------------------------------------------------

    local function load_config()
        local o = { preset = '', denoise = '', deband = '', lines = '', sharpen = '', color = '' }
        options.read_options(o, NS)
        local problems = {}
        local levels = {}
        local preset = trim(o.preset):lower()
        local base = PRESETS.original
        if preset ~= '' then
            if PRESETS[preset] then
                base = PRESETS[preset]
            elseif preset ~= 'custom' then
                problems[#problems + 1] = 'invalid preset "' .. printable(o.preset) .. '"'
            end
        end
        for _, f in ipairs(FILTERS) do
            levels[f] = base[f]
            if trim(o[f]) ~= '' then
                local n = parse_level(o[f])
                if n then
                    levels[f] = n
                else
                    problems[#problems + 1] = 'invalid ' .. f .. ' "' .. printable(o[f]) .. '"'
                end
            end
        end
        cfg = new_cfg(levels)
        config_error = #problems > 0 and (NS .. '.conf: ' .. table.concat(problems, '; ')) or nil
    end

    local function ps_literal(value)
        return "'" .. value:gsub("'", "''") .. "'"
    end

    local function windows_files(script)
        -- Pass paths as PowerShell literals, never through cmd's %, &, ^ expansion.
        return mp.command_native({
            name = 'subprocess',
            args = { 'powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
                "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);"
                .. "$ErrorActionPreference='Stop';try{" .. script
                .. "}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}" },
            playback_only = false, capture_stdout = true, capture_stderr = true,
        })
    end

    local function ensure_dir(dir)
        local info = utils.file_info(dir)
        if info then
            if info.is_dir then return true end
            return nil, dir .. ' is not a directory'
        end
        local r
        if WIN then
            r = windows_files('[IO.Directory]::CreateDirectory(' .. ps_literal(dir) .. ') | Out-Null')
        else
            r = mp.command_native({ name = 'subprocess', args = { 'mkdir', '-p', dir },
                                    playback_only = false, capture_stderr = true })
        end
        info = utils.file_info(dir)
        if info and info.is_dir then return true end
        return nil, 'cannot create ' .. dir .. (r and r.stderr and trim(r.stderr) ~= '' and (': ' .. trim(r.stderr)) or '')
    end

    local function read_file(path)
        local f = io.open(path, 'rb')
        if not f then return nil end
        local data = f:read('*a')
        f:close()
        return data
    end

    local function write_file(path, data)
        local f, err = io.open(path, 'wb')
        if not f then return nil, tostring(err) end
        local ok, werr = f:write(data)
        local cok, cerr = f:close()
        if not ok then return nil, tostring(werr) end
        if not cok then return nil, tostring(cerr) end
        return true
    end

    -- Windows C rename does not replace an existing file. File.Replace keeps the old
    -- destination intact if replacement fails, without interpreting shell metacharacters.
    local function replace_file(tmp, path)
        if os.rename(tmp, path) then return true end
        if not WIN then return nil, 'cannot rename temporary settings file' end
        local r = windows_files('[IO.File]::Replace(' .. ps_literal(tmp) .. ','
                                .. ps_literal(path) .. ',[NullString]::Value)')
        if r and r.status == 0 and not utils.file_info(tmp) then return true end
        return nil, (r and trim((r.stderr or '') ~= '' and r.stderr or r.error_string) or 'move failed')
    end

    -- Writes the whole file through a temporary copy, reads it back and keeps the old file if anything fails.
    local function save()
        local path = mp.command_native({ 'expand-path', CONF })
        if type(path) ~= 'string' or not is_absolute(path) then
            return nil, 'no configuration folder is available (' .. CONF .. ')'
        end
        local data = ('preset=%s\ndenoise=%d\ndeband=%d\nlines=%d\nsharpen=%d\ncolor=%d\n')
            :format(cfg.preset, cfg.denoise, cfg.deband, cfg.lines, cfg.sharpen, cfg.color)
        local dir = path:match('^(.*)[/\\][^/\\]+$')
        local ok, err = ensure_dir(dir)
        if not ok then return nil, err end
        local tmp = path .. '.tmp'
        ok, err = write_file(tmp, data)
        if not ok then
            os.remove(tmp)
            return nil, 'cannot write ' .. tmp .. ': ' .. err
        end
        if read_file(tmp) ~= data then
            os.remove(tmp)
            return nil, 'cannot verify ' .. tmp
        end
        ok, err = replace_file(tmp, path)
        if not ok then
            os.remove(tmp)
            return nil, 'cannot replace ' .. path .. ': ' .. errtext(err)
        end
        if read_file(path) ~= data then return nil, 'cannot verify ' .. path end
        return true
    end

    ----------------------------------------------------------------------------------------------------
    -- Player options that belong to the active filters
    ----------------------------------------------------------------------------------------------------

    -- Sets an option and remembers its previous value. value is a string or a function of the previous value.
    -- When the option was changed behind our back it is no longer ours: with force (the user chose something)
    -- the new value becomes the previous one, otherwise nothing is set.
    local function own_set(name, value, force)
        local o = own.props[name]
        local cur = mp.get_property(name)
        if o and cur ~= o.set then
            own.props[name] = nil
            o = nil
            if not force then return true end
        end
        local base = o and o.base or cur
        if type(value) == 'function' then value = value(base) end
        if o and o.want == value then return true end
        if cur == value then return true end
        local ok, err = mp.set_property(name, value)
        if not ok then return nil, name .. ': ' .. errtext(err) end
        own.props[name] = { base = base, set = mp.get_property(name), want = value }
        return true
    end

    -- Gives the previous value back, unless the option was changed by somebody else since.
    local function restore(name)
        local o = own.props[name]
        if not o then return true end
        own.props[name] = nil
        if o.base == nil or mp.get_property(name) ~= o.set then return true end
        local ok, err = mp.set_property(name, o.base)
        if not ok then
            msg.warn(NS .. ': cannot restore ' .. name .. ': ' .. errtext(err))
            return nil, name .. ': ' .. errtext(err)
        end
        return true
    end

    local function video_params()
        local vp = mp.get_property_native('video-params')
        if type(vp) ~= 'table' or not vp.w or not vp.h or vp.w <= 0 or vp.h <= 0 then return nil end
        if mp.get_property_native('vo-configured') ~= true then return nil end
        return vp
    end

    -- nil when the video output can run the filters (or none is chosen yet), else the reason it cannot.
    local function renderer_error()
        local cur = mp.get_property('current-vo')
        local name = (cur and cur ~= '') and cur or first_item(mp.get_property('vo'))
        if name == '' or name == 'gpu-next' or name == 'gpu' then return nil end
        return 'video output "' .. name .. '" cannot run the picture filters (gpu-next or gpu is required)'
    end

    ----------------------------------------------------------------------------------------------------
    -- Log synchronisation. Messages reach the script after the fact and carry no time, so before every
    -- change that can make the renderer complain a marker line is logged; what arrives before it is old.
    ----------------------------------------------------------------------------------------------------

    local arm_timer = mp.add_timeout(1.5, function()
        if rt.armed ~= rt.gen then rt.armed = rt.gen end        -- marker lost (log buffer overflow): arm anyway
    end, true)

    local function mark()
        rt.gen = rt.gen + 1
        rt.armed = nil
        restart(arm_timer, 1.5)
        msg.warn(SYNC .. rt.gen)
    end

    ----------------------------------------------------------------------------------------------------
    -- Owned shaders
    ----------------------------------------------------------------------------------------------------

    local function current_shaders()
        local l = mp.get_property_native('glsl-shaders')
        return type(l) == 'table' and l or {}
    end

    local function without_owned(list)
        local out = copy_list(list)
        for i = #(own.shaders or {}), 1, -1 do
            for j = #out, 1, -1 do
                if out[j] == own.shaders[i] then
                    table.remove(out, j)
                    break
                end
            end
        end
        return out
    end

    local function drop_shaders()
        if not own.shaders then return true end
        local cur = current_shaders()
        local list = without_owned(cur)
        own.shaders, own.keys = nil, nil
        if same_list(cur, list) then return true end
        local ok, err = mp.set_property_native('glsl-shaders', list)
        if not ok then
            msg.warn(NS .. ': cannot restore glsl-shaders: ' .. errtext(err))
            return nil, 'glsl-shaders: ' .. errtext(err)
        end
        return true
    end

    -- Replaces our entries by the given files, in front of the entries that are not ours.
    local function apply_shaders(list)
        local cur = current_shaders()
        local base = without_owned(cur)
        local seen, add, keys = {}, {}, {}
        for _, p in ipairs(base) do seen[norm(p)] = true end
        for _, p in ipairs(list) do
            local k = norm(p)
            if not seen[k] then
                seen[k] = true
                add[#add + 1] = p
                keys[#keys + 1] = k
            end
        end
        local new = copy_list(add)
        for _, p in ipairs(base) do new[#new + 1] = p end
        if not same_list(cur, new) then
            if #add > 0 then mark() end
            local ok, err = mp.set_property_native('glsl-shaders', new)
            if not ok then return nil, 'glsl-shaders: ' .. errtext(err) end
        end
        own.shaders = #add > 0 and add or nil
        own.keys = #add > 0 and keys or nil
        rt.window_until = now() + 6
        return true
    end

    local function foreign_shaders()
        local ours = {}
        for _, p in ipairs(own.shaders or {}) do ours[p] = true end
        for _, p in ipairs(current_shaders()) do
            if not ours[p] then return true end
        end
        return false
    end

    local function release_all()
        drop_shaders()
        for _, name in ipairs(DEBAND_KEYS) do restore(name) end
        restore('deband')
        for _, name in ipairs(COLOR_KEYS) do restore(name) end
    end

    -- Whether somebody removed our entries from glsl-shaders since we set them. Options that were changed
    -- by somebody else (the user's own saturation key, say) are simply no longer ours and are left alone.
    local function shaders_removed()
        for name, o in pairs(own.props) do
            if mp.get_property(name) ~= o.set then own.props[name] = nil end
        end
        if not own.shaders then return false end
        local have = {}
        for _, p in ipairs(current_shaders()) do have[p] = true end
        for _, p in ipairs(own.shaders) do
            if not have[p] then return true end
        end
        return false
    end

    local EXTERNAL = 'glsl-shaders was changed outside the picture settings; the picture filters are off '
        .. 'until something is chosen again'

    ----------------------------------------------------------------------------------------------------
    -- Applying. Returns true or nil, error, kind.
    ----------------------------------------------------------------------------------------------------

    local function apply_deband(level, force)
        if level == 0 then
            for _, name in ipairs(DEBAND_KEYS) do restore(name) end
            return restore('deband')
        end
        local ok, err = own_set('deband', 'yes', force)
        if not ok then return nil, err end
        for _, name in ipairs(DEBAND_KEYS) do
            ok, err = own_set(name, tostring(DEBAND[level][name]), force)
            if not ok then return nil, err end
        end
        return true
    end

    local function apply_color(level, force)
        for _, name in ipairs(COLOR_KEYS) do
            if level == 0 then
                restore(name)
            else
                local delta = COLOR[level][name]
                local ok, err = own_set(name, function(base)
                    local v = (tonumber(base) or 0) + delta
                    return tostring(math.max(-100, math.min(100, math.floor(v + 0.5))))
                end, force)
                if not ok then return nil, err end
            end
        end
        return true
    end

    local function apply(force)
        local e = effective()
        if not any_level(e) then
            release_all()
            return true
        end
        local why = renderer_error()
        if why then return nil, why, 'renderer' end
        local files = {}
        for _, f in ipairs(SHADER_ORDER) do
            if e[f] > 0 then
                local dir, derr = shader_dir()
                if not dir then return nil, derr, 'apply' end
                local p = ('%s/%s-%d.glsl'):format(dir, f, e[f])
                local ok, err = check_shader(p)
                if not ok then return nil, err, 'apply' end
                local bad = rt.bad[norm(p)]
                if bad then
                    return nil, 'the renderer rejected the picture shaders earlier in this session and does not '
                        .. 'load them again; restart the player to retry (' .. compose(bad) .. ')', 'shader'
                end
                files[#files + 1] = p
            end
        end
        local ok, err = apply_shaders(files)
        if not ok then return nil, err, 'apply' end
        ok, err = apply_deband(e.deband, force)
        if not ok then return nil, err, 'apply' end
        ok, err = apply_color(e.color, force)
        if not ok then return nil, err, 'apply' end
        return true
    end

    -- apply() that leaves nothing half done on failure.
    local function activate(force)
        local ok, err, kind = apply(force)
        if not ok then
            release_all()
            return nil, err, kind
        end
        return true
    end

    -- Status in line with the video that is playing (or not). Failures stand until the user acts.
    local function sync()
        if rt.failed then return end
        local e = effective()
        if rt.comparing then
            set_status('comparing')
        elseif not any_level(e) then
            set_status('original')
        else
            local why = video_params() and renderer_error()
            if why then
                fail('renderer', why)
            elseif not video_params() then
                set_status('waiting')
            else
                set_status('active')
            end
        end
    end

    ----------------------------------------------------------------------------------------------------
    -- Failures
    ----------------------------------------------------------------------------------------------------

    -- The lines that carry the message: headings such as "shaderc output:" say nothing.
    function compose(lines)
        local good = {}
        for _, l in ipairs(lines) do
            if not l:find(':$') and #good < 3 then good[#good + 1] = l end
        end
        if #good == 0 then good[1] = lines[1] end
        return table.concat(good, ' | '):sub(1, 700)
    end

    function fail(kind, detail)
        detail = trim(detail)
        if detail == '' then detail = 'unknown error' end
        msg.verbose(NS .. ': ' .. kind .. ' failed: ' .. detail)
        rt.failed = { kind = kind, file = rt.file }
        local lines = { detail }
        if kind == 'shader' then
            for _, k in ipairs(own.keys or {}) do rt.bad[k] = lines end    -- filled up by on_log
        end
        release_all()
        rt.collect = kind == 'shader' and { gen = rt.gen, deadline = now() + 0.6, lines = lines } or nil
        set_status('error', detail)
    end

    -- Re-checks after a file change or a timer; never writes properties.
    local function run_sync()
        if not rt.failed and shaders_removed() then
            fail('external', EXTERNAL)
            return
        end
        sync()
    end

    -- Re-applies after the comparison or RTX changed (properties changed by others are respected).
    local function run_soft_apply()
        if rt.failed then
            publish()
            return
        end
        if shaders_removed() then
            fail('external', EXTERNAL)
            return
        end
        local ok, err, kind = activate(false)
        if not ok then
            fail(kind or 'apply', err)
            return
        end
        sync()
    end

    -- Reports from the renderer. Only what arrives after our marker, while our shaders are in place and shortly
    -- after they were applied, counts. With shaders of somebody else present a report is ours only if it names
    -- our shader (the DESC of every file starts with "nanum-picture"); alone in the list any renderer error is.
    local function on_log(ev)
        local text = ev.text or ''
        local g = text:match('^nanum%-picture sync (%d+)')
        if g then
            if tonumber(g) == rt.gen then rt.armed = rt.gen end
            return
        end
        local level, prefix = ev.level, ev.prefix or ''
        if level ~= 'warn' and level ~= 'error' and level ~= 'fatal' then return end
        if prefix == mp.get_script_name() or rt.armed ~= rt.gen then return end
        local line = trim(text)
        if line == '' then return end
        local from_gpu = level ~= 'warn' and (prefix:find('^vo') ~= nil or prefix:find('libplacebo', 1, true) ~= nil)
        local c = rt.collect
        if c and c.gen == rt.gen and now() <= c.deadline then
            if #c.lines < 10 and from_gpu then
                for _, l in ipairs(c.lines) do
                    if l == line then return end
                end
                c.lines[#c.lines + 1] = line
                if st.status == 'error' then
                    st.detail = compose(c.lines)
                    publish()
                end
            end
            return
        end
        if own.shaders and from_gpu and now() <= rt.window_until then
            local mine = line:find(NS, 1, true) ~= nil
            if not mine then
                for _, p in ipairs(own.shaders) do
                    local name = p:match('([^/\\]+)$')
                    if name and line:find(name, 1, true) then mine = true break end
                end
            end
            if mine or not foreign_shaders() then fail('shader', line) end
        end
    end

    ----------------------------------------------------------------------------------------------------
    -- Setters
    ----------------------------------------------------------------------------------------------------

    -- Applies a new choice; if that cannot be done the previous one is restored and nothing is saved.
    local function commit(new)
        local old, old_failed, old_compare = cfg, rt.failed, rt.comparing
        local old_status = { st.status, st.detail }
        cfg, rt.failed, rt.comparing = new, nil, false
        local ok, err = activate(true)
        if not ok then
            cfg, rt.failed, rt.comparing = old, old_failed, old_compare
            if old_failed then
                release_all()                       -- the failure it ended in is still standing
                set_status(old_status[1], old_status[2])
            else
                local rok, rerr, rkind = activate(true)
                if rok then
                    sync()
                else
                    fail(rkind or 'apply', rerr)
                end
            end
            publish()
            return nil, err
        end
        sync()
        local sok, serr = save()
        if sok then
            persist_error, config_error = nil, nil
        else
            persist_error = serr
        end
        publish()
        if not sok then return nil, 'cannot save the picture settings: ' .. serr end
        return true
    end

    local controller = {}

    function controller.get_state()
        return snapshot()
    end

    function controller.set_preset(id)
        if id == 'custom' and cfg.preset == 'custom' then return true end
        if type(id) ~= 'string' or not PRESETS[id] then
            return nil, 'unknown picture preset: ' .. printable(id)
        end
        return commit(new_cfg(PRESETS[id]))
    end

    function controller.set_filter(arg)
        if type(arg) ~= 'table' then return nil, 'set_filter needs { name =, level = }' end
        local name = arg.name
        local known = false
        for _, f in ipairs(FILTERS) do
            if f == name then known = true end
        end
        if not known then return nil, 'unknown picture filter: ' .. printable(name) end
        local level = parse_level(arg.level)
        if not level then return nil, 'strength must be 0, 1, 2 or 3: ' .. printable(arg.level) end
        local levels = {}
        for _, f in ipairs(FILTERS) do levels[f] = cfg[f] end
        levels[name] = level
        return commit(new_cfg(levels))
    end

    function controller.set_compare(on)
        if type(on) ~= 'boolean' then return nil, 'set_compare needs true or false' end
        if on == rt.comparing then return true end
        if on then
            if rt.failed then return nil, 'the picture filters are not active (' .. errtext(st.detail) .. ')' end
            if not any_level(planned()) then return nil, 'nothing to compare: no picture filter is active' end
        end
        local old = rt.comparing
        rt.comparing = on
        local ok, err, kind = activate(false)
        if not ok then
            rt.comparing = old
            if old then
                activate(false)
                set_status('comparing')
            else
                release_all()
                fail(kind or 'apply', err)
            end
            return nil, err
        end
        sync()
        return true
    end

    ----------------------------------------------------------------------------------------------------
    -- Player events
    ----------------------------------------------------------------------------------------------------

    local function guard(name, fn)
        return function(...)
            local ok, err = pcall(fn, ...)
            if not ok then msg.error(NS .. ' ' .. name .. ': ' .. tostring(err)) end
        end
    end

    local function defer(delay)
        restart(sync_timer, delay)
    end

    local soft_timer = mp.add_timeout(0.15, guard('apply', run_soft_apply), true)
    sync_timer = mp.add_timeout(0.2, guard('sync', run_sync), true)

    -- One new attempt per file for a renderer problem (the video output may have been changed meanwhile).
    mp.add_hook('on_before_start_file', 50, guard('start-file', function()
        rt.file = rt.file + 1
        if rt.failed and rt.failed.kind == 'renderer' then
            rt.failed = nil
            local ok, err, kind = activate(false)
            if not ok then fail(kind or 'apply', err) end
        end
        if not rt.failed then
            if rt.comparing then
                set_status('comparing')
            elseif any_level(effective()) then
                set_status('waiting')
            else
                set_status('original')
            end
        end
    end))

    mp.register_event('end-file', guard('end-file', function()
        if not rt.failed then
            if rt.comparing then
                set_status('comparing')
            elseif any_level(effective()) then
                set_status('waiting')
            else
                set_status('original')
            end
        end
    end))

    mp.register_event('file-loaded', guard('file-loaded', function()
        if own.shaders then rt.window_until = now() + 4 end
        defer(0.1)
    end))

    mp.register_event('video-reconfig', guard('video-reconfig', function()
        if own.shaders then rt.window_until = now() + 4 end
        defer(0.15)
    end))

    -- A renderer problem is judged again when the video output changes.
    mp.observe_property('current-vo', 'string', guard('current-vo', function()
        if rt.failed and rt.failed.kind == 'renderer' then
            rt.failed = nil
            restart(soft_timer, 0.3)
        elseif not rt.failed then
            defer(0.3)
        end
    end))

    local function note_upscale(_, v)
        local on = type(v) == 'table' and v.mode == 'rtx'
        if on == rt.rtx then return end
        rt.rtx = on
        if rt.comparing and not any_level(planned()) then rt.comparing = false end
        publish()
        restart(soft_timer, 0.15)
    end

    pcall(mp.enable_messages, 'warn')
    mp.register_event('log-message', guard('log-message', on_log))

    ----------------------------------------------------------------------------------------------------
    -- Startup: the saved choice is applied before the first file starts.
    ----------------------------------------------------------------------------------------------------

    load_config()
    do
        local ok, v = pcall(mp.get_property_native, 'user-data/nanum/upscale')
        rt.rtx = ok and type(v) == 'table' and v.mode == 'rtx' or false
    end
    local ok, err, kind = activate(true)
    if not ok then
        fail(kind or 'apply', err)
    else
        sync()
    end
    publish()

    mp.observe_property('user-data/nanum/upscale', 'native', guard('upscale', note_upscale))

    instance = { controller = controller, host = host }
    return controller
end

return factory
