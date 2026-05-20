# Container Code Companion Visual Polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add nine cyberpunk-glow visual effects to the Container Code Companion GUI — neon topbar underglow, gauge halo, scanlines, sidebar glow bar, hover lifts, section fade-in, pulsing health dot, and animated gauge sweep — all theme-aware via a new `--accent-rgb` CSS variable.

**Architecture:** Pure CSS for static effects (effects 1–5, 7–9); `requestAnimationFrame` loop for gauge sweep (effect 6); tiny JS class toggles for section fade and health dot. All glow uses `rgba(var(--accent-rgb), alpha)` so effects automatically match the active theme color. No layout or functionality changes.

**Tech Stack:** CSS custom properties, `@keyframes`, `requestAnimationFrame`, vanilla JS.

---

## File Map

- `container-code-companion/web/styles.css` — all CSS effects
- `container-code-companion/web/app.js` — `applyTheme`, `loadHealth`, `renderSection`, `bindSectionActions`, new `animateGauges` function
- `tests/container-code-companion-static.sh` — 9 new static assertions

---

## Context for implementers

The repo root is `/home/peyton/repos/CCC`. All commands run from there unless noted.

**Build:** `/home/peyton/.local/go/bin/go build -C container-code-companion -o /tmp/aw-test ./cmd/server`
**JS syntax:** `node --check container-code-companion/web/app.js && echo OK`
**Static tests:** `bash tests/container-code-companion-static.sh`

The static test suite uses `require_file_contains file pattern` to assert strings exist. We use this as our test harness — add assertions first (TDD), then implement.

Key existing CSS variables (in `:root`): `--accent` (hex color), `--border`, `--accent-bg`. We're adding `--accent-rgb` (comma-separated RGB numbers, e.g. `74, 222, 128`) set in `applyTheme()` in `app.js`.

Key existing functions in `app.js`:
- `applyTheme(name)` at line ~1480 — sets CSS vars, already computes `rgb` via `hexToRgb(hex)`
- `loadHealth()` at line ~45 — sets `#health` textContent
- `renderSection(section)` at line ~160 — sets `body.innerHTML` then calls `bindSectionActions`
- `bindSectionActions(section)` at line ~533 — wires section-specific buttons
- `gauge(label, value, detail)` at line ~1421 — renders a gauge with `style="--value:${percent}"`

---

## Task 1: Add failing static assertions + `--accent-rgb` prerequisite

**Files:**
- Modify: `tests/container-code-companion-static.sh`
- Modify: `container-code-companion/web/app.js`

- [ ] **Step 1: Add static assertions (will fail until later tasks implement them)**

Find the `# Task 5: Network graph accent` block near the end of `tests/container-code-companion-static.sh` and add after it:

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

- [ ] **Step 2: Verify assertions fail**

Run:
```bash
bash tests/container-code-companion-static.sh 2>&1 | head -5
```
Expected: `FAIL: container-code-companion/web/styles.css missing: pulse-dot` (or similar)

- [ ] **Step 3: Add `--accent-rgb` to `applyTheme`**

In `container-code-companion/web/app.js`, find `applyTheme`:
```js
function applyTheme(name) {
  const hex = THEMES[name] || THEMES[DEFAULT_THEME];
  const rgb = hexToRgb(hex);
  const root = document.documentElement;
  root.style.setProperty('--accent', hex);
  root.style.setProperty('--border', `rgba(${rgb}, 0.12)`);
  root.style.setProperty('--accent-bg', `rgba(${rgb}, 0.10)`);
  localStorage.setItem(THEME_STORAGE_KEY, name);
}
```

Replace with:
```js
function applyTheme(name) {
  const hex = THEMES[name] || THEMES[DEFAULT_THEME];
  const rgb = hexToRgb(hex);
  const root = document.documentElement;
  root.style.setProperty('--accent', hex);
  root.style.setProperty('--accent-rgb', rgb);
  root.style.setProperty('--border', `rgba(${rgb}, 0.12)`);
  root.style.setProperty('--accent-bg', `rgba(${rgb}, 0.10)`);
  localStorage.setItem(THEME_STORAGE_KEY, name);
}
```

- [ ] **Step 4: Verify JS syntax**

```bash
node --check container-code-companion/web/app.js && echo OK
```
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add tests/container-code-companion-static.sh container-code-companion/web/app.js
git commit -m "feat(polish): add --accent-rgb CSS var + static test stubs for visual effects"
```

---

## Task 2: CSS glow effects — topbar, gauges, scanlines, sidebar (Effects 1–4)

**Files:**
- Modify: `container-code-companion/web/styles.css`

- [ ] **Step 1: Add topbar neon underglow (Effect 1)**

Find `.topbar {` in `styles.css`. It currently ends before the closing `}`. Add `box-shadow` to the rule:

```css
.topbar {
  height: 56px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 20px;
  border-bottom: 1px solid var(--border);
  background: var(--topbar);
  box-shadow:
    0 1px 0 rgba(var(--accent-rgb), 0.40),
    0 2px 28px rgba(var(--accent-rgb), 0.13),
    0 6px 60px rgba(var(--accent-rgb), 0.05);
}
```

- [ ] **Step 2: Add gauge halo glow (Effect 2)**

Find `.gauge {` in `styles.css`. Add `filter` and `transition` to the existing rule, then add the hover rule immediately after:

```css
.gauge {
  width: 148px;
  aspect-ratio: 1;
  display: grid;
  place-items: center;
  border-radius: 50%;
  background:
    radial-gradient(circle at center, var(--panel2) 0 57%, transparent 58%),
    conic-gradient(var(--accent) calc(var(--value) * 1%), rgba(255,255,255,0.15) 0);
  filter: drop-shadow(0 0 7px rgba(var(--accent-rgb), 0.45));
  transition: filter 0.25s;
}

.gauge:hover {
  filter: drop-shadow(0 0 16px rgba(var(--accent-rgb), 0.80));
}
```

- [ ] **Step 3: Add scanlines overlay (Effect 3)**

Add after the `body { ... }` rule block:

```css
/* scanlines */
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

- [ ] **Step 4: Add sidebar active left bar + ambient glow (Effect 4)**

Find `.sidebar button.active {` in `styles.css`. Add `box-shadow` to the existing rule:

```css
.sidebar button.active {
  background: var(--accent-bg);
  color: var(--accent);
  font-weight: 600;
  box-shadow: inset 3px 0 0 var(--accent), 0 0 14px rgba(var(--accent-rgb), 0.08);
}
```

- [ ] **Step 5: Verify scanlines and drop-shadow strings are in the file**

```bash
grep -c 'scanlines\|drop-shadow' container-code-companion/web/styles.css
```
Expected: `2` (or higher)

- [ ] **Step 6: Commit**

```bash
git add container-code-companion/web/styles.css
git commit -m "feat(polish): topbar underglow, gauge halo, scanlines, sidebar active bar"
```

---

## Task 3: CSS hover glows — panels, tiles, gauge cards (Effect 5)

**Files:**
- Modify: `container-code-companion/web/styles.css`

- [ ] **Step 1: Add transition and hover rule to `.panel`**

Find `.panel {` in `styles.css`. Add `transition` to the existing rule:

```css
.panel {
  border: 1px solid var(--border);
  background: var(--panel);
  border-radius: 6px;
  padding: 16px;
  overflow: auto;
  transition: border-color 0.2s, box-shadow 0.2s;
}
```

Add the hover rule immediately after:

```css
.panel:hover {
  border-color: rgba(var(--accent-rgb), 0.28);
  box-shadow: 0 0 20px rgba(var(--accent-rgb), 0.06);
}
```

- [ ] **Step 2: Add transition and hover lift to `.status-tile`**

Find `.status-tile {` in `styles.css`. Add `transition` to the existing rule:

```css
.status-tile {
  min-height: 72px;
  padding: 12px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: var(--panel2);
  transition: transform 0.18s, box-shadow 0.18s, border-color 0.18s;
}
```

Add hover rule immediately after:

```css
.status-tile:hover {
  transform: translateY(-3px);
  border-color: rgba(var(--accent-rgb), 0.35);
  box-shadow: 0 6px 20px rgba(var(--accent-rgb), 0.12);
}
```

- [ ] **Step 3: Add transition and hover lift to `.gauge-card`**

Find `.gauge-card {` in `styles.css`. Add `transition` to the existing rule:

```css
.gauge-card {
  display: grid;
  justify-items: center;
  gap: 10px;
  padding: 16px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: var(--panel2);
  transition: transform 0.18s, box-shadow 0.18s, border-color 0.18s;
}
```

Add hover rule immediately after:

```css
.gauge-card:hover {
  transform: translateY(-2px);
  border-color: rgba(var(--accent-rgb), 0.28);
  box-shadow: 0 4px 16px rgba(var(--accent-rgb), 0.10);
}
```

- [ ] **Step 4: Commit**

```bash
git add container-code-companion/web/styles.css
git commit -m "feat(polish): hover glow on panels, status tiles, and gauge cards"
```

---

## Task 4: Section fade-in (Effect 7) — CSS + JS

**Files:**
- Modify: `container-code-companion/web/styles.css`
- Modify: `container-code-companion/web/app.js`

- [ ] **Step 1: Add keyframe and class to `styles.css`**

Append to the end of `container-code-companion/web/styles.css`:

```css
@keyframes section-fade {
  from { opacity: 0; transform: translateY(5px); }
  to   { opacity: 1; transform: translateY(0); }
}

.section-enter {
  animation: section-fade 0.28s ease-out;
}
```

- [ ] **Step 2: Add class toggle in `renderSection`**

In `app.js`, find the line inside `renderSection`:
```js
  body.innerHTML = renderers[section]?.() || '<p>Section unavailable.</p>';
  bindSectionActions(section);
```

Replace with:
```js
  body.innerHTML = renderers[section]?.() || '<p>Section unavailable.</p>';
  body.classList.remove('section-enter');
  void body.offsetWidth;
  body.classList.add('section-enter');
  bindSectionActions(section);
```

- [ ] **Step 3: Verify JS syntax**

```bash
node --check container-code-companion/web/app.js && echo OK
```
Expected: `OK`

- [ ] **Step 4: Check static assertions for section-fade and section-enter pass**

```bash
bash tests/container-code-companion-static.sh 2>&1 | grep -E 'section-fade|section-enter|FAIL'
```
Expected: no output (those two assertions now pass)

- [ ] **Step 5: Commit**

```bash
git add container-code-companion/web/styles.css container-code-companion/web/app.js
git commit -m "feat(polish): section fade-in animation on nav change"
```

---

## Task 5: Pulsing health dot (Effect 8) — CSS + JS

**Files:**
- Modify: `container-code-companion/web/styles.css`
- Modify: `container-code-companion/web/app.js`

- [ ] **Step 1: Add pulse keyframe and `#health` rules to `styles.css`**

Append to the end of `container-code-companion/web/styles.css`:

```css
@keyframes pulse-dot {
  0%, 100% { opacity: 1; box-shadow: 0 0 6px rgba(var(--accent-rgb), 0.75); }
  50%       { opacity: 0.45; box-shadow: 0 0 14px rgba(var(--accent-rgb), 0.20); }
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
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--accent);
  box-shadow: 0 0 6px rgba(var(--accent-rgb), 0.75);
  animation: pulse-dot 2.4s ease-in-out infinite;
  flex-shrink: 0;
}
```

- [ ] **Step 2: Update `loadHealth` to toggle the `.online` class**

In `app.js`, find and replace the entire `loadHealth` function:

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

- [ ] **Step 3: Verify JS syntax**

```bash
node --check container-code-companion/web/app.js && echo OK
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add container-code-companion/web/styles.css container-code-companion/web/app.js
git commit -m "feat(polish): pulsing accent dot on Online health indicator"
```

---

## Task 6: Gauge sweep animation (Effect 6) — JS only

**Files:**
- Modify: `container-code-companion/web/app.js`

- [ ] **Step 1: Add `animateGauges` function**

In `app.js`, find the `gauge()` function (around line 1421). Add the new function immediately after the closing `}` of `gauge()`:

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

- [ ] **Step 2: Call `animateGauges` from `bindSectionActions`**

In `app.js`, find the `bindSectionActions` function. Locate the block:
```js
  if (section === 'network') {
    bindNetwork();
  }
```

Add immediately after:
```js
  if (section === 'overview') {
    requestAnimationFrame(animateGauges);
  }
```

- [ ] **Step 3: Verify JS syntax**

```bash
node --check container-code-companion/web/app.js && echo OK
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add container-code-companion/web/app.js
git commit -m "feat(polish): gauge sweep animation on overview load"
```

---

## Task 7: Final verification

**Files:** none (read-only checks)

- [ ] **Step 1: Run full static test suite**

```bash
bash tests/container-code-companion-static.sh
```
Expected: `container-code-companion static checks passed`

If any assertion fails, fix it before continuing.

- [ ] **Step 2: Go build**

```bash
/home/peyton/.local/go/bin/go build -C container-code-companion -o /tmp/aw-test ./cmd/server && echo BUILD OK
```
Expected: `BUILD OK`

- [ ] **Step 3: Go tests**

```bash
cd container-code-companion && /home/peyton/.local/go/bin/go test ./... && echo TESTS OK
```
Expected: all `ok`, then `TESTS OK`

- [ ] **Step 4: JS syntax**

```bash
node --check container-code-companion/web/app.js && echo JS OK
```
Expected: `JS OK`

- [ ] **Step 5: Push**

```bash
git push origin container-code-companion-native-ui
```
