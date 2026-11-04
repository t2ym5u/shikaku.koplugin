local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("ShikakuBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    local function newBoard(n, diff)
        math.randomseed(42)
        local b = Board:new{ n = n or 6 }
        b:generate(diff or "medium")
        return b
    end

    describe("construction", function()
        it("creates a 6×6 board by default", function()
            local b = Board:new()
            assert.are.equal(6, b.n)
        end)
    end)

    describe("generate", function()
        it("produces at least one region", function()
            local b = newBoard(6)
            assert.is_true(#b.rects >= 1)
        end)

        it("every cell belongs to exactly one solution rectangle", function()
            local b = newBoard(6)
            for r = 1, b.n do
                for c = 1, b.n do
                    assert.is_true(b.solution_rect[r][c] >= 1)
                end
            end
        end)

        it("every region has exactly one clue equal to its area", function()
            local b = newBoard(6)
            for idx, rect in ipairs(b.rects) do
                local area = (rect.r2 - rect.r1 + 1) * (rect.c2 - rect.c1 + 1)
                local clue_count, clue_val = 0, 0
                for r = rect.r1, rect.r2 do
                    for c = rect.c1, rect.c2 do
                        if b.clues[r][c] > 0 then
                            clue_count = clue_count + 1
                            clue_val = b.clues[r][c]
                        end
                    end
                end
                assert.are.equal(1, clue_count, ("region %d has %d clues"):format(idx, clue_count))
                assert.are.equal(area, clue_val)
            end
        end)
    end)

    describe("selectCorner / placeRect", function()
        it("first tap selects a corner, second tap attempts placement", function()
            local b = newBoard(6)
            local rect = b.rects[1]
            local ok1 = b:selectCorner(rect.r1, rect.c1)
            assert.is_true(ok1)
            assert.is_not_nil(b.selected_corner)
            local ok2 = b:selectCorner(rect.r2, rect.c2)
            assert.is_true(ok2)
            assert.is_nil(b.selected_corner)
        end)

        it("placing the exact solution rectangle succeeds", function()
            local b = newBoard(6)
            local rect = b.rects[1]
            local ok, err = b:placeRect(rect.r1, rect.c1, rect.r2, rect.c2)
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("rejects a rectangle out of bounds", function()
            local b = newBoard(6)
            local ok, err = b:placeRect(1, 1, b.n + 1, 1)
            assert.is_false(ok)
            assert.are.equal("out_of_bounds", err)
        end)

        it("rejects a rectangle containing zero clues", function()
            local b = newBoard(6)
            -- A single non-clue cell (if one exists outside all 1x1 regions)
            for r = 1, b.n do
                for c = 1, b.n do
                    if b.clues[r][c] == 0 then
                        local ok, err = b:placeRect(r, c, r, c)
                        assert.is_false(ok)
                        assert.are.equal("must_contain_one_clue", err)
                        return
                    end
                end
            end
        end)

        it("rejects a rectangle whose area does not match its clue", function()
            local b = newBoard(6)
            -- Find a region with area > 1, then place a 1×1 rect exactly on
            -- its clue cell: clue_count is still 1 (area mismatch, not the
            -- must_contain_one_clue branch).
            for _, rect in ipairs(b.rects) do
                local area = (rect.r2 - rect.r1 + 1) * (rect.c2 - rect.c1 + 1)
                if area > 1 then
                    local cr, cc
                    for r = rect.r1, rect.r2 do
                        for c = rect.c1, rect.c2 do
                            if b.clues[r][c] > 0 then cr, cc = r, c end
                        end
                    end
                    local ok, err = b:placeRect(cr, cc, cr, cc)
                    assert.is_false(ok)
                    assert.are.equal("area_mismatch", err)
                    return
                end
            end
        end)

        it("rejects a rectangle overlapping an already-placed one", function()
            local b = newBoard(6)
            local rect = b.rects[1]
            local ok1 = b:placeRect(rect.r1, rect.c1, rect.r2, rect.c2)
            assert.is_true(ok1)
            local ok2, err = b:placeRect(rect.r1, rect.c1, rect.r2, rect.c2)
            assert.is_false(ok2)
            assert.are.equal("overlap", err)
        end)
    end)

    describe("clearCell / clearAll", function()
        it("clearCell removes a placed rectangle", function()
            local b = newBoard(6)
            local rect = b.rects[1]
            b:placeRect(rect.r1, rect.c1, rect.r2, rect.c2)
            local ok = b:clearCell(rect.r1, rect.c1)
            assert.is_true(ok)
            assert.are.equal(0, b.rect_marks[rect.r1][rect.c1])
        end)

        it("clearCell on an empty cell returns false", function()
            local b = newBoard(6)
            local ok, err = b:clearCell(1, 1)
            if b.rect_marks[1][1] == 0 then
                assert.is_false(ok)
                assert.are.equal("empty", err)
            end
        end)

        it("clearAll resets all placed rectangles", function()
            local b = newBoard(6)
            local rect = b.rects[1]
            b:placeRect(rect.r1, rect.c1, rect.r2, rect.c2)
            b:clearAll()
            assert.are.equal(0, b:getPlacedCount())
        end)
    end)

    describe("undo", function()
        -- self.undo is an UndoStack instance field that shadows the class's
        -- :undo() method — b:undo() would try to call a table, not a function.
        -- Must call Board.undo(b) directly, matching kakuro/hitori house style.
        it("canUndo is false before any action", function()
            local b = newBoard(6)
            assert.is_false(b:canUndo())
        end)

        it("Board.undo(b) reverts a placed rectangle", function()
            local b = newBoard(6)
            local rect = b.rects[1]
            b:placeRect(rect.r1, rect.c1, rect.r2, rect.c2)
            assert.is_true(b:canUndo())
            local ok = Board.undo(b)
            assert.is_true(ok)
            assert.are.equal(0, b.rect_marks[rect.r1][rect.c1])
            assert.is_false(b:canUndo())
        end)
    end)

    describe("checkWin", function()
        it("returns false on a fresh board", function()
            local b = newBoard(6)
            assert.is_false(b:checkWin())
        end)

        it("returns true once every region is correctly placed", function()
            local b = newBoard(6)
            for _, rect in ipairs(b.rects) do
                local ok = b:placeRect(rect.r1, rect.c1, rect.r2, rect.c2)
                assert.is_true(ok)
            end
            assert.is_true(b:checkWin())
        end)
    end)

    describe("serialize / load", function()
        it("round-trips clues, solution and placed rectangles", function()
            local b = newBoard(6)
            local rect = b.rects[1]
            b:placeRect(rect.r1, rect.c1, rect.r2, rect.c2)
            local data = b:serialize()
            local b2 = Board:new{ n = 6 }
            local ok = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            assert.are.equal(1, b2:getPlacedCount())
            assert.are.equal(b.rect_marks[rect.r1][rect.c1], b2.rect_marks[rect.r1][rect.c1])
        end)

        it("load returns false for invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)
    describe("uniqueness check (1.5.0)", function()
        it("counts the tilings of small grids", function()
            -- 2x2 with a single 4: one rectangle, the whole grid
            assert.are.equal(1, (Board.countSolutions({ { 4, 0 }, { 0, 0 } }, 2, 100, 1e6)))
            -- 2x2 with two 2s on a diagonal: two dominoes either way
            assert.are.equal(2, (Board.countSolutions({ { 2, 0 }, { 0, 2 } }, 2, 100, 1e6)))
            -- areas that don't add up to the grid: no tiling
            assert.are.equal(0, (Board.countSolutions({ { 2, 0 }, { 0, 0 } }, 2, 100, 1e6)))
        end)

        it("every generated puzzle is unique, and generation is fast", function()
            for _, n in ipairs({ 6, 8, 10 }) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local worst = 0
                    for seed = 1, 8 do
                        math.randomseed(seed * 7919 + n)
                        local t0 = os.clock()
                        local b = Board:new{ n = n }
                        b:generate(diff)
                        worst = math.max(worst, os.clock() - t0)
                        local solutions, exhausted = Board.countSolutions(b.clues, n, 2, 1e6)
                        assert.is_false(exhausted)
                        assert.are.equal(1, solutions,
                            ("n=%d diff=%s seed=%d: not unique"):format(n, diff, seed))
                    end
                    -- 1.6.0: under 40 ms worst on a desktop (LuaJIT, 1,000
                    -- seeds per level); generous for PUC Lua and slow CI.
                    assert.is_true(worst < 1.5, ("n=%d diff=%s took %.2fs"):format(n, diff, worst))
                end
            end
        end)

        it("reports progress while generating", function()
            local calls, last = 0, 0
            math.randomseed(3)
            Board:new{ n = 10 }:generate("hard", function(f)
                calls = calls + 1
                assert.is_true(f >= last and f <= 1)
                last = f
            end)
            assert.is_true(calls > 0)
        end)
    end)
    describe("difficulty levels (1.6.0)", function()
        it("the human-style solver grades small grids", function()
            -- 2x2, one 4: the only rectangle, tier 1
            local ok, t2 = Board.logicSolve({ { 4, 0 }, { 0, 0 } }, 2)
            assert.is_true(ok); assert.are.equal(0, t2)
            -- two 2s on a diagonal: two solutions, never "solved"
            assert.is_false((Board.logicSolve({ { 2, 0 }, { 0, 2 } }, 2)))
            -- areas that don't add up: no solution
            assert.is_false((Board.logicSolve({ { 2, 0 }, { 0, 0 } }, 2)))
        end)

        local SEEDS = 30
        local stats = {}
        local function level_stats(n, diff)
            local key = n .. diff
            if stats[key] then return stats[key] end
            local st = { rects = 0, t2 = 0, max_area = 0, worst = 0, puzzles = {} }
            local lvl = Board.LEVELS[diff](n)
            for seed = 1, SEEDS do
                math.randomseed(seed * 104729 + n)
                local t0 = os.clock()
                local b = Board:new{ n = n }
                b:generate(diff)
                st.worst = math.max(st.worst, os.clock() - t0)
                -- proper puzzle: a real partition of the whole grid
                assert.is_true(#b.rects >= 3, ("n=%d %s seed=%d: %d rects"):format(n, diff, seed, #b.rects))
                local covered = 0
                for _, r in ipairs(b.rects) do
                    local a = (r.r2 - r.r1 + 1) * (r.c2 - r.c1 + 1)
                    covered = covered + a
                    st.max_area = math.max(st.max_area, a)
                end
                assert.are.equal(n * n, covered)
                -- solvable without trial, inside the level's tier-2 range
                local ok, t2 = Board.logicSolve(b.clues, n)
                assert.is_true(ok, ("n=%d %s seed=%d needs trial"):format(n, diff, seed))
                assert.is_true(t2 >= lvl.min_t2 and t2 <= lvl.max_t2,
                    ("n=%d %s seed=%d: %d tier-2 steps"):format(n, diff, seed, t2))
                local solutions, exhausted = Board.countSolutions(b.clues, n, 2, 1e6)
                assert.is_false(exhausted)
                assert.are.equal(1, solutions)
                st.rects = st.rects + #b.rects
                st.t2 = st.t2 + t2
                local flat = {}
                for r = 1, n do flat[r] = table.concat(b.clues[r], ",") end
                st.puzzles[seed] = table.concat(flat, ";")
            end
            st.rects, st.t2 = st.rects / SEEDS, st.t2 / SEEDS
            stats[key] = st
            return st
        end

        for _, n in ipairs({ 6, 8, 10 }) do
            it(("%dx%d: Easy, Medium and Hard really differ"):format(n, n), function()
                local e, m, h = level_stats(n, "easy"), level_stats(n, "medium"), level_stats(n, "hard")
                -- fewer, bigger rectangles as the level rises
                assert.is_true(e.rects > m.rects and m.rects > h.rects,
                    ("rects %.1f / %.1f / %.1f"):format(e.rects, m.rects, h.rects))
                assert.is_true(e.max_area < m.max_area and m.max_area < h.max_area)
                -- more steps beyond "only one place fits"
                assert.are.equal(0, e.t2)
                assert.is_true(m.t2 >= 1 and h.t2 > m.t2,
                    ("tier-2 steps %.1f / %.1f / %.1f"):format(e.t2, m.t2, h.t2))
                -- the 1.5.x bug: the same seed gave the same puzzle at every level
                for seed = 1, SEEDS do
                    assert.are_not.equal(e.puzzles[seed], m.puzzles[seed])
                    assert.are_not.equal(m.puzzles[seed], h.puzzles[seed])
                end
                for _, st in ipairs({ e, m, h }) do
                    assert.is_true(st.worst < 1.5, ("took %.2fs"):format(st.worst))
                end
            end)
        end

        it("the same seed gives the same puzzle", function()
            local function gen()
                math.randomseed(777)
                local b = Board:new{ n = 10 }
                b:generate("hard")
                return b.clues
            end
            assert.are.same(gen(), gen())
        end)
    end)
end)
