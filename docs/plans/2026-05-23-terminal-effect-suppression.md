# Terminal Effect Suppression Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Disable CCC's CRT overlay effects while the Terminal section is active so full-screen terminal apps like Gemini CLI render normally.

**Architecture:** Add a body state class from the existing `selectSection()` router and make CSS suppress the overlay pseudo-elements when that class is active. Keep all display-effect preference storage and toggles unchanged.

**Tech Stack:** Browser JavaScript, CSS, existing shell static checks, Node syntax validation.

---

## File Map

- Modify `tests/container-code-companion-static.sh`: add regression markers for the terminal suppression class and CSS rules.
- Modify `container-code-companion/web/app.js`: toggle `terminal-effects-suppressed` from `selectSection()`.
- Modify `container-code-companion/web/styles.css`: suppress flicker, scanlines, and sync-drift overlays when Terminal is active.

### Task 1: Add Failing Static Coverage

**Files:**
- Modify: `tests/container-code-companion-static.sh`
- Test: `tests/container-code-companion-static.sh`

- [ ] **Step 1: Add static checks**

Add these checks near the existing display effect assertions:

```bash
require_file_contains container-code-companion/web/app.js "terminal-effects-suppressed"
require_file_contains container-code-companion/web/app.js "section === 'terminal'"
require_file_contains container-code-companion/web/styles.css "body.terminal-effects-suppressed.effect-flicker::before"
require_file_contains container-code-companion/web/styles.css "body.terminal-effects-suppressed::after"
require_file_contains container-code-companion/web/styles.css "body.terminal-effects-suppressed.effect-sync-drift .layout::after"
```

- [ ] **Step 2: Run static checks and verify red**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: FAIL because the terminal suppression class and CSS rules do not exist.

- [ ] **Step 3: Commit the red test checkpoint**

Run:

```bash
git add tests/container-code-companion-static.sh
git commit -m "test(ui): cover terminal effect suppression"
```

### Task 2: Toggle Terminal Suppression State

**Files:**
- Modify: `container-code-companion/web/app.js`
- Test: `tests/container-code-companion-static.sh`

- [ ] **Step 1: Toggle the body class from `selectSection()`**

In `selectSection(section)`, add:

```js
document.body.classList.toggle('terminal-effects-suppressed', section === 'terminal');
```

- [ ] **Step 2: Run static checks and syntax validation**

Run:

```bash
bash tests/container-code-companion-static.sh
node --check container-code-companion/web/app.js
```

Expected: static checks still fail because CSS suppression rules are not present, and the syntax check exits 0.

### Task 3: Suppress Overlay Effects In Terminal

**Files:**
- Modify: `container-code-companion/web/styles.css`
- Test: `tests/container-code-companion-static.sh`

- [ ] **Step 1: Add suppression CSS**

Add this CSS near the existing effect rules:

```css
body.terminal-effects-suppressed.effect-flicker::before,
body.terminal-effects-suppressed::after,
body.terminal-effects-suppressed.effect-sync-drift .layout::after {
  display: none;
  animation: none;
}
```

- [ ] **Step 2: Run focused verification**

Run:

```bash
bash tests/container-code-companion-static.sh
node --check container-code-companion/web/app.js
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 3: Commit the implementation checkpoint**

Run:

```bash
git add container-code-companion/web/app.js container-code-companion/web/styles.css docs/plans/2026-05-23-terminal-effect-suppression.md
git commit -m "fix(ui): suppress display effects in terminal"
```

### Task 4: Final Verification

**Files:**
- Verify: `container-code-companion/web/app.js`
- Verify: `container-code-companion/web/styles.css`
- Verify: `tests/container-code-companion-static.sh`

- [ ] **Step 1: Run full relevant verification**

Run:

```bash
bash tests/container-code-companion-static.sh
node --check container-code-companion/web/app.js
(cd container-code-companion && go test ./...)
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 2: Inspect repo state**

Run:

```bash
git status --short --branch
```

Expected: only intentional plan checkbox updates remain if any.

