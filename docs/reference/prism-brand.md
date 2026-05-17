# PRISM Brand & Design System

**Parallax Group** · PRISM Control Dashboard · Dark-only UI

---

## Color Palette

Source of truth: `client/src/constants.jsx` — always import from `C`, never hardcode inline.

| Token | Hex | Use |
|-------|-----|-----|
| `C.bg` | `#060d16` | Page/app background |
| `C.card` / `C.surface` | `#0a1628` | Card, panel, sidebar background |
| `C.card2` / `C.surface2` | `#0d1f38` | Elevated card, nested panel |
| `C.cyan` | `#22d3ee` | Primary accent — active states, links, focus rings, primary buttons |
| `C.green` | `#4ade80` | Success, running, healthy, online |
| `C.amber` | `#f59e0b` | Warning, pending, degraded, needs attention |
| `C.pink` | `#f472b6` | Error alt, destructive actions, alerts |
| `C.purple` | `#a78bfa` | AI/agent features, secondary accent |
| `C.red` | `#f87171` | Error, stopped, failed, critical |
| `C.text` | `#e2e8f0` | Primary text |
| `C.muted` | `#64748b` | Secondary/muted text, labels, placeholders |
| `C.textDim` | `#94a3b8` | Dimmed text, inactive |
| `C.border` | `rgba(34,211,238,0.12)` | Borders, dividers (cyan tint at low opacity) |

**Log background:** `#020810` (deeper than `C.bg`, used in `LogBox`)

---

## Typography

| Role | Font | Weight | Size |
|------|------|--------|------|
| Monospace UI / labels / code | `IBM Plex Mono` | 400, 500, 600 | 10–13px |
| Metric values / display numbers | `Orbitron` | 400, 700, 900 | 16–24px |
| Body / descriptions | `IBM Plex Mono` | 400 | 12–13px |

**Global font:** `IBM Plex Mono` — set on `body` in `client/index.html`.
**Metric font:** `Orbitron` — used in `MetricCard` and anywhere large numbers are displayed.

Both loaded from Google Fonts in `client/index.html`.

**Label style:** `10px`, `uppercase`, `letter-spacing: 0.12em`, `color: C.muted`

---

## Shared Components (`client/src/constants.jsx`)

### `MetricCard`
Stat card with colored left border accent. Props: `label`, `value`, `sub`, `accent`.

### `SmallBtn`
Standard action button. Uses `children` pattern (not `label` prop). Props: `onClick`, `disabled`, `color` (defaults to `C.cyan`), `outline`, `style`, `title`.

```jsx
<SmallBtn color={C.amber} onClick={fn}>Restart</SmallBtn>
```

### `SectionLabel`
Uppercase monospace section heading. Wraps `children`.

```jsx
<SectionLabel>Service Status</SectionLabel>
```

### `ServiceChip`
Status pill for a service. Prop: `svc` object with `status`, `name`, `port`.

### `Dot`
Pulsing status dot. Props: `color`, `pulse` (boolean).

### `LogBox`
Scrollable monospace log viewer. Props: `content`, `height` (default 360), `logRef`.

### `formatUptime(s)` / `fmtBytes(bytes)`
Utility formatters — uptime in seconds → `Xd Xh`, bytes → human-readable.

---

## Design Principles

- **Dark only** — no light mode, no system theme. Background is `#060d16`.
- **Cyan is primary** — `C.cyan` (#22d3ee) is the PRISM signature color. Use for active states, primary CTAs, focus rings.
- **Purple for AI** — `C.purple` (#a78bfa) is reserved for AI/agent features (Agentic OS, AI Manager).
- **Monospace everywhere** — IBM Plex Mono is the UI font, not just for code.
- **Borders are subtle** — `C.border` is a 12% opacity cyan tint. Avoid heavy borders.
- **Status colors are semantic:** green = running/healthy, amber = warning/pending, red = error/stopped, pink = critical/destructive.
- **Inline styles** — the codebase uses inline styles throughout. Follow the existing pattern rather than introducing CSS modules or utility classes.
- **No emojis** in UI labels or status text.

---

## Border Radius

| Context | Value |
|---------|-------|
| Cards, panels | `6–8px` |
| Buttons (`SmallBtn`) | `4px` |
| Chips/badges | `4px` or `10px` (pill) |
| Log boxes | `6px` |

---

## Spacing

- Card padding: `14px 20px`
- Button padding: `5px 12px`
- Section gap: `12–16px`
- Label margin-bottom: `12px`

---

## Brainstorming Companion

When using the Superpowers visual brainstorming companion for PRISM design work, always use the PRISM dark palette above — never the default light/system companion theme. The header should show **PRISM** in `C.cyan` with a green connected dot.
