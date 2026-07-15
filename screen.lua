local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
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

local DeviceScreen = Device.screen

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
    local sw           = DeviceScreen:getWidth()
    local is_landscape = self:isLandscape()

    self.board_widget = ShikakuBoardWidget:new{
        board        = self.board,
        onCellAction = function(r, c, is_hold)
            self:onCellAction(r, c, is_hold)
        end,
    }

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)

    local title_bar = self:buildTitleBar(_("Shikaku"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            { text = self:getGridButtonText(), callback = function() self:openGridMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    local bottom_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {{
            { text = _("Check"),     callback = function() self:onCheck() end },
            { text = _("Clear All"), callback = function() self:onClearAll() end },
            { id = "undo_button", text = _("Undo"),
              callback = function() self:onUndo() end },
        }},
    }
    self.undo_button = bottom_buttons:getButtonById("undo_button")
    self:_updateUndoButton()

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        local content = VerticalGroup:new{
            align = "center",
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
        }
        self:buildPortraitLayout(title_bar, content, bottom_buttons)
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
end

function ShikakuScreen:onUndo()
    local ok, msg = self.board:undo()
    if ok then
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
        self:updateStatus()
    else
        self:updateStatus(msg)
    end
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
        title     = _("Select grid size"),
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
        local corner = self.board.selected_corner
            and _(" \xC2\xB7 Tap second corner")
            or  _(" \xC2\xB7 Tap two corners to place")
        status = T(_("%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Rects: %4/%5%6"),
            self.board.n, self.board.n, label, placed, total, corner)
    end
    ScreenBase.updateStatus(self, status)
end

function ShikakuScreen:getGridButtonText()
    return T(_("Grid: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function ShikakuScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "medium")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Diff: %1"), label)
end

function ShikakuScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return ShikakuScreen
