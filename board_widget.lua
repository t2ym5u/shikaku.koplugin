local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local gwb            = require("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

-- ---------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------

local C_BG          = Blitbuffer.COLOR_WHITE
local C_PLACED_BG   = Blitbuffer.COLOR_GRAY_E   -- light shade for placed rects
local C_CORNER_BG   = Blitbuffer.COLOR_GRAY_B   -- selected corner highlight
local C_CLUE_BG     = Blitbuffer.COLOR_GRAY_D   -- clue cell background
local C_LINE_THIN   = Blitbuffer.COLOR_GRAY_9
local C_LINE        = Blitbuffer.COLOR_BLACK
local C_CLUE_FG     = Blitbuffer.COLOR_BLACK
local C_RECT_BORDER = Blitbuffer.COLOR_BLACK

-- ---------------------------------------------------------------------------
-- ShikakuBoardWidget
-- ---------------------------------------------------------------------------

local ShikakuBoardWidget = GridWidgetBase:extend{ board = nil }

function ShikakuBoardWidget:init()
    local n   = self.board and self.board.n or 6
    self.cols = n
    self.rows = n
    GridWidgetBase.init(self)
end

function ShikakuBoardWidget:onCellTap(row, col)
    if self.onCellAction then self.onCellAction(row, col, false) end
end

function ShikakuBoardWidget:onCellHold(row, col)
    if self.onCellAction then self.onCellAction(row, col, true) end
end

-- ---------------------------------------------------------------------------
-- paintTo
-- ---------------------------------------------------------------------------

function ShikakuBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local board  = self.board
    local n      = board.n
    local cell   = self.dimen.w / n
    local thin   = Size.line.thin or 1
    local thick  = math.max(2, math.floor(cell * 0.08))

    -- White background
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- -----------------------------------------------------------------------
    -- Cell backgrounds
    -- -----------------------------------------------------------------------
    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c - 1) * cell)
            local cy = y + math.floor((r - 1) * cell)
            local cw = math.ceil(cell)
            local ch = math.ceil(cell)

            if board.rect_marks[r][c] ~= 0 then
                bb:paintRect(cx, cy, cw, ch, C_PLACED_BG)
            end
            -- Clue cell gets its own shade on top
            if board.clues[r][c] > 0 then
                bb:paintRect(cx, cy, cw, ch, C_CLUE_BG)
            end
            -- Selected corner
            if board.selected_corner and
               board.selected_corner.r == r and board.selected_corner.c == c then
                bb:paintRect(cx, cy, cw, ch, C_CORNER_BG)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Grid lines (thin interior, thick outer)
    -- -----------------------------------------------------------------------
    for i = 1, n - 1 do
        drawLine(bb, x + math.floor(i * cell), y, thin, self.dimen.h, C_LINE_THIN)
        drawLine(bb, x, y + math.floor(i * cell), self.dimen.w, thin, C_LINE_THIN)
    end
    -- Outer border
    drawLine(bb, x,                      y,                      self.dimen.w, thick, C_LINE)
    drawLine(bb, x,                      y + self.dimen.h - thick, self.dimen.w, thick, C_LINE)
    drawLine(bb, x,                      y,                      thick, self.dimen.h, C_LINE)
    drawLine(bb, x + self.dimen.w - thick, y,                    thick, self.dimen.h, C_LINE)

    -- -----------------------------------------------------------------------
    -- Thick borders around placed rectangles
    -- -----------------------------------------------------------------------
    local half = math.floor(thick / 2)
    for r = 1, n do
        for c = 1, n - 1 do
            local id1 = board.rect_marks[r][c]
            local id2 = board.rect_marks[r][c + 1]
            if id1 ~= id2 and (id1 ~= 0 or id2 ~= 0) then
                local lx = x + math.floor(c * cell) - half
                local ly = y + math.floor((r - 1) * cell)
                drawLine(bb, lx, ly, thick, math.ceil(cell), C_RECT_BORDER)
            end
        end
    end
    for r = 1, n - 1 do
        for c = 1, n do
            local id1 = board.rect_marks[r][c]
            local id2 = board.rect_marks[r + 1][c]
            if id1 ~= id2 and (id1 ~= 0 or id2 ~= 0) then
                local lx = x + math.floor((c - 1) * cell)
                local ly = y + math.floor(r * cell) - half
                drawLine(bb, lx, ly, math.ceil(cell), thick, C_RECT_BORDER)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Clue numbers
    -- -----------------------------------------------------------------------
    local pad  = self.number_padding or 2
    local cinn = math.max(1, math.floor(cell - 2 * pad))

    for r = 1, n do
        for c = 1, n do
            local v = board.clues[r][c]
            if v > 0 then
                local cx   = x + math.floor((c - 1) * cell)
                local cy   = y + math.floor((r - 1) * cell)
                local text = tostring(v)
                local m    = RenderText:sizeUtf8Text(0, cinn, self.number_face, text, true, false)
                local base = cy + pad + math.floor((cinn + m.y_top - m.y_bottom) / 2)
                local tx   = cx + pad + math.floor((cinn - m.x) / 2)
                RenderText:renderUtf8Text(bb, tx, base, self.number_face, text, true, false, C_CLUE_FG)
            end
        end
    end
end

return ShikakuBoardWidget
