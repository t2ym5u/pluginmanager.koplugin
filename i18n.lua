-- i18n.lua — Plugin translation module
--
-- Drop-in replacement for `local _ = require("gettext")`.
-- Priority: custom table → KOReader gettext → original string.
--
-- This plugin doesn't belong to a shared common/ family, so this module is
-- self-contained: all of its strings live in this plugin's own i18n_fr.lua,
-- which this module reads itself, for the UI language only, on first use.
--
-- Usage:
--   local _ = require("i18n")   -- works exactly like _() from gettext
--   local i18n = require("i18n")
--   i18n.lang()                  -- returns "fr", "en", etc.

local koreader_t = require("gettext")

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local function lang()
    return (G_reader_settings and G_reader_settings:readSetting("language") or "en"):sub(1, 2)
end

-- i18n_fr.lua holds every language's strings (~150 KB once loaded). Only
-- the UI language's are kept, read on its first translated string: English
-- never loads the file, and the table is rebuilt if the language changes.
local S, S_lang = {}, nil
local EXTRA = {}  -- what extend() added, all languages

local function strings(l)
    if S_lang ~= l then
        S, S_lang = {}, l
        local chunk = loadfile(_dir .. "i18n_fr.lua")
        local ok, all = pcall(chunk or error)
        if ok and type(all) == "table" then
            for k, v in pairs(all) do
                if type(v) == "table" and v[l] then S[k] = v[l] end
            end
        end
    end
    return S
end

local function translate(s)
    local l = lang()
    if l ~= "en" then
        local t = strings(l)[s]
        if t then return t end
        local entry = EXTRA[s]
        if entry and entry[l] then return entry[l] end
    end
    return koreader_t(s)
end

local function extend(tbl)
    for k, v in pairs(tbl) do
        EXTRA[k] = v
    end
end

-- Which language's strings are loaded (nil: none), for the specs.
local function loadedLanguage()
    return S_lang
end

return setmetatable({ lang = lang, extend = extend, loadedLanguage = loadedLanguage }, {
    __call = function(_, s) return translate(s) end,
})
