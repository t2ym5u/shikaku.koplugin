# Changelog

All notable changes to this project will be documented in this file.

## [1.6.0] - 2026-11-04

### Fixed
- Easy, Medium and Hard now really differ. Every level's rectangles were
  capped at 8 cells, so at 8×8 and 10×10 (and Medium vs Hard at 6×6) the
  three levels gave the very same puzzle. Now:
  - **Easy**: small rectangles (up to the grid's width), and every step is
    "this number has only one place left" or "only one rectangle can
    still reach this cell".
  - **Medium**: bigger rectangles, fewer numbers (about 10 instead of 16
    at 10×10), and one to three steps that need a closer look: a cell
    that every possible rectangle of a number covers is that number's, or
    a cell only one number can still reach.
  - **Hard**: the biggest rectangles (up to twice the grid's width), the
    fewest numbers (about 8 at 10×10), and at least four such steps
    (three at 6×6), often many more.
- No puzzle needs trial and error any more: before, about one 10×10
  puzzle in eight could only be finished by trying a rectangle and seeing
  whether it led to a dead end. Every puzzle still has exactly one
  solution.
- Puzzles therefore differ from 1.5.x for the same seed (Daily Challenge
  included). Generation stays fast (at most a few hundredths of a second
  on a desktop).

## [1.5.0] - 2026-11-04

### Changed
- Faster puzzle generation: a 10×10 grid took up to 0.66 s on a desktop
  (about 15 s on an e-reader); it now takes at most a few hundredths of a
  second (about a second on a Kobo). The uniqueness check now also spots
  a cell no rectangle can cover anymore, and fills the most constrained
  cell or clue first. Same puzzles as before for the same seed.
- A "Generating puzzle…" bar appears if generation still takes a moment
  (needs game-common 1.12.0).

## [1.4.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.4.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.4.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.4.0] - 2026-10-30

### Added
- "Daily Challenge" in the menu, right after "New game": today's puzzle at
  your size and difficulty, the same grid for everyone playing it today.
  Needs game-common 1.7.0.

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
