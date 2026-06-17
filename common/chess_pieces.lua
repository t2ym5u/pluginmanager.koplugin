-- ---------------------------------------------------------------------------
-- chess_pieces.lua — chess piece renderer (e-ink optimised)
--
-- Primary path: loads pre-composited 128-px grayscale PNG files from the
-- chess_pieces_img/ directory that sits next to this file (resolved via
-- realpath so the symlink in each plugin directory is transparent).
-- Fallback: pixel-art drawn entirely with paintRect / scanline ovals.
--
-- Exported function:
--   M.drawPiece(bb, cx, cy, cw, ch, piece)
--     bb            blitbuffer
--     cx, cy        top-left corner of the cell (pixels)
--     cw, ch        cell width / height (pixels)
--     piece         1-6  white  pawn/rook/knight/bishop/queen/king
--                   7-12 black  pawn/rook/knight/bishop/queen/king
-- ---------------------------------------------------------------------------

local Blitbuffer = require("ffi/blitbuffer")

local M = {}

local C_WHITE  = Blitbuffer.COLOR_WHITE
local C_BLACK  = Blitbuffer.COLOR_BLACK
local C_LIGHT  = Blitbuffer.COLOR_GRAY_E

-- Piece image filenames (index = piece number 1-12)
-- white: pawn rook knight bishop queen king
-- black: pawn rook knight bishop queen king
local PIECE_NAMES = {
    "wp", "wr", "wn", "wb", "wq", "wk",
    "bp", "br", "bn", "bb", "bq", "bk",
}

-- ---------------------------------------------------------------------------
-- Image loading
-- ---------------------------------------------------------------------------

local img_cache  = {}   -- key "name:size" → blitbuffer (or false = not found)
local pieces_dir = nil  -- resolved once

local function getPiecesDir()
    if pieces_dir then return pieces_dir end
    -- Resolve the real path of this .lua file (follows symlinks in plugins)
    local src = debug.getinfo(1, "S").source:sub(2)
    local dir = src:match("(.+/)") or ""
    local ok, util = pcall(require, "ffi/util")
    if ok and util and util.realpath then
        local real = util.realpath(src)
        if real then dir = real:match("(.+/)") or dir end
    end
    pieces_dir = dir .. "chess_pieces_img/"
    return pieces_dir
end

local function getPieceImage(name, size)
    local key = name .. ":" .. size
    local cached = img_cache[key]
    if cached ~= nil then return cached or nil end  -- false = known missing

    local ok, RenderImage = pcall(require, "ui/renderimage")
    if not ok then img_cache[key] = false; return nil end

    local path = getPiecesDir() .. name .. ".png"
    local img  = RenderImage:renderImageFile(path, false, size, size)
    img_cache[key] = img or false
    return img
end

-- ---------------------------------------------------------------------------
-- Pixel-art fallback
-- ---------------------------------------------------------------------------

local function fr(bb, ix, iy, iw, ih, xf, yf, wf, hf, color)
    local x = ix + math.floor(iw * xf)
    local y = iy + math.floor(ih * yf)
    local w = math.max(1, math.floor(iw * wf))
    local h = math.max(1, math.floor(ih * hf))
    bb:paintRect(x, y, w, h, color)
end

local function drawOval(bb, ix, iy, iw, ih, cfx, cfy, rfx, rfy, color)
    local cx = ix + math.floor(iw * cfx)
    local cy = iy + math.floor(ih * cfy)
    local rx = math.max(1, math.floor(iw * rfx))
    local ry = math.max(1, math.floor(ih * rfy))
    for dy = -ry, ry do
        local frac = 1.0 - (dy * dy) / (ry * ry + 0.001)
        if frac >= 0 then
            local hw = math.floor(rx * math.sqrt(frac))
            local py = cy + dy
            local px = cx - hw
            local pw = 2 * hw + 1
            if py >= iy and py < iy + ih then
                if px < ix          then pw = pw - (ix - px); px = ix end
                if px + pw > ix + iw then pw = ix + iw - px          end
                if pw > 0 then bb:paintRect(px, py, pw, 1, color) end
            end
        end
    end
end

local function drawPawn(bb, ix, iy, iw, ih, c)
    drawOval(bb, ix,iy,iw,ih, 0.50, 0.14, 0.22, 0.14, c)
    fr(bb, ix,iy,iw,ih, 0.38, 0.28, 0.24, 0.14, c)
    fr(bb, ix,iy,iw,ih, 0.20, 0.42, 0.60, 0.16, c)
    fr(bb, ix,iy,iw,ih, 0.06, 0.58, 0.88, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.02, 0.68, 0.96, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.00, 0.78, 1.00, 0.22, c)
end

local function drawRook(bb, ix, iy, iw, ih, c)
    fr(bb, ix,iy,iw,ih, 0.00, 0.00, 0.26, 0.22, c)
    fr(bb, ix,iy,iw,ih, 0.37, 0.00, 0.26, 0.22, c)
    fr(bb, ix,iy,iw,ih, 0.74, 0.00, 0.26, 0.22, c)
    fr(bb, ix,iy,iw,ih, 0.00, 0.22, 1.00, 0.06, c)
    fr(bb, ix,iy,iw,ih, 0.06, 0.28, 0.88, 0.42, c)
    fr(bb, ix,iy,iw,ih, 0.00, 0.70, 1.00, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.00, 0.80, 1.00, 0.20, c)
end

local function drawKnight(bb, ix, iy, iw, ih, c)
    fr(bb, ix,iy,iw,ih, 0.58, 0.00, 0.18, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.28, 0.08, 0.72, 0.12, c)
    fr(bb, ix,iy,iw,ih, 0.14, 0.20, 0.82, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.02, 0.30, 0.76, 0.08, c)
    fr(bb, ix,iy,iw,ih, 0.12, 0.38, 0.68, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.24, 0.48, 0.68, 0.12, c)
    fr(bb, ix,iy,iw,ih, 0.08, 0.60, 0.86, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.00, 0.70, 1.00, 0.12, c)
    fr(bb, ix,iy,iw,ih, 0.00, 0.82, 1.00, 0.18, c)
end

local function drawBishop(bb, ix, iy, iw, ih, c)
    drawOval(bb, ix,iy,iw,ih, 0.50, 0.07, 0.10, 0.07, c)
    fr(bb, ix,iy,iw,ih, 0.40, 0.14, 0.20, 0.08, c)
    fr(bb, ix,iy,iw,ih, 0.32, 0.22, 0.36, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.24, 0.32, 0.52, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.16, 0.42, 0.68, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.42, 0.52, 0.16, 0.08, c)
    fr(bb, ix,iy,iw,ih, 0.06, 0.60, 0.88, 0.14, c)
    fr(bb, ix,iy,iw,ih, 0.00, 0.74, 1.00, 0.26, c)
end

local function drawQueen(bb, ix, iy, iw, ih, c)
    drawOval(bb, ix,iy,iw,ih, 0.10, 0.07, 0.09, 0.07, c)
    drawOval(bb, ix,iy,iw,ih, 0.50, 0.05, 0.09, 0.07, c)
    drawOval(bb, ix,iy,iw,ih, 0.90, 0.07, 0.09, 0.07, c)
    fr(bb, ix,iy,iw,ih, 0.02, 0.12, 0.96, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.28, 0.22, 0.44, 0.14, c)
    fr(bb, ix,iy,iw,ih, 0.16, 0.36, 0.68, 0.12, c)
    fr(bb, ix,iy,iw,ih, 0.08, 0.48, 0.84, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.04, 0.58, 0.92, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.02, 0.68, 0.96, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.00, 0.78, 1.00, 0.22, c)
end

local function drawKing(bb, ix, iy, iw, ih, c)
    fr(bb, ix,iy,iw,ih, 0.18, 0.04, 0.64, 0.08, c)
    fr(bb, ix,iy,iw,ih, 0.44, 0.00, 0.12, 0.20, c)
    fr(bb, ix,iy,iw,ih, 0.34, 0.20, 0.32, 0.14, c)
    fr(bb, ix,iy,iw,ih, 0.22, 0.34, 0.56, 0.14, c)
    fr(bb, ix,iy,iw,ih, 0.10, 0.48, 0.80, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.06, 0.58, 0.88, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.02, 0.68, 0.96, 0.10, c)
    fr(bb, ix,iy,iw,ih, 0.00, 0.78, 1.00, 0.22, c)
end

local PIXEL_ART = { drawPawn, drawRook, drawKnight, drawBishop, drawQueen, drawKing }

local LETTERS = {
    [1]="P",  [2]="T",  [3]="C",  [4]="F",  [5]="D",  [6]="R",
    [7]="P",  [8]="T",  [9]="C",  [10]="F", [11]="D", [12]="R",
}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.drawPiece(bb, cx, cy, cw, ch, piece)
    if piece == 0 then return end
    local is_white = (piece <= 6)
    local ptype    = is_white and piece or (piece - 6)  -- 1..6

    local pad   = math.max(2, math.floor(math.min(cw, ch) * 0.08))
    local bw    = math.max(1, math.floor(math.min(cw, ch) * 0.055))
    local bx    = cx + pad
    local by    = cy + pad
    local box_w = cw - 2 * pad
    local box_h = ch - 2 * pad
    if box_w <= 0 or box_h <= 0 then return end

    local fill_c   = is_white and C_WHITE or C_BLACK
    local border_c = is_white and C_BLACK or C_LIGHT
    local draw_c   = is_white and C_BLACK or C_WHITE

    -- Background box + border
    bb:paintRect(bx, by, box_w, box_h, fill_c)
    bb:paintRect(bx,              by,               box_w, bw,    border_c)
    bb:paintRect(bx,              by + box_h - bw,  box_w, bw,    border_c)
    bb:paintRect(bx,              by,               bw,    box_h, border_c)
    bb:paintRect(bx + box_w - bw, by,               bw,    box_h, border_c)

    local inset = bw + 1
    local ix    = bx + inset
    local iy    = by + inset
    local iw    = box_w - 2 * inset
    local ih    = box_h - 2 * inset
    if iw < 4 or ih < 4 then return end

    -- Very small cells: letter
    if iw < 10 or ih < 10 then
        local Font       = require("ui/font")
        local RenderText = require("ui/rendertext")
        local face   = Font:getFace("cfont", math.max(8, math.floor(ih * 0.65)))
        local letter = LETTERS[piece] or "?"
        local m  = RenderText:sizeUtf8Text(0, iw, face, letter, true, false)
        local tx = ix + math.floor((iw - m.x) / 2)
        local ty = iy + math.floor((ih - (m.y_bottom - m.y_top)) / 2) + math.abs(m.y_top)
        RenderText:renderUtf8Text(bb, tx, ty, face, letter, true, false, draw_c)
        return
    end

    -- Try PNG image (cburnett set)
    local name = PIECE_NAMES[piece]
    local size = math.min(iw, ih)
    local img  = name and getPieceImage(name, size)
    if img then
        local iw2 = img:getWidth()
        local ih2 = img:getHeight()
        local ox  = ix + math.floor((iw - iw2) / 2)
        local oy  = iy + math.floor((ih - ih2) / 2)
        bb:blitFrom(img, ox, oy, 0, 0, iw2, ih2)
        return
    end

    -- Pixel-art fallback
    local drawFn = PIXEL_ART[ptype]
    if drawFn then drawFn(bb, ix, iy, iw, ih, draw_c) end
end

return M
