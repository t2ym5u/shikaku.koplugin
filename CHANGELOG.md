# Changelog

All notable changes to this project will be documented in this file.

## [1.1.8] - 2026-07-29

### Fixed
- Generated puzzles had no uniqueness verification at all — measured as
  0 in 15 puzzles actually having a unique solution at n=8 and n=10,
  every difficulty. Added a rectangle-tiling uniqueness solver and
  reworked generation to verify each puzzle before accepting it. Every
  size and difficulty is now guaranteed unique.
