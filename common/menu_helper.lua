local Device     = require("device")
local Menu       = require("ui/widget/menu")
local UIManager  = require("ui/uimanager")
local _          = require("gettext")

local DeviceScreen = Device.screen

-- ---------------------------------------------------------------------------
-- MenuHelper — reusable picker-menu builder
--
-- openPickerMenu(opts) — shows a full Menu widget with a checkmark on the
-- currently selected item and calls on_select(id) on confirmation.
--
-- opts fields:
--   title       (string)   — menu title
--   items       (table)    — array of { id, text } entries
--   current_id  (any)      — id of the currently selected item
--   on_select   (function) — called with (id) when an item is picked
--   parent      (widget)   — show_parent for the Menu (optional)
--   width_ratio (float)    — fraction of screen width (default 0.7)
--   height_ratio(float)    — fraction of screen height (default 0.9)
-- ---------------------------------------------------------------------------

local MenuHelper = {}

function MenuHelper.openPickerMenu(opts)
    local title        = opts.title       or _("Select")
    local items        = opts.items       or {}
    local current_id   = opts.current_id
    local on_select    = opts.on_select   or function() end
    local width_ratio  = opts.width_ratio  or 0.7
    local height_ratio = opts.height_ratio or 0.9

    local menu_ref  -- forward declaration for close inside callback

    local item_table = {}
    for _, entry in ipairs(items) do
        local id   = entry.id
        local text = entry.text
        item_table[#item_table + 1] = {
            text     = text,
            checked  = (id == current_id),
            callback = function()
                if menu_ref then UIManager:close(menu_ref) end
                on_select(id)
                return true
            end,
        }
    end

    menu_ref = Menu:new{
        title                  = title,
        item_table             = item_table,
        width                  = math.floor(DeviceScreen:getWidth()  * width_ratio),
        height                 = math.floor(DeviceScreen:getHeight() * height_ratio),
        disable_footer_padding = true,
        show_parent            = opts.parent,
    }
    UIManager:show(menu_ref)
    return menu_ref
end

-- ---------------------------------------------------------------------------
-- Predefined difficulty levels (easy / medium / hard)
-- ---------------------------------------------------------------------------

MenuHelper.DIFFICULTY_ORDER = { "easy", "medium", "hard" }
MenuHelper.DIFFICULTY_LABELS = {
    easy   = _("Easy"),
    medium = _("Medium"),
    hard   = _("Hard"),
}

-- Convenience wrapper: open a difficulty picker.
-- opts: { current, on_select, parent }
function MenuHelper.openDifficultyMenu(opts)
    local items = {}
    for _, id in ipairs(MenuHelper.DIFFICULTY_ORDER) do
        items[#items + 1] = { id = id, text = MenuHelper.DIFFICULTY_LABELS[id] or id }
    end
    return MenuHelper.openPickerMenu{
        title      = _("Select difficulty"),
        items      = items,
        current_id = opts.current,
        on_select  = opts.on_select,
        parent     = opts.parent,
    }
end

-- Convenience wrapper: open a generic "select size" picker.
-- sizes: array of { id, label } (e.g. { { id="5x5", label="5×5" }, ... })
function MenuHelper.openSizeMenu(opts)
    return MenuHelper.openPickerMenu{
        title      = opts.title or _("Select size"),
        items      = opts.sizes or {},
        current_id = opts.current,
        on_select  = opts.on_select,
        parent     = opts.parent,
    }
end

return MenuHelper
