# Container Code Companion Visual Polish — Design Spec

**Goal:** Add nine visual effects to the Container Code Companion GUI — cyberpunk glow base with animated gauges and hover dynamics — without changing layout, functionality, or the theme system.

**Architecture:** Pure CSS for static effects; small JS additions for animation triggers. All glow effects use `--accent-rgb` (new CSS variable, set alongside `--accent` in `applyTheme`) so every effect automatically tracks the active theme color.

**Tech Stack:** CSS custom properties, `@keyframes`, `requestAnimationFrame` (gauge sweep), vanilla JS class toggling (section fade, health dot).

---

## Files

- Modify: `container-code-companion/web/styles.css` — effects 1–5, 7, 8, 9
- Modify: `container-code-companion/web/app.js` — `--accent-rgb` in `applyTheme`, gauge sweep (`animateGauges`), section fade class toggle in `renderSection`, health class toggle in `loadHealth`
- Modify: `tests/container-code-companion-static.sh` — new static assertions

---

## Effect 1 — Topbar neon underglow

**Where:** `.topbar` in `styles.css`

Add to the existing `.topbar` rule:
```css
box-shadow:
  0 1px 0 rgba(var(--accent-rgb), 0.40),
  0 2px 28px rgba(var(--accent-rgb), 0.13),
  0 6px 60px rgba(var(--accent-rgb), 0.05);
```

**Requires `--accent-rgb`** (Effect 0 prerequisite below).

---

## Effect 0 (prerequisite) — `--accent-rgb` CSS variable

In `applyTheme()` in `app.js`, add one line after the existing `--accent-bg` set:
```js
root.style.setProperty('--accent-rgb', rgb);
```

`rgb` is already computed by `hexToRgb(hex)` in the same function. This makes `rgba(var(--accent-rgb), alpha)` available in CSS for all nine effects.

---

## Effect 2 — Gauge halo glow

**Where:** `.gauge` rule in `styles.css`

Add to `.gauge`:
```css
filter: drop-shadow(0 0 7px rgba(var(--accent-rgb), 0.45));
transition: filter 0.25s;
```

Add new rule:
```css
.gauge:hover {
  filter: drop-shadow(0 0 16px rgba(var(--accent-rgb), 0.80));
}
```

---

## Effect 3 — Scanlines overlay

**Where:** `body` in `styles.css`

Add new rule:
```css
body::after {
  content: '';
  position: fixed;
  inset: 0;
  background: repeating-linear-gradient(
    0deg,
    transparent,
    transparent 3px,
    rgba(0, 0, 0, 0.07) 3px,
    rgba(0, 0, 0, 0.07) 4px
  );
  pointer-events: none;
  z-index: 9999;
}
```

---

## Effect 4 — Sidebar active item: left accent bar + ambient glow

**Where:** `.sidebar button.active` in `styles.css`

Add to existing `.sidebar button.active` rule:
```css
box-shadow: inset 3px 0 0 var(--accent), 0 0 14px rgba(var(--accent-rgb), 0.08);
```

---

## Effect 5 — Panel and tile hover border glow

**Where:** `styles.css`

Add transition to `.panel`:
```css
transition: border-color 0.2s, box-shadow 0.2s;
```

Add new rule:
```css
.panel:hover {
  border-color: rgba(var(--accent-rgb), 0.28);
  box-shadow: 0 0 20px rgba(var(--accent-rgb), 0.06);
}
```

Add transition to `.status-tile`:
```css
transition: transform 0.18s, box-shadow 0.18s, border-color 0.18s;
```

Add new rule:
```css
.status-tile:hover {
  transform: translateY(-3px);
  border-color: rgba(var(--accent-rgb), 0.35);
  box-shadow: 0 6px 20px rgba(var(--accent-rgb), 0.12);
}
```

Also add to `.gauge-card` (same transition + hover lift):
```css
/* on .gauge-card */
transition: transform 0.18s, box-shadow 0.18s, border-color 0.18s;

/* new rule */
.gauge-card:hover {
  transform: translateY(-2px);
  border-color: rgba(var(--accent-rgb), 0.28);
  box-shadow: 0 4px 16px rgba(var(--accent-rgb), 0.10);
}
```

---

## Effect 6 — Gauge sweep animation on load

**Where:** `app.js`

Add new function `animateGauges()` after the `gauge()` helper function:
```js
function animateGauges() {
  document.querySelectorAll('.gauge[style]').forEach(el => {
    const match = el.getAttribute('style').match(/--value:\s*([\d.]+)/);
    if (!match) return;
    const target = parseFloat(match[1]);
    const start = performance.now();
    const duration = 1100;
    const ease = t => 1 - Math.pow(1 - t, 3);
    el.style.setProperty('--value', 0);
    function step(now) {
      const t = Math.min((now - start) / duration, 1);
      el.style.setProperty('--value', target * ease(t));
      if (t < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  });
}
```

In `bindSectionActions`, add after the existing `if (section === 'network')` block:
```js
if (section === 'overview') {
  requestAnimationFrame(animateGauges);
}
```

---

## Effect 7 — Section fade-in

**Where:** `styles.css` (keyframe + class) and `app.js` (`renderSection`)

Add to `styles.css`:
```css
@keyframes section-fade {
  from { opacity: 0; transform: translateY(5px); }
  to   { opacity: 1; transform: translateY(0); }
}
.section-enter {
  animation: section-fade 0.28s ease-out;
}
```

In `renderSection` in `app.js`, after the line `body.innerHTML = renderers[section]?.() || ...`:
```js
body.classList.remove('section-enter');
void body.offsetWidth; // force reflow to restart animation
body.classList.add('section-enter');
```

---

## Effect 8 — Pulsing online dot in topbar

**Where:** `styles.css` (keyframe + `::before` pseudo) and `app.js` (`loadHealth`)

Add to `styles.css`:
```css
@keyframes pulse-dot {
  0%, 100% { opacity: 1; box-shadow: 0 0 6px rgba(var(--accent-rgb), 0.75); }
  50%       { opacity: 0.45; box-shadow: 0 0 14px rgba(var(--accent-rgb), 0.2); }
}
#health {
  display: flex;
  align-items: center;
  gap: 6px;
}
#health.online {
  color: var(--accent);
}
#health.online::before {
  content: '';
  display: inline-block;
  width: 7px; height: 7px;
  border-radius: 50%;
  background: var(--accent);
  box-shadow: 0 0 6px rgba(var(--accent-rgb), 0.75);
  animation: pulse-dot 2.4s ease-in-out infinite;
  flex-shrink: 0;
}
```

In `loadHealth()` in `app.js`, replace the current `target.textContent = ...` assignments:
```js
async function loadHealth() {
  const target = document.getElementById('health');
  try {
    const response = await fetch('/api/health');
    const data = await response.json();
    target.textContent = data.ok ? 'Online' : 'Unhealthy';
    target.className = data.ok ? 'online' : '';
  } catch {
    target.textContent = 'Offline';
    target.className = '';
  }
}
```

---

## Effect 9 — Status tile hover lift

Already covered under Effect 5 (same `.status-tile:hover` rule).

---

## Static test additions

Add to `tests/container-code-companion-static.sh`:
```bash
# Visual polish
require_file_contains container-code-companion/web/styles.css 'pulse-dot'
require_file_contains container-code-companion/web/styles.css 'section-fade'
require_file_contains container-code-companion/web/styles.css 'section-enter'
require_file_contains container-code-companion/web/styles.css 'drop-shadow'
require_file_contains container-code-companion/web/styles.css 'scanlines'
require_file_contains container-code-companion/web/app.js 'animateGauges'
require_file_contains container-code-companion/web/app.js '--accent-rgb'
require_file_contains container-code-companion/web/app.js 'section-enter'
require_file_contains container-code-companion/web/app.js 'health.online'
```

Note: the scanlines check requires a comment `/* scanlines */` in styles.css above the `body::after` rule so the word appears in the file.
