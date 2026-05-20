# Agent Workstation Theme System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the Prism dark navy base palette and IBM Plex Mono font to the Agent Workstation UI, then add a user-selectable accent-color theme system (7 themes, green default) accessible via a new Settings page.

**Architecture:** All theming is done via CSS custom properties (`--accent`, `--border`, `--accent-bg`) set by `applyTheme()` on `document.documentElement`. The base Prism dark palette (bg/panel/topbar) is hardcoded in `:root`. The selected theme is persisted in `localStorage` and restored by `loadTheme()` called once at script load before the page renders. The Settings page renders a list of swatch buttons; clicking one calls `applyTheme()` then re-renders the section.

**Tech Stack:** Vanilla JS (no bundler), CSS custom properties, `localStorage`, Google Fonts (IBM Plex Mono), Canvas 2D API.

---

## Files Modified

| File | Change |
|---|---|
| `agent-workstation/web/styles.css` | Replace all vars + hardcoded colors with Prism palette; add swatch CSS; accent-colored active sidebar |
| `agent-workstation/web/index.html` | Google Fonts link; Settings nav group |
| `agent-workstation/web/app.js` | THEMES constant; hexToRgb, applyTheme, loadTheme, renderSettings, bindSettings; loadTheme() call at init; network graph uses --accent |
| `tests/agent-workstation-static.sh` | New assertions for all changes |

---

## Task 1: CSS — Prism Dark Palette

**Files:**
- Modify: `agent-workstation/web/styles.css`
- Modify: `tests/agent-workstation-static.sh`

Replace the current gray palette (`#17191c` bg, `#24282d` panels) with the Prism navy palette (`#060d16` bg, `#0a1628` panels). Replace all hardcoded dark color literals with CSS variables. Update the sidebar active state to use the accent color. Add Settings swatch CSS.

- [ ] **Step 1: Write failing static assertions**

Add to `tests/agent-workstation-static.sh`:
```bash
# Task 1: CSS Prism palette
require_file_contains agent-workstation/web/styles.css '--topbar'
require_file_contains agent-workstation/web/styles.css '--panel2'
require_file_contains agent-workstation/web/styles.css '--accent-bg'
require_file_contains agent-workstation/web/styles.css '#060d16'
require_file_contains agent-workstation/web/styles.css 'IBM Plex Mono'
require_file_contains agent-workstation/web/styles.css 'settings-swatch-row'
require_file_not_contains agent-workstation/web/styles.css '#17191c'
require_file_not_contains agent-workstation/web/styles.css '#24282d'
require_file_not_contains agent-workstation/web/styles.css '#3f454d'
require_file_not_contains agent-workstation/web/styles.css '#a7adb5'
require_file_not_contains agent-workstation/web/styles.css '#111316'
require_file_not_contains agent-workstation/web/styles.css '#1b1e22'
require_file_not_contains agent-workstation/web/styles.css '#050608'
```

Run:
```bash
bash tests/agent-workstation-static.sh
```
Expected: FAIL (all the old color values are still present)

- [ ] **Step 2: Replace the entire `:root` block in styles.css**

Find:
```css
:root {
  color-scheme: dark;
  --bg: #17191c;
  --panel: #24282d;
  --border: #3f454d;
  --text: #eef0f3;
  --muted: #a7adb5;
  --accent: #68a6f8;
}
```

Replace with:
```css
:root {
  color-scheme: dark;
  --bg:        #060d16;
  --topbar:    #020810;
  --panel:     #0a1628;
  --panel2:    #0d1f38;
  --text:      #e2e8f0;
  --muted:     #64748b;
  --text-dim:  #94a3b8;
  /* accent and derived vars — overridden by applyTheme() on load */
  --accent:    #4ade80;
  --border:    rgba(74, 222, 128, 0.12);
  --accent-bg: rgba(74, 222, 128, 0.10);
}
```

- [ ] **Step 3: Update body font and add form element font inheritance**

Find:
```css
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font: 14px/1.45 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
```

Replace with:
```css
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font: 13px/1.5 'IBM Plex Mono', monospace;
}

input, select, textarea, button { font: inherit; }
```

- [ ] **Step 4: Update .topbar background**

Find:
```css
.topbar {
  height: 56px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 20px;
  border-bottom: 1px solid var(--border);
  background: #111316;
}
```

Replace with:
```css
.topbar {
  height: 56px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 20px;
  border-bottom: 1px solid var(--border);
  background: var(--topbar);
}
```

- [ ] **Step 5: Update active sidebar state to use accent**

Find:
```css
.sidebar button.active,
.sidebar button:hover {
  background: var(--panel);
  color: var(--text);
}
```

Replace with:
```css
.sidebar button.active {
  background: var(--accent-bg);
  color: var(--accent);
  font-weight: 600;
}

.sidebar button:hover {
  background: var(--panel2);
  color: var(--text);
}
```

- [ ] **Step 6: Replace hardcoded .status-tile background**

Find:
```css
.status-tile {
  min-height: 72px;
  padding: 12px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #1b1e22;
}
```

Replace with:
```css
.status-tile {
  min-height: 72px;
  padding: 12px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: var(--panel2);
}
```

- [ ] **Step 7: Replace hardcoded gauge backgrounds**

Find:
```css
.gauge-card {
  display: grid;
  justify-items: center;
  gap: 10px;
  padding: 16px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #1b1e22;
}

.gauge {
  width: 148px;
  aspect-ratio: 1;
  display: grid;
  place-items: center;
  border-radius: 50%;
  background:
    radial-gradient(circle at center, #1b1e22 0 57%, transparent 58%),
    conic-gradient(var(--accent) calc(var(--value) * 1%), #3f454d 0);
}

.gauge-inner {
  width: 104px;
  aspect-ratio: 1;
  display: grid;
  place-items: center;
  align-content: center;
  border-radius: 50%;
  background: #111316;
}
```

Replace with:
```css
.gauge-card {
  display: grid;
  justify-items: center;
  gap: 10px;
  padding: 16px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: var(--panel2);
}

.gauge {
  width: 148px;
  aspect-ratio: 1;
  display: grid;
  place-items: center;
  border-radius: 50%;
  background:
    radial-gradient(circle at center, var(--panel2) 0 57%, transparent 58%),
    conic-gradient(var(--accent) calc(var(--value) * 1%), rgba(255,255,255,0.07) 0);
}

.gauge-inner {
  width: 104px;
  aspect-ratio: 1;
  display: grid;
  place-items: center;
  align-content: center;
  border-radius: 50%;
  background: var(--topbar);
}
```

- [ ] **Step 8: Replace hardcoded .dash-panel background**

Find:
```css
.dash-panel {
  min-height: 180px;
  padding: 14px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #1b1e22;
}
```

Replace with:
```css
.dash-panel {
  min-height: 180px;
  padding: 14px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: var(--panel2);
}
```

- [ ] **Step 9: Replace hardcoded input/output/editor backgrounds**

Find and replace each of these (they appear at multiple points in the CSS):

```css
.login-panel > input,
.login-row input {
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #111316;
  color: var(--text);
  padding: 8px 10px;
}
```
→ change `background: #111316` to `background: var(--topbar)`

```css
.project-create input,
.project-create select,
.account-create input {
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #111316;
  color: var(--text);
  padding: 8px 10px;
}
```
→ change `background: #111316` to `background: var(--topbar)`

```css
.terminal-tab {
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #111316;
  color: var(--muted);
  padding: 7px 10px;
  cursor: pointer;
}
```
→ change `background: #111316` to `background: var(--topbar)`

```css
.terminal-pane {
  min-height: 560px;
  padding: 8px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #050608;
}
```
→ change `background: #050608` to `background: var(--topbar)`

```css
.output {
  max-height: 380px;
  overflow: auto;
  margin: 0 0 14px;
  padding: 12px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #111316;
  color: var(--text);
  white-space: pre-wrap;
}
```
→ change `background: #111316` to `background: var(--topbar)`

```css
.terminal-form input,
.file-toolbar input {
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #111316;
  color: var(--text);
  padding: 8px 10px;
}
```
→ change `background: #111316` to `background: var(--topbar)`

```css
.file-entry {
  display: grid;
  grid-template-columns: 42px minmax(0, 1fr) auto;
  gap: 8px;
  align-items: center;
  width: 100%;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #111316;
  color: var(--text);
  padding: 8px;
  text-align: left;
  cursor: pointer;
}
```
→ change `background: #111316` to `background: var(--topbar)`

```css
#file-editor {
  width: 100%;
  min-height: 460px;
  resize: vertical;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #111316;
  color: var(--text);
  padding: 12px;
  font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
```
→ change `background: #111316` to `background: var(--topbar)`

```css
.config-editor-textarea {
  display: block;
  width: 100%;
  min-height: 320px;
  padding: 12px 14px;
  background: #111316;
  color: var(--text);
  border: none;
  font: 13px/1.5 "Cascadia Code", "Fira Code", "JetBrains Mono", monospace;
  resize: vertical;
}
```
→ change `background: #111316` to `background: var(--topbar)`

- [ ] **Step 10: Replace remaining hardcoded panel2-level backgrounds**

Find and replace each:

```css
.config-editor-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 10px 14px;
  border-bottom: 1px solid var(--border);
  background: #1b1e22;
}
```
→ change `background: #1b1e22` to `background: var(--panel2)`

```css
.config-row {
  display: grid;
  grid-template-columns: minmax(260px, 1fr) auto;
  gap: 14px;
  align-items: center;
  padding: 12px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #1b1e22;
}
```
→ change `background: #1b1e22` to `background: var(--panel2)`

```css
.account-row {
  display: grid;
  grid-template-columns: minmax(260px, 1fr) auto;
  gap: 14px;
  align-items: center;
  padding: 12px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #1b1e22;
}
```
→ change `background: #1b1e22` to `background: var(--panel2)`

```css
.project-row {
  display: grid;
  grid-template-columns: minmax(260px, 1fr) auto;
  gap: 14px;
  align-items: center;
  padding: 12px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #1b1e22;
}
```
→ change `background: #1b1e22` to `background: var(--panel2)`

```css
.service-row {
  display: grid;
  grid-template-columns: minmax(240px, 1fr) auto;
  gap: 14px;
  align-items: center;
  padding: 12px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #1b1e22;
}
```
→ change `background: #1b1e22` to `background: var(--panel2)`

```css
#network-graph {
  width: 100%;
  max-height: 220px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #111316;
}
```
→ change `background: #111316` to `background: var(--topbar)`

- [ ] **Step 11: Add Settings swatch CSS**

Append to the end of `styles.css`:
```css
.settings-section {
  max-width: 480px;
}

.settings-swatch-grid {
  display: grid;
  gap: 6px;
  margin-top: 12px;
}

.settings-swatch-row {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 12px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: var(--panel2);
  color: var(--text);
  cursor: pointer;
  text-align: left;
  width: 100%;
  transition: border-color 0.15s;
}

.settings-swatch-row:hover {
  border-color: var(--accent);
}

.settings-swatch-row.active {
  border-color: var(--accent);
  background: var(--accent-bg);
}

.settings-swatch-circle {
  width: 22px;
  height: 22px;
  border-radius: 50%;
  flex-shrink: 0;
  border: 2px solid rgba(255,255,255,0.15);
}

.settings-swatch-name {
  font-weight: 600;
  min-width: 64px;
}

.settings-swatch-hex {
  color: var(--muted);
  font-size: 11px;
}

.settings-swatch-default {
  margin-left: auto;
  font-size: 10px;
  letter-spacing: 0.08em;
  color: var(--muted);
  border: 1px solid var(--border);
  border-radius: 3px;
  padding: 1px 6px;
}
```

- [ ] **Step 12: Run static checks and JS syntax**

```bash
bash tests/agent-workstation-static.sh
```
Expected: `agent-workstation static checks passed`

- [ ] **Step 13: Commit**

```bash
git add agent-workstation/web/styles.css tests/agent-workstation-static.sh
git commit -m "feat(theme): apply Prism dark palette and add theme swatch CSS"
```

---

## Task 2: index.html — Google Fonts + Settings Nav

**Files:**
- Modify: `agent-workstation/web/index.html`
- Modify: `tests/agent-workstation-static.sh`

- [ ] **Step 1: Write failing static assertions**

Add to `tests/agent-workstation-static.sh`:
```bash
# Task 2: index.html
require_file_contains agent-workstation/web/index.html 'IBM+Plex+Mono'
require_file_contains agent-workstation/web/index.html 'data-section="settings"'
```

Run:
```bash
bash tests/agent-workstation-static.sh
```
Expected: FAIL

- [ ] **Step 2: Add Google Fonts link to index.html**

Find:
```html
  <link rel="stylesheet" href="/vendor/xterm.min.css">
```

Replace with:
```html
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="/vendor/xterm.min.css">
```

- [ ] **Step 3: Add Settings nav group to sidebar**

Find the closing `</nav>` in `index.html`:
```html
      </div>
    </nav>
```

The last nav group before `</nav>` is the Agents group. Add a Preferences group after it:
```html
      <div class="nav-group">
        <div class="nav-heading">Agents</div>
        <button data-section="configs">Agent Configs</button>
        <button data-section="oculus">oculus-configs</button>
      </div>
      <div class="nav-group">
        <div class="nav-heading">Preferences</div>
        <button data-section="settings">Settings</button>
      </div>
    </nav>
```

- [ ] **Step 4: Run static checks**

```bash
bash tests/agent-workstation-static.sh
```
Expected: pass

- [ ] **Step 5: Commit**

```bash
git add agent-workstation/web/index.html tests/agent-workstation-static.sh
git commit -m "feat(theme): add Google Fonts and Settings nav item"
```

---

## Task 3: JS — Theme Engine

**Files:**
- Modify: `agent-workstation/web/app.js`
- Modify: `tests/agent-workstation-static.sh`

Add the constants and functions that power the theme system. `loadTheme()` is called at script initialization so the theme is applied before any render.

- [ ] **Step 1: Write failing static assertions**

Add to `tests/agent-workstation-static.sh`:
```bash
# Task 3: JS theme engine
require_file_contains agent-workstation/web/app.js 'const THEMES'
require_file_contains agent-workstation/web/app.js 'applyTheme'
require_file_contains agent-workstation/web/app.js 'loadTheme'
require_file_contains agent-workstation/web/app.js 'aw-theme'
require_file_contains agent-workstation/web/app.js 'hexToRgb'
```

Run:
```bash
bash tests/agent-workstation-static.sh
```
Expected: FAIL

- [ ] **Step 2: Add theme constants at the top of app.js**

After the `const titles = { ... };` block (end of that block is the closing `};` on line 13), insert:

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
const THEME_STORAGE_KEY = 'aw-theme';
```

- [ ] **Step 3: Add hexToRgb, applyTheme, loadTheme functions**

Add these three functions anywhere before the `loadHealth()` call at the bottom of the file (a good place is just before `function stripANSI`):

```js
function hexToRgb(hex) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `${r}, ${g}, ${b}`;
}

function applyTheme(name) {
  const hex = THEMES[name] || THEMES[DEFAULT_THEME];
  const rgb = hexToRgb(hex);
  const root = document.documentElement;
  root.style.setProperty('--accent', hex);
  root.style.setProperty('--border', `rgba(${rgb}, 0.12)`);
  root.style.setProperty('--accent-bg', `rgba(${rgb}, 0.10)`);
  localStorage.setItem(THEME_STORAGE_KEY, name);
}

function loadTheme() {
  const saved = localStorage.getItem(THEME_STORAGE_KEY);
  applyTheme(saved && THEMES[saved] ? saved : DEFAULT_THEME);
}
```

- [ ] **Step 4: Call loadTheme() at initialization**

Find the initialization block at the bottom of `app.js`:
```js
loadHealth();
refresh();
```

Replace with:
```js
loadTheme();
loadHealth();
refresh();
```

- [ ] **Step 5: Run checks**

```bash
bash tests/agent-workstation-static.sh
node --check agent-workstation/web/app.js
```
Expected: both pass

- [ ] **Step 6: Commit**

```bash
git add agent-workstation/web/app.js tests/agent-workstation-static.sh
git commit -m "feat(theme): add theme engine — THEMES, applyTheme, loadTheme, hexToRgb"
```

---

## Task 4: JS — Settings Page

**Files:**
- Modify: `agent-workstation/web/app.js`
- Modify: `tests/agent-workstation-static.sh`

Add `renderSettings` and `bindSettings`. Wire them into the existing `renderSection` / `bindSectionActions` dispatch.

- [ ] **Step 1: Write failing static assertions**

Add to `tests/agent-workstation-static.sh`:
```bash
# Task 4: Settings page
require_file_contains agent-workstation/web/app.js 'renderSettings'
require_file_contains agent-workstation/web/app.js 'bindSettings'
require_file_contains agent-workstation/web/app.js 'settings-swatch'
require_file_contains agent-workstation/web/app.js "settings: 'Settings'"
```

Run:
```bash
bash tests/agent-workstation-static.sh
```
Expected: FAIL

- [ ] **Step 2: Add 'settings' to the titles map**

Find:
```js
const titles = {
  overview: 'Overview',
  logs: 'Logs',
  network: 'Network',
  accounts: 'Accounts',
  services: 'Services',
  files: 'Files',
  updates: 'Updates',
  terminal: 'Terminal',
  projects: 'Projects',
  configs: 'Agent Configs',
  oculus: 'oculus-configs',
};
```

Replace with:
```js
const titles = {
  overview: 'Overview',
  logs: 'Logs',
  network: 'Network',
  accounts: 'Accounts',
  services: 'Services',
  files: 'Files',
  updates: 'Updates',
  terminal: 'Terminal',
  projects: 'Projects',
  configs: 'Agent Configs',
  oculus: 'oculus-configs',
  settings: 'Settings',
};
```

- [ ] **Step 3: Add renderSettings to the renderers map in renderSection**

Find in `renderSection`:
```js
  const renderers = {
    overview: renderOverview,
    logs: renderLogs,
    network: renderNetwork,
    accounts: renderAccounts,
    services: renderServices,
    files: renderFiles,
    updates: renderUpdates,
    terminal: renderTerminal,
    projects: renderProjects,
    configs: renderConfigs,
    oculus: renderOculus,
  };
```

Replace with:
```js
  const renderers = {
    overview: renderOverview,
    logs: renderLogs,
    network: renderNetwork,
    accounts: renderAccounts,
    services: renderServices,
    files: renderFiles,
    updates: renderUpdates,
    terminal: renderTerminal,
    projects: renderProjects,
    configs: renderConfigs,
    oculus: renderOculus,
    settings: renderSettings,
  };
```

- [ ] **Step 4: Add bindSettings call in bindSectionActions**

Find in `bindSectionActions`:
```js
  if (section === 'accounts') {
    bindAccounts();
  }
  if (section === 'network') {
    bindNetwork();
  }
```

Replace with:
```js
  if (section === 'accounts') {
    bindAccounts();
  }
  if (section === 'network') {
    bindNetwork();
  }
  if (section === 'settings') {
    bindSettings();
  }
```

- [ ] **Step 5: Add renderSettings function**

Add after the `renderOculus` function (or wherever other `render*` functions are defined). A safe anchor is just before `function bindSectionActions`:

```js
function renderSettings() {
  const current = localStorage.getItem(THEME_STORAGE_KEY) || DEFAULT_THEME;
  return `
    <div class="settings-section">
      <h3>Theme</h3>
      <div class="settings-swatch-grid">
        ${Object.entries(THEMES).map(([name, hex]) => `
          <button class="settings-swatch-row${name === current ? ' active' : ''}" data-theme="${escapeAttribute(name)}">
            <span class="settings-swatch-circle" style="background:${hex};${name === current ? `box-shadow:0 0 0 2px #fff,0 0 0 4px ${hex};` : ''}"></span>
            <span class="settings-swatch-name">${escapeHTML(name.charAt(0).toUpperCase() + name.slice(1))}</span>
            <span class="settings-swatch-hex">${escapeHTML(hex)}</span>
            ${name === DEFAULT_THEME ? '<span class="settings-swatch-default">default</span>' : ''}
          </button>
        `).join('')}
      </div>
    </div>
  `;
}
```

- [ ] **Step 6: Add bindSettings function**

Add immediately after `renderSettings`:

```js
function bindSettings() {
  document.querySelectorAll('[data-theme]').forEach(button => {
    button.addEventListener('click', () => {
      applyTheme(button.dataset.theme);
      renderSection('settings');
    });
  });
}
```

- [ ] **Step 7: Note — renderSettings does not check snapshot**

`renderSettings` does not call `snapshot` — it reads only from `THEMES` and `localStorage`. This means it renders even when the user is not signed in. Verify `renderSection` doesn't block settings rendering:

```bash
grep -n "if (!snapshot)" agent-workstation/web/app.js
```

The guard in `renderSection` returns early with a "sign in required" message if `!snapshot`. Settings should still be accessible unauthenticated. Fix: add `settings` to the guard exception.

Find in `renderSection`:
```js
  if (!snapshot) {
    body.textContent = 'Sign in is required before management data is shown.';
    return;
  }
```

Replace with:
```js
  if (!snapshot && section !== 'settings') {
    body.textContent = 'Sign in is required before management data is shown.';
    return;
  }
```

- [ ] **Step 8: Run checks**

```bash
bash tests/agent-workstation-static.sh
node --check agent-workstation/web/app.js
```
Expected: both pass

- [ ] **Step 9: Commit**

```bash
git add agent-workstation/web/app.js tests/agent-workstation-static.sh
git commit -m "feat(theme): add Settings page with theme swatch picker"
```

---

## Task 5: Network Graph — Accent-Aware Colors

**Files:**
- Modify: `agent-workstation/web/app.js`
- Modify: `agent-workstation/web/styles.css`
- Modify: `tests/agent-workstation-static.sh`

The network graph currently uses the old hardcoded blue `#68a6f8` for the RX line. Update it to read `--accent` from the computed style, so it matches the active theme. The TX line stays `#34d399` (semantic green for upload).

- [ ] **Step 1: Write failing static assertions**

Add to `tests/agent-workstation-static.sh`:
```bash
# Task 5: Network graph accent
require_file_not_contains agent-workstation/web/app.js "'#68a6f8'"
require_file_not_contains agent-workstation/web/styles.css '#68a6f8'
```

Run:
```bash
bash tests/agent-workstation-static.sh
```
Expected: FAIL (both values are still present)

- [ ] **Step 2: Update drawNetworkGraph in app.js to read --accent**

Find:
```js
function drawNetworkGraph() {
  const canvas = document.getElementById('network-graph');
  if (!canvas?.getContext) return;
  const ctx = canvas.getContext('2d');
  const width = canvas.width;
  const height = canvas.height;
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = '#111316';
  ctx.fillRect(0, 0, width, height);
  const maxRate = Math.max(1, ...networkHistory.flatMap(point => [point.rxRate, point.txRate]));
  drawNetworkSeries(ctx, width, height, maxRate, 'rxRate', '#68a6f8');
  drawNetworkSeries(ctx, width, height, maxRate, 'txRate', '#34d399');
}
```

Replace with:
```js
function drawNetworkGraph() {
  const canvas = document.getElementById('network-graph');
  if (!canvas?.getContext) return;
  const ctx = canvas.getContext('2d');
  const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#4ade80';
  const width = canvas.width;
  const height = canvas.height;
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = '#020810';
  ctx.fillRect(0, 0, width, height);
  const maxRate = Math.max(1, ...networkHistory.flatMap(point => [point.rxRate, point.txRate]));
  drawNetworkSeries(ctx, width, height, maxRate, 'rxRate', accent);
  drawNetworkSeries(ctx, width, height, maxRate, 'txRate', '#34d399');
}
```

- [ ] **Step 3: Update .network-legend-rx in styles.css to use --accent**

Find:
```css
.network-legend-rx { color: #68a6f8; }
```

Replace with:
```css
.network-legend-rx { color: var(--accent); }
```

- [ ] **Step 4: Run checks**

```bash
bash tests/agent-workstation-static.sh
node --check agent-workstation/web/app.js
```
Expected: both pass

- [ ] **Step 5: Commit**

```bash
git add agent-workstation/web/app.js agent-workstation/web/styles.css tests/agent-workstation-static.sh
git commit -m "feat(theme): network graph RX line uses active accent color"
```

---

## Task 6: Final Verification

**Files:** None modified — verification only.

- [ ] **Step 1: Go test suite**

```bash
/home/peyton/.local/go/bin/go test ./agent-workstation/... -v 2>&1 | tail -20
```
Expected: all PASS, no FAIL lines.

- [ ] **Step 2: Build**

```bash
/home/peyton/.local/go/bin/go build ./agent-workstation/cmd/server
rm -f server
```
Expected: no errors.

- [ ] **Step 3: All static and syntax checks**

```bash
bash tests/agent-workstation-static.sh
node --check agent-workstation/web/app.js
bash -n ccc-bootstrap.sh
```
Expected: all pass.

- [ ] **Step 4: Update HANDOFF.md**

Update `HANDOFF.md` next steps:
- Theme system implemented: 7 themes (green default), accessible via Settings page
- Full Prism dark base applied (navy backgrounds, IBM Plex Mono font)
- Themes persist in localStorage key `aw-theme`
- Network graph RX line tracks active accent color
- Next: push to origin/main; test on live LXC; validate theme picker in browser
- Note: push to `origin/main` still needed before self-update validates on deployed LXC

- [ ] **Step 5: Push**

```bash
git push origin agent-workstation-native-ui
```

---

## Self-Review

**Spec coverage:**
- ✅ Prism dark base palette (bg, topbar, panel, panel2) — Tasks 1–2
- ✅ IBM Plex Mono font — Tasks 1–2
- ✅ THEMES constant with all 7 colors — Task 3
- ✅ applyTheme sets --accent, --border, --accent-bg — Task 3
- ✅ loadTheme reads localStorage, falls back to green — Task 3
- ✅ loadTheme() called at init before render — Task 3
- ✅ Settings page with swatch grid — Task 4
- ✅ Settings accessible unauthenticated — Task 4
- ✅ Clicking swatch applies theme + persists — Task 4
- ✅ Active swatch shows white ring — Task 4
- ✅ Network graph RX uses --accent — Task 5
- ✅ .network-legend-rx uses var(--accent) — Task 5
- ✅ All hardcoded grays replaced with CSS vars — Task 1
- ✅ Static assertions for every change — Tasks 1–5

**Placeholder scan:** None found.

**Type consistency:** `applyTheme(name)` is consistent in Task 3 definition and Task 4 bindSettings usage. `THEME_STORAGE_KEY` is consistent across applyTheme, loadTheme, and renderSettings. `DEFAULT_THEME = 'green'` is consistent with `THEMES.green = '#4ade80'`.
