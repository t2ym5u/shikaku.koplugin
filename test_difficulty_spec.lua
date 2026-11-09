-- Difficulty guarantees for Shikaku: every size x level builds a unique
-- puzzle quickly, the game's human-style solver finishes it without trial
-- within the level's tier-2 range, Easy needs tier 1 only, levels are
-- distinct and ordered (fewer, bigger rectangles, more tier-2 steps), and a
-- seed gives the same puzzle without reading the clock.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

-- Runs fn with os.clock/os.time/os.date replaced by functions that fail:
-- a generator must bound its work by counts, never by time.
local function withoutClock(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local function boom(name) return function() error("generator read " .. name, 2) end end
    os.clock, os.time, os.date = boom("os.clock"), boom("os.time"), boom("os.date")
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
end

describe("Shikaku difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    describe("uniqueness (1.5.0)", function()
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

    it("generation never reads the clock", function()
        for _, n in ipairs({ 6, 8, 10 }) do
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                math.randomseed(n * 31)
                withoutClock(function() Board:new{ n = n }:generate(diff) end)
            end
        end
    end)
end)
