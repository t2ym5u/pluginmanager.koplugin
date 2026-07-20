-- i18n.lua — Plugin translation module
--
-- Drop-in replacement for `local _ = require("gettext")`.
-- Priority: custom table → KOReader gettext → original string.
--
-- This plugin doesn't belong to a shared common/ family, so this module is
-- self-contained: all of its strings live in this plugin's own i18n_fr.lua,
-- merged in from main.lua:
--   require("i18n").extend(lrequire("i18n_fr"))
--
-- Usage:
--   local _ = require("i18n")   -- works exactly like _() from gettext
--   local i18n = require("i18n")
--   i18n.lang()                  -- returns "fr", "en", etc.

local koreader_t = require("gettext")

local function lang()
    return (G_reader_settings and G_reader_settings:readSetting("language") or "en"):sub(1, 2)
end

local S = {}

local function translate(s)
    local l = lang()
    if l ~= "en" then
        local entry = S[s]
        if entry and entry[l] then return entry[l] end
    end
    return koreader_t(s)
end

local function extend(tbl)
    for k, v in pairs(tbl) do
        S[k] = v
    end
end

return setmetatable({ lang = lang, extend = extend }, {
    __call = function(_, s) return translate(s) end,
})
