# Agent Workstation Update Console Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mixed Updates page with a two-tab App/OS update console and fix fresh-container Git ownership failures.

**Architecture:** Keep the existing Go HTTP endpoints and CLI-backed update commands. Replace the frontend update renderer/binders with tab-specific state and outputs, then harden installer and self-update build commands around `/opt/agent-workstation-src`.

**Tech Stack:** Go standard library HTTP server, static JavaScript/CSS, Bash installer/update scripts, shell static tests.

---

### Task 1: Static Tests For Replacement UI And Git Hardening

**Files:**
- Modify: `tests/agent-workstation-static.sh`

- [ ] **Step 1: Write failing static assertions**

Add assertions requiring:

```bash
require_file_contains agent-workstation/web/app.js "let activeUpdateTab = 'app'"
require_file_contains agent-workstation/web/app.js "data-update-tab=\"app\""
require_file_contains agent-workstation/web/app.js "data-update-tab=\"os\""
require_file_contains agent-workstation/web/app.js "Update App"
require_file_contains agent-workstation/web/app.js "Update OS"
require_file_contains agent-workstation/web/app.js "renderUpdateConsole"
require_file_not_contains agent-workstation/web/app.js "Refresh Agent Workstation Status"
require_file_contains agent-workstation/web/styles.css ".update-tabs"
require_file_contains agent-workstation/web/styles.css ".update-console"
require_file_contains claude-code-commander.sh "-buildvcs=false"
require_file_contains claude-code-commander.sh "git config --system --replace-all safe.directory \"$AGENT_WORKSTATION_SRC\""
require_file_contains claude-code-commander.sh "git config --system --replace-all safe.directory \"$SRC\""
```

- [ ] **Step 2: Run static test and verify failure**

Run: `bash tests/agent-workstation-static.sh`

Expected: FAIL on one of the new missing update-console assertions.

- [ ] **Step 3: Commit after implementation passes**

Run:

```bash
git add tests/agent-workstation-static.sh agent-workstation/web/app.js agent-workstation/web/styles.css claude-code-commander.sh
git commit -m "feat(update): replace update console"
```

### Task 2: Replace Updates Page Frontend

**Files:**
- Modify: `agent-workstation/web/app.js`
- Modify: `agent-workstation/web/styles.css`

- [ ] **Step 1: Add update tab state**

Add:

```javascript
let activeUpdateTab = 'app';
```

- [ ] **Step 2: Replace `renderUpdates`**

Change `renderUpdates()` so it returns `renderUpdateConsole()`. Add helpers that render a stable tab bar and either the App or OS tab. The App tab owns `self-update-output`; the OS tab owns `action-output`.

- [ ] **Step 3: Bind tab and action clicks**

Update `bindUpdates()` so `[data-update-tab]` changes `activeUpdateTab` and re-renders, `#self-update-btn` runs the SSE self-update stream, and `#os-update-btn` runs `runAction('os-update')`.

- [ ] **Step 4: Add CSS**

Add `.update-console`, `.update-tabs`, `.update-tab`, `.update-tab.active`, `.update-summary`, and `.update-log-panel` styles using existing Prism variables.

- [ ] **Step 5: Run static test**

Run: `bash tests/agent-workstation-static.sh`

Expected: frontend assertions pass after Task 3 also completes.

### Task 3: Harden Installer And Self-Update Git/Build Path

**Files:**
- Modify: `claude-code-commander.sh`

- [ ] **Step 1: Harden `ccc-self-update` script**

In the `SELFUPDATESCRIPT` section, configure system-level safe-directory before Git commands when possible, keep inline `safe.directory`, and build with:

```bash
timeout 600 "$GO" build -buildvcs=false -C "$SRC/agent-workstation" -o "$BIN" ./cmd/server
```

- [ ] **Step 2: Harden fresh installer clone/build**

After the fresh clone to `$AGENT_WORKSTATION_SRC`, configure:

```bash
git config --system --replace-all safe.directory "$AGENT_WORKSTATION_SRC" 2>/dev/null || true
```

Build with:

```bash
timeout 600 /usr/local/go/bin/go build \
  -buildvcs=false \
  -C "$AGENT_WORKSTATION_SRC/agent-workstation" \
  -o /usr/local/bin/agent-workstation \
  ./cmd/server
```

- [ ] **Step 3: Verify embedded script syntax**

Run: `awk '/SELFUPDATESCRIPT/{flag=!flag; next} flag{print}' claude-code-commander.sh > /tmp/ccc-self-update.syntax && bash -n /tmp/ccc-self-update.syntax`

Expected: no output and exit 0.

### Task 4: Verification

**Files:**
- Verify only

- [ ] **Step 1: Run Go tests**

Run: `cd agent-workstation && go test ./...`

Expected: all packages pass.

- [ ] **Step 2: Run static suite**

Run: `bash tests/agent-workstation-static.sh`

Expected: no output and exit 0.

- [ ] **Step 3: Run diff hygiene**

Run: `git diff --check`

Expected: no whitespace errors.

- [ ] **Step 4: Commit if not already committed**

Commit any uncommitted implementation changes with a focused update message.
