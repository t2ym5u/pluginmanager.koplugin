local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local InfoMessage     = require("ui/widget/infomessage")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextViewer      = require("ui/widget/textviewer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")

local DeviceScreen = Device.screen

-- ---------------------------------------------------------------------------
-- ScreenBase — shared full-screen game UI
--
-- Subclasses must implement:
--   :buildLayout()       — build all widgets and assign self.layout
--   :updateStatus([msg]) — refresh the status bar text
--
-- Subclasses receive:
--   self.plugin      — the parent PluginBase instance
--   self.status_text — TextWidget for the status bar (place it in layout)
--   self.dimen       — full-screen Geom
--
-- Subclasses may call:
--   :isLandscape()
--   :showMessage(msg, timeout)
--   :closeScreen()
-- ---------------------------------------------------------------------------

local ScreenBase = InputContainer:extend{
    vertical_align = "center",
}

function ScreenBase:init()
    self.dimen         = Geom:new{ x = 0, y = 0, w = DeviceScreen:getWidth(), h = DeviceScreen:getHeight() }
    self.covers_fullscreen = true

    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end

    self.status_text = TextWidget:new{
        text = "",
        face = Font:getFace("smallinfofont"),
    }

    self:buildLayout()

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

function ScreenBase:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)

    if not self.layout then return end
    local content_size = self.layout:getSize()
    local offset_x = x + math.floor((self.dimen.w - content_size.w) / 2)
    local offset_y = y
    if self.vertical_align == "center" then
        offset_y = offset_y + math.max(0, math.floor((self.dimen.h - content_size.h) / 2))
    end
    self.layout:paintTo(bb, offset_x, offset_y)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function ScreenBase:isLandscape()
    return DeviceScreen:getWidth() > DeviceScreen:getHeight()
end

function ScreenBase:showMessage(msg, timeout)
    UIManager:show(InfoMessage:new{ text = msg, timeout = timeout or 3 })
end

function ScreenBase:closeScreen()
    if self.plugin then
        self.plugin:saveState(self.serializeState and self:serializeState() or nil)
        self.plugin:onScreenClosed()
    end
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
end

-- ---------------------------------------------------------------------------
-- Fixed portrait layout helper
-- ---------------------------------------------------------------------------

-- Build a full-screen portrait layout with header pinned to top and footer
-- pinned to bottom. Content is centred in the space between them.
-- Call this from buildLayout() instead of building self.layout manually.
--   header  — top button row widget (required)
--   content — middle game area widget (required)
--   footer  — bottom button/input widget, or nil
function ScreenBase:buildPortraitLayout(header, content, footer)
    local sh       = self.dimen.h
    local header_h = header  and header:getSize().h  or 0
    local content_h= content and content:getSize().h or 0
    local footer_h = footer  and footer:getSize().h  or 0
    local remaining = math.max(0, sh - header_h - content_h - footer_h)
    local top_gap   = math.floor(remaining / 2)
    local bot_gap   = remaining - top_gap
    local items = { align = "center" }
    if header  then items[#items+1] = header  end
    items[#items+1] = VerticalSpan:new{ width = top_gap }
    if content then items[#items+1] = content end
    items[#items+1] = VerticalSpan:new{ width = bot_gap }
    if footer  then items[#items+1] = footer  end
    self.layout = VerticalGroup:new(items)
    self[1] = self.layout
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

function ScreenBase:updateStatus(msg)
    if not self.status_text then return end
    self.status_text:setText(msg or "")
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

-- ---------------------------------------------------------------------------
-- Key events
-- ---------------------------------------------------------------------------

function ScreenBase:onClose()
    self:closeScreen()
end

-- ---------------------------------------------------------------------------
-- Standard close-button config (for use in ButtonTable rows)
-- ---------------------------------------------------------------------------

function ScreenBase:makeCloseButtonConfig()
    return {
        text     = _("Close"),
        callback = function() self:closeScreen() end,
    }
end

-- ---------------------------------------------------------------------------
-- Rules dialog (for use in ButtonTable rows)
-- ---------------------------------------------------------------------------

function ScreenBase:showRules(text)
    UIManager:show(TextViewer:new{
        title  = _("Rules"),
        text   = text,
        width  = math.floor(DeviceScreen:getWidth() * 0.9),
        height = math.floor(DeviceScreen:getHeight() * 0.9),
    })
end

function ScreenBase:makeRulesButtonConfig(en_text, fr_text)
    return {
        text     = _("Rules"),
        callback = function()
            local lang = (G_reader_settings and G_reader_settings:readSetting("language") or "en"):sub(1, 2)
            self:showRules((lang == "fr" and fr_text) or en_text)
        end,
    }
end

return ScreenBase
