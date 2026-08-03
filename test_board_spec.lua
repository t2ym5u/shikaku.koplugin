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
end)
