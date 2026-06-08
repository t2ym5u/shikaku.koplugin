# Shikaku

> **Status: stub — not yet implemented**

## Description

Divide the grid into non-overlapping rectangles. Each rectangle contains exactly one number clue equal to its area.

## Files to create

- `board.lua` — game logic, puzzle generator, serialize/load
- `board_widget.lua` — grid rendering and tap gestures
- `screen.lua` — full-screen layout (buttons + board)
- `main.lua` — PluginBase entry point

## Notes

Grid-based logic puzzle — use GridWidgetBase from game-common.
