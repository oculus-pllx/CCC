# SSH Key Inventory Settings Page Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Relocate the existing SSH Key Inventory from Projects to a dedicated Settings page without changing its behavior or styling.

**Architecture:** Extend the existing client-side section registry and Settings navigation with an `ssh-keys` section. Reuse the current inventory loader, renderer, binder, API calls, and CSS while removing only the Projects-page placeholder and load hook.

**Tech Stack:** Static HTML, vanilla JavaScript, CSS, Bash regression tests, Markdown documentation

---

## File Map

- Modify `container-code-companion/web/index.html`: add the Settings navigation button.
- Modify `container-code-companion/web/app.js`: register and render the page, bind its existing inventory behavior, and remove inventory loading from Projects.
- Modify `tests/container-code-companion-static.sh`: assert the new navigation/page wiring and the absence of inventory wiring in Projects.
- Modify `docs/guides/ssh-key-management.md`: document the new menu location.

### Task 1: Add Failing Navigation And Page Regression Checks

**Files:**
- Modify: `tests/container-code-companion-static.sh`

- [x] **Step 1: Add the failing static assertions**

Add assertions that require:

```bash
require_file_contains container-code-companion/web/index.html 'data-section="ssh-keys"'
require_file_contains container-code-companion/web/app.js "ssh-keys: 'SSH Key Inventory'"
require_file_contains container-code-companion/web/app.js "'ssh-keys': renderSSHKeyInventoryPage"
require_file_contains container-code-companion/web/app.js "if (section === 'ssh-keys')"
require_file_contains container-code-companion/web/app.js 'function renderSSHKeyInventoryPage()'
require_file_contains container-code-companion/web/app.js 'function bindSSHKeyInventoryPage()'
```

Update the Settings navigation ordering assertion to include
`data-section="ssh-keys"` between GitHub and oculus-configs.

Extract the Projects renderer and binder and assert that neither contains the
inventory placeholder or loader:

```bash
projects_renderer=$(sed -n '/^function renderProjects()/,/^function renderConfigs()/p' container-code-companion/web/app.js)
projects_binder=$(sed -n '/^function bindProjects()/,/^async function repairProjectPermissions()/p' container-code-companion/web/app.js)
[[ "$projects_renderer" != *'ssh-key-inventory-placeholder'* ]] || fail "Projects renderer still contains SSH Key Inventory"
[[ "$projects_binder" != *'loadSSHKeyInventory()'* ]] || fail "Projects binder still loads SSH Key Inventory"
```

- [x] **Step 2: Run the static test to verify it fails**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: FAIL because `data-section="ssh-keys"` and the dedicated page wiring do
not exist yet.

- [x] **Step 3: Commit the failing regression test**

```bash
git add tests/container-code-companion-static.sh
git commit -m "test: require SSH key inventory settings page"
```

### Task 2: Move The Inventory To Its Dedicated Page

**Files:**
- Modify: `container-code-companion/web/index.html`
- Modify: `container-code-companion/web/app.js`

- [x] **Step 1: Add the Settings navigation item**

Insert:

```html
<button data-section="ssh-keys">SSH Key Inventory</button>
```

after GitHub in the Settings navigation group.

- [x] **Step 2: Register the title and renderer**

Add:

```javascript
'ssh-keys': 'SSH Key Inventory',
```

to `titles`, and:

```javascript
'ssh-keys': renderSSHKeyInventoryPage,
```

to the renderer map.

- [x] **Step 3: Add the dedicated page renderer and binder**

Add:

```javascript
function renderSSHKeyInventoryPage() {
  return '<div id="ssh-key-inventory-placeholder"></div>';
}

function bindSSHKeyInventoryPage() {
  loadSSHKeyInventory().then(keys => {
    const placeholder = document.getElementById('ssh-key-inventory-placeholder');
    if (placeholder) {
      placeholder.outerHTML = renderSSHKeyInventory(keys);
      bindSSHKeyInventory();
    }
  });
}
```

Bind it from `bindSectionActions`:

```javascript
if (section === 'ssh-keys') {
  bindSSHKeyInventoryPage();
}
```

- [x] **Step 4: Remove inventory loading from Projects**

Remove the inventory placeholder from `renderProjects()` and remove the
`loadSSHKeyInventory()` block from `bindProjects()`. Leave all project and
per-project SSH controls unchanged.

- [x] **Step 5: Run the static test to verify it passes**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: PASS.

- [x] **Step 6: Commit the UI relocation**

```bash
git add container-code-companion/web/index.html container-code-companion/web/app.js
git commit -m "feat: move SSH key inventory to settings"
```

### Task 3: Update User Documentation

**Files:**
- Modify: `docs/guides/ssh-key-management.md`

- [x] **Step 1: Change the documented navigation path**

Replace the Projects-page instruction with:

```markdown
Open **Settings > SSH Key Inventory** in the web UI.
```

- [x] **Step 2: Verify the old location is absent**

Run:

```bash
rg -n 'Open \\*\\*Projects\\*\\*|Settings > SSH Key Inventory' docs/guides/ssh-key-management.md
```

Expected: one match for the new Settings path and no match for the old Projects
instruction.

- [x] **Step 3: Commit the documentation update**

```bash
git add docs/guides/ssh-key-management.md
git commit -m "docs: update SSH key inventory location"
```

### Task 4: Full Verification

**Files:**
- Verify all modified files

- [ ] **Step 1: Run formatting and whitespace checks**

```bash
git diff --check HEAD~3..HEAD
```

Expected: no output and exit code 0.

- [ ] **Step 2: Run static and JavaScript tests**

```bash
bash tests/container-code-companion-static.sh
node tests/update-status-ui.test.mjs
```

Expected: both commands pass.

- [ ] **Step 3: Run Go tests**

```bash
cd container-code-companion && go test ./...
```

Expected: all packages pass.

- [ ] **Step 4: Inspect the final diff and status**

```bash
git status --short
git diff HEAD~3..HEAD -- container-code-companion/web/index.html container-code-companion/web/app.js tests/container-code-companion-static.sh docs/guides/ssh-key-management.md
```

Expected: only the intended relocation, tests, and documentation changes; the
pre-existing untracked `CLAUDE.md` remains untouched.
