local DataStorage     = require("datastorage")
local LuaSettings     = require("luasettings")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _               = require("gettext")

-- ---------------------------------------------------------------------------
-- PluginBase — shared plugin lifecycle for all game plugins
--
-- Subclasses must set:
--   name        (string)  — unique plugin id, used as settings file name
--   menu_text   (string)  — label shown in KOReader's Tools menu
--   menu_hint   (string)  — sorting_hint for the menu category
--
-- Subclasses must implement:
--   :createScreen()       — return a new ScreenBase subclass instance
--
-- Subclasses may override:
--   :addToMainMenu(menu_items)  — for extra menu entries
-- ---------------------------------------------------------------------------

local PluginBase = WidgetContainer:extend{
    name        = "game",
    menu_text   = _("Game"),
    menu_hint   = "tools",
    is_doc_only = false,
}

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

function PluginBase:ensureSettings()
    if not self.settings_file then
        self.settings_file = DataStorage:getSettingsDir() .. "/" .. self.name .. ".lua"
    end
    if not self.settings then
        self.settings = LuaSettings:open(self.settings_file)
    end
end

function PluginBase:saveState(data, key)
    self:ensureSettings()
    self.settings:saveSetting(key or "state", data)
    self.settings:flush()
end

function PluginBase:loadState(key)
    self:ensureSettings()
    return self.settings:readSetting(key or "state")
end

function PluginBase:saveSetting(key, value)
    self:ensureSettings()
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function PluginBase:getSetting(key, default)
    self:ensureSettings()
    local v = self.settings:readSetting(key)
    if v == nil then return default end
    return v
end

-- ---------------------------------------------------------------------------
-- Menu registration
-- ---------------------------------------------------------------------------

function PluginBase:init()
    self:ensureSettings()
    self.ui.menu:registerToMainMenu(self)
end

function PluginBase:addToMainMenu(menu_items)
    menu_items[self.name] = {
        text         = self.menu_text,
        sorting_hint = self.menu_hint,
        callback     = function() self:showGame() end,
    }
end

-- ---------------------------------------------------------------------------
-- Screen lifecycle
-- ---------------------------------------------------------------------------

function PluginBase:showGame()
    if self.screen then return end
    self.screen = self:createScreen()
    UIManager:show(self.screen)
end

function PluginBase:onScreenClosed()
    self.screen = nil
end

-- Stub — subclasses must implement this and return a Screen instance.
function PluginBase:createScreen()
    error(self.name .. ": createScreen() not implemented")
end

return PluginBase
