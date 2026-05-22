# Project Clone Layout Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align the Projects clone controls into a usable responsive row and make the top header message visibly editable from the main view.

**Architecture:** Keep both changes in the existing browser UI layer. Add static regression checks first, then add small markup hooks and client bindings in the existing page renderer before tightening CSS around the new clone-row and header-message row.

**Tech Stack:** Browser HTML/CSS/JavaScript, existing shell static checks, Node syntax validation.

---

## File Map

- Modify `tests/container-code-companion-static.sh`: prove the clone layout hook, header edit button, and navigation/focus binding exist.
- Modify `container-code-companion/web/index.html`: wrap the header message display with a small `Edit` button.
- Modify `container-code-companion/web/app.js`: add the clone controls row hook and bind the header edit button to Preferences focus behavior.
- Modify `container-code-companion/web/styles.css`: align clone controls on desktop, stack them on mobile, and place the header edit button at the far right.

### Task 1: Lock The UI Contract With Static Checks

**Files:**
- Modify: `tests/container-code-companion-static.sh`
- Test: `tests/container-code-companion-static.sh`

- [x] **Step 1: Add failing static checks**

Add checks near the existing Projects assertions:

```bash
require_file_contains container-code-companion/web/app.js "project-clone-controls"
require_file_contains container-code-companion/web/index.html "custom-title-edit"
require_file_contains container-code-companion/web/app.js "focusHeaderMessageEditor"
```

- [x] **Step 2: Run the static suite and verify red**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: FAIL because `project-clone-controls`, `custom-title-edit`, and
`focusHeaderMessageEditor` are not present yet.

- [x] **Step 3: Commit the red test checkpoint**

Run:

```bash
git add tests/container-code-companion-static.sh
git commit -m "test(ui): cover clone layout affordances"
```

### Task 2: Add Clone Layout And Header Edit Markup

**Files:**
- Modify: `container-code-companion/web/index.html`
- Modify: `container-code-companion/web/app.js`
- Test: `tests/container-code-companion-static.sh`

- [x] **Step 1: Wrap the clone controls with a row hook**

Change the Projects clone block in `renderProjects()` to keep the heading and
group only the actionable controls:

```js
<div class="project-create project-clone">
  <strong>Clone Repository</strong>
  <div class="project-clone-controls">
    <input id="project-clone-remote" type="text" placeholder="git@github.com:owner/repo.git or https://host/owner/repo.git">
    <input id="project-clone-name" type="text" placeholder="optional-project-name">
    <button id="clone-project-button" class="small-button">Clone</button>
  </div>
</div>
```

- [x] **Step 2: Add the header message edit button**

Replace the current title display in `index.html` with:

```html
<div class="custom-title-row">
  <div id="custom-title-display" class="custom-title-display">Container Code Companion</div>
  <button id="custom-title-edit" class="small-button" type="button">Edit</button>
</div>
```

- [x] **Step 3: Add the Preferences focus helper and binding**

Add a helper in `app.js` near the custom title editor functions:

```js
function focusHeaderMessageEditor() {
  selectSection('settings');
  requestAnimationFrame(() => document.getElementById('custom-title-input')?.focus());
}
```

Bind it during global event setup with:

```js
document.getElementById('custom-title-edit')?.addEventListener('click', focusHeaderMessageEditor);
```

- [x] **Step 4: Run static checks and syntax validation**

Run:

```bash
bash tests/container-code-companion-static.sh
node --check container-code-companion/web/app.js
```

Expected: both commands exit 0.

- [x] **Step 5: Commit the markup and binding checkpoint**

Run:

```bash
git add container-code-companion/web/index.html container-code-companion/web/app.js
git commit -m "feat(ui): expose header message editing"
```

### Task 3: Tighten Responsive Layout Styling

**Files:**
- Modify: `container-code-companion/web/styles.css`
- Test: `tests/container-code-companion-static.sh`

- [ ] **Step 1: Add desktop layout styling**

Add styles that make clone heading and controls independent, and keep the title
action aligned without stretching the button:

```css
.project-clone {
  display: grid;
  grid-template-columns: 1fr;
}

.project-clone-controls {
  display: grid;
  grid-template-columns: minmax(260px, 1fr) minmax(160px, 240px) auto;
  gap: 8px;
  align-items: center;
}

.custom-title-row {
  display: flex;
  align-items: flex-end;
  gap: 12px;
  margin-bottom: 16px;
}

.custom-title-row .custom-title-display {
  flex: 1 1 auto;
  margin-bottom: 0;
}

.custom-title-row .small-button {
  flex: 0 0 auto;
  margin-bottom: 12px;
}
```

- [ ] **Step 2: Stack clone controls on mobile**

Extend the existing narrow-screen media block with:

```css
.project-clone-controls {
  grid-template-columns: 1fr;
}

.custom-title-row {
  align-items: flex-start;
}
```

- [ ] **Step 3: Run focused verification**

Run:

```bash
bash tests/container-code-companion-static.sh
node --check container-code-companion/web/app.js
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 4: Commit the styling checkpoint**

Run:

```bash
git add container-code-companion/web/styles.css
git commit -m "style(ui): align project clone controls"
```

### Task 4: Verify The UI Slice

**Files:**
- Verify: `container-code-companion/web/index.html`
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
git status --short
```

Expected: only intentional plan checkbox updates remain if any.
