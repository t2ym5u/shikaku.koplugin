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
-- Uniqueness counter: the clue grid (one area number per rectangle, placed
-- at a chosen cell within it) IS the entire puzzle -- there's no separate
-- "given" mask. Solving means partitioning the whole grid into rectangles,
-- each containing exactly one clue cell whose value equals that
-- rectangle's area. For each clue, enumerate every rectangle containing it
-- with the right area and no OTHER clue inside, then backtrack (MRV:
-- fewest currently-fitting candidates first) trying to tile the whole
-- grid with no gaps or overlaps.
-- ---------------------------------------------------------------------------

local function candidateRectsFor(clues, n, cr, cc, area)
    local cands = {}
    for h = 1, area do
        if area % h == 0 then
            local w = area / h
            for dr = 0, h - 1 do
                local r1 = cr - dr
                local r2 = r1 + h - 1
                if r1 >= 1 and r2 <= n then
                    for dc = 0, w - 1 do
                        local c1 = cc - dc
                        local c2 = c1 + w - 1
                        if c1 >= 1 and c2 <= n then
                            local ok = true
                            for r = r1, r2 do
                                for c = c1, c2 do
                                    if not (r == cr and c == cc) and clues[r][c] and clues[r][c] > 0 then
                                        ok = false; break
                                    end
                                end
                                if not ok then break end
                            end
                            if ok then
                                cands[#cands + 1] = { r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
                            end
                        end
                    end
                end
            end
        end
    end
    return cands
end

local function countSolutions(clues, n, limit, node_budget)
    local clue_list = {}
    for r = 1, n do
        for c = 1, n do
            if clues[r][c] and clues[r][c] > 0 then
                clue_list[#clue_list + 1] = { r = r, c = c, area = clues[r][c] }
            end
        end
    end

    local occupied = {}
    for r = 1, n do occupied[r] = {}; for c = 1, n do occupied[r][c] = false end end
    local placed = {}
    for i = 1, #clue_list do placed[i] = false end
    local total_cells = n * n
    local cells_filled = 0

    local solutions, nodes, exhausted = 0, 0, false

    local function rectFits(rect)
        for r = rect.r1, rect.r2 do
            for c = rect.c1, rect.c2 do
                if occupied[r][c] then return false end
            end
        end
        return true
    end

    local function applyRect(rect, val)
        for r = rect.r1, rect.r2 do
            for c = rect.c1, rect.c2 do occupied[r][c] = val end
        end
    end

    local function search()
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end

        local best_i, best_fits, best_len = nil, nil, math.huge
        for i = 1, #clue_list do
            if not placed[i] then
                local cl = clue_list[i]
                local cands = candidateRectsFor(clues, n, cl.r, cl.c, cl.area)
                local fits = {}
                for _, rect in ipairs(cands) do
                    if rectFits(rect) then fits[#fits + 1] = rect end
                end
                if #fits < best_len then
                    best_len, best_fits, best_i = #fits, fits, i
                    if best_len == 0 then break end
                end
            end
        end

        if not best_i then
            if cells_filled == total_cells then solutions = solutions + 1 end
            return
        end
        if best_len == 0 then return end

        placed[best_i] = true
        local area = clue_list[best_i].area
        for _, rect in ipairs(best_fits) do
            applyRect(rect, true)
            cells_filled = cells_filled + area
            search()
            cells_filled = cells_filled - area
            applyRect(rect, false)
            if solutions >= limit or exhausted then break end
        end
        placed[best_i] = false
    end

    search()
    return solutions, exhausted
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

    -- The clue grid (one area number per rectangle, at a chosen cell
    -- within it) IS the entire puzzle -- there's no "given" mask to dig,
    -- so like hitori/nurikabe this generates+verifies whole candidates
    -- instead. Repicking which cell holds each rectangle's clue is much
    -- cheaper than re-splitting the grid (no search involved, and a
    -- different clue-cell choice can turn an ambiguous layout unique), so
    -- that's tried many times per partition before falling back to a
    -- fresh split. Measured pre-fix: 0/15 unique at n=8 and n=10 (every
    -- difficulty) -- naive single-random-clue-cell placement is severely
    -- ambiguous for this genre, as expected.
    local node_budget = n <= 6 and 20000 or (n <= 8 and 40000 or 80000)
    local best_regions, best_solution_rect, best_clues

    for partition_attempt = 1, 40 do
        local regions = {}
        for a = 1, 20 do
            regions = {}
            splitRect(1, 1, n, n, max_area, regions)
            if #regions >= 2 then break end
        end

        local solution_rect = emptyGrid(n)
        local rect_cells = {}
        for idx, rect in ipairs(regions) do
            local cells = {}
            for r = rect.r1, rect.r2 do
                for c = rect.c1, rect.c2 do
                    solution_rect[r][c] = idx
                    cells[#cells + 1] = { r, c }
                end
            end
            rect_cells[idx] = cells
        end

        for clue_attempt = 1, 25 do
            local clues = emptyGrid(n)
            for idx, rect in ipairs(regions) do
                local area = (rect.r2 - rect.r1 + 1) * (rect.c2 - rect.c1 + 1)
                local cells = rect_cells[idx]
                local ci = math.random(#cells)
                clues[cells[ci][1]][cells[ci][2]] = area
            end

            if not best_regions then
                best_regions, best_solution_rect, best_clues = regions, solution_rect, clues
            end

            local solutions, exhausted = countSolutions(clues, n, 2, node_budget)
            if solutions == 1 and not exhausted then
                self.rects          = regions
                self.solution_rect  = solution_rect
                self.clues          = clues
                self.total_rects    = #regions
                self.rect_marks     = emptyGrid(n)
                self.player_rects   = {}
                self.selected_corner = nil
                return
            end
        end
    end

    self.rects          = best_regions
    self.solution_rect   = best_solution_rect
    self.clues           = best_clues
    self.total_rects     = #best_regions
    self.rect_marks       = emptyGrid(n)
    self.player_rects     = {}
    self.selected_corner  = nil
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
