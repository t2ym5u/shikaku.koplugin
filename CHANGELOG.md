# Changelog

All notable changes to this project will be documented in this file.

## [1.3.0] - 2026-10-30

### Changed
- Redesigned play screen: the board is larger, filling the room the controls
  leave, with a full-width action bar under the status line and a single
  frame around the board.
- The status line reads "8×8 · Medium · Rectangles: 3/12" and wraps in
  landscape instead of being cut off. The "Tap two corners" reminder it used
  to carry is in the rules.
- The title-bar menu shows "Size: …" and "Difficulty: …" (was "Grid: …" and
  "Diff: …"), like every other game.
- Once the puzzle is solved, the action bar shows "New game" in place of
  Check/Hint/Clear All/Undo, so the next round no longer needs the menu.

### Fixed
- Tapping Undo crashed ("attempt to call method 'undo'").
- Clue numbers overflowed their cells: the font was sized for one digit,
  but areas reach two. It is now fitted to the widest clue on the board.
- Using a hint wiped the saved game; it is now kept. When a hint completes
  the puzzle, the status shows the win message.

## [1.2.2] - 2026-10-07

### Fixed
- The Tools menu entry is translated again. `main.lua` took `_` from
  KOReader's `gettext`, which knows nothing of this plugin's strings, so the
  menu label stayed English while the game's own screen, which goes through
  `i18n`, was translated. `_` now comes from `i18n` here too.


## [1.2.1] - 2026-10-01

### Fixed
- Picks up game-common v1.5.0. Play statistics were recorded under a key no
  tool could match: `ReaderUI`/`FileManager:registerModule()` rewrite a plugin
  instance's `name` to `reader<id>` / `filemanager<id>` right after it is
  built, so this game's sessions were split across two rows and neither
  carried its plugin id. Rows written under the old keys are merged back on
  first read. The same release brings the `stopPlugin()` /
  `deletePluginSettings()` hooks KOReader 2026.07 calls when a plugin is
  deleted from the device (PR #15240).

  No change to this plugin's own code -- it inherits all of it from the
  shared library.

## [1.2.0] - 2026-09-30

### Added
- **Hint** button. Two taps: the first says where a rectangle starts and what size it is, the second draws it. Revealing a single cell would say almost nothing here, since the puzzle is about where the borders fall. A move that contradicts the solution is always
  reported before a fresh one is revealed.


## [1.1.8] - 2026-07-29

### Fixed
- Generated puzzles had no uniqueness verification at all — measured as
  0 in 15 puzzles actually having a unique solution at n=8 and n=10,
  every difficulty. Added a rectangle-tiling uniqueness solver and
  reworked generation to verify each puzzle before accepting it. Every
  size and difficulty is now guaranteed unique.
