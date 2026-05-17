# Agent Workstation Native UI Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Cockpit-dependent management surface with a first-party headless Agent Workstation web UI on port 9090 while preserving the automated Proxmox LXC build and code-server on port 8080.

**Architecture:** Build a single Go service that serves static frontend assets, exposes allowlisted management APIs, and runs as `agent-workstation.service`. The service owns port 9090, code-server remains on port 8080, and `oculus-configs` remains the shared upstream for Claude/Codex/Gemini configuration.

**Tech Stack:** Go standard library for HTTP, auth/session cookies, static files, JSON APIs, and command execution; `github.com/creack/pty` plus Gorilla/websocket or `nhooyr.io/websocket` for the later real terminal slice; vanilla HTML/CSS/JS frontend.

---

## File Structure

- Create `agent-workstation/go.mod`: Go module declaration.
- Create `agent-workstation/cmd/server/main.go`: process entry point, config loading, HTTP server startup.
- Create `agent-workstation/internal/server/server.go`: router, middleware, static serving, health endpoint.
- Create `agent-workstation/internal/server/server_test.go`: API and auth tests.
- Create `agent-workstation/internal/system/overview.go`: system overview data collector.
- Create `agent-workstation/internal/system/overview_test.go`: overview parsing tests.
- Create `agent-workstation/web/index.html`: first native UI shell.
- Create `agent-workstation/web/app.js`: frontend API loading and rendering.
- Create `agent-workstation/web/styles.css`: UI styling.
- Modify `claude-code-commander.sh`: later installer task installs the binary and systemd unit instead of Cockpit.
- Modify `tests/agent-workstation-static.sh`: later static checks for no Cockpit dependency and no legacy dashboard.
- Modify `README.md`: later docs for native UI and rollback.

## Task 1: Native Service Foundation

**Files:**
- Create: `agent-workstation/go.mod`
- Create: `agent-workstation/cmd/server/main.go`
- Create: `agent-workstation/internal/server/server.go`
- Create: `agent-workstation/internal/server/server_test.go`
- Create: `agent-workstation/web/index.html`
- Create: `agent-workstation/web/app.js`
- Create: `agent-workstation/web/styles.css`

- [x] **Step 1: Write failing health/static/auth tests**

Create `agent-workstation/internal/server/server_test.go` with tests that assert:
- `GET /api/health` returns `{"ok":true,"name":"Agent Workstation"}`.
- `GET /` serves HTML containing `Agent Workstation`.
- protected API routes return `401` without a session cookie.

- [x] **Step 2: Run tests to verify they fail**

Run:
```bash
cd agent-workstation && go test ./internal/server
```
Expected: FAIL because the module and package do not exist yet.

- [x] **Step 3: Implement minimal server**

Create a Go module, static embed, router, health endpoint, and auth middleware. Do not add management actions yet.

- [x] **Step 4: Run tests to verify they pass**

Run:
```bash
cd agent-workstation && go test ./internal/server
```
Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add agent-workstation
git commit -m "feat(native-ui): add service foundation"
```

## Task 2: Overview API

**Files:**
- Create: `agent-workstation/internal/system/overview.go`
- Create: `agent-workstation/internal/system/overview_test.go`
- Modify: `agent-workstation/internal/server/server.go`
- Modify: `agent-workstation/web/app.js`
- Modify: `agent-workstation/web/index.html`

- [x] **Step 1: Write failing parser tests**

Test parsing `/proc/meminfo`, `/proc/loadavg`, and disk command output into an overview DTO with uptime, CPU load, memory, disk, hostname, and IP fields.

- [x] **Step 2: Run tests to verify they fail**

Run:
```bash
cd agent-workstation && go test ./internal/system
```
Expected: FAIL because the overview package does not exist.

- [x] **Step 3: Implement overview collector**

Use file reads for `/proc` data and `os.Hostname`; keep command execution behind small functions so tests can inject sample data.

- [x] **Step 4: Wire `GET /api/overview`**

Expose overview through the server behind session auth.

- [x] **Step 5: Run tests**

Run:
```bash
cd agent-workstation && go test ./...
```
Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add agent-workstation
git commit -m "feat(native-ui): add system overview"
```

## Task 3: Installer Switch From Cockpit to Native UI

**Files:**
- Modify: `claude-code-commander.sh`
- Modify: `tests/agent-workstation-static.sh`
- Modify: `README.md`

- [x] **Step 1: Write failing static checks**

Update `tests/agent-workstation-static.sh` to require `agent-workstation.service`, port `9090`, `agent-workstation/`, and no Cockpit install path for the native UI branch.

- [x] **Step 2: Run static check to verify it fails**

Run:
```bash
bash tests/agent-workstation-static.sh
```
Expected: FAIL because the installer still provisions Cockpit.

- [x] **Step 3: Modify installer**

Replace the Cockpit plugin install section with native UI installation:
- build or install `/usr/local/bin/agent-workstation`
- write `/etc/agent-workstation/config`
- write `/etc/systemd/system/agent-workstation.service`
- enable/start `agent-workstation.service`
- keep code-server on port 8080
- remove legacy `ccc-dashboard` conflicts

- [x] **Step 4: Run checks**

Run:
```bash
bash tests/agent-workstation-static.sh
bash -n claude-code-commander.sh
git diff --check
```
Expected: PASS, except unrelated pre-existing `HANDOFF.md` whitespace may remain outside the scoped diff.

- [x] **Step 5: Commit**

```bash
git add README.md claude-code-commander.sh tests/agent-workstation-static.sh
git commit -m "feat(native-ui): install Agent Workstation service"
```

## Later Tasks

- Logs API and UI: journalctl readers for allowlisted units.
- Services API and UI: status/start/stop/restart for allowlisted services.
- Updates API and UI: OS update, Agent Workstation update, CLI update, `oculus-configs` sync.
- Files API and UI: safe-root browser/editor.
- Terminal API and UI: Go PTY over WebSocket, user shell by default.
- Projects API and UI: create/import/open, templates, Git status.
- Agent configs API and UI: Claude/Codex/Gemini editors, MCP, skills/plugins.
- Network/accounts APIs and UI: conservative read-first management with explicit allowlists.

## Self-Review

- Spec coverage: the plan starts with a working replacement service and keeps later management surfaces as separate testable slices.
- Placeholder scan: no task uses "TBD" or undefined implementation targets.
- Type consistency: service package owns routing; system package owns overview data.
