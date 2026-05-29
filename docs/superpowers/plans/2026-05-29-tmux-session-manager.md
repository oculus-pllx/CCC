# Tmux Session Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tmux session manager inside each account row in the CCC Accounts panel, with List, Attach, Rename, Send Keys, Kill, New Session, and Kill All actions.

**Architecture:** Backend adds `TmuxSession` type and `ListTmuxSessions()` to `management.go`, populates it in `collectAccounts()`, and handles five new `AccountOperation` cases. Frontend renders a `TMUX SESSIONS` block inside each account row in `renderAccounts()` with inline inputs for Rename/Send Keys and confirm flows for Kill/Kill All. Attach switches to the Terminal section and injects the attach command.

**Tech Stack:** Go (backend), vanilla JS (frontend), tmux CLI, existing `/api/account` endpoint.

---

## File Map

| File | Change |
|------|--------|
| `container-code-companion/internal/system/management.go` | Add `TmuxSession` type, extend `AccountStatus` and `AccountOperation`, add `ListTmuxSessions()`, update `collectAccounts()`, add 5 operation cases to `RunAccountOperation()` |
| `container-code-companion/internal/system/management_test.go` | Add `TestParseTmuxOutput` and `TestListTmuxSessionsNoServer` |
| `container-code-companion/web/app.js` | Add `renderTmuxSessions()`, update `renderAccounts()` to call it, add event handlers for all 6 actions |

---

### Task 1: Add TmuxSession type and extend AccountStatus / AccountOperation

**Files:**
- Modify: `container-code-companion/internal/system/management.go:80-88` (AccountStatus)
- Modify: `container-code-companion/internal/system/management.go:263-271` (AccountOperation)

- [ ] **Step 1: Add the TmuxSession struct and extend AccountStatus**

In `management.go`, after the closing `}` of `AccountStatus` (currently line 88), add:

```go
type TmuxSession struct {
	Name            string `json:"name"`
	Windows         int    `json:"windows"`
	AttachedClients int    `json:"attachedClients"`
	IdleSeconds     int    `json:"idleSeconds"`
}
```

And extend `AccountStatus` to include:
```go
type AccountStatus struct {
	Username     string            `json:"username"`
	UID          string            `json:"uid"`
	Groups       string            `json:"groups"`
	Home         string            `json:"home"`
	Shell        string            `json:"shell"`
	AgentConfigs []AgentConfigFile `json:"agentConfigs"`
	Plugins      []PluginEntry     `json:"plugins"`
	TmuxSessions []TmuxSession     `json:"tmuxSessions"`
}
```

- [ ] **Step 2: Extend AccountOperation with tmux fields**

Replace the existing `AccountOperation` struct:
```go
type AccountOperation struct {
	Operation   string `json:"operation"`
	Username    string `json:"username"`
	Password    string `json:"password"`
	Shell       string `json:"shell"`
	Groups      string `json:"groups"`
	Plugin      string `json:"plugin"`
	Enabled     bool   `json:"enabled"`
	SessionName string `json:"sessionName"`
	NewName     string `json:"newName"`
	Keys        string `json:"keys"`
}
```

- [ ] **Step 3: Build to verify no compile errors**

```bash
cd /srv/ccc/projects/CCC/container-code-companion && go build ./...
```
Expected: no output (clean build).

- [ ] **Step 4: Commit**

```bash
git -C /srv/ccc/projects/CCC add container-code-companion/internal/system/management.go
git -C /srv/ccc/projects/CCC commit -m "feat: add TmuxSession type and extend AccountStatus/AccountOperation"
```

---

### Task 2: Implement ListTmuxSessions and tests

**Files:**
- Modify: `container-code-companion/internal/system/management.go` (add function)
- Modify: `container-code-companion/internal/system/management_test.go` (add tests)

- [ ] **Step 1: Write the failing tests**

Add to `management_test.go`:

```go
func TestParseTmuxOutput(t *testing.T) {
	input := "work|2|1|1748000000\nscratch|1|0|1747999500\n"
	now := int64(1748000300)
	got := parseTmuxOutput(input, now)
	if len(got) != 2 {
		t.Fatalf("expected 2 sessions, got %d", len(got))
	}
	if got[0].Name != "work" {
		t.Errorf("got[0].Name = %q, want %q", got[0].Name, "work")
	}
	if got[0].Windows != 2 {
		t.Errorf("got[0].Windows = %d, want 2", got[0].Windows)
	}
	if got[0].AttachedClients != 1 {
		t.Errorf("got[0].AttachedClients = %d, want 1", got[0].AttachedClients)
	}
	if got[0].IdleSeconds != 300 {
		t.Errorf("got[0].IdleSeconds = %d, want 300", got[0].IdleSeconds)
	}
	if got[1].Name != "scratch" {
		t.Errorf("got[1].Name = %q, want %q", got[1].Name, "scratch")
	}
	if got[1].AttachedClients != 0 {
		t.Errorf("got[1].AttachedClients = %d, want 0", got[1].AttachedClients)
	}
	if got[1].IdleSeconds != 800 {
		t.Errorf("got[1].IdleSeconds = %d, want 800", got[1].IdleSeconds)
	}
}

func TestParseTmuxOutputEmpty(t *testing.T) {
	got := parseTmuxOutput("", time.Now().Unix())
	if len(got) != 0 {
		t.Fatalf("expected 0 sessions, got %d", len(got))
	}
}

func TestParseTmuxOutputMalformedLineSkipped(t *testing.T) {
	input := "work|2|1|1748000000\nbadline\nscratch|1|0|1747999500\n"
	got := parseTmuxOutput(input, time.Now().Unix())
	if len(got) != 2 {
		t.Fatalf("expected 2 sessions (bad line skipped), got %d", len(got))
	}
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/... -run "TestParseTmux" -v
```
Expected: `FAIL` — `parseTmuxOutput` undefined.

- [ ] **Step 3: Implement parseTmuxOutput and ListTmuxSessions**

Add to `management.go` (after `collectAccounts`, around line 1923):

```go
// parseTmuxOutput parses the output of:
//   tmux list-sessions -F "#{session_name}|#{session_windows}|#{session_attached}|#{session_activity}"
// nowUnix is used to compute IdleSeconds; pass time.Now().Unix() in production.
func parseTmuxOutput(output string, nowUnix int64) []TmuxSession {
	var sessions []TmuxSession
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		if line == "" {
			continue
		}
		parts := strings.Split(line, "|")
		if len(parts) != 4 {
			continue
		}
		windows, _ := strconv.Atoi(parts[1])
		attached, _ := strconv.Atoi(parts[2])
		activity, _ := strconv.ParseInt(parts[3], 10, 64)
		idle := 0
		if activity > 0 && nowUnix > activity {
			idle = int(nowUnix - activity)
		}
		sessions = append(sessions, TmuxSession{
			Name:            parts[0],
			Windows:         windows,
			AttachedClients: attached,
			IdleSeconds:     idle,
		})
	}
	return sessions
}

// ListTmuxSessions returns active tmux sessions for username.
// Returns an empty slice (never an error) if tmux has no server running.
func ListTmuxSessions(username string) []TmuxSession {
	cmd := exec.Command("sudo", "-u", username,
		"tmux", "list-sessions", "-F",
		"#{session_name}|#{session_windows}|#{session_attached}|#{session_activity}")
	out, err := cmd.Output()
	if err != nil {
		// tmux exits non-zero when no server is running — not an error for us
		return []TmuxSession{}
	}
	return parseTmuxOutput(string(out), time.Now().Unix())
}
```

Make sure `"os/exec"` and `"time"` are in the import block (both are already present).

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/... -run "TestParseTmux" -v
```
Expected:
```
--- PASS: TestParseTmuxOutput (0.00s)
--- PASS: TestParseTmuxOutputEmpty (0.00s)
--- PASS: TestParseTmuxOutputMalformedLineSkipped (0.00s)
PASS
```

- [ ] **Step 5: Confirm full test suite still passes**

```bash
cd /srv/ccc/projects/CCC/container-code-companion && go test ./...
```
Expected: `ok` for all packages.

- [ ] **Step 6: Commit**

```bash
git -C /srv/ccc/projects/CCC add container-code-companion/internal/system/management.go container-code-companion/internal/system/management_test.go
git -C /srv/ccc/projects/CCC commit -m "feat: add ListTmuxSessions and parseTmuxOutput with tests"
```

---

### Task 3: Wire ListTmuxSessions into collectAccounts

**Files:**
- Modify: `container-code-companion/internal/system/management.go` (collectAccounts)

- [ ] **Step 1: Update collectAccounts to populate TmuxSessions**

Replace the `accounts = append(...)` block in `collectAccounts()` (currently lines 1912-1920):

```go
accounts = append(accounts, AccountStatus{
	Username:     fields[0],
	UID:          fields[2],
	Groups:       strings.TrimSpace(runText("id", "-nG", fields[0])),
	Home:         home,
	Shell:        fields[6],
	AgentConfigs: collectAgentConfigs(home),
	Plugins:      collectPluginStatus(home),
	TmuxSessions: ListTmuxSessions(fields[0]),
})
```

- [ ] **Step 2: Build to verify**

```bash
cd /srv/ccc/projects/CCC/container-code-companion && go build ./...
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git -C /srv/ccc/projects/CCC add container-code-companion/internal/system/management.go
git -C /srv/ccc/projects/CCC commit -m "feat: populate TmuxSessions in collectAccounts snapshot"
```

---

### Task 4: Add tmux operation cases to RunAccountOperation

**Files:**
- Modify: `container-code-companion/internal/system/management.go` (RunAccountOperation)

- [ ] **Step 1: Add the five tmux cases**

In `RunAccountOperation`, add these cases before the `default:` line (currently around line 640):

```go
case "tmux-new":
	if !safeProjectName(operation.SessionName) {
		return CommandResult{}, errors.New("valid session name is required")
	}
	home := "/home/" + operation.Username
	return RunShellCommand("sudo -u "+shellQuote(operation.Username)+" env HOME="+shellQuote(home)+" tmux new-session -d -s "+shellQuote(operation.SessionName), workstationHome())
case "tmux-kill":
	if operation.SessionName == "" {
		return CommandResult{}, errors.New("session name is required")
	}
	return RunShellCommand("sudo -u "+shellQuote(operation.Username)+" tmux kill-session -t "+shellQuote(operation.SessionName), workstationHome())
case "tmux-kill-all":
	return RunShellCommand("sudo -u "+shellQuote(operation.Username)+" tmux kill-server", workstationHome())
case "tmux-rename":
	if operation.SessionName == "" || operation.NewName == "" {
		return CommandResult{}, errors.New("session name and new name are required")
	}
	if !safeProjectName(operation.NewName) {
		return CommandResult{}, errors.New("invalid new session name")
	}
	return RunShellCommand("sudo -u "+shellQuote(operation.Username)+" tmux rename-session -t "+shellQuote(operation.SessionName)+" "+shellQuote(operation.NewName), workstationHome())
case "tmux-send-keys":
	if operation.SessionName == "" || operation.Keys == "" {
		return CommandResult{}, errors.New("session name and keys are required")
	}
	return RunShellCommand("sudo -u "+shellQuote(operation.Username)+" tmux send-keys -t "+shellQuote(operation.SessionName)+" "+shellQuote(operation.Keys)+" Enter", workstationHome())
```

- [ ] **Step 2: Build to verify**

```bash
cd /srv/ccc/projects/CCC/container-code-companion && go build ./...
```
Expected: clean.

- [ ] **Step 3: Run full test suite**

```bash
cd /srv/ccc/projects/CCC/container-code-companion && go test ./...
```
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git -C /srv/ccc/projects/CCC add container-code-companion/internal/system/management.go
git -C /srv/ccc/projects/CCC commit -m "feat: add tmux-new/kill/kill-all/rename/send-keys account operations"
```

---

### Task 5: Frontend — renderTmuxSessions helper

**Files:**
- Modify: `container-code-companion/web/app.js`

- [ ] **Step 1: Add the renderTmuxSessions function**

Add this function to `app.js` immediately before `renderAccounts()` (currently around line 403):

```js
function renderTmuxSessions(account) {
  const sessions = account.tmuxSessions || [];
  const username = account.username;

  const sessionRows = sessions.map(s => {
    const dot = s.attachedClients > 0
      ? '<span style="color:#6db86d">●</span>'
      : '<span style="color:#555">○</span>';
    const statusLabel = s.attachedClients > 0
      ? '<span class="badge ok">attached</span>'
      : `<span class="muted">idle ${idleLabel(s.idleSeconds)}</span>`;
    const winLabel = `<span class="muted">${s.windows} ${s.windows === 1 ? 'window' : 'windows'}</span>`;
    const name = escapeHTML(s.name);
    const nameAttr = escapeAttribute(s.name);
    return `
      <div class="tmux-session-row">
        <span class="tmux-session-info">${dot} <strong>${name}</strong> ${statusLabel} ${winLabel}</span>
        <span class="tmux-session-actions">
          <button class="small-button" data-tmux-attach="${escapeAttribute(username)}" data-tmux-session="${nameAttr}">Attach</button>
          <button class="small-button" data-tmux-rename="${escapeAttribute(username)}" data-tmux-session="${nameAttr}">Rename</button>
          <button class="small-button" data-tmux-sendkeys="${escapeAttribute(username)}" data-tmux-session="${nameAttr}">Send Keys</button>
          <button class="small-button danger-button" data-tmux-kill="${escapeAttribute(username)}" data-tmux-session="${nameAttr}">Kill</button>
        </span>
      </div>`;
  }).join('');

  const emptyMsg = sessions.length === 0
    ? '<p class="muted" style="font-size:0.85em;margin:4px 0">No tmux sessions</p>'
    : '';

  return `
    <div class="tmux-sessions-block">
      <div class="tmux-sessions-header">
        <span class="label">Tmux Sessions</span>
        <span class="tmux-sessions-footer-actions">
          <button class="small-button" data-tmux-new="${escapeAttribute(username)}">+ New Session</button>
          ${sessions.length > 0 ? `<button class="small-button danger-button" data-tmux-killall="${escapeAttribute(username)}">Kill All</button>` : ''}
        </span>
      </div>
      ${emptyMsg}
      ${sessionRows}
    </div>`;
}

function idleLabel(seconds) {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  return `${Math.floor(seconds / 3600)}h`;
}
```

- [ ] **Step 2: Call renderTmuxSessions inside renderAccounts**

Find the account row template in `renderAccounts()`. It currently ends the `<section class="account-row">` block with:
```js
          <p class="section-description">First login checklist: run <code>claude</code>...
        </section>
```

Add the tmux block just before that `<p class="section-description">` line:
```js
          ${renderTmuxSessions(account)}
          <p class="section-description">First login checklist: run <code>claude</code>...
```

- [ ] **Step 3: Add CSS for tmux session rows**

Find the `<style>` block in `app.js` (search for `.account-row`). Add after the existing account styles:

```css
.tmux-sessions-block { margin-top: 10px; border-top: 1px solid var(--border); padding-top: 8px; }
.tmux-sessions-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 6px; }
.tmux-sessions-footer-actions { display: flex; gap: 4px; }
.tmux-session-row { display: flex; align-items: center; justify-content: space-between; padding: 4px 0; border-bottom: 1px solid var(--border-subtle, #222); }
.tmux-session-row:last-child { border-bottom: none; }
.tmux-session-info { display: flex; align-items: center; gap: 6px; font-size: 0.88em; }
.tmux-session-actions { display: flex; gap: 4px; flex-shrink: 0; }
```

- [ ] **Step 4: Commit**

```bash
git -C /srv/ccc/projects/CCC add container-code-companion/web/app.js
git -C /srv/ccc/projects/CCC commit -m "feat: add renderTmuxSessions helper and CSS"
```

---

### Task 6: Frontend — event handlers for all tmux actions

**Files:**
- Modify: `container-code-companion/web/app.js`

- [ ] **Step 1: Add the tmux action handler block**

Find the section in `app.js` where account button event handlers are wired up (search for `data-account-delete`). Add a new delegated handler block in the same area (inside the `document.addEventListener('click', ...)` handler or equivalent pattern used by the codebase):

Search for this pattern in `app.js`:
```js
document.body.addEventListener('click', async e => {
```
or the equivalent. Add the following cases inside that handler (alongside the existing `data-account-*` cases):

```js
// tmux attach — switch to terminal and inject attach command
const tmuxAttach = e.target.closest('[data-tmux-attach]');
if (tmuxAttach) {
  const username = tmuxAttach.dataset.tmuxAttach;
  const session = tmuxAttach.dataset.tmuxSession;
  selectSection('terminal');
  setTimeout(() => sendTerminalInput(`tmux attach-session -t ${session}\n`), 300);
  return;
}

// tmux new session
const tmuxNew = e.target.closest('[data-tmux-new]');
if (tmuxNew) {
  const username = tmuxNew.dataset.tmuxNew;
  const name = prompt('Session name', 'work');
  if (!name) return;
  await runAccountOperation({ operation: 'tmux-new', username, sessionName: name });
  return;
}

// tmux kill session
const tmuxKill = e.target.closest('[data-tmux-kill]');
if (tmuxKill) {
  const username = tmuxKill.dataset.tmuxKill;
  const session = tmuxKill.dataset.tmuxSession;
  if (!confirm(`Kill session "${session}" for ${username}?`)) return;
  await runAccountOperation({ operation: 'tmux-kill', username, sessionName: session });
  return;
}

// tmux kill all sessions
const tmuxKillAll = e.target.closest('[data-tmux-killall]');
if (tmuxKillAll) {
  const username = tmuxKillAll.dataset.tmuxKillall;
  if (!confirm(`Kill ALL tmux sessions for ${username}?`)) return;
  await runAccountOperation({ operation: 'tmux-kill-all', username });
  return;
}

// tmux rename — inline input
const tmuxRename = e.target.closest('[data-tmux-rename]');
if (tmuxRename) {
  const username = tmuxRename.dataset.tmuxRename;
  const session = tmuxRename.dataset.tmuxSession;
  const newName = prompt(`Rename session "${session}" to:`, session);
  if (!newName || newName === session) return;
  await runAccountOperation({ operation: 'tmux-rename', username, sessionName: session, newName });
  return;
}

// tmux send keys
const tmuxSendKeys = e.target.closest('[data-tmux-sendkeys]');
if (tmuxSendKeys) {
  const username = tmuxSendKeys.dataset.tmuxSendkeys;
  const session = tmuxSendKeys.dataset.tmuxSession;
  const keys = prompt(`Send command to "${session}" (${username}):`);
  if (!keys) return;
  await runAccountOperation({ operation: 'tmux-send-keys', username, sessionName: session, keys });
  return;
}
```

- [ ] **Step 2: Find where the existing delegated click handler lives**

Search `app.js` for `data-account-delete` to find the click delegation block. The tmux handlers above go in the same block, directly before the closing of the handler.

- [ ] **Step 3: Rebuild and verify**

```bash
cd /srv/ccc/projects/CCC/container-code-companion && go build ./...
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git -C /srv/ccc/projects/CCC add container-code-companion/web/app.js
git -C /srv/ccc/projects/CCC commit -m "feat: wire tmux session manager event handlers"
```

---

### Task 7: Manual smoke test and push

- [ ] **Step 1: Restart the CCC service to pick up the new binary**

```bash
sudo systemctl restart container-code-companion.service
```

- [ ] **Step 2: Open the CCC UI at http://192.168.0.53:9090**

Navigate to Accounts. Verify:
- Each account row has a `TMUX SESSIONS` block
- Accounts with no sessions show "No tmux sessions"
- `terminus` shows its active sessions with status dots, idle time, window counts

- [ ] **Step 3: Test each action**

For `terminus` (has active sessions):
1. **Kill** one session — confirm dialog appears, session disappears after refresh
2. **New Session** — creates `work` session, appears in list
3. **Rename** — renames the session, new name appears
4. **Send Keys** — sends `echo hello` to the session; then **Attach** and verify it ran
5. **Attach** — switches to Terminal tab, tmux attach command runs

- [ ] **Step 4: Verify snapshot refresh**

Wait 5 seconds after any change — session list should update automatically without page reload.

- [ ] **Step 5: Push**

```bash
git -C /srv/ccc/projects/CCC push
```

---

## Self-Review

**Spec coverage:**
- ✅ Sessions inline per account row
- ✅ Status dot (attached/detached)
- ✅ Name, idle time, window count
- ✅ Attach, Rename, Send Keys, Kill per row
- ✅ + New Session and Kill All per user
- ✅ Empty state ("No tmux sessions")
- ✅ Attach via PTY terminal
- ✅ Rename/Send Keys via prompt (consistent with existing Password/Shell pattern)
- ✅ Kill/Kill All with confirm
- ✅ Refreshes with 5s snapshot poll
- ✅ Errors in account-output pre

**Type consistency check:**
- `TmuxSession.Name` used consistently across all tasks ✅
- `AccountOperation.SessionName` matches all operation cases ✅
- `AccountOperation.NewName` used only in tmux-rename ✅
- `AccountOperation.Keys` used only in tmux-send-keys ✅
- `parseTmuxOutput` defined in Task 2, used in `ListTmuxSessions` in Task 2 ✅
- `renderTmuxSessions` defined in Task 5, called in Task 5 ✅
- `data-tmux-*` attribute names consistent between render (Task 5) and handlers (Task 6) ✅
- `idleLabel` defined in Task 5, called in Task 5 ✅
