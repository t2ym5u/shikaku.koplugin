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
-- 1.6.0: a cut is only made where both halves keep at least min_area cells
-- (a piece with no such cut is kept as it is, even above max_area), so a
-- level's rectangles stay in its size range instead of including slivers
-- of 1-2 cells at every level.
local function splitRect(r1, c1, r2, c2, max_area, regions, min_area)
    min_area = min_area or 1
    local area = (r2 - r1 + 1) * (c2 - c1 + 1)
    if area <= max_area then
        regions[#regions + 1] = { r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
        return
    end
    local h = r2 - r1 + 1
    local w = c2 - c1 + 1
    -- Split along the longer axis (rows when square), where both halves
    -- keep min_area cells; else across the other axis; else keep it whole.
    local function cuts(len, other)
        local lo = math.max(1, math.ceil(min_area / other))
        local hi = len - lo
        return lo, hi
    end
    local axes = h >= w and { "h", "w" } or { "w", "h" }
    for _, axis in ipairs(axes) do
        local len, other = h, w
        if axis == "w" then len, other = w, h end
        local lo, hi = cuts(len, other)
        if lo <= hi then
            local k = math.random(lo, hi)
            if axis == "h" then
                splitRect(r1, c1, r1 + k - 1, c2, max_area, regions, min_area)
                splitRect(r1 + k, c1, r2, c2, max_area, regions, min_area)
            else
                splitRect(r1, c1, r2, c1 + k - 1, max_area, regions, min_area)
                splitRect(r1, c1 + k, r2, c2, max_area, regions, min_area)
            end
            return
        end
    end
    regions[#regions + 1] = { r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
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

-- Every clue's candidate rectangles are listed once up front, each with a
-- count of its cells already covered (blocked[id]; it still fits while
-- that is 0, kept up to date as rectangles are placed and removed). The
-- search then works like an exact cover: at each node it counts, for
-- every unplaced clue, its rectangles that still fit, and for every empty
-- cell, the fitting rectangles (of any unplaced clue) that would cover it.
-- A clue or a cell with none is a dead end -- the old clue-only search
-- only noticed an uncoverable cell once every clue was placed. It branches
-- on whichever clue or cell has the fewest options (every cell is covered
-- by exactly one rectangle, so branching over a cell's options counts each
-- tiling once, same as branching over a clue's). 1.5.0: up to 0.66 s per
-- 10x10 puzzle before, on a desktop.
local function countSolutions(clues, n, limit, node_budget)
    local clue_list = {}
    for r = 1, n do
        for c = 1, n do
            if clues[r][c] and clues[r][c] > 0 then
                clue_list[#clue_list + 1] = { r = r, c = c, area = clues[r][c] }
            end
        end
    end
    local K, N = #clue_list, n * n

    -- rect id -> its cells and its clue; cands[i] = clue i's rect ids;
    -- cover[cell] = ids of the rects covering it.
    local rcells, rclue, blocked = {}, {}, {}
    local cands, cover = {}, {}
    for cell = 1, N do cover[cell] = {} end
    local clue_area = 0
    for i, cl in ipairs(clue_list) do
        clue_area = clue_area + cl.area
        local list = {}
        for _, rect in ipairs(candidateRectsFor(clues, n, cl.r, cl.c, cl.area)) do
            local id = #rcells + 1
            local cells = {}
            for r = rect.r1, rect.r2 do
                for c = rect.c1, rect.c2 do
                    local cell = (r - 1) * n + c
                    cells[#cells + 1] = cell
                    local cv = cover[cell]
                    cv[#cv + 1] = id
                end
            end
            rcells[id], rclue[id], blocked[id] = cells, i, 0
            list[#list + 1] = id
        end
        cands[i] = list
    end
    if clue_area ~= N then return 0, false, 0 end

    local occupied, placed = {}, {}
    for cell = 1, N do occupied[cell] = false end
    for i = 1, K do placed[i] = false end

    local function apply(id, delta)
        for _, cell in ipairs(rcells[id]) do
            occupied[cell] = delta > 0
            for _, other in ipairs(cover[cell]) do
                blocked[other] = blocked[other] + delta
            end
        end
    end

    local solutions, nodes, exhausted = 0, 0, false

    local function search(left)
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        if left == 0 then
            solutions = solutions + 1  -- areas add up to n*n, no overlaps
            return
        end
        local best_i, best_cell, best_len = nil, nil, math.huge
        for i = 1, K do
            if not placed[i] then
                local cnt = 0
                for _, id in ipairs(cands[i]) do
                    if blocked[id] == 0 then cnt = cnt + 1 end
                end
                if cnt == 0 then return end
                if cnt < best_len then best_i, best_len = i, cnt end
            end
        end
        if best_len > 1 then
            for cell = 1, N do
                if not occupied[cell] then
                    local cnt = 0
                    for _, id in ipairs(cover[cell]) do
                        if blocked[id] == 0 and not placed[rclue[id]] then cnt = cnt + 1 end
                    end
                    if cnt == 0 then return end
                    if cnt < best_len then
                        best_i, best_cell, best_len = nil, cell, cnt
                        if cnt == 1 then break end
                    end
                end
            end
        end
        local options = best_cell and cover[best_cell] or cands[best_i]
        for _, id in ipairs(options) do
            local i = rclue[id]
            if blocked[id] == 0 and not placed[i] then
                placed[i] = true; apply(id, 1)
                search(left - 1)
                apply(id, -1); placed[i] = false
                if solutions >= limit or exhausted then return end
            end
        end
    end

    search(K)
    return solutions, exhausted, nodes
end

-- ---------------------------------------------------------------------------
-- Human-style solver (1.6.0): grades a clue grid by the reasoning a player
-- needs, never by trial ("suppose this rectangle, find a contradiction",
-- which on paper is indistinguishable from guessing).
--
--   tier 1  a clue with only one rectangle left that fits, or a cell only
--           one rectangle (of any clue) can still cover: draw it, and
--           strike every other rectangle overlapping it.
--   tier 2  a cell that every remaining rectangle of a clue covers belongs
--           to that clue: strike the other clues' rectangles over it; a
--           cell only one clue's rectangles can still reach must be that
--           clue's: strike its rectangles that miss it.
--
-- Every deduction is sound, so a grid this solves completely has exactly
-- one solution. Returns solved, tier2 (how many tier-2 deductions were
-- needed because tier 1 was stuck), tier1_rects (rectangles drawn by a
-- tier-1 move).
-- ---------------------------------------------------------------------------
local function logicSolve(clues, n, max_tier)
    max_tier = max_tier or 2
    local clue_list = {}
    for r = 1, n do
        for c = 1, n do
            if clues[r][c] and clues[r][c] > 0 then
                clue_list[#clue_list + 1] = { r = r, c = c, area = clues[r][c] }
            end
        end
    end
    local K, N = #clue_list, n * n
    local rcells, rclue, alive = {}, {}, {}
    local cands, cover = {}, {}
    for cell = 1, N do cover[cell] = {} end
    local total = 0
    for i, cl in ipairs(clue_list) do
        total = total + cl.area
        local list = {}
        for _, rect in ipairs(candidateRectsFor(clues, n, cl.r, cl.c, cl.area)) do
            local id = #rcells + 1
            local cells = {}
            for r = rect.r1, rect.r2 do
                for c = rect.c1, rect.c2 do
                    local cell = (r - 1) * n + c
                    cells[#cells + 1] = cell
                    local cv = cover[cell]
                    cv[#cv + 1] = id
                end
            end
            rcells[id], rclue[id], alive[id] = cells, i, true
            list[#list + 1] = id
        end
        cands[i] = list
    end
    if total ~= N then return false, 0, 0 end

    local fixed, covered = {}, {}
    local left = K

    local function fix(id)
        local i = rclue[id]
        fixed[i] = id
        left = left - 1
        for _, other in ipairs(cands[i]) do
            if other ~= id then alive[other] = false end
        end
        for _, cell in ipairs(rcells[id]) do
            covered[cell] = true
            for _, other in ipairs(cover[cell]) do
                if other ~= id then alive[other] = false end
            end
        end
    end

    local t2_rounds, t1_rects = 0, 0
    while left > 0 do
        local progress = false
        -- tier 1: clue singles
        for i = 1, K do
            if not fixed[i] then
                local only, cnt = nil, 0
                for _, id in ipairs(cands[i]) do
                    if alive[id] then cnt = cnt + 1; only = id end
                end
                if cnt == 0 then return false, t2_rounds, t1_rects end
                if cnt == 1 then fix(only); t1_rects = t1_rects + 1; progress = true end
            end
        end
        -- tier 1: cell singles
        if not progress then
            for cell = 1, N do
                if not covered[cell] then
                    local only, cnt = nil, 0
                    for _, id in ipairs(cover[cell]) do
                        if alive[id] then cnt = cnt + 1; only = id end
                    end
                    if cnt == 0 then return false, t2_rounds, t1_rects end
                    if cnt == 1 then
                        fix(only); t1_rects = t1_rects + 1; progress = true
                        break
                    end
                end
            end
        end
        -- Tier 2 makes one deduction (one clue's shared cells, or one
        -- cell's single owner) and goes back to tier 1, so tier2 counts
        -- the steps a player could not take with tier 1 alone.
        if not progress and max_tier >= 2 then
            -- tier 2a: cells common to all of a clue's rectangles
            for i = 1, K do
                if not fixed[i] then
                    local hits, nalive = {}, 0
                    for _, id in ipairs(cands[i]) do
                        if alive[id] then
                            nalive = nalive + 1
                            for _, cell in ipairs(rcells[id]) do
                                hits[cell] = (hits[cell] or 0) + 1
                            end
                        end
                    end
                    for cell = 1, N do
                        if hits[cell] == nalive then
                            for _, other in ipairs(cover[cell]) do
                                if alive[other] and rclue[other] ~= i then
                                    alive[other] = false; progress = true
                                end
                            end
                        end
                    end
                    if progress then break end
                end
            end
            -- tier 2b: a cell only one clue can reach
            for cell = 1, N do
                if progress then break end
                if not covered[cell] then
                    local owner, single = nil, true
                    for _, id in ipairs(cover[cell]) do
                        if alive[id] then
                            if owner == nil then owner = rclue[id]
                            elseif owner ~= rclue[id] then single = false; break end
                        end
                    end
                    if owner and single then
                        for _, id in ipairs(cands[owner]) do
                            if alive[id] then
                                local hit = false
                                for _, c2 in ipairs(rcells[id]) do
                                    if c2 == cell then hit = true; break end
                                end
                                if not hit then alive[id] = false; progress = true end
                            end
                        end
                    end
                end
            end
            if progress then t2_rounds = t2_rounds + 1 end
        end
        if not progress then return false, t2_rounds, t1_rects end
    end
    return true, t2_rounds, t1_rects
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

-- What each level asks for (1.6.0). Before, every level's rectangles were
-- capped at 8 cells, so at 8x8 and 10x10 (and Medium/Hard at 6x6) all
-- three levels built the very same puzzles.
--   max_area / min_area  rectangle sizes (see splitRect)
--   min_t2 / max_t2      how many tier-2 deductions (see logicSolve) the
--                        solution needs; tier 1 alone when both are 0
-- Easy: small rectangles, "only one place fits" all the way.
-- Medium: mid-size rectangles, a few tier-2 steps.
-- Hard: big rectangles (fewer numbers), more tier-2 steps.
-- Never trial and error, at any level.
local LEVELS = {
    easy   = function(n) return { max_area = n, min_area = 2, min_t2 = 0, max_t2 = 0 } end,
    medium = function(n) return { max_area = math.floor(n * 1.6), min_area = 3,
                                  min_t2 = 1, max_t2 = n >= 8 and 3 or 2 } end,
    hard   = function(n) return { max_area = 2 * n, min_area = 4,
                                  min_t2 = n >= 8 and 4 or 3, max_t2 = math.huge } end,
}
ShikakuBoard.LEVELS = LEVELS
ShikakuBoard.PARTITIONS, ShikakuBoard.CLUE_TRIES = 200, 5

-- on_progress(fraction), optional: called after every candidate grid
-- (screen.lua wires it to the shared "Generating puzzle…" bar).
function ShikakuBoard:generate(difficulty, on_progress)
    self.difficulty = difficulty or self.difficulty
    self.undo:clear()
    local n = self.n
    local level = (LEVELS[self.difficulty] or LEVELS.medium)(n)

    -- The clue grid (one area number per rectangle, at a chosen cell
    -- within it) IS the entire puzzle, so whole candidates are generated
    -- and graded: a random partition, then several random choices of
    -- which cell carries each rectangle's number (cheap, and that choice
    -- is what makes a layout ambiguous or not), then a fresh partition.
    -- A candidate is kept when the human-style solver finishes it (so it
    -- has exactly one solution) with a tier-2 count in the level's range.
    -- All work is bounded by attempt counts (same seed, same puzzle on
    -- every device).
    local PARTITIONS, CLUE_TRIES = ShikakuBoard.PARTITIONS, ShikakuBoard.CLUE_TRIES
    local total = PARTITIONS * CLUE_TRIES
    local checks = 0
    -- Fallback if the budget runs out (rare, see the specs): the solvable
    -- candidate whose tier-2 count came closest to the range; the very
    -- first candidate only if none was solvable without trial.
    local fb, fb_dist, first

    local function accept(regions, solution_rect, clues)
        self.rects           = regions
        self.solution_rect   = solution_rect
        self.clues           = clues
        self.total_rects     = #regions
        self.rect_marks      = emptyGrid(n)
        self.player_rects    = {}
        self.selected_corner = nil
    end

    for _ = 1, PARTITIONS do
        local regions = {}
        splitRect(1, 1, n, n, level.max_area, regions, level.min_area)

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

        for _ = 1, CLUE_TRIES do
            local clues = emptyGrid(n)
            for idx, rect in ipairs(regions) do
                local area = (rect.r2 - rect.r1 + 1) * (rect.c2 - rect.c1 + 1)
                local cells = rect_cells[idx]
                local ci = math.random(#cells)
                clues[cells[ci][1]][cells[ci][2]] = area
            end
            if not first then first = { regions, solution_rect, clues } end

            checks = checks + 1
            if on_progress then on_progress(checks / total) end
            local solved, t2 = logicSolve(clues, n)
            if solved then
                if t2 >= level.min_t2 and t2 <= level.max_t2 then
                    accept(regions, solution_rect, clues)
                    return
                end
                local dist = t2 < level.min_t2 and level.min_t2 - t2 or t2 - level.max_t2
                if not fb or dist < fb_dist then
                    fb, fb_dist = { regions, solution_rect, clues }, dist
                end
            end
        end
    end
    local pick = fb or first
    accept(pick[1], pick[2], pick[3])
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

-- ---------------------------------------------------------------------------
-- Hints
--
-- The unit here is a rectangle, not a cell: revealing a single cell of one
-- would say almost nothing, since the puzzle is about where the borders fall.
-- So a hint offers a whole rectangle, and each step carries its own wording.
--
-- A rectangle the player has drawn that matches none of the solution's is
-- reported before a fresh one is revealed, and clearing it means clearing its
-- cells rather than solving it for them.
local function rectKey(rect)
    return rect.r1 .. "," .. rect.c1 .. "," .. rect.r2 .. "," .. rect.c2
end

function ShikakuBoard:findHint()
    local solution = {}
    for _, rect in ipairs(self.rects or {}) do solution[rectKey(rect)] = true end

    -- A player rectangle that is not in the solution at all.
    for _, rect in ipairs(self.player_rects or {}) do
        if not solution[rectKey(rect)] then
            return {
                kind = "mistake", r = rect.r1, c = rect.c1, rect = rect,
            }
        end
    end

    -- The first solution rectangle the player has not drawn.
    local placed = {}
    for _, rect in ipairs(self.player_rects or {}) do placed[rectKey(rect)] = true end
    for _, rect in ipairs(self.rects or {}) do
        if not placed[rectKey(rect)] then
            local w = rect.c2 - rect.c1 + 1
            local h = rect.r2 - rect.r1 + 1
            return {
                kind = "fill", r = rect.r1, c = rect.c1, rect = rect,
            }
        end
    end
    return nil, "complete"
end

function ShikakuBoard:applyHint(step)
    if not step or not step.rect then return false end
    local rect = step.rect
    if step.kind == "mistake" then
        for r = rect.r1, rect.r2 do
            for c = rect.c1, rect.c2 do self:clearCell(r, c) end
        end
        return true
    end
    -- Clear whatever overlaps first, or placeRect refuses the ground.
    for r = rect.r1, rect.r2 do
        for c = rect.c1, rect.c2 do self:clearCell(r, c) end
    end
    return self:placeRect(rect.r1, rect.c1, rect.r2, rect.c2) ~= false
end

function ShikakuBoard:getHintsUsed()
    return self.hints_used or 0
end

function ShikakuBoard:noteHintUsed()
    self.hints_used = (self.hints_used or 0) + 1
end

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

-- exposed for the specs
ShikakuBoard.countSolutions = countSolutions
ShikakuBoard.logicSolve     = logicSolve
ShikakuBoard.splitRect      = splitRect

return ShikakuBoard
