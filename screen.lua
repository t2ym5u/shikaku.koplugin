local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase         = require("screen_base")
local MenuHelper         = require("menu_helper")
local ShikakuBoard       = lrequire("board")
local ShikakuBoardWidget = lrequire("board_widget")

local GRID_SIZES = { 6, 8, 10 }

-- ---------------------------------------------------------------------------
-- ShikakuScreen
-- ---------------------------------------------------------------------------

local GAME_RULES_EN = _([[
Shikaku — Rules

Divide the entire grid into non-overlapping rectangles.

Rules:
• Each numbered cell belongs to exactly one rectangle.
• The area of that rectangle (width × height) equals the number it contains.
• Every cell of the grid must belong to exactly one rectangle.

Tap a cell to start drawing a rectangle, then tap another cell to set the opposite corner. Tap the same corner twice to cancel. Hold a cell to remove its rectangle.
]])

local GAME_RULES_FR = [[
Shikaku — Règles

Divisez toute la grille en rectangles non superposés.

Règles :
• Chaque case numérotée appartient à exactement un rectangle.
• L'aire de ce rectangle (largeur × hauteur) est égale au nombre qu'il contient.
• Chaque case de la grille doit appartenir à exactement un rectangle.

Appuyez sur une case pour commencer à dessiner un rectangle, puis appuyez sur une autre case pour définir le coin opposé. Appuyez deux fois sur le même coin pour annuler. Maintenez une case enfoncée pour supprimer son rectangle.
]]

local ShikakuScreen = ScreenBase:extend{}

-- The unit here is a rectangle: revealing one cell of one would say almost
-- nothing, since the puzzle is about where the borders fall.
function ShikakuScreen:describeHintStep(step, level)
    local rect = step.rect
    local h = rect and (rect.r2 - rect.r1 + 1) or 0
    local w = rect and (rect.c2 - rect.c1 + 1) or 0
    if level == 1 then
        return step.kind == "mistake"
            and T(_("The rectangle at R%1C%2 is wrong. Tap Hint again to clear it."),
                  step.r, step.c)
            or  T(_("A %1x%2 rectangle starts at R%3C%4. Tap Hint again to draw it."),
                  h, w, step.r, step.c)
    end
    return step.kind == "mistake"
        and T(_("Cleared the rectangle at R%1C%2."), step.r, step.c)
        or  T(_("Drew the %1x%2 rectangle at R%3C%4."), h, w, step.r, step.c)
end

function ShikakuScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", 6)
    self.board  = ShikakuBoard:new{ n = n }
    if not self.board:load(state) then
        self.board:generate(self.plugin:getSetting("difficulty", "medium"))
    end
    ScreenBase.init(self)
end

function ShikakuScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function ShikakuScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Shikaku"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            { text = self:getGridButtonText(), callback = function() self:openGridMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Controls first: the board is sized from whatever room they leave.
    self.status_text:setMaxWidth(self:getControlsWidth())
    local action_bar = self:buildActionBar({
        { text = _("Check"),     callback = function() self:onCheck() end },
        { text = _("Hint"), callback = function() self:onHint() end },
        { text = _("Clear All"), callback = function() self:onClearAll() end },
        { id = "undo_button", text = _("Undo"),
          callback = function() self:onUndo() end },
    })
    self.undo_button = action_bar:getButtonById("undo_button")
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    -- The widget draws its own thick outer border, so the frame only pads.
    local frame_pad   = Size.padding.large
    local frame_extra = 2 * frame_pad
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = ShikakuBoardWidget:new{
        board        = self.board,
        max_size     = math.min(budget_w, budget_h) - frame_extra,
        onCellAction = function(r, c, is_hold)
            self:onCellAction(r, c, is_hold)
        end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }
    self:_updateUndoButton()

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Cell interaction
-- ---------------------------------------------------------------------------

function ShikakuScreen:onCellAction(r, c, is_hold)
    if is_hold then
        -- Hold: clear rectangle at this cell
        local ok, err = self.board:clearCell(r, c)
        if not ok and err == "empty" then
            -- Nothing to clear
        end
    else
        -- Tap: select corner or place rectangle
        local ok, err = self.board:selectCorner(r, c)
        if not ok then
            local msgs = {
                must_contain_one_clue = _("Rectangle must contain exactly one clue."),
                area_mismatch         = _("Rectangle area must equal the clue number."),
                overlap               = _("Rectangles cannot overlap."),
                out_of_bounds         = _("Rectangle is outside the grid."),
            }
            self:updateStatus(msgs[err] or _("Cannot place rectangle here."))
            self.board_widget:refresh()
            return
        end
    end
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    if self.board:checkWin() then
        self:updateStatus(_("Congratulations! Puzzle solved!"))
    else
        self:updateStatus()
    end
    self:refreshActionBar()
end

-- ---------------------------------------------------------------------------
-- Game actions
-- ---------------------------------------------------------------------------

function ShikakuScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "medium")
    local n    = self.plugin:getSetting("grid_n", 6)
    self.board = ShikakuBoard:new{ n = n }
    self.board:generate(diff)
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function ShikakuScreen:onClearAll()
    self.board:clearAll()
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    self:updateStatus()
    self:refreshActionBar()
end

function ShikakuScreen:onUndo()
    -- The board's `undo` field (its UndoStack) shadows the :undo() method.
    local ok, msg = ShikakuBoard.undo(self.board)
    if ok then
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
        self:updateStatus()
    else
        self:updateStatus(msg)
    end
    self:refreshActionBar()
end

function ShikakuScreen:isRoundOver()
    return self.board:checkWin()
end

-- A hint can place the last cell, so the round may end here.
function ShikakuScreen:onHint()
    ScreenBase.onHint(self)
    self:refreshActionBar()
end

function ShikakuScreen:onCheck()
    if self.board:checkWin() then
        self:updateStatus(_("Congratulations! Puzzle solved!"))
    else
        local placed = self.board:getPlacedCount()
        local total  = self.board.total_rects
        self:updateStatus(T(_("Rectangles placed: %1/%2 — keep going!"), placed, total))
    end
    self.board_widget:refresh()
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

function ShikakuScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes + 1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", 6),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function ShikakuScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "medium"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

function ShikakuScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:checkWin() then
        status = _("Congratulations! Puzzle solved!")
    else
        local placed = self.board:getPlacedCount()
        local total  = self.board.total_rects
        local diff   = self.plugin:getSetting("difficulty", "medium")
        local label  = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        status = self:joinStatus(
            T("%1×%1", self.board.n), label, T(_("Rectangles: %1/%2"), placed, total))
    end
    ScreenBase.updateStatus(self, status)
end

function ShikakuScreen:getGridButtonText()
    return T(_("Size: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function ShikakuScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "medium")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Difficulty: %1"), label)
end

function ShikakuScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return ShikakuScreen
