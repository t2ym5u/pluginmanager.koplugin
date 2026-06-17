local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local GestureRange    = require("ui/gesturerange")
local Geom            = require("ui/geometry")
local InputContainer  = require("ui/widget/container/inputcontainer")
local RenderText      = require("ui/rendertext")
local UIManager       = require("ui/uimanager")

local Screen = Device.screen

-- ---------------------------------------------------------------------------
-- Drawing helpers (exported alongside the class)
-- ---------------------------------------------------------------------------

local function drawLine(bb, x, y, w, h, color)
    bb:paintRect(x, y, w, h, color or Blitbuffer.COLOR_BLACK)
end

local function drawDiagonalLine(bb, x, y, length, dx, dy, color, thickness)
    color     = color     or Blitbuffer.COLOR_BLACK
    thickness = thickness or 1
    length    = math.max(0, length)
    for step = 0, length do
        local px = math.floor(x + dx * step)
        local py = math.floor(y + dy * step)
        bb:paintRect(px, py, thickness, thickness, color)
    end
end

local function drawCenteredText(bb, text, face, cx, cy, color)
    RenderText:renderUtf8Text(bb, cx, cy, face, text, true, false, color or Blitbuffer.COLOR_BLACK)
end

-- ---------------------------------------------------------------------------
-- GridWidgetBase — base widget for any square-cell grid game
--
-- Constructor parameters:
--   cols          (int)    — number of columns (required)
--   rows          (int)    — number of rows (defaults to cols)
--   size_ratio    (float)  — fraction of min(screen_w, screen_h) to use (default 0.82)
--
-- Subclasses must implement:
--   :paintTo(bb, x, y)
--
-- Subclasses may override:
--   :onCellTap(row, col)       — called when a cell is tapped
--   :onCellHold(row, col)      — called when a cell is long-pressed
--
-- Subclasses may call:
--   :getCellRect(row, col)     — returns {x, y, w, h} of a cell in paint coords
--   :refresh()
-- ---------------------------------------------------------------------------

local GridWidgetBase = InputContainer:extend{
    cols       = 9,
    rows       = nil,    -- defaults to cols
    size_ratio = 0.82,
}

function GridWidgetBase:init()
    local cols      = self.cols or 9
    local rows      = self.rows or cols
    self.cols       = cols
    self.rows       = rows

    local min_dim  = math.min(Screen:getWidth(), Screen:getHeight())
    self.size      = math.floor(min_dim * (self.size_ratio or 0.82))
    self.cell_w    = self.size / cols
    self.cell_h    = self.size / rows
    self.cell_w_px = math.ceil(self.size / cols)
    self.cell_h_px = math.ceil(self.size / rows)

    self.dimen      = Geom:new{ w = self.size, h = self.size }
    self.paint_rect = Geom:new{ x = 0, y = 0, w = self.size, h = self.size }

    self:_initFonts()

    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges   = "tap",
                range = function() return self.paint_rect end,
            }
        },
        HoldRelease = {
            GestureRange:new{
                ges   = "hold_release",
                range = function() return self.paint_rect end,
            }
        },
    }
end

-- Auto-size number and note fonts to fit within a single cell.
-- Uses binary search to minimise Font:getFace() calls (O(log n) vs O(n)).
function GridWidgetBase:_initFonts()
    local cell_w = self.cell_w
    local cell_h = self.cell_h
    local min_cell = math.min(cell_w, cell_h)

    local function bsearchFont(font_name, lo, hi, max_w, max_h)
        local best = lo
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local face = Font:getFace(font_name, mid)
            local m    = RenderText:sizeUtf8Text(0, max_w, face, "8", true, false)
            if m.x <= max_w and (m.y_bottom - m.y_top) <= max_h then
                best = mid
                lo   = mid + 1
            else
                hi   = mid - 1
            end
        end
        return best
    end

    -- Main number font: fits in the full cell (keep same -2 safety margin)
    local num_padding = math.max(2, math.floor(min_cell / 9))
    local num_safety  = math.max(1, math.floor(min_cell / 20))
    local max_nw = math.max(1, math.floor(cell_w - 2 * num_padding - num_safety))
    local max_nh = math.max(1, math.floor(cell_h - 2 * num_padding - num_safety))
    local num_hi = math.max(10, math.floor(min_cell * 0.6))
    local num_size = math.max(10, bsearchFont("cfont", 10, num_hi, max_nw, max_nh) - 2)
    self.number_face    = Font:getFace("cfont", num_size)
    self.number_padding = num_padding

    -- Small note font: fits in a cell third (for candidate annotations)
    local mini_w = cell_w / 3
    local mini_h = cell_h / 3
    local min_mini = math.min(mini_w, mini_h)
    local note_padding = math.max(1, math.floor(min_mini / 8))
    local note_safety  = math.max(1, math.floor(min_mini / 18))
    local max_mw = math.max(1, math.floor(mini_w - 2 * note_padding - note_safety))
    local max_mh = math.max(1, math.floor(mini_h - 2 * note_padding - note_safety))
    local note_hi = math.max(8, math.floor(min_mini * 0.6))
    local note_size = math.max(8, bsearchFont("smallinfofont", 8, note_hi, max_mw, max_mh) - 1)
    self.note_face    = Font:getFace("smallinfofont", note_size)
    self.note_padding = note_padding
end

-- ---------------------------------------------------------------------------
-- Coordinate helpers
-- ---------------------------------------------------------------------------

function GridWidgetBase:getCellFromPoint(x, y)
    local rect    = self.paint_rect
    local local_x = x - rect.x
    local local_y = y - rect.y
    if local_x < 0 or local_y < 0 or local_x > rect.w or local_y > rect.h then
        return nil
    end
    local col = math.min(self.cols, math.floor(local_x / self.cell_w) + 1)
    local row = math.min(self.rows, math.floor(local_y / self.cell_h) + 1)
    if row < 1 or col < 1 then return nil end
    return row, col
end

function GridWidgetBase:getCellRect(row, col)
    local rect = self.paint_rect
    return {
        x = rect.x + math.floor((col - 1) * self.cell_w),
        y = rect.y + math.floor((row - 1) * self.cell_h),
        w = self.cell_w_px,
        h = self.cell_h_px,
    }
end

-- ---------------------------------------------------------------------------
-- Gesture handlers
-- ---------------------------------------------------------------------------

function GridWidgetBase:onTap(_, ges)
    if not (ges and ges.pos) then return false end
    local row, col = self:getCellFromPoint(ges.pos.x, ges.pos.y)
    if not row then return false end
    if self.onCellTap then self:onCellTap(row, col) end
    return true
end

function GridWidgetBase:onHoldRelease(_, ges)
    if not (ges and ges.pos) then return false end
    local row, col = self:getCellFromPoint(ges.pos.x, ges.pos.y)
    if not row then return false end
    if self.onCellHold then self:onCellHold(row, col) end
    return true
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

function GridWidgetBase:refresh()
    local geom = self._dirty_geom
    if not geom then
        local rect = self.paint_rect
        geom = Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
        self._dirty_geom = geom
    end
    UIManager:setDirty(self, function()
        return "ui", geom
    end)
end

return {
    GridWidgetBase   = GridWidgetBase,
    drawLine         = drawLine,
    drawDiagonalLine = drawDiagonalLine,
    drawCenteredText = drawCenteredText,
}
