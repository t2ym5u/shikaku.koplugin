local UndoStack  = require("undo_stack")
local grid_utils = require("grid_utils")

local emptyGrid     = grid_utils.emptyGrid
local emptyBoolGrid = grid_utils.emptyBoolGrid
local copyGrid      = grid_utils.copyGrid
local shuffle       = grid_utils.shuffle

local DEFAULT_N          = 6
local DEFAULT_DIFFICULTY = "medium"

-- ---------------------------------------------------------------------------
-- Rectangle partitioning helpers
-- ---------------------------------------------------------------------------

-- Split a rectangle region recursively until all pieces have area <= max_area.
-- regions: list of {r1,c1,r2,c2}
local function splitRect(r1, c1, r2, c2, max_area, regions)
    local area = (r2 - r1 + 1) * (c2 - c1 + 1)
    if area <= max_area then
        regions[#regions + 1] = { r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
        return
    end
    local h = r2 - r1 + 1
    local w = c2 - c1 + 1
    -- Choose split axis: prefer to split along the longer axis
    if h >= w then
        -- Horizontal split: split along rows
        if h < 2 then
            regions[#regions + 1] = { r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
            return
        end
        local split = r1 + math.random(1, h - 1)
        splitRect(r1, c1, split - 1, c2, max_area, regions)
        splitRect(split, c1, r2, c2, max_area, regions)
    else
        -- Vertical split: split along columns
        if w < 2 then
            regions[#regions + 1] = { r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
            return
        end
        local split = c1 + math.random(1, w - 1)
        splitRect(r1, c1, r2, split - 1, max_area, regions)
        splitRect(r1, split, r2, c2, max_area, regions)
    end
end

-- ---------------------------------------------------------------------------
-- ShikakuBoard
-- ---------------------------------------------------------------------------

local ShikakuBoard = {}
ShikakuBoard.__index = ShikakuBoard

function ShikakuBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    local obj = setmetatable({
        n               = n,
        difficulty      = opts.difficulty or DEFAULT_DIFFICULTY,
        clues           = emptyGrid(n),
        solution_rect   = emptyGrid(n),   -- rect id per cell
        rects           = {},             -- list of {r1,c1,r2,c2}
        rect_marks      = emptyGrid(n),   -- player-placed rect id per cell (0=empty)
        player_rects    = {},             -- list of {r1,c1,r2,c2}
        selected_corner = nil,
        total_rects     = 0,
        undo            = UndoStack:new{ max_size = 200 },
    }, self)
    return obj
end

function ShikakuBoard:generate(difficulty)
    self.difficulty     = difficulty or self.difficulty
    self.undo:clear()
    local n       = self.n
    -- max area per rectangle: fewer rects = harder
    local max_area
    if self.difficulty == "easy" then
        max_area = math.max(2, math.floor(n * n / 6))
    elseif self.difficulty == "hard" then
        max_area = math.min(n * n, math.floor(n * n / 2))
    else
        max_area = math.max(2, math.floor(n * n / 4))
    end
    max_area = math.min(max_area, 8)

    local regions = {}
    for attempt = 1, 20 do
        regions = {}
        splitRect(1, 1, n, n, max_area, regions)
        if #regions >= 2 then break end
    end

    -- Build solution_rect and clues
    local solution_rect = emptyGrid(n)
    local clues         = emptyGrid(n)

    for idx, rect in ipairs(regions) do
        local area = (rect.r2 - rect.r1 + 1) * (rect.c2 - rect.c1 + 1)
        -- Collect cells of this rectangle
        local cells = {}
        for r = rect.r1, rect.r2 do
            for c = rect.c1, rect.c2 do
                solution_rect[r][c] = idx
                cells[#cells + 1] = { r, c }
            end
        end
        -- Pick one random clue cell
        local ci = math.random(#cells)
        local cr, cc = cells[ci][1], cells[ci][2]
        clues[cr][cc] = area
    end

    self.rects        = regions
    self.solution_rect = solution_rect
    self.clues        = clues
    self.total_rects  = #regions
    self.rect_marks   = emptyGrid(n)
    self.player_rects = {}
    self.selected_corner = nil
end

-- ---------------------------------------------------------------------------
-- Interactions
-- ---------------------------------------------------------------------------

function ShikakuBoard:selectCorner(r, c)
    if self.selected_corner then
        -- Second tap: try to place a rectangle
        local r1 = math.min(self.selected_corner.r, r)
        local c1 = math.min(self.selected_corner.c, c)
        local r2 = math.max(self.selected_corner.r, r)
        local c2 = math.max(self.selected_corner.c, c)
        self.selected_corner = nil
        local ok, err = self:placeRect(r1, c1, r2, c2)
        return ok, err
    else
        self.selected_corner = { r = r, c = c }
        return true, nil
    end
end

function ShikakuBoard:placeRect(r1, c1, r2, c2)
    local n = self.n
    -- Validate bounds
    if r1 < 1 or c1 < 1 or r2 > n or c2 > n then
        return false, "out_of_bounds"
    end
    local area = (r2 - r1 + 1) * (c2 - c1 + 1)

    -- Count clues inside and check area matches
    local clue_count = 0
    local clue_val   = 0
    for r = r1, r2 do
        for c = c1, c2 do
            if self.clues[r][c] > 0 then
                clue_count = clue_count + 1
                clue_val   = self.clues[r][c]
            end
        end
    end
    if clue_count ~= 1 then
        return false, "must_contain_one_clue"
    end
    if area ~= clue_val then
        return false, "area_mismatch"
    end

    -- Check no overlap with already-placed rectangles
    for r = r1, r2 do
        for c = c1, c2 do
            if self.rect_marks[r][c] ~= 0 then
                return false, "overlap"
            end
        end
    end

    -- Place the rectangle
    local pid = #self.player_rects + 1
    self.player_rects[pid] = { r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
    for r = r1, r2 do
        for c = c1, c2 do
            self.rect_marks[r][c] = pid
        end
    end

    -- Record undo
    self.undo:push{ action = "place", pid = pid, r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
    return true, nil
end

function ShikakuBoard:clearCell(r, c)
    local pid = self.rect_marks[r][c]
    if pid == 0 then return false, "empty" end
    local rect = self.player_rects[pid]
    if not rect then return false, "no_rect" end

    -- Record undo
    self.undo:push{ action = "clear", pid = pid,
        r1 = rect.r1, c1 = rect.c1, r2 = rect.r2, c2 = rect.c2 }

    -- Remove the rectangle cells
    for r2 = rect.r1, rect.r2 do
        for c2 = rect.c1, rect.c2 do
            self.rect_marks[r2][c2] = 0
        end
    end
    self.player_rects[pid] = nil
    return true, nil
end

function ShikakuBoard:clearAll()
    local n = self.n
    self.rect_marks   = emptyGrid(n)
    self.player_rects = {}
    self.selected_corner = nil
    self.undo:clear()
end

-- ---------------------------------------------------------------------------
-- Undo
-- ---------------------------------------------------------------------------

function ShikakuBoard:canUndo() return self.undo:canUndo() end

function ShikakuBoard:undo()
    local entry = self.undo:pop()
    if not entry then return false, UndoStack.NOTHING_TO_UNDO end
    if entry.action == "place" then
        local pid = entry.pid
        for r = entry.r1, entry.r2 do
            for c = entry.c1, entry.c2 do
                self.rect_marks[r][c] = 0
            end
        end
        self.player_rects[pid] = nil
    elseif entry.action == "clear" then
        local pid = entry.pid
        self.player_rects[pid] = { r1 = entry.r1, c1 = entry.c1,
                                    r2 = entry.r2, c2 = entry.c2 }
        for r = entry.r1, entry.r2 do
            for c = entry.c1, entry.c2 do
                self.rect_marks[r][c] = pid
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Win condition
-- ---------------------------------------------------------------------------

function ShikakuBoard:checkWin()
    local n = self.n
    -- All cells must be covered
    for r = 1, n do
        for c = 1, n do
            if self.rect_marks[r][c] == 0 then return false end
        end
    end
    -- Each player rect must match solution rect (same cells)
    -- Verify by checking each player rect has exactly one clue equal to its area
    for _, rect in pairs(self.player_rects) do
        if rect then
            local area = (rect.r2 - rect.r1 + 1) * (rect.c2 - rect.c1 + 1)
            local clue_count = 0
            local clue_val   = 0
            for r = rect.r1, rect.r2 do
                for c = rect.c1, rect.c2 do
                    if self.clues[r][c] > 0 then
                        clue_count = clue_count + 1
                        clue_val   = self.clues[r][c]
                    end
                end
            end
            if clue_count ~= 1 or area ~= clue_val then return false end
        end
    end
    return true
end

function ShikakuBoard:getPlacedCount()
    local count = 0
    for _, rect in pairs(self.player_rects) do
        if rect then count = count + 1 end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function ShikakuBoard:serialize()
    local n = self.n
    local rects_out = {}
    for i, rect in ipairs(self.rects) do
        rects_out[i] = { r1=rect.r1, c1=rect.c1, r2=rect.r2, c2=rect.c2 }
    end
    local prects_out = {}
    for pid, rect in pairs(self.player_rects) do
        if rect then
            prects_out[#prects_out + 1] = {
                pid = pid, r1=rect.r1, c1=rect.c1, r2=rect.r2, c2=rect.c2
            }
        end
    end
    return {
        n               = n,
        difficulty      = self.difficulty,
        clues           = copyGrid(self.clues, n),
        solution_rect   = copyGrid(self.solution_rect, n),
        rect_marks      = copyGrid(self.rect_marks, n),
        rects           = rects_out,
        player_rects    = prects_out,
        total_rects     = self.total_rects,
        undo            = self.undo:serialize(),
    }
end

function ShikakuBoard:load(data)
    if type(data) ~= "table" or not data.clues or not data.solution_rect then
        return false
    end
    local n = data.n or DEFAULT_N
    self.n              = n
    self.difficulty     = data.difficulty or DEFAULT_DIFFICULTY
    self.clues          = copyGrid(data.clues, n)
    self.solution_rect  = copyGrid(data.solution_rect, n)
    self.rect_marks     = copyGrid(data.rect_marks or {}, n)
    self.total_rects    = data.total_rects or 0
    self.rects          = {}
    if data.rects then
        for i, r in ipairs(data.rects) do
            self.rects[i] = { r1=r.r1, c1=r.c1, r2=r.r2, c2=r.c2 }
        end
    end
    self.player_rects = {}
    if data.player_rects then
        for _, pr in ipairs(data.player_rects) do
            self.player_rects[pr.pid] = {
                r1=pr.r1, c1=pr.c1, r2=pr.r2, c2=pr.c2
            }
        end
    end
    self.selected_corner = nil
    self.undo = UndoStack:new{ max_size = 200 }
    if data.undo then self.undo:load(data.undo) end
    return true
end

return ShikakuBoard
