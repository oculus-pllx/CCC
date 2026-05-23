# Terminal Effect Suppression Design

Date: 2026-05-23
Status: Approved design

## Goal

Prevent CCC's CRT-style display effects from interfering with full-screen
terminal applications such as Gemini CLI, while preserving those effects in the
rest of the interface.

## Root Cause

Gemini CLI works correctly when CCC's display effects are disabled. The terminal
PTY environment already advertises `TERM=xterm-256color`, Node reports an
8-bit color depth, and Gemini works in the same terminal once the effects are
off. That points to the browser overlay effects, not the PTY or GitHub/Gemini
installation, as the cause of the flicker/blanking.

## Scope

The change is browser UI only:

- Add an active-section state class to the page when Terminal is selected.
- Suppress CRT flicker, scanline, and sync-drift overlays while that class is
  active.
- Restore the user-selected effects automatically when leaving Terminal.
- Keep the existing Preferences toggles unchanged.

The change does not alter PTY startup, shell environment variables, tmux config,
Gemini config, or terminal dimensions.

## Behavior

When the user opens the Terminal section, CCC should add a body class named
`terminal-effects-suppressed`. CSS should use that class to disable the
following overlay pseudo-elements:

- `body.effect-flicker::before`
- `body::after`
- `body.effect-sync-drift .layout::after`

When the user navigates to any non-Terminal section, CCC should remove
`terminal-effects-suppressed`. The user's saved display-effect preferences
remain intact the whole time.

## Testing

Static regression checks should prove:

- `selectSection()` toggles `terminal-effects-suppressed` based on the active
  section.
- CSS contains suppression rules for flicker, scanlines, and sync drift.
- Existing display-effect preference markers remain present.
