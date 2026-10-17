-- Video upscale backend for NanumPlayer. scripts/nanum.lua loads this file and calls the factory it returns:
--
--   local ctl = factory({ changed = function(state) end })
--   ctl.get_state()      -> { mode, scale, shaders, status, detail, factor }   (also user-data/nanum/upscale)
--   ctl.set_mode(m)      m: default | quality | rtx | shader
--   ctl.set_scale(s)     s: auto | 1.5 | 2 | 3 (any factor in (1, 4]); only the RTX mode uses it
--   ctl.set_shaders(l)   l: ordered array of absolute .glsl/.hook/.frag paths; only the shader mode uses them
--
-- Setters return true or nil, <raw error>. Nothing happens until the factory is called, so the file is harmless
-- when mpv auto-loads it from a scripts folder. Choices are kept in ~~/script-opts/nanum-upscale.conf
-- (mode, scale, shaders as a JSON array) and are read with mp.options under the namespace "nanum-upscale".
--
-- Every option this module changes is remembered together with its previous value and put back when the mode is
-- left, unless somebody else changed it in the meantime. Filters and shaders that are not ours are never touched:
-- the RTX filter carries the label @nanum-upscale and only our own glsl-shaders entries are removed again.
--
--   default  nothing changes
--   quality  scale=ewa_lanczossharp, scale-antiring=0.6 on vo=gpu-next
--   rtx      vo=gpu-next, gpu-api=d3d11, hwdec=d3d11va and vf @nanum-upscale:d3d11vpp=scale=N:scaling-mode=nvidia.
--            Whether the driver really runs RTX Video Super Resolution is decided by the NVIDIA driver settings
--            and cannot be observed: status rtx_requested only means "requested". The filter's own warnings
--            (extension unavailable, HDR, ...) are taken as failure and remove the filter.
--            N is the chosen factor, or with "auto" the enlargement needed to fill the window (original video
--            size from video-params, drawable size from osd-dimensions, quarter steps, at most 4, no filter at all
--            when the picture would not be enlarged). The filter is taken out before every file starts and put
--            back once video and window are known; while it is in the chain auto-window-resize is held off so
--            that the enlarged picture does not resize the window (and with it the next factor).
--   shader   the configured shader files are appended to glsl-shaders after the existing entries; compile or
--            parse errors the renderer logs afterwards remove those entries again.
--
-- Log reports reach the script late and without a time stamp, so a marker line is logged before each change that
-- can fail in the renderer or the filter and only what follows the marker is attributed to the new state.
--
-- Statuses: default, waiting (chosen, nothing to apply yet), quality, rtx_requested, shader, not_needed (auto
-- factor without enlargement), error (detail holds the raw message; it stays until a setter is called again,
-- the RTX mode gets one new attempt per file).

local mp = require 'mp'
local options = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local NS = 'nanum-upscale'
local LABEL = 'nanum-upscale'                       -- label of the vf entry that belongs to this module
local CONF = '~~/script-opts/nanum-upscale.conf'
local PIN = 'auto-window-resize'                    -- held off while our filter changes the video size
local SYNC = 'nanum-upscale sync '                  -- log marker, see mark()
local WIN = package.config:sub(1, 1) == '\\'
local MODES = { default = true, quality = true, rtx = true, shader = true }
local EXTS = { glsl = true, hook = true, frag = true }
-- Properties each mode keeps owned; everything else that was changed is restored when the mode is entered.
local KEEP = {
    default = {},
    quality = { vo = true, scale = true, ['scale-antiring'] = true },
    rtx = { vo = true, ['gpu-api'] = true, hwdec = true },
    shader = { vo = true },
}
local MAX_SHADERS = 32
local MAX_SHADER_BYTES = 16 * 1024 * 1024
local MAX_FACTOR = 4                                -- UI policy; actual device limits still depend on the driver
local MIN_ENLARGE = 1.05                            -- below this the picture is not enlarged enough to matter
local DEBOUNCE = 0.5                                -- seconds the window size must stay put before the factor follows
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

-- "auto" or a factor above 1 and up to MAX_FACTOR, in the canonical spelling ("1.5", "2", "3").
local function parse_scale(v)
    local s = trim(v):lower()
    if s == 'auto' then return 'auto' end
    local n = tonumber(s)
    if n and n > 1 and n <= MAX_FACTOR then return ('%g'):format(n) end
    return nil
end

-- A user shader must exist and be readable now; the GPU compiles it later (see on_log for that failure).
local function check_shader(p)
    if type(p) ~= 'string' or p == '' then return nil, 'shader path must be a non-empty string' end
    if p:find('%c') then return nil, 'shader path contains control characters: ' .. printable(p) end
    if not is_absolute(p) then return nil, 'shader path is not absolute: ' .. p end
    local ext = p:match('%.([^./\\]+)$')
    if not (ext and EXTS[ext:lower()]) then
        return nil, 'unsupported shader file type (.glsl, .hook or .frag expected): ' .. p
    end
    local info = utils.file_info(p)
    if not info then return nil, 'shader file not found: ' .. p end
    if not info.is_file then return nil, 'shader path is not a file: ' .. p end
    if info.size <= 0 then return nil, 'shader file is empty: ' .. p end
    if info.size > MAX_SHADER_BYTES then return nil, 'shader file is too large: ' .. p end
    local f, err = io.open(p, 'rb')
    if not f then return nil, 'shader file is not readable: ' .. p .. ' (' .. tostring(err) .. ')' end
    local head = f:read(1)
    f:close()
    if not head then return nil, 'shader file is not readable: ' .. p end
    return true
end

local function check_shaders(list)
    for _, p in ipairs(list) do
        local ok, err = check_shader(p)
        if not ok then return nil, err end
    end
    return true
end

-- Ordered list without duplicates (same file spelled differently counts once); nil, error for anything else.
local function clean_shader_list(v)
    if type(v) ~= 'table' then return nil, 'shader list must be an array of paths' end
    local list, seen, n = {}, {}, 0
    for i, p in ipairs(v) do
        if type(p) ~= 'string' or p == '' or p:find('%c') then
            return nil, 'shader list entry ' .. i .. ' is not a valid path'
        end
        n = n + 1
        local k = norm(p)
        if not seen[k] then
            seen[k] = true
            list[#list + 1] = p
        end
    end
    if next(v) ~= nil and n == 0 then return nil, 'shader list must be an array of paths' end
    if #list > MAX_SHADERS then return nil, 'too many shaders (at most ' .. MAX_SHADERS .. ')' end
    return list
end

local function copy_list(l)
    local out = {}
    for i, v in ipairs(l) do out[i] = v end
    return out
end

local function restart(timer, seconds)
    timer.timeout = seconds
    timer:kill()
    timer:resume()
end

local function factory(env)
    if instance then
        if type(env) == 'table' and env.changed then instance.host.changed = env.changed end
        return instance.controller
    end
    local host = { changed = type(env) == 'table' and env.changed or nil }

    local cfg = { mode = 'default', scale = 'auto', shaders = {} }      -- what the user chose (persisted)
    local st = { status = 'default', detail = '', factor = 1 }          -- what is actually happening
    local own = { props = {}, shaders = nil, filter = false }           -- what this module changed in the player
    local rt = {
        gen = 0, armed = 0,         -- log synchronisation, see mark()
        file = 0,                   -- counts file starts
        failed = nil,               -- { kind =, file = } after a failure; stays until the user acts (or next file for rtx)
        window_until = 0,           -- shader compile errors are attributed to us until then
        renderer_until = 0,         -- grace period after we switched vo/gpu-api
        collect = nil,              -- gathers the log lines that follow a failure
        pin_wait = false,
        bad = {},                   -- shader path (normalised) -> how often it failed in the renderer
    }
    local config_error, persist_error, last_json
    local fail, defer, sync
    local sync_timer

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
        return { mode = cfg.mode, scale = cfg.scale, shaders = copy_list(cfg.shaders),
                 status = st.status, detail = detail, factor = st.factor }
    end

    local function publish()
        local s = snapshot()
        local key = utils.format_json(s)
        if key == last_json then return end
        last_json = key
        pcall(mp.set_property_native, 'user-data/nanum/upscale', s)
        if host.changed then
            local ok, e = pcall(host.changed, snapshot())
            if not ok then msg.warn(NS .. ': changed callback failed: ' .. tostring(e)) end
        end
    end

    local function set_status(status, detail, factor)
        st.status, st.detail, st.factor = status, detail or '', factor or 1
        publish()
    end

    local function idle_status()
        if cfg.mode == 'default' or (cfg.mode == 'shader' and #cfg.shaders == 0) then
            set_status('default')
        else
            set_status('waiting')
        end
    end

    ----------------------------------------------------------------------------------------------------
    -- Persistence
    ----------------------------------------------------------------------------------------------------

    local function load_config()
        local o = { mode = 'default', scale = 'auto', shaders = '[]' }
        options.read_options(o, NS)
        local problems = {}
        if MODES[o.mode] then
            cfg.mode = o.mode
        else
            problems[#problems + 1] = 'invalid mode "' .. printable(o.mode) .. '"'
        end
        local sc = parse_scale(o.scale)
        if sc then
            cfg.scale = sc
        else
            problems[#problems + 1] = 'invalid scale "' .. printable(o.scale) .. '"'
        end
        local v, jerr
        if trim(o.shaders) == '' then v = {} else v, jerr = utils.parse_json(o.shaders) end
        if v == nil then
            problems[#problems + 1] = 'shaders is not valid JSON' .. (jerr and (' (' .. tostring(jerr) .. ')') or '')
        else
            local list, lerr = clean_shader_list(v)
            if list then cfg.shaders = list else problems[#problems + 1] = lerr end
        end
        config_error = #problems > 0 and (NS .. '.conf: ' .. table.concat(problems, '; ')) or nil
    end

    local function ensure_dir(dir)
        local info = utils.file_info(dir)
        if info then
            if info.is_dir then return true end
            return nil, dir .. ' is not a directory'
        end
        local args = WIN and { 'cmd', '/c', 'mkdir', (dir:gsub('/', '\\')) } or { 'mkdir', '-p', dir }
        local r = mp.command_native({ name = 'subprocess', args = args, playback_only = false, capture_stderr = true })
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

    -- Writes the whole file through a temporary copy and reads it back; false positives ("saved") are not allowed.
    local function save()
        local path = mp.command_native({ 'expand-path', CONF })
        if type(path) ~= 'string' or not is_absolute(path) then
            return nil, 'no configuration folder is available (' .. CONF .. ')'
        end
        local json, jerr = utils.format_json(cfg.shaders)
        if not json or json:find('[\r\n]') then return nil, 'cannot encode the shader list: ' .. tostring(jerr) end
        local data = ('mode=%s\nscale=%s\nshaders=%s\n'):format(cfg.mode, cfg.scale, json)
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
        if not os.rename(tmp, path) then
            os.remove(path)                         -- Windows will not rename over an existing file
            if not os.rename(tmp, path) then
                os.remove(tmp)
                ok, err = write_file(path, data)
                if not ok then return nil, 'cannot write ' .. path .. ': ' .. err end
            end
        end
        if read_file(path) ~= data then return nil, 'cannot verify ' .. path end
        return true
    end

    ----------------------------------------------------------------------------------------------------
    -- Player options that belong to the active mode
    ----------------------------------------------------------------------------------------------------

    -- Sets an option and remembers its previous value; false when the option cannot be set.
    local function own_set(name, value)
        local o = own.props[name]
        local cur = mp.get_property(name)
        if o and cur ~= o.set then                  -- changed behind our back: that value is not ours to restore
            own.props[name] = nil
            o = nil
        end
        if o and o.want == value then return true end
        if cur == value then return true end
        local ok, err = mp.set_property(name, value)
        if not ok then return nil, name .. ': ' .. errtext(err) end
        own.props[name] = { base = o and o.base or cur, set = mp.get_property(name), want = value }
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

    local function first_item(s)
        return (tostring(s or ''):match('^[^,=:]*')) or ''
    end

    local function vo_ok(allow_gpu)
        local cur = mp.get_property('current-vo')
        if cur and cur ~= '' then return cur == 'gpu-next' or (allow_gpu and cur == 'gpu') end
        local first = first_item(mp.get_property('vo'))
        return first == '' or first == 'gpu-next' or (allow_gpu and first == 'gpu')
    end

    local function api_ok()
        local ctx = mp.get_property('current-gpu-context')
        if ctx and ctx ~= '' then return ctx == 'd3d11' end
        return first_item(mp.get_property('gpu-api')) == 'd3d11'
    end

    local function hwdec_ok()
        return mp.get_property('hwdec-current') == 'd3d11va' or first_item(mp.get_property('hwdec')) == 'd3d11va'
    end

    -- vo / gpu-api changes reinitialise the renderer; give it a moment before judging the result.
    local function set_renderer(name, value)
        local ok, err = own_set(name, value)
        if ok then rt.renderer_until = now() + 6 end
        return ok, err
    end

    -- 'ok', 'pending' (renderer is changing) or 'bad' plus a reason.
    local function renderer_state(d3d11, allow_gpu)
        local pending = now() < rt.renderer_until
        local cur = mp.get_property('current-vo')
        if not cur or cur == '' then
            if pending then return 'pending' end
            return 'bad', 'no video output is active'
        end
        if not (cur == 'gpu-next' or (allow_gpu and cur == 'gpu')) then
            if pending then return 'pending' end
            return 'bad', 'video output is "' .. cur .. '", ' .. (allow_gpu and 'gpu-next or gpu' or 'gpu-next') .. ' is required'
        end
        if d3d11 then
            local ctx = mp.get_property('current-gpu-context')
            if ctx and ctx ~= '' and ctx ~= 'd3d11' then
                if pending then return 'pending' end
                return 'bad', 'GPU context is "' .. ctx .. '", d3d11 is required'
            end
        end
        return 'ok'
    end

    ----------------------------------------------------------------------------------------------------
    -- Log synchronisation. Messages reach the script after the fact and carry no time, so a failure report
    -- from the previous mode could be mistaken for one of the new mode. Before every mutation that can
    -- produce such reports a marker line is logged; what arrives before the marker is old and ignored.
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
    -- Window size pin. The filter changes the size of the video; with auto-window-resize the window would
    -- follow, the drawable area would grow and the automatic factor with it. While our filter is present the
    -- option is off, and it is released only after the reconfiguration caused by removing the filter.
    ----------------------------------------------------------------------------------------------------

    local pin_timer
    local function pin_restore()
        rt.pin_wait = false
        pin_timer:kill()
        if own.filter then return end
        restore(PIN)
    end
    pin_timer = mp.add_timeout(2.5, function() pin_restore() end, true)

    local function pin_on()
        rt.pin_wait = false
        pin_timer:kill()
        return own_set(PIN, 'no')
    end

    local function pin_release()
        if not own.props[PIN] then return end
        if video_params() then
            rt.pin_wait = true
            restart(pin_timer, 2.5)                 -- shortened by the first video-reconfig that follows
        else
            pin_restore()
        end
    end

    ----------------------------------------------------------------------------------------------------
    -- Owned filter and shaders
    ----------------------------------------------------------------------------------------------------

    local function find_filter()
        local list = mp.get_property_native('vf')
        if type(list) == 'table' then
            for _, e in ipairs(list) do
                if e.label == LABEL then return e end
            end
        end
        return nil
    end

    local function drop_filter()
        own.filter = false
        if find_filter() then
            local ok, err = mp.commandv('vf', 'remove', '@' .. LABEL)
            if not ok then
                msg.warn(NS .. ': cannot remove the video filter: ' .. errtext(err))
                return nil, 'vf remove: ' .. errtext(err)
            end
        end
        pin_release()
        return true
    end

    local function ensure_filter(factor)
        local e = find_filter()
        local p = e and e.params or {}
        if e and e.name == 'd3d11vpp' and e.enabled ~= false and tonumber(p.scale) == factor
           and p['scaling-mode'] == 'nvidia' then
            own.filter = true
            return true
        end
        local ok, err = pin_on()
        if not ok then return nil, err end
        mark()
        local spec = ('@%s:d3d11vpp=scale=%g:scaling-mode=nvidia'):format(LABEL, factor)
        ok, err = mp.commandv('vf', 'add', spec)
        if not ok then
            own.filter = e ~= nil
            return nil, 'vf add ' .. spec .. ': ' .. errtext(err)
        end
        own.filter = true
        return true
    end

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

    local function same_list(a, b)
        if #a ~= #b then return false end
        for i = 1, #a do
            if a[i] ~= b[i] then return false end
        end
        return true
    end

    local function drop_shaders()
        if not own.shaders then return true end
        local cur = current_shaders()
        local list = without_owned(cur)
        own.shaders, own.shader_keys = nil, nil
        if same_list(cur, list) then return true end
        local ok, err = mp.set_property_native('glsl-shaders', list)
        if not ok then
            msg.warn(NS .. ': cannot restore glsl-shaders: ' .. errtext(err))
            return nil, 'glsl-shaders: ' .. errtext(err)
        end
        return true
    end

    -- The renderer remembers every shader path it has loaded, a failed one included, and never reads it again
    -- while the renderer lives: a shader that was fixed and selected again would be skipped without a word.
    -- After a failure the same file is therefore handed over under another spelling of its path.
    local function spell(p)
        local n = rt.bad[norm(p)] or 0
        if n == 0 then return p end
        if WIN and n == 1 then
            if p:find('\\', 1, true) then return (p:gsub('\\', '/')) end
            return (p:gsub('/', '\\'))
        end
        local dir, name = p:gsub('\\', '/'):match('^(.*)/([^/]+)$')
        return dir .. string.rep('/.', WIN and n - 1 or n) .. '/' .. name
    end

    -- Appends the configured shaders after the entries that are already there.
    local function apply_shaders(list)
        local cur = current_shaders()
        local base = without_owned(cur)
        local seen, add, keys = {}, {}, {}
        for _, p in ipairs(base) do seen[norm(p)] = true end
        for _, p in ipairs(list) do
            local k = norm(p)
            if not seen[k] then
                seen[k] = true
                add[#add + 1] = spell(p)
                keys[#keys + 1] = k
            end
        end
        local new = copy_list(base)
        for _, p in ipairs(add) do new[#new + 1] = p end
        if not same_list(cur, new) then
            if #add > 0 then mark() end
            local ok, err = mp.set_property_native('glsl-shaders', new)
            if not ok then return nil, 'glsl-shaders: ' .. errtext(err) end
        end
        own.shaders = #add > 0 and add or nil
        own.shader_keys = #add > 0 and keys or nil
        rt.window_until = now() + 6
        return true
    end

    local function release_all()
        drop_filter()
        drop_shaders()
        for name in pairs(own.props) do
            if name ~= PIN then restore(name) end
        end
    end

    ----------------------------------------------------------------------------------------------------
    -- Automatic factor
    ----------------------------------------------------------------------------------------------------

    -- How much larger the picture has to be than the original to fill the drawable area: the original video
    -- size and aspect (video-params, not the filtered output) fitted into the window (osd-dimensions).
    -- nil while the window has not been measured. Quantised upwards to quarter steps so that dragging the
    -- window edge does not rebuild the filter for every pixel.
    local function auto_factor(vp)
        local od = mp.get_property_native('osd-dimensions')
        if type(od) ~= 'table' or not od.w or not od.h or od.w <= 0 or od.h <= 0 then return nil end
        local function pos(v) return type(v) == 'number' and v > 0 and v or nil end
        local sw, sh = pos(vp['crop-w']) or vp.w, pos(vp['crop-h']) or vp.h
        local dw, dh = pos(vp.dw) or sw, pos(vp.dh) or sh
        local rot = ((tonumber(vp.rotate) or 0) + (tonumber(mp.get_property_number('video-rotate', 0)) or 0)) % 180
        if rot == 90 then sw, sh, dw, dh = sh, sw, dh, dw end
        if sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0 then return nil end
        local aspect = dw / dh
        local fw, fh
        if od.w / od.h >= aspect then
            fh, fw = od.h, od.h * aspect
        else
            fw, fh = od.w, od.w / aspect
        end
        local factor = math.max(fw / sw, fh / sh)
        if factor <= MIN_ENLARGE then return 1 end
        return math.min(MAX_FACTOR, math.ceil(factor * 4 - 1e-6) / 4)
    end

    ----------------------------------------------------------------------------------------------------
    -- Applying a mode. All of these return true or nil, error.
    ----------------------------------------------------------------------------------------------------

    local function sync_rtx()
        local vp = video_params()
        if not vp then
            drop_filter()
            set_status('waiting')
            return true
        end
        local state, why = renderer_state(true, false)
        if state == 'pending' then
            set_status('waiting')
            defer(0.6)
            return true
        elseif state == 'bad' then
            return nil, why
        end
        local factor
        if cfg.scale == 'auto' then
            factor = auto_factor(vp)
            if not factor then
                set_status('waiting')
                return true
            end
        else
            factor = tonumber(cfg.scale)
        end
        if factor <= 1 then
            drop_filter()
            set_status('not_needed')
            return true
        end
        local ok, err = ensure_filter(factor)
        if not ok then return nil, err end
        set_status('rtx_requested', '', factor)
        return true
    end

    local function sync_renderer_mode(status, allow_gpu)
        if not video_params() then
            set_status('waiting')
            return true
        end
        local state, why = renderer_state(false, allow_gpu)
        if state == 'pending' then
            set_status('waiting')
            defer(0.6)
            return true
        elseif state == 'bad' then
            return nil, why
        end
        set_status(status)
        return true
    end

    -- Brings the status in line with the video that is playing (or not) and keeps the filter in step.
    function sync()
        if rt.failed then return true end           -- a failure stands until the user acts (or the next file)
        if cfg.mode == 'rtx' then
            return sync_rtx()
        elseif cfg.mode == 'quality' then
            return sync_renderer_mode('quality', false)
        elseif cfg.mode == 'shader' then
            if #cfg.shaders == 0 then
                set_status('default')
                return true
            end
            return sync_renderer_mode('shader', true)
        end
        return true
    end

    local function apply()
        local mode = cfg.mode
        local ok, err
        if mode == 'shader' then
            ok, err = check_shaders(cfg.shaders)
            if not ok then return nil, err end
        elseif mode == 'rtx' and not WIN then
            return nil, 'NVIDIA RTX upscale needs Windows (Direct3D 11)'
        end

        -- The filter goes first: with the renderer switched back it could no longer be created and the video
        -- chain would be left without a picture.
        if mode ~= 'rtx' then drop_filter() end
        if mode ~= 'shader' then drop_shaders() end
        local keep = KEEP[mode]
        for name in pairs(own.props) do
            if name ~= PIN and not keep[name] then restore(name) end
        end

        if mode == 'default' then
            set_status('default')
            return true
        end
        if not vo_ok(mode == 'shader') then
            ok, err = set_renderer('vo', 'gpu-next')
            if not ok then return nil, err end
        end
        if mode == 'quality' then
            ok, err = own_set('scale', 'ewa_lanczossharp')
            if not ok then return nil, err end
            ok, err = own_set('scale-antiring', '0.6')
            if not ok then return nil, err end
        elseif mode == 'rtx' then
            if not api_ok() then
                ok, err = set_renderer('gpu-api', 'd3d11')
                if not ok then return nil, err end
            end
            if not hwdec_ok() then
                ok, err = own_set('hwdec', 'd3d11va')
                if not ok then return nil, err end
            end
        else
            ok, err = apply_shaders(cfg.shaders)
            if not ok then return nil, err end
        end
        return sync()
    end

    -- apply() that leaves nothing half done on failure.
    local function activate()
        local ok, err = apply()
        if not ok then
            release_all()
            return nil, err
        end
        return true
    end

    ----------------------------------------------------------------------------------------------------
    -- Failures
    ----------------------------------------------------------------------------------------------------

    -- The lines that carry the message: headings such as "shaderc output:" say nothing.
    local function compose(lines)
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
        for _, k in ipairs(own.shader_keys or {}) do rt.bad[k] = (rt.bad[k] or 0) + 1 end
        release_all()
        rt.collect = { kind = kind, gen = rt.gen, deadline = now() + 0.6, lines = { detail } }
        set_status('error', detail)
    end

    local function run_sync()
        local ok, err = sync()
        if not ok then fail(cfg.mode, err) end
    end

    function defer(delay)
        restart(sync_timer, delay)
    end

    -- Reports from the renderer and from the filter. Only what arrives after our marker and while the
    -- matching part of this module is active counts: d3d11vpp warnings/errors (the NVIDIA extension failing
    -- makes the filter fall back to plain scaling, so it is removed) and renderer errors shortly after
    -- the shaders were applied (compile or parse failures of the user's shaders).
    local function on_log(ev)
        local text = ev.text or ''
        local g = text:match('^nanum%-upscale sync (%d+)')
        if g then
            if tonumber(g) == rt.gen then rt.armed = rt.gen end
            return
        end
        local level, prefix = ev.level, ev.prefix or ''
        if level ~= 'warn' and level ~= 'error' and level ~= 'fatal' then return end
        if prefix == mp.get_script_name() or rt.armed ~= rt.gen then return end
        local line = trim(text)
        if line == '' then return end
        local from_filter = prefix == 'd3d11vpp' or (level ~= 'warn' and line:find(LABEL, 1, true) ~= nil)
        local from_gpu = level ~= 'warn' and (prefix:find('^vo') ~= nil or prefix:find('libplacebo', 1, true) ~= nil)
        local c = rt.collect
        if c and c.gen == rt.gen and now() <= c.deadline then
            if #c.lines < 10 and ((c.kind == 'rtx' and from_filter) or (c.kind == 'shader' and from_gpu)) then
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
        if own.filter and from_filter then
            fail('rtx', line)
        elseif own.shaders and from_gpu and now() <= rt.window_until then
            fail('shader', line)
        end
    end

    ----------------------------------------------------------------------------------------------------
    -- Setters
    ----------------------------------------------------------------------------------------------------

    -- Applies a new choice; if that cannot be done the previous one is restored and nothing is saved.
    local function commit(new)
        local old, old_failed = cfg, rt.failed
        local old_status = { st.status, st.detail, st.factor }
        cfg, rt.failed = new, nil
        local ok, err = activate()
        if not ok then
            cfg, rt.failed = old, old_failed
            if old_failed then
                release_all()                       -- the failure it ended in is still standing
                set_status(unpack(old_status))
            else
                local rok, rerr = activate()
                if not rok then
                    rt.failed = { kind = cfg.mode, file = rt.file }
                    set_status('error', rerr)
                end
            end
            publish()
            return nil, err
        end
        local sok, serr = save()
        if sok then
            persist_error, config_error = nil, nil
        else
            persist_error = serr
        end
        publish()
        if not sok then return nil, 'cannot save the upscale settings: ' .. serr end
        return true
    end

    local controller = {}

    function controller.get_state()
        return snapshot()
    end

    function controller.set_mode(mode)
        if type(mode) ~= 'string' or not MODES[mode] then
            return nil, 'unknown upscale mode: ' .. printable(mode)
        end
        return commit({ mode = mode, scale = cfg.scale, shaders = cfg.shaders })
    end

    function controller.set_scale(scale)
        local s = parse_scale(scale)
        if not s then return nil, 'unsupported scale (auto or a factor above 1 up to ' .. MAX_FACTOR .. '): ' .. printable(scale) end
        return commit({ mode = cfg.mode, scale = s, shaders = cfg.shaders })
    end

    function controller.set_shaders(paths)
        local list, err = clean_shader_list(paths)
        if not list then return nil, err end
        local ok
        ok, err = check_shaders(list)
        if not ok then return nil, err end
        return commit({ mode = cfg.mode, scale = cfg.scale, shaders = list })
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

    sync_timer = mp.add_timeout(0.2, guard('sync', run_sync), true)

    -- Runs before the next file is opened, so no file ever starts with our filter in the chain: its size would
    -- change the window and the factor was measured for the previous video anyway.
    mp.add_hook('on_before_start_file', 50, guard('start-file', function()
        rt.file = rt.file + 1
        drop_filter()
        if rt.failed and rt.failed.kind == 'rtx' then
            rt.failed = nil                         -- one new attempt per file
            local ok, err = activate()
            if not ok then
                rt.failed = { kind = 'rtx', file = rt.file }
                set_status('error', err)
            end
        elseif not rt.failed then
            idle_status()
        end
    end))

    mp.register_event('end-file', guard('end-file', function()
        drop_filter()
        if not rt.failed then idle_status() end
    end))

    mp.register_event('file-loaded', guard('file-loaded', function()
        if cfg.mode ~= 'default' then defer(0.1) end
    end))

    mp.register_event('video-reconfig', guard('video-reconfig', function()
        if rt.pin_wait then restart(pin_timer, 0.35) end
        if own.shaders then rt.window_until = now() + 4 end
        if cfg.mode ~= 'default' then defer(0.15) end
    end))

    mp.observe_property('osd-dimensions', 'native', guard('osd-dimensions', function()
        if cfg.mode == 'rtx' and cfg.scale == 'auto' and not rt.failed then defer(DEBOUNCE) end
    end))

    mp.observe_property('current-vo', 'string', guard('current-vo', function()
        if cfg.mode ~= 'default' and not rt.failed then defer(0.3) end
    end))

    pcall(mp.enable_messages, 'warn')
    mp.register_event('log-message', guard('log-message', on_log))

    ----------------------------------------------------------------------------------------------------
    -- Startup: the saved choice is applied before the first file starts.
    ----------------------------------------------------------------------------------------------------

    load_config()
    local ok, err = activate()
    if not ok then
        rt.failed = { kind = cfg.mode, file = rt.file }
        set_status('error', err)
    else
        publish()
    end

    instance = { controller = controller, host = host }
    return controller
end

return factory
