# Native UI Interactive Workstation Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Agent Workstation usable as a real headless workstation UI with Prism-style file/project management and a real tmux-capable PTY terminal.

**Architecture:** Keep the existing Go native service on port 9090 and add JSON APIs for project/file operations plus a WebSocket PTY endpoint. The frontend remains vanilla HTML/CSS/JS and uses the same authenticated session cookie; the terminal uses Go PTY, not `node-pty`.

**Tech Stack:** Go standard library, `github.com/creack/pty`, `github.com/gorilla/websocket`, vanilla JS/CSS, and local xterm.js browser assets.

---

### Task 1: Project APIs

**Files:**
- Modify: `agent-workstation/internal/system/management.go`
- Modify: `agent-workstation/internal/server/server.go`
- Modify: `agent-workstation/internal/server/server_test.go`
- Modify: `agent-workstation/web/app.js`

- [x] Add failing tests for create, rename, and delete project API calls.
- [x] Implement project operations under `~/projects`.
- [x] Wire Projects panel to create, rename, delete, open in VS Code, and browse files.
- [x] Verify with `go test ./...` and `node --check agent-workstation/web/app.js`.

### Task 2: Prism-Style File Manager

**Files:**
- Modify: `agent-workstation/web/app.js`
- Modify: `agent-workstation/web/styles.css`
- Modify: `agent-workstation/internal/system/management.go`
- Modify: `agent-workstation/internal/server/server.go`

- [x] Add create folder, create file, rename, delete controls.
- [x] Keep read/write bounded to text files and return clear permission errors.
- [x] Use a left browser pane, main list, and editor pane.
- [x] Verify with static checks and JS syntax check.

### Task 3: Real PTY Terminal

**Files:**
- Modify: `agent-workstation/go.mod`
- Modify: `agent-workstation/go.sum`
- Create: `agent-workstation/internal/server/terminal.go`
- Modify: `agent-workstation/internal/server/server.go`
- Modify: `agent-workstation/web/index.html`
- Modify: `agent-workstation/web/app.js`
- Modify: `agent-workstation/web/styles.css`

- [x] Add Go dependencies `github.com/creack/pty` and `github.com/gorilla/websocket`.
- [x] Add `/api/pty` WebSocket endpoint that starts `bash -l` in `~/projects` inside a PTY.
- [x] Bridge browser input/output to the PTY and support terminal resize messages.
- [x] Update the Terminal panel to use local xterm.js assets when available and fall back to a raw terminal pane.
- [ ] Verify `tmux` can run through the PTY path in a fresh LXC by using the browser terminal.

### Task 4: Verification and Push

**Files:**
- Modify as needed from Tasks 1-3.

- [x] Run `bash tests/agent-workstation-static.sh`.
- [x] Run `bash -n claude-code-commander.sh`.
- [x] Run `cd agent-workstation && go test ./...`.
- [x] Run `node --check agent-workstation/web/app.js`.
- [x] Run `git diff --check`.
- [ ] Commit and push `agent-workstation-native-ui`.
