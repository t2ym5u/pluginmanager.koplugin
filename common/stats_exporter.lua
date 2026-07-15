-- stats_exporter.lua — cross-plugin play-session tracker
--
-- Each plugin writes one record per session via plugin_base.lua (automatic).
-- Dashboard (and any other reader) calls StatsExporter:readAll().
--
-- Record schema per plugin:
--   sessions    (int)    — total number of play sessions
--   last_played (int)    — os.time() of the last session end
--   time_played (int)    — accumulated seconds across all sessions

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local STATS_FILE  -- resolved lazily so DataStorage is ready
local function open()
    if not STATS_FILE then
        STATS_FILE = DataStorage:getSettingsDir() .. "/game_stats.lua"
    end
    return LuaSettings:open(STATS_FILE)
end

local StatsExporter = {}

-- Write (merge) data for one plugin.
function StatsExporter:record(plugin_name, data)
    local s = open()
    local existing = s:readSetting(plugin_name) or {}
    for k, v in pairs(data) do existing[k] = v end
    s:saveSetting(plugin_name, existing)
    s:flush()
end

-- Read one field (or the whole record) for a plugin.
-- Returns nil if no data exists yet.
function StatsExporter:get(plugin_name, key)
    local d = open():readSetting(plugin_name)
    if not d then return nil end
    return key and d[key] or d
end

-- Return the full stats table (all plugins).
function StatsExporter:readAll()
    return open().data or {}
end

return StatsExporter
