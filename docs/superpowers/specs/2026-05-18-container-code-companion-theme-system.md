# Container Code Companion — Theme System Design

**Date:** 2026-05-18  
**Status:** Approved  
**Goal:** Apply Prism dark branding to Container Code Companion and add a user-selectable accent-color theme system with a Settings page.

---

## Overview

The current UI uses a dark gray palette and system-ui font. This replaces it with the full Prism dark base (navy backgrounds, IBM Plex Mono font) while making the accent color swappable via a Settings page. Seven themes ship by default; green is the default. The selected theme persists in `localStorage`.

---

## Color System

### Base (fixed across all themes — Prism dark)

| CSS Variable | Value | Role |
|---|---|---|
| `--bg` | `#060d16` | Page/app background |
| `--panel` | `#0a1628` | Sidebar, cards, panels |
| `--panel2` | `#0d1f38` | Elevated/nested panels (config editor, log bg) |
| `--topbar` | `#020810` | Topbar background |
| `--text` | `#e2e8f0` | Primary text |
| `--muted` | `#64748b` | Secondary text, labels, placeholders |
| `--text-dim` | `#94a3b8` | Dimmed text, inactive items |

### Accent (per-theme — applied via JS to `document.documentElement`)

| CSS Variable | Role |
|---|---|
| `--accent` | Primary accent — active states, links, focus rings, primary buttons, metric values |
| `--border` | Accent at 12% opacity — all borders and dividers |
| `--accent-bg` | Accent at 10% opacity — active sidebar item background, badge backgrounds |

### Themes

| Name | `--accent` | Default |
|---|---|---|
| Green | `#4ade80` | ✅ yes |
| Purple | `#a78bfa` | |
| Cyan | `#22d3ee` | |
| Amber | `#f59e0b` | |
| Red | `#f87171` | |
| Pink | `#f472b6` | |
| White | `#e2e8f0` | |

`--border` and `--accent-bg` are computed from the accent RGB values at the time of application. No pre-defined per-theme CSS classes — all theming is done via `style.setProperty` on `:root`.

### Semantic status colors (unchanged by theme)

These are not accent — they carry fixed semantic meaning and must not be repurposed as accent:

| Color | Hex | Meaning |
|---|---|---|
| Green status | `#4ade80` | Running, healthy, online, success |
| Amber status | `#f59e0b` | Warning, pending, degraded |
| Red status | `#f87171` | Error, stopped, failed |

When the active theme is Green, Amber, or Red, the UI uses the accent color for interactive elements AND the same hue for status — this is acceptable because status badges carry text/icon context that disambiguates. No special handling required.

---

## Typography

Switch from `system-ui` to `IBM Plex Mono` for the entire UI body. Loaded from Google Fonts in `index.html`.

| Role | Font | Size |
|---|---|---|
| Body / all UI text | IBM Plex Mono | 13px |
| Nav labels (uppercase) | IBM Plex Mono | 10px, letter-spacing 0.12em |
| Metric values (gauges) | IBM Plex Mono | existing sizes |

Orbitron is used in the Prism reference but is not included here — IBM Plex Mono alone is sufficient for this UI and avoids adding a second font load.

---

## Settings Page

### Sidebar entry

A new nav group "Preferences" appears at the bottom of the sidebar with a single item "Settings" (`data-section="settings"`).

### Page content (`renderSettings`)

```
SETTINGS
─────────────────────────
THEME
  ● ● ● ● ● ● ●   ← color swatches (circles, 32px, selected has white ring)
  Active theme: Green

  [swatch] Green      #4ade80  (default)
  [swatch] Purple     #a78bfa
  [swatch] Cyan       #22d3ee
  [swatch] Amber      #f59e0b
  [swatch] Red        #f87171
  [swatch] Pink       #f472b6
  [swatch] White      #e2e8f0
─────────────────────────
```

Each swatch row shows: colored circle + theme name + hex code. Clicking any row (or the circle) applies the theme immediately and saves to `localStorage`. The currently active theme shows a white ring on its swatch circle.

No save button needed — changes are applied and persisted on click.

---

## JS Architecture

### New constants

```js
const THEMES = {
  green:  '#4ade80',
  purple: '#a78bfa',
  cyan:   '#22d3ee',
  amber:  '#f59e0b',
  red:    '#f87171',
  pink:   '#f472b6',
  white:  '#e2e8f0',
};
const DEFAULT_THEME = 'green';
const THEME_STORAGE_KEY = 'ccc-theme';
```

### New functions

**`hexToRgb(hex)`** — converts `#rrggbb` to `"r, g, b"` string for use in `rgba(...)`.

**`applyTheme(name)`** — looks up accent hex from `THEMES`, then calls:
```js
document.documentElement.style.setProperty('--accent', hex);
document.documentElement.style.setProperty('--border', `rgba(${rgb}, 0.12)`);
document.documentElement.style.setProperty('--accent-bg', `rgba(${rgb}, 0.10)`);
```
Saves `name` to `localStorage(THEME_STORAGE_KEY)`.

**`loadTheme()`** — reads `localStorage(THEME_STORAGE_KEY)`, falls back to `DEFAULT_THEME`, calls `applyTheme`.

**`renderSettings()`** — returns HTML for the settings page (swatch grid).

**`bindSettings()`** — wires `[data-theme]` click events → `applyTheme(name)`, then calls `renderSection('settings')` to re-render swatches so the active ring updates immediately.

### Initialization

`loadTheme()` is called once at the top of the script (before `DOMContentLoaded`), so theme is applied before any content renders — no flash of wrong theme.

---

## CSS Changes

### Remove / replace

- `--bg: #17191c` → `#060d16`
- `--panel: #24282d` → `#0a1628`
- `--border: #3f454d` → `rgba(var(--accent-rgb), 0.12)` — **note:** because CSS custom properties can't do math on hex, border is set via JS `applyTheme`. The `:root` default is the green border value.
- `--accent: #68a6f8` → `#4ade80` (green default)
- `--muted: #a7adb5` → `#64748b`
- Add `--text-dim: #94a3b8` to `:root`
- Add `--topbar: #020810` to `:root`
- Add `--panel2: #0d1f38` to `:root`
- `body` font: `system-ui, -apple-system, ...` → `'IBM Plex Mono', monospace`
- Hardcoded dark values to replace with variables:
  - `.topbar` background `#111316` → `var(--topbar)` (define `--topbar: #020810`)
  - `.status-tile` background `#1b1e22` → `var(--panel)`
  - `.config-editor-header` background `#1b1e22` → `var(--panel)`
  - `.config-editor-textarea` background `#111316` → `var(--topbar)`
  - xterm.js terminal background (in `bindTerminal`) → `#020810` — already hardcoded in JS, update to use `--topbar` value or keep as constant

### Add

```css
.settings-swatch-row { ... }         /* clickable theme row */
.settings-swatch-circle { ... }      /* 32px circle, border: 2px solid transparent */
.settings-swatch-circle.active { border-color: #fff; box-shadow: 0 0 0 2px rgba(255,255,255,0.2); }
```

Active sidebar item background uses `var(--accent-bg)` instead of the hardcoded `var(--panel)` tint. Active sidebar text uses `var(--accent)` instead of `var(--text)`.

---

## `index.html` Changes

1. Add Google Fonts link in `<head>`:
   ```html
   <link rel="preconnect" href="https://fonts.googleapis.com">
   <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
   ```

2. Add Settings to sidebar:
   ```html
   <div class="nav-group">
     <div class="nav-heading">Preferences</div>
     <button data-section="settings">Settings</button>
   </div>
   ```

---

## `tests/container-code-companion-static.sh` Changes

Add assertions:
```bash
require_file_contains container-code-companion/web/app.js "THEMES"
require_file_contains container-code-companion/web/app.js "applyTheme"
require_file_contains container-code-companion/web/app.js "loadTheme"
require_file_contains container-code-companion/web/app.js "ccc-theme"
require_file_contains container-code-companion/web/app.js "settings-swatch"
require_file_contains container-code-companion/web/index.html "IBM+Plex+Mono"
require_file_contains container-code-companion/web/index.html 'data-section="settings"'
```

---

## Files Modified

| File | Change |
|---|---|
| `container-code-companion/web/index.html` | Google Fonts link; Settings nav item |
| `container-code-companion/web/styles.css` | Prism dark palette; IBM Plex Mono font; swatch CSS; active sidebar accent; replace hardcoded colors with vars |
| `container-code-companion/web/app.js` | `THEMES`, `DEFAULT_THEME`, `THEME_STORAGE_KEY` constants; `hexToRgb`, `applyTheme`, `loadTheme`, `renderSettings`, `bindSettings` functions; `loadTheme()` call at init; `titles` map entry for `settings` |
| `tests/container-code-companion-static.sh` | New assertions |

---

## Out of Scope

- Light mode / system theme detection
- Custom color input (hex picker)
- Font size preferences
- Any non-color theme dimensions (layout, density)
