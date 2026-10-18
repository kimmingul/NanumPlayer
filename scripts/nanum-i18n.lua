-- Display language is independent of speech recognition and subtitle translation.
local mp = require 'mp'
local utils = require 'mp.utils'
local M = {}
local supported = { ko=true, en=true, ja=true, ['zh-CN']=true, ['zh-TW']=true, es=true }
local catalogs, callbacks = {}, {}
local source = debug.getinfo(1, 'S').source
local directory = source:sub(1, 1) == '@' and source:sub(2):match('^(.*)[/\\][^/\\]*$')
local roots = {}
if directory then roots[#roots + 1] = utils.join_path(directory, '../locales') end
local ok, installed = pcall(mp.command_native, { 'expand-path', '~~exe_dir/locales' })
if ok and installed then roots[#roots + 1] = installed end
local language = mp.get_property_native('user-data/nanum/ui-language', 'en')
if not supported[language] then language = 'en' end

local function catalog(namespace)
    if catalogs[namespace] ~= nil then return catalogs[namespace] end
    for _, root in ipairs(roots) do
        local file = io.open(utils.join_path(root, namespace .. '.json'), 'rb')
        if file then
            local data = file:read('*a')
            file:close()
            local parsed = utils.parse_json(data)
            if type(parsed) == 'table' then
                catalogs[namespace] = parsed
                return parsed
            end
        end
    end
    mp.msg.error('Missing or invalid UI translation catalog: ' .. namespace)
    catalogs[namespace] = false
    return false
end

function M.language()
    return language
end

local reported = {}

function M.t(namespace, key, ...)
    local entries = catalog(namespace)
    local row = entries and entries[key]
    local text = type(row) == 'table' and row[language] or key
    if type(text) ~= 'string' then text = key end
    if text == key and language ~= 'ko' and entries and type(row) ~= 'table' then
        -- Not a catalog key: shown as written. Logged once (tools/check_i18n.py finds these statically;
        -- dynamic text such as a subtitle site's name is expected here).
        local id = namespace .. '\0' .. key
        if not reported[id] then
            reported[id] = true
            mp.msg.verbose(string.format('no %s translation in the "%s" catalog for: %s', language, namespace, key))
        end
    end
    if select('#', ...) > 0 then return string.format(text, ...) end
    return text
end

function M.translator(namespace)
    return function(key, ...) return M.t(namespace, key, ...) end
end

function M.on_change(callback)
    callbacks[#callbacks + 1] = callback
end

mp.observe_property('user-data/nanum/ui-language', 'native', function(_, value)
    if not supported[value] or value == language then return end
    language = value
    for _, callback in ipairs(callbacks) do callback(value) end
end)

return M
