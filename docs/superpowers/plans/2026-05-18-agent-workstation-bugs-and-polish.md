# Agent Workstation — Bugs, Polish & Branch Sync Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix terminal reconnect, self-update GUI, agent configs inline editor, network graph, account management, overview navigation, all code-review findings, sync `CCC_SELF_UPDATE_REF` to `main`, and push the branch as `main` — leaving the codebase ready for a theme pass.

**Architecture:** The service is a Go HTTP server (`agent-workstation/`) serving a vanilla JS SPA. Changes split cleanly between Go (server.go, terminal.go, management.go) and the frontend (app.js, styles.css). Tests live in server_test.go (Go table-style) and agent-workstation-static.sh (grep-based). Every backend fix gets a server_test.go test first; frontend fixes get static-check assertions.

**Tech Stack:** Go 1.22+, net/http, github.com/creack/pty, github.com/gorilla/websocket, vanilla JS (no bundler), Canvas API, CSS custom properties.

---

## Files Modified

| File | Responsibility |
|------|---------------|
| `claude-code-commander.sh` | Self-update ref (×2 locations), static Cockpit cleanup |
| `agent-workstation/internal/system/management.go` | `StartSelfUpdate` daemonization; `ParseMemInfo` tolerance |
| `agent-workstation/internal/server/server.go` | `handleOverview` method guard; cookie `Secure` flag |
| `agent-workstation/internal/server/terminal.go` | WebSocket `CheckOrigin` host validation |
| `agent-workstation/web/app.js` | Terminal reconnect; configs inline editor; overview badge link; `stripANSI`; `window.open` protocol; remove dead `formatPercent` |
| `agent-workstation/web/styles.css` | Inline config-editor panel styles |
| `agent-workstation/internal/server/server_test.go` | Tests for method guard, new endpoint behaviors |
| `tests/agent-workstation-static.sh` | Updated grep assertions |

---

## Task 1: Branch Sync — CCC_SELF_UPDATE_REF → main

**Files:**
- Modify: `claude-code-commander.sh:546` (global constant)
- Modify: `claude-code-commander.sh:1643` (embedded `ccc-self-update` default)
- Modify: `tests/agent-workstation-static.sh`

The self-update scripts reference branch `agent-workstation-native-ui` in two places. Changing both to `main` makes every deployed workstation pull from `main` after merge. The static test must assert `main` and forbid the old branch name.

- [ ] **Step 1: Change global constant (line 546)**

In `claude-code-commander.sh`, find:
```bash
CCC_SELF_UPDATE_REF="agent-workstation-native-ui"
```
Change to:
```bash
CCC_SELF_UPDATE_REF="main"
```

- [ ] **Step 2: Change embedded script default (line 1643)**

Find inside the `SELFUPDATESCRIPT` heredoc:
```bash
CCC_SELF_UPDATE_REF="${CCC_SELF_UPDATE_REF:-agent-workstation-native-ui}"
```
Change to:
```bash
CCC_SELF_UPDATE_REF="${CCC_SELF_UPDATE_REF:-main}"
```

- [ ] **Step 3: Update static checks**

In `tests/agent-workstation-static.sh`, add after the existing `require_file_contains` block:
```bash
require_file_contains claude-code-commander.sh 'CCC_SELF_UPDATE_REF="main"'
require_file_not_contains claude-code-commander.sh 'agent-workstation-native-ui'
```

- [ ] **Step 4: Run static checks**

```bash
bash tests/agent-workstation-static.sh
```
Expected: `agent-workstation static checks passed`

- [ ] **Step 5: Syntax checks**

```bash
bash -n claude-code-commander.sh
awk '/SELFUPDATESCRIPT/{flag=!flag; next} flag{print}' claude-code-commander.sh > /tmp/ccc-self-update.syntax && bash -n /tmp/ccc-self-update.syntax
```
Expected: no output (no errors)

- [ ] **Step 6: Commit**

```bash
git add claude-code-commander.sh tests/agent-workstation-static.sh
git commit -m "fix(update): set CCC_SELF_UPDATE_REF to main for post-merge self-update"
```

- [ ] **Step 7: Push branch as main on GitHub**

⚠️ **Confirm with user before running this step** — it force-pushes to `main`.

```bash
git push origin agent-workstation-native-ui:main --force-with-lease
git push origin agent-workstation-native-ui
```

The first push sets `origin/main` to the current branch tip. The second keeps the feature branch in sync.

---

## Task 2: Fix Terminal Reconnect on Refresh

**Files:**
- Modify: `agent-workstation/web/app.js`
- Modify: `tests/agent-workstation-static.sh`

**Root cause:** `renderSection` replaces `body.innerHTML`, destroying terminal pane DOM elements. When the terminal section is re-rendered (via the Refresh button or navigating away and back), the existing xterm.js instance is still alive but attached to a detached DOM node. `connectTerminal()` sees the WebSocket as `OPEN` and returns early without re-attaching xterm to the new DOM. The user sees a blank terminal that won't accept input.

**Fix:** Remove the `if (section !== 'terminal')` guard on `stopTerminalSessions()` in `renderSection`. Always tear down terminal resources before re-rendering. `bindTerminal()` auto-connects immediately after render, producing a fresh connection.

- [ ] **Step 1: Write failing static assertion**

In `tests/agent-workstation-static.sh`, add:
```bash
require_file_not_contains agent-workstation/web/app.js "section !== 'terminal') {"
```

Run:
```bash
bash tests/agent-workstation-static.sh
```
Expected: FAIL (`section !== 'terminal') {` is present in app.js)

- [ ] **Step 2: Fix renderSection in app.js**

Find in `app.js`:
```js
function renderSection(section) {
  const body = document.getElementById('section-body');
  if (section !== 'network') {
    stopNetworkGraph();
  }
  if (section !== 'terminal') {
    stopTerminalSessions();
  }
```
Replace with:
```js
function renderSection(section) {
  const body = document.getElementById('section-body');
  stopNetworkGraph();
  stopTerminalSessions();
```

- [ ] **Step 3: Verify auto-connect still works**

`bindTerminal()` already calls `connectTerminal()` at the end. After `stopTerminalSessions()` sets all `tab.socket = null`, `connectTerminal()` will not hit the early-return guards (`tab.socket.readyState === WebSocket.OPEN`). Confirm by reading:

```bash
grep -n "connectTerminal\|bindTerminal\|stopTerminalSessions" agent-workstation/web/app.js
```

Expected output includes `bindTerminal()` calling `connectTerminal()` as the last action, and `stopTerminalSessions()` in `renderSection` with no condition.

- [ ] **Step 4: Run static checks**

```bash
bash tests/agent-workstation-static.sh
node --check agent-workstation/web/app.js
```
Expected: both pass

- [ ] **Step 5: Commit**

```bash
git add agent-workstation/web/app.js tests/agent-workstation-static.sh
git commit -m "fix(terminal): always stop sessions before re-render to prevent blank terminal"
```

---

## Task 3: Fix Self-Update GUI ("Failed to fetch")

**Files:**
- Modify: `agent-workstation/internal/system/management.go`
- Modify: `agent-workstation/web/app.js`
- Modify: `agent-workstation/internal/server/server_test.go`
- Modify: `tests/agent-workstation-static.sh`

**Root cause (most likely):** The `StartSelfUpdate` command uses `nohup ... &` inside a `sudo bash -lc` shell. Some Linux/LXC environments configure sudo with `requiretty` or restrict running background processes without a controlling terminal. If the nohup fails silently, `ccc-self-update` never runs. The service remains up, but the log file is either empty or missing. The monitor never sees "Self-update successful" and eventually times out.

Additionally, the monitor's "Failed to fetch" display replaces the "Update started" message when the initial POST fails, causing confusion. The initial POST can fail if the service is mid-restart (from a previous update attempt) when the user clicks the button.

**Fix:**
1. In `StartSelfUpdate`, add `setsid` to ensure the update process survives any session/PTY cleanup and make the command more resilient.
2. Make `monitorSelfUpdate` not overwrite its own progress output when the initial POST fails — keep the progress display going.

- [ ] **Step 1: Write failing test in server_test.go**

Add to `server_test.go`:
```go
func TestSelfUpdateActionReturnsMonitorStartedMessage(t *testing.T) {
	started := false
	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		RunAction: func(action string) (system.CommandResult, error) {
			if action == "self-update" {
				started = true
				return system.CommandResult{
					Command:  "ccc-self-update",
					Output:   "Agent Workstation self-update monitor started.",
					ExitCode: 0,
				}, nil
			}
			return system.CommandResult{}, fmt.Errorf("unknown action: %s", action)
		},
	})
	req := httptest.NewRequest(http.MethodPost, "/api/action", strings.NewReader(`{"action":"self-update"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", res.Code, res.Body.String())
	}
	if !started {
		t.Fatal("expected RunAction to be called with self-update")
	}
	if !strings.Contains(res.Body.String(), "monitor started") {
		t.Fatalf("expected monitor started message, got %q", res.Body.String())
	}
}
```

Add `"fmt"` to imports if not already present.

Run:
```bash
cd agent-workstation && go test ./internal/server/ -run TestSelfUpdateActionReturnsMonitorStartedMessage -v
```
Expected: FAIL (`fmt` import may be missing)

- [ ] **Step 2: Add fmt import to server_test.go if missing**

Check: `grep '"fmt"' agent-workstation/internal/server/server_test.go`

If missing, add `"fmt"` to the import block.

Run test again:
```bash
cd agent-workstation && go test ./internal/server/ -run TestSelfUpdateActionReturnsMonitorStartedMessage -v
```
Expected: PASS (the action route is already wired correctly)

- [ ] **Step 3: Harden StartSelfUpdate in management.go**

Find in `management.go`:
```go
func StartSelfUpdate() (CommandResult, error) {
	command := "umask 022; touch /var/log/ccc-self-update.log; chmod 0644 /var/log/ccc-self-update.log; printf 'Agent Workstation self-update started at %s\\n' \"$(date -Is)\" > /var/log/ccc-self-update.log; nohup env NO_COLOR=1 ccc-self-update >> /var/log/ccc-self-update.log 2>&1 < /dev/null &"
	cmd := exec.Command("sudo", "bash", "-lc", command)
```
Replace the `command` variable:
```go
func StartSelfUpdate() (CommandResult, error) {
	logPath := "/var/log/ccc-self-update.log"
	command := "umask 022" +
		" && mkdir -p /var/log" +
		" && touch " + logPath +
		" && chmod 0644 " + logPath +
		" && printf 'Agent Workstation self-update started at %s\\n' \"$(date -Is)\" > " + logPath +
		" && setsid env NO_COLOR=1 ccc-self-update >> " + logPath + " 2>&1 < /dev/null &"
	cmd := exec.Command("sudo", "bash", "-lc", command)
```

`setsid` creates a new session, fully detaching the process from the controlling terminal so it survives the agent-workstation service restart.

- [ ] **Step 4: Improve self-update monitor in app.js — don't overwrite on initial POST failure**

Find in `app.js`:
```js
  } catch (error) {
    if (selfUpdate) {
      output.textContent = formatSelfUpdateProgress('Update request is reconnecting. Agent Workstation may be restarting...', 0, '');
      return;
    }
    output.textContent = stripANSI(error.message);
  }
```
Replace:
```js
  } catch (error) {
    if (selfUpdate) {
      return;
    }
    output.textContent = stripANSI(error.message);
  }
```

The monitor is already running in the background via `monitorSelfUpdate(output)`. If the POST fails (service restarting), the monitor catches the poll error and shows "reconnecting". Overwriting with a static message was stopping the live progress display.

- [ ] **Step 5: Static check assertion**

In `tests/agent-workstation-static.sh`, add:
```bash
require_file_contains agent-workstation/internal/system/management.go "setsid env NO_COLOR=1 ccc-self-update"
```

- [ ] **Step 6: Build and test**

```bash
cd agent-workstation && go test ./... && go build ./cmd/server
node --check agent-workstation/web/app.js
bash tests/agent-workstation-static.sh
```
Expected: all pass

- [ ] **Step 7: Commit**

```bash
git add agent-workstation/internal/system/management.go agent-workstation/internal/server/server_test.go agent-workstation/web/app.js tests/agent-workstation-static.sh
git commit -m "fix(update): use setsid for detached self-update; fix monitor not to overwrite progress"
```

---

## Task 4: Agent Configs Inline Editor

**Files:**
- Modify: `agent-workstation/web/app.js`
- Modify: `agent-workstation/web/styles.css`
- Modify: `tests/agent-workstation-static.sh`

**Root cause:** The "Edit" button in Agent Configs navigates away to the Files section. The user expects to edit in-place on the Configs page. We need an inline editor that loads, edits, and saves config files without leaving the section.

- [ ] **Step 1: Write failing static assertions**

In `tests/agent-workstation-static.sh`, add:
```bash
require_file_contains agent-workstation/web/app.js "config-editor-panel"
require_file_contains agent-workstation/web/app.js "showConfigEditor"
require_file_contains agent-workstation/web/app.js "saveConfigFile"
```

Run:
```bash
bash tests/agent-workstation-static.sh
```
Expected: FAIL (those identifiers don't exist yet)

- [ ] **Step 2: Rewrite renderConfigs in app.js**

Find:
```js
function renderConfigs() {
  const configs = snapshot.agentConfigs || [];
  if (!configs.length) return '<p>No agent config files found.</p>';
  return `
    <div class="config-list">
      ${configs.map(config => `
        <section class="config-row">
          <div>
            <strong>${escapeHTML(config.name)}</strong>
            <p>${escapeHTML(config.path)}</p>
            <span>${config.exists ? escapeHTML(formatBytes(config.size)) : 'missing'}</span>
          </div>
          <button class="small-button" data-config-edit="${escapeAttribute(config.path)}">Edit</button>
        </section>
      `).join('')}
    </div>
  `;
}
```

Replace with:
```js
function renderConfigs() {
  const configs = snapshot.agentConfigs || [];
  if (!configs.length) return '<p>No agent config files found.</p>';
  return `
    <div class="config-list">
      ${configs.map(config => `
        <section class="config-row">
          <div>
            <strong>${escapeHTML(config.name)}</strong>
            <p>${escapeHTML(config.path)}</p>
            <span>${config.exists ? escapeHTML(formatBytes(config.size)) : 'missing'}</span>
          </div>
          <button class="small-button" data-config-edit="${escapeAttribute(config.path)}">Edit</button>
        </section>
      `).join('')}
    </div>
    <div id="config-editor-panel" class="config-editor-panel" hidden>
      <div class="config-editor-header">
        <strong id="config-editor-title"></strong>
        <div class="action-row">
          <button id="config-editor-save" class="small-button">Save</button>
          <button id="config-editor-cancel" class="small-button">Cancel</button>
        </div>
      </div>
      <textarea id="config-editor-textarea" class="config-editor-textarea" spellcheck="false"></textarea>
      <pre id="config-editor-output" class="output" hidden></pre>
    </div>
  `;
}
```

- [ ] **Step 3: Rewrite bindConfigs in app.js**

Find:
```js
function bindConfigs() {
  document.querySelectorAll('[data-config-edit]').forEach(button => {
    button.addEventListener('click', () => openAgentConfig(button.dataset.configEdit));
  });
}

function openAgentConfig(path) {
  if (!path) return;
  filePath = directoryName(path);
  currentFile = path;
  selectSection('files');
  openFile(path);
}
```

Replace with:
```js
function bindConfigs() {
  document.querySelectorAll('[data-config-edit]').forEach(button => {
    button.addEventListener('click', () => showConfigEditor(button.dataset.configEdit));
  });
  const saveBtn = document.getElementById('config-editor-save');
  const cancelBtn = document.getElementById('config-editor-cancel');
  if (saveBtn) saveBtn.addEventListener('click', saveConfigFile);
  if (cancelBtn) cancelBtn.addEventListener('click', hideConfigEditor);
}

async function showConfigEditor(path) {
  const panel = document.getElementById('config-editor-panel');
  const title = document.getElementById('config-editor-title');
  const textarea = document.getElementById('config-editor-textarea');
  const output = document.getElementById('config-editor-output');
  if (!panel) return;
  panel.hidden = false;
  output.hidden = true;
  textarea.value = '';
  title.textContent = path;
  textarea.dataset.path = path;
  textarea.placeholder = 'Loading...';
  try {
    const response = await fetch(`/api/file?path=${encodeURIComponent(path)}`, { credentials: 'include' });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || `Request failed with ${response.status}`);
    textarea.value = data.content;
    textarea.placeholder = '';
    textarea.focus();
  } catch (error) {
    output.hidden = false;
    output.textContent = error.message;
  }
}

async function saveConfigFile() {
  const textarea = document.getElementById('config-editor-textarea');
  const output = document.getElementById('config-editor-output');
  const path = textarea?.dataset.path;
  if (!path) return;
  output.hidden = false;
  output.textContent = 'Saving...';
  try {
    await postJSON('/api/file', { path, content: textarea.value }, 'PUT');
    output.textContent = 'Saved.';
    await loadSnapshot();
  } catch (error) {
    output.textContent = error.message;
  }
}

function hideConfigEditor() {
  const panel = document.getElementById('config-editor-panel');
  if (panel) panel.hidden = true;
}

function openAgentConfig(path) {
  if (!path) return;
  filePath = directoryName(path);
  currentFile = path;
  selectSection('files');
  openFile(path);
}
```

- [ ] **Step 4: Add CSS for the inline editor in styles.css**

Append to `styles.css`:
```css
.config-editor-panel {
  margin-top: 16px;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--panel);
  overflow: hidden;
}

.config-editor-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 10px 14px;
  border-bottom: 1px solid var(--border);
  background: #1b1e22;
}

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

.config-editor-textarea:focus {
  outline: none;
  box-shadow: inset 0 0 0 2px var(--accent);
}
```

- [ ] **Step 5: Run static checks and build**

```bash
bash tests/agent-workstation-static.sh
node --check agent-workstation/web/app.js
```
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add agent-workstation/web/app.js agent-workstation/web/styles.css tests/agent-workstation-static.sh
git commit -m "feat(configs): add inline editor for agent config files on configs page"
```

---

## Task 5: Account Management — Validate and Verify

**Files:**
- Modify: `agent-workstation/web/app.js`
- Modify: `tests/agent-workstation-static.sh`

The accounts section already has create/modify/delete handlers but provides no client-side validation before submitting. Empty username submissions produce backend validation errors that aren't surfaced clearly. Add basic client-side guards to give immediate feedback.

- [ ] **Step 1: Write failing static assertion**

In `tests/agent-workstation-static.sh`, add:
```bash
require_file_contains agent-workstation/web/app.js "username is required"
```

Run:
```bash
bash tests/agent-workstation-static.sh
```
Expected: FAIL

- [ ] **Step 2: Add client-side validation to createAccount in app.js**

Find:
```js
async function createAccount() {
  await runAccountOperation({
    operation: 'create',
    username: document.getElementById('account-username').value.trim(),
    password: document.getElementById('account-password').value,
    shell: document.getElementById('account-shell').value.trim() || '/bin/bash',
  });
}
```

Replace with:
```js
async function createAccount() {
  const username = document.getElementById('account-username').value.trim();
  const output = document.getElementById('account-output');
  if (!username) {
    output.hidden = false;
    output.textContent = 'Error: username is required';
    return;
  }
  await runAccountOperation({
    operation: 'create',
    username,
    password: document.getElementById('account-password').value,
    shell: document.getElementById('account-shell').value.trim() || '/bin/bash',
  });
}
```

- [ ] **Step 3: Also clear password field after successful account creation**

In `runAccountOperation`, after the success branch, clear the username/password fields if the operation was `create`:

Find:
```js
async function runAccountOperation(payload) {
  const output = document.getElementById('account-output');
  output.hidden = false;
  output.textContent = 'Running...';
  try {
    const result = await postJSON('/api/account', payload);
    output.textContent = result.output || 'account updated';
    await loadSnapshot();
    renderSection('accounts');
  } catch (error) {
    output.textContent = error.message;
  }
}
```

Replace with:
```js
async function runAccountOperation(payload) {
  const output = document.getElementById('account-output');
  output.hidden = false;
  output.textContent = 'Running...';
  try {
    const result = await postJSON('/api/account', payload);
    output.textContent = result.output || 'account updated';
    if (payload.operation === 'create') {
      const usernameEl = document.getElementById('account-username');
      const passwordEl = document.getElementById('account-password');
      if (usernameEl) usernameEl.value = '';
      if (passwordEl) passwordEl.value = '';
    }
    await loadSnapshot();
    renderSection('accounts');
  } catch (error) {
    output.textContent = error.message;
  }
}
```

- [ ] **Step 4: Run checks**

```bash
bash tests/agent-workstation-static.sh
node --check agent-workstation/web/app.js
```
Expected: pass

- [ ] **Step 5: Commit**

```bash
git add agent-workstation/web/app.js tests/agent-workstation-static.sh
git commit -m "fix(accounts): add client-side username validation and clear form after create"
```

---

## Task 6: Overview Update Badge → Clickable Navigation

**Files:**
- Modify: `agent-workstation/web/app.js`
- Modify: `tests/agent-workstation-static.sh`

The Overview dashboard shows an update status badge. When the status is not "Current", users should be able to click it to jump to the Updates section.

- [ ] **Step 1: Write failing static assertion**

In `tests/agent-workstation-static.sh`, add:
```bash
require_file_contains agent-workstation/web/app.js "selectSection('updates')"
```

Run:
```bash
bash tests/agent-workstation-static.sh
```
Expected: FAIL (not yet in app.js, or only in bindProjects — need it in the overview context)

Actually `selectSection('updates')` might not exist anywhere yet. Check:
```bash
grep "selectSection('updates')" agent-workstation/web/app.js
```

- [ ] **Step 2: Replace the static badge in renderOverview with a button**

Find in `app.js` inside `renderOverview()`:
```js
          <span class="badge ${updateBadge === 'Current' ? 'ok' : updateBadge === 'Updates available' ? 'warn' : ''}">${escapeHTML(updateBadge)}</span>
```
Replace with:
```js
          <button class="badge badge-link ${updateBadge === 'Current' ? 'ok' : updateBadge === 'Updates available' ? 'warn' : ''}" data-nav-updates>${escapeHTML(updateBadge)}</button>
```

- [ ] **Step 3: Bind the badge navigation in bindSectionActions**

Find in `bindSectionActions`:
```js
  document.querySelectorAll('[data-action]').forEach(button => {
    button.addEventListener('click', () => runAction(button.dataset.action));
  });
```
Add after it:
```js
  document.querySelectorAll('[data-nav-updates]').forEach(button => {
    button.addEventListener('click', () => selectSection('updates'));
  });
```

- [ ] **Step 4: Add badge-link CSS in styles.css**

Find in `styles.css` the `.badge` rule (or add near it):
```css
.badge-link {
  cursor: pointer;
  border: none;
  font: inherit;
}

.badge-link:hover {
  opacity: 0.85;
}
```

- [ ] **Step 5: Run checks**

```bash
bash tests/agent-workstation-static.sh
node --check agent-workstation/web/app.js
```
Expected: pass

- [ ] **Step 6: Commit**

```bash
git add agent-workstation/web/app.js agent-workstation/web/styles.css tests/agent-workstation-static.sh
git commit -m "feat(overview): make update badge a clickable link to the Updates section"
```

---

## Task 7: Network Graph — Verify and Improve

**Files:**
- Modify: `agent-workstation/web/app.js`
- Modify: `agent-workstation/web/styles.css`

The network graph already exists as a Canvas element polled every 2s. Ensure it is visually clear: add a legend, verify the canvas dimensions are responsive, and confirm polling resumes correctly when re-entering the Network section.

- [ ] **Step 1: Check current graph render**

```bash
grep -n "network-graph\|drawNetworkGraph\|drawNetworkSeries\|canvas" agent-workstation/web/app.js | head -20
```

Verify that `drawNetworkGraph` and `drawNetworkSeries` exist and the canvas background/colors are set.

- [ ] **Step 2: Add a legend below the canvas in renderNetwork**

Find:
```js
function renderNetwork() {
  return `
    <h3>Activity</h3>
    <div class="network-graph-wrap">
      <canvas id="network-graph" width="900" height="220"></canvas>
      <div id="network-rate">Collecting network samples...</div>
    </div>
```
Replace with:
```js
function renderNetwork() {
  return `
    <h3>Activity</h3>
    <div class="network-graph-wrap">
      <canvas id="network-graph" width="900" height="220"></canvas>
      <div class="network-legend">
        <span class="network-legend-rx">&#9644; Download (RX)</span>
        <span class="network-legend-tx">&#9644; Upload (TX)</span>
        <span id="network-rate">Collecting samples...</span>
      </div>
    </div>
```

- [ ] **Step 3: Add legend CSS in styles.css**

Add after `.network-graph-wrap` (or append at end):
```css
.network-graph-wrap {
  overflow-x: auto;
}

.network-graph-wrap canvas {
  display: block;
  max-width: 100%;
  border-radius: 4px;
}

.network-legend {
  display: flex;
  gap: 20px;
  padding: 6px 4px;
  font-size: 12px;
  color: var(--muted);
}

.network-legend-rx { color: #68a6f8; }
.network-legend-tx { color: #34d399; }
```

- [ ] **Step 4: Ensure stopNetworkGraph is correct**

The `stopNetworkGraph` / `bindNetwork` pair was already verified as correct. Confirm that navigating away from Network stops polling and navigating back starts fresh:

```bash
grep -n "stopNetworkGraph\|bindNetwork\|networkPollTimer" agent-workstation/web/app.js
```

Expected: `stopNetworkGraph` is called in `renderSection` (now unconditionally after Task 2), and `bindNetwork` starts fresh polling.

- [ ] **Step 5: Static check**

In `tests/agent-workstation-static.sh`, add:
```bash
require_file_contains agent-workstation/web/app.js "network-legend"
```

Run:
```bash
bash tests/agent-workstation-static.sh
node --check agent-workstation/web/app.js
```
Expected: pass

- [ ] **Step 6: Commit**

```bash
git add agent-workstation/web/app.js agent-workstation/web/styles.css tests/agent-workstation-static.sh
git commit -m "feat(network): add RX/TX legend and improve graph layout"
```

---

## Task 8: Code Review Fixes — Security and Correctness

**Files:**
- Modify: `agent-workstation/internal/server/server.go`
- Modify: `agent-workstation/internal/server/terminal.go`
- Modify: `agent-workstation/internal/system/management.go`
- Modify: `agent-workstation/web/app.js`
- Modify: `agent-workstation/internal/server/server_test.go`
- Modify: `tests/agent-workstation-static.sh`

Eight discrete fixes grouped in one commit for efficiency.

### 8a. handleOverview method guard

- [ ] **Step 1: Write failing test**

In `server_test.go`, add:
```go
func TestOverviewRejectsNonGetMethod(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/overview", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", res.Code)
	}
}
```

Run:
```bash
cd agent-workstation && go test ./internal/server/ -run TestOverviewRejectsNonGetMethod -v
```
Expected: FAIL (currently returns 200)

- [ ] **Step 2: Add method guard to handleOverview in server.go**

Find:
```go
func (s *Server) handleOverview(w http.ResponseWriter, _ *http.Request) {
	overview, err := s.overview()
```
Replace:
```go
func (s *Server) handleOverview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	overview, err := s.overview()
```

Run:
```bash
cd agent-workstation && go test ./internal/server/ -run TestOverviewRejectsNonGetMethod -v
```
Expected: PASS

### 8b. stripANSI regex fix

- [ ] **Step 3: Write failing static assertion**

In `tests/agent-workstation-static.sh`, add:
```bash
require_file_contains agent-workstation/web/app.js '\x1b\['
require_file_not_contains agent-workstation/web/app.js '(?:\x1b)?'
```

Run:
```bash
bash tests/agent-workstation-static.sh
```
Expected: FAIL

- [ ] **Step 4: Fix stripANSI regex in app.js**

Find:
```js
function stripANSI(value) {
  return String(value || '').replace(/(?:\x1b)?\[[0-9;]*m/g, '');
}
```
Replace:
```js
function stripANSI(value) {
  return String(value || '').replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
}
```

This correctly matches `ESC[` followed by optional params and a terminal letter, covering all standard ANSI control sequences (not just the `m` SGR terminator).

### 8c. window.open protocol fix

- [ ] **Step 5: Write failing static assertion**

In `tests/agent-workstation-static.sh`, add:
```bash
require_file_not_contains agent-workstation/web/app.js '`http://${location.hostname}'
```

Run:
```bash
bash tests/agent-workstation-static.sh
```
Expected: FAIL

- [ ] **Step 6: Fix window.open in app.js**

Find:
```js
      window.open(`http://${location.hostname}:8080/?folder=${encodeURIComponent(button.dataset.projectOpen)}`, '_blank');
```
Replace:
```js
      window.open(`${location.protocol}//${location.hostname}:8080/?folder=${encodeURIComponent(button.dataset.projectOpen)}`, '_blank');
```

### 8d. Remove dead formatPercent

- [ ] **Step 7: Remove unused formatPercent from app.js**

Find and delete:
```js
function formatPercent(value) {
  return typeof value === 'number' ? `${value.toFixed(1)}% used` : 'unknown';
}
```

Verify it's not called anywhere:
```bash
grep "formatPercent" agent-workstation/web/app.js
```
Expected: no output after deletion.

### 8e. WebSocket CheckOrigin — validate host

- [ ] **Step 8: Fix CheckOrigin in terminal.go**

Find:
```go
var ptyUpgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}
```
Replace:
```go
var ptyUpgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		if origin == "" {
			return true
		}
		return strings.HasPrefix(origin, "http://"+r.Host) ||
			strings.HasPrefix(origin, "https://"+r.Host)
	},
}
```

Add `"strings"` to the import block of `terminal.go` if not already present.

### 8f. Cookie Secure flag (HTTPS-aware)

- [ ] **Step 9: Make sessionCookie Secure when served over HTTPS in server.go**

The server doesn't know at startup whether TLS is in use (TLS termination happens upstream). Add a `Secure` field to `Config` so the binary can be passed `--secure` if running behind HTTPS:

In `server.go`, find `Config` struct and add a field:
```go
type Config struct {
	SessionToken     string
	Username         string
	Password         string
	WebDir           string
	SecureCookies    bool   // set true when serving behind HTTPS
	...
```

Add to `Server` struct:
```go
type Server struct {
	...
	secureCookies    bool
```

In `New`:
```go
	s := &Server{
		...
		secureCookies:    config.SecureCookies,
```

Update `sessionCookie`:
```go
func (s *Server) sessionCookie(value string, maxAge int) *http.Cookie {
	return &http.Cookie{
		Name:     SessionCookieName,
		Value:    value,
		Path:     "/",
		HttpOnly: true,
		Secure:   s.secureCookies,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   maxAge,
	}
}
```

Update callers — find `sessionCookie(` in `server.go` and replace with `s.sessionCookie(`:
- `handleLogin`: `http.SetCookie(w, sessionCookie(s.sessionToken, 0))` → `http.SetCookie(w, s.sessionCookie(s.sessionToken, 0))`
- `handleLogout`: `http.SetCookie(w, sessionCookie("", -1))` → `http.SetCookie(w, s.sessionCookie("", -1))`

Remove the package-level `sessionCookie` function and replace with the method above.

Update `server_test.go` — `newTestServer()` doesn't need `SecureCookies` set (defaults false, matching existing test assertions).

### 8g. ParseMemInfo — skip non-numeric fields

- [ ] **Step 10: Make ParseMemInfo tolerant of non-numeric lines in management.go**

Find in `overview.go` (note: `ParseMemInfo` is in `overview.go`, not `management.go`):
```go
func ParseMemInfo(input string) (MemoryInfo, error) {
	values := map[string]uint64{}
	for _, line := range strings.Split(input, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		key := strings.TrimSuffix(fields[0], ":")
		value, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			return MemoryInfo{}, fmt.Errorf("parse %s: %w", key, err)
		}
		values[key] = value * 1024
	}
```
Replace:
```go
func ParseMemInfo(input string) (MemoryInfo, error) {
	values := map[string]uint64{}
	for _, line := range strings.Split(input, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		key := strings.TrimSuffix(fields[0], ":")
		value, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			continue
		}
		values[key] = value * 1024
	}
```

MemTotal being absent is still a hard error (checked below). All other non-numeric lines are silently skipped.

- [ ] **Step 11: Run all tests and static checks**

```bash
cd agent-workstation && go test ./... && go build ./cmd/server
bash tests/agent-workstation-static.sh
node --check agent-workstation/web/app.js
```
Expected: all pass

- [ ] **Step 12: Commit**

```bash
git add \
  agent-workstation/internal/server/server.go \
  agent-workstation/internal/server/terminal.go \
  agent-workstation/internal/system/overview.go \
  agent-workstation/web/app.js \
  agent-workstation/internal/server/server_test.go \
  tests/agent-workstation-static.sh
git commit -m "fix(security): method guard, WebSocket origin check, cookie Secure flag, stripANSI, window.open protocol, remove dead formatPercent"
```

---

## Task 9: Final Verification Pass

**Files:** None modified — verification only.

- [ ] **Step 1: Full test suite**

```bash
cd agent-workstation && go test ./... -v 2>&1 | tail -30
```
Expected: all PASS, no FAIL lines.

- [ ] **Step 2: Build**

```bash
cd agent-workstation && go build ./cmd/server
rm -f server
```
Expected: binary produced, no errors.

- [ ] **Step 3: Static checks**

```bash
bash tests/agent-workstation-static.sh
```
Expected: `agent-workstation static checks passed`

- [ ] **Step 4: JS syntax**

```bash
node --check agent-workstation/web/app.js
```
Expected: no output

- [ ] **Step 5: Shell syntax**

```bash
bash -n claude-code-commander.sh
awk '/SELFUPDATESCRIPT/{flag=!flag; next} flag{print}' claude-code-commander.sh > /tmp/ccc-self-update.syntax && bash -n /tmp/ccc-self-update.syntax
```
Expected: no output

- [ ] **Step 6: Update HANDOFF.md**

Update `HANDOFF.md` to reflect completed work:
- Self-update GUI fix and setsid approach
- Terminal reconnect fix (always stop on re-render)
- Configs inline editor added
- Overview badge → Updates link
- Network graph legend added
- Account create validation added
- All code-review items addressed
- `CCC_SELF_UPDATE_REF` is now `main`
- Next task: theme implementation (styles.css)
- Note: push to `origin/main` needed before self-update can be validated on deployed LXC

- [ ] **Step 7: Final push**

```bash
git push origin agent-workstation-native-ui
```

If Task 1 Step 7 (push to main) was done earlier, also verify:
```bash
git log --oneline origin/main -5
```

---

## Self-Review

**Spec coverage:**
- ✅ Branch sync (Task 1)
- ✅ Self-update GUI (Task 3)
- ✅ Terminal reconnect (Task 2)
- ✅ Agent Configs inline editor (Task 4)
- ✅ Account management validation (Task 5)
- ✅ Network graph improvement (Task 7)
- ✅ Overview → Updates link (Task 6)
- ✅ Code review: stripANSI, window.open, handleOverview, WebSocket origin, cookie Secure, formatPercent, ParseMemInfo (Task 8)

**Placeholder scan:** No TBD, no "implement later". All code blocks are complete.

**Type consistency:** `showConfigEditor`, `saveConfigFile`, `hideConfigEditor` are consistent across all references. `s.sessionCookie` replaces the package-level function everywhere it was called.
