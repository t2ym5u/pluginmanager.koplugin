local Device     = require("device")
local Menu       = require("ui/widget/menu")
local UIManager  = require("ui/uimanager")
local _          = require("i18n")

local DeviceScreen = Device.screen

-- ---------------------------------------------------------------------------
-- SettingsDialog — generic multi-section settings menu
--
-- Usage:
--   local SettingsDialog = require("settings_dialog")
--
--   SettingsDialog.open({
--     title  = _("Sudoku settings"),
--     plugin = self.plugin,
--     parent = self,
--     sections = {
--       {
--         title = _("Gameplay"),
--         items = {
--           {
--             label       = _("Difficulty"),
--             setting_key = "difficulty",
--             type        = "picker",
--             values      = {
--               { id = "easy",   text = _("Easy")   },
--               { id = "medium", text = _("Medium")  },
--               { id = "hard",   text = _("Hard")    },
--             },
--             on_change   = function(id) ... end,   -- optional callback
--           },
--           {
--             label       = _("Auto-save"),
--             setting_key = "auto_save",
--             type        = "toggle",     -- boolean on/off
--             on_change   = function(v) ... end,
--           },
--         },
--       },
--     },
--   })
--
-- Item types:
--   "picker"  — cycles through a list of { id, text } values
--   "toggle"  — boolean true/false stored as setting
--   "info"    — read-only text row (no setting_key needed)
--   "action"  — fires callback immediately, no persisted value
-- ---------------------------------------------------------------------------

local SettingsDialog = {}

-- Build a flat item_table for Menu from a sections definition.
local function buildItemTable(sections, plugin, close_fn)
    local item_table = {}

    local function currentLabel(item)
        if item.type == "picker" then
            local cur = plugin:getSetting(item.setting_key)
            for _, v in ipairs(item.values or {}) do
                if v.id == cur then return v.text end
            end
            -- fallback: first value
            if item.values and item.values[1] then
                return item.values[1].text
            end
            return tostring(cur)
        elseif item.type == "toggle" then
            local cur = plugin:getSetting(item.setting_key, false)
            return cur and _("On") or _("Off")
        end
        return ""
    end

    local function rowText(item)
        local t = item.label or ""
        if item.type == "picker" or item.type == "toggle" then
            t = t .. ": " .. currentLabel(item)
        end
        return t
    end

    for _, section in ipairs(sections) do
        -- Section header row (not selectable)
        if section.title then
            item_table[#item_table + 1] = {
                text       = section.title,
                bold       = true,
                dim        = true,
                callback   = function() end,  -- no-op
            }
        end

        for _, item in ipairs(section.items or {}) do
            if item.type == "picker" then
                item_table[#item_table + 1] = {
                    text = rowText(item),
                    callback = function()
                        -- Find next value in cycle
                        local values = item.values or {}
                        local cur    = plugin:getSetting(item.setting_key)
                        local next_id
                        for i, v in ipairs(values) do
                            if v.id == cur then
                                next_id = (values[i % #values + 1] or values[1]).id
                                break
                            end
                        end
                        if not next_id and values[1] then
                            next_id = values[1].id
                        end
                        if next_id then
                            plugin:saveSetting(item.setting_key, next_id)
                            if item.on_change then item.on_change(next_id) end
                        end
                        -- Reopen to reflect new value
                        if close_fn then close_fn() end
                        SettingsDialog.open(item._opts_ref)
                    end,
                }
            elseif item.type == "toggle" then
                item_table[#item_table + 1] = {
                    text = rowText(item),
                    callback = function()
                        local cur = plugin:getSetting(item.setting_key, false)
                        plugin:saveSetting(item.setting_key, not cur)
                        if item.on_change then item.on_change(not cur) end
                        if close_fn then close_fn() end
                        SettingsDialog.open(item._opts_ref)
                    end,
                }
            elseif item.type == "action" then
                item_table[#item_table + 1] = {
                    text = item.label or "",
                    callback = function()
                        if item.callback then item.callback() end
                        if item.close_after ~= false and close_fn then close_fn() end
                    end,
                }
            elseif item.type == "info" then
                item_table[#item_table + 1] = {
                    text     = item.label or "",
                    dim      = true,
                    callback = function() end,
                }
            end
        end
    end

    return item_table
end

function SettingsDialog.open(opts)
    local title   = opts.title   or _("Settings")
    local plugin  = opts.plugin
    local parent  = opts.parent
    local sections = opts.sections or {}

    -- Inject back-reference so picker/toggle callbacks can reopen with same opts.
    for _, section in ipairs(sections) do
        for _, item in ipairs(section.items or {}) do
            item._opts_ref = opts
        end
    end

    local menu_ref
    local function close_fn()
        if menu_ref then UIManager:close(menu_ref) end
    end

    local item_table = buildItemTable(sections, plugin, close_fn)

    menu_ref = Menu:new{
        title                  = title,
        item_table             = item_table,
        width                  = math.floor(DeviceScreen:getWidth()  * 0.85),
        height                 = math.floor(DeviceScreen:getHeight() * 0.9),
        disable_footer_padding = true,
        show_parent            = parent,
    }
    UIManager:show(menu_ref)
    return menu_ref
end

return SettingsDialog
