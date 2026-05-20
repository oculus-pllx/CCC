# Container Code Companion Punchlist Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the current working UI into a practical daily workstation: better files, projects, terminal/tmux, notes, and first-run tooling.

**Architecture:** Keep the Go server as the system boundary for filesystem, package, project, notes, and terminal operations. Keep the vanilla JS SPA, but split large UI surfaces into clearer sections and use small JSON files under the CCC user home for persistent local state. Bootstrap should install missing OS prerequisites so Codex, GitHub, Node, Go, and file workflows work immediately in a fresh LXC.

**Tech Stack:** Go HTTP server, vanilla JavaScript, CSS, xterm.js, Linux tools (`bubblewrap`, `gh`, `tmux`, optional `sshfs`/`cifs-utils`/`nfs-common`), static shell test.

---

## Priority Order

- [x] **P0 Bootstrap prerequisites:** install `bubblewrap` for Codex sandboxing and install GitHub CLI from the official apt repository.
- [ ] **P1 File manager foundation:** webmin-style file manager with upload/download, better directory navigation, and safe file operations.
- [ ] **P1 Project handling:** add existing directory as project, improve project metadata, and expose project actions clearly.
- [ ] **P1 Terminal improvements:** larger adjustable terminal, tmux quick buttons, and usable scroll behavior.
- [ ] **P2 Notes:** persistent notes section stored on disk.
- [ ] **P2 Map drives wizard:** add workspace shortcuts first, then optional SMB/NFS/SSHFS mount support.
- [ ] **P2 App catalog:** show installed dev apps, missing recommended apps, and one-click installs where safe.
- [ ] **P3 Navigation polish:** larger/brighter menu headings and indented clickable items.

---

## Task 1: Bootstrap Tooling Prerequisites

**Files:**
- Modify: `ccc-bootstrap.sh`
- Modify: `README.md`
- Modify: `tests/container-code-companion-static.sh`

**Acceptance Criteria:**
- Fresh LXC installs `bubblewrap` so Codex does not warn that sandbox prerequisites are missing.
- Fresh LXC installs `gh` from `https://cli.github.com/packages`, not Debian's stale package.
- `ccc-doctor` reports `bubblewrap`, `gh`, `node`, `npm`, `go`, `tmux`, and `code-server` presence.
- Static test asserts the bootstrap includes `bubblewrap`, the GitHub CLI keyring, and `apt install gh`.

**Implementation Notes:**
- Add `bubblewrap` to core apt packages.
- Add a dedicated step after core packages for GitHub CLI:
  - create `/etc/apt/keyrings`
  - download `githubcli-archive-keyring.gpg`
  - write `/etc/apt/sources.list.d/github-cli.list`
  - `apt-get update`
  - `apt-get install -y -qq gh`
- Keep install idempotent.

**Verification:**
- `bash tests/container-code-companion-static.sh`
- `bash -n ccc-bootstrap.sh`
- Fresh LXC: `command -v bwrap gh node npm go tmux code-server`
- Fresh LXC: `codex` no longer reports missing bubblewrap.

- [x] Task 1 complete.

---

## Task 2: File Uploads And Downloads

**Files:**
- Modify: `container-code-companion/internal/server/server.go`
- Modify: `container-code-companion/internal/server/server_test.go`
- Modify: `container-code-companion/internal/system/management.go`
- Modify: `container-code-companion/web/app.js`
- Modify: `container-code-companion/web/styles.css`
- Modify: `tests/container-code-companion-static.sh`

**Acceptance Criteria:**
- Files page has an Upload button that writes selected files to the current directory.
- Files page has a Download button for the selected file.
- Directory download is handled intentionally: either zip directory server-side or disabled with a clear message.
- Upload rejects empty path, directory traversal surprises, and files over a defined limit.
- Existing edit/save behavior still works.

**Implementation Notes:**
- Add `POST /api/file-upload?path=<dir>` using `multipart/form-data`.
- Add `GET /api/file-download?path=<file>` using `Content-Disposition: attachment`.
- Use absolute cleaned paths, but do not silently rewrite target outside the selected directory.
- Keep text editing size limit separate from binary upload/download.

**Verification:**
- Go tests for upload, download, bad method, missing file, and directory behavior.
- Static test for `/api/file-upload`, `/api/file-download`, `type="file"`, and `download`.
- Browser smoke: upload a text file, download it, compare content.

- [ ] Task 2 complete.

---

## Task 3: Webmin-Style File Manager

**Files:**
- Modify: `container-code-companion/internal/system/management.go`
- Modify: `container-code-companion/web/app.js`
- Modify: `container-code-companion/web/styles.css`
- Modify: `tests/container-code-companion-static.sh`

**Acceptance Criteria:**
- File manager supports a toolbar: Back, Home, Projects, Refresh, New File, New Folder, Upload, Download, Rename, Delete.
- Directory list is denser and scannable: icon/type, name, size, modified time, permissions.
- Selected item state is explicit; actions operate on selected item instead of whichever path is in a hidden input.
- Breadcrumbs allow jumping to parent directories.
- Editor pane is visually separate from browser pane without nested cards.

**Implementation Notes:**
- Extend `FileEntry` to include mode/permissions and owner/group if cheap to collect.
- Add single-selection state in JS: `selectedFilePath`.
- Avoid prompts for normal flows; use inline inputs or a small modal pattern.

**Verification:**
- Go tests for enriched file listing fields.
- Static test for toolbar commands and breadcrumb rendering.
- Browser smoke: create, rename, delete, upload, open, edit, save, download.

- [ ] Task 3 complete.

---

## Task 4: Notes Section With Persistence

**Files:**
- Modify: `container-code-companion/internal/server/server.go`
- Modify: `container-code-companion/internal/server/server_test.go`
- Create or modify: `container-code-companion/internal/system/notes.go`
- Modify: `container-code-companion/web/index.html`
- Modify: `container-code-companion/web/app.js`
- Modify: `container-code-companion/web/styles.css`
- Modify: `tests/container-code-companion-static.sh`

**Acceptance Criteria:**
- Sidebar includes Notes.
- Notes persist across service restart and browser refresh.
- Notes are stored under `$HOME/.ccc/notes.json` or `$HOME/.ccc/notes.md`.
- User can create, rename, edit, delete, and save notes.
- Autosave or explicit Save is clear; no silent data loss on navigation.

**Implementation Notes:**
- Prefer JSON if multiple named notes are needed:
  - `[{ "id": "...", "title": "...", "content": "...", "updatedAt": "..." }]`
- Use atomic writes: write temp file, then rename.
- Keep notes local to the CCC user, not global root state.

**Verification:**
- Go tests for list/create/update/delete and malformed JSON recovery.
- Static test for Notes nav and `/api/notes`.
- Manual: create note, restart `container-code-companion.service`, confirm note remains.

- [ ] Task 4 complete.

---

## Task 5: Better Project Handling

**Files:**
- Modify: `container-code-companion/internal/system/management.go`
- Modify: `container-code-companion/internal/server/server_test.go`
- Modify: `container-code-companion/web/app.js`
- Modify: `container-code-companion/web/styles.css`
- Modify: `tests/container-code-companion-static.sh`

**Acceptance Criteria:**
- Projects page has two clear flows: Create New Project and Add Existing Directory.
- Add Existing Directory can register a directory already under `$HOME`, especially `$HOME/projects`.
- Project list shows git branch, dirty status, last modified, and path.
- Project actions include Open in Files, Open in code-server, Terminal Here, Rename, Remove From List, Delete Directory.
- Removing a project from the list does not delete files.

**Implementation Notes:**
- Current project discovery scans `$HOME/projects`; keep that as default.
- Add persistent project registry at `$HOME/.ccc/projects.json` for external or explicitly added paths.
- Add `ProjectOperation` operation `add-existing` and `remove`.
- Keep destructive delete separate from non-destructive remove.

**Verification:**
- Go tests for adding existing path, rejecting missing path, and remove vs delete.
- Static test for `add-existing`, `Remove From List`, and `Terminal Here`.
- Manual: add an existing repo outside `$HOME/projects`, refresh, verify it remains.

- [ ] Task 5 complete.

---

## Task 6: Adjustable Terminal And Tmux Quick Controls

**Files:**
- Modify: `container-code-companion/internal/server/terminal.go`
- Modify: `container-code-companion/web/app.js`
- Modify: `container-code-companion/web/styles.css`
- Modify: `tests/container-code-companion-static.sh`

**Acceptance Criteria:**
- Terminal viewport is larger by default and uses available page height.
- User can resize terminal height or choose Compact / Standard / Tall / Full page.
- xterm scrollback works with mouse wheel.
- Buttons exist for common tmux actions:
  - Start/Attach
  - New Window
  - Previous Window
  - Next Window
  - Split Horizontal
  - Split Vertical
  - Detach
  - List Sessions
- Buttons send tmux prefix sequences or commands intentionally.

**Implementation Notes:**
- Initialize xterm with larger scrollback: `scrollback: 10000`.
- Increase server PTY default size from `Rows: 30, Cols: 100` after UI resize support is stable.
- Consider fitting terminal with xterm fit addon if vendored, or calculate rows/cols based on pane size.
- Tmux controls can send `tmux ...\n` commands first; prefix key sequences can come later.

**Verification:**
- Static test for `scrollback`, terminal size controls, and tmux button labels.
- Browser smoke: resize terminal, run long output, scroll back, use tmux start/split/detach.

- [ ] Task 6 complete.

---

## Task 7: Map Drives Wizard

**Files:**
- Modify: `ccc-bootstrap.sh`
- Modify: `container-code-companion/internal/server/server.go`
- Modify: `container-code-companion/internal/server/server_test.go`
- Create or modify: `container-code-companion/internal/system/mounts.go`
- Modify: `container-code-companion/web/app.js`
- Modify: `container-code-companion/web/styles.css`
- Modify: `tests/container-code-companion-static.sh`

**Acceptance Criteria:**
- File manager has Map Drive wizard.
- First version supports named shortcuts to local directories.
- Optional mount types are explicit: SMB/CIFS, NFS, SSHFS.
- Wizard validates required fields before running mount commands.
- Mapped locations appear in file manager quick locations.
- Mount support warns when LXC permissions prevent mounting.

**Implementation Notes:**
- Install optional client tools: `cifs-utils`, `nfs-common`, `sshfs`.
- Store mappings in `$HOME/.ccc/mapped-drives.json`.
- Treat local shortcuts as P1 and actual mounts as P2 because Proxmox LXC mount permissions vary.
- Do not store plaintext passwords unless the user explicitly accepts it; prefer credential file with `0600` if SMB needs it.

**Verification:**
- Go tests for local shortcut add/remove/list.
- Static test for Map Drive UI and `/api/mounts`.
- Manual: add local shortcut to `/opt/oculus-configs`, browse it from Files.

- [ ] Task 7 complete.

---

## Task 8: App Catalog And Recommended Tools

**Files:**
- Modify: `ccc-bootstrap.sh`
- Modify: `container-code-companion/internal/system/management.go`
- Modify: `container-code-companion/internal/server/server.go`
- Modify: `container-code-companion/web/app.js`
- Modify: `tests/container-code-companion-static.sh`

**Acceptance Criteria:**
- UI shows installed/missing state for common tools:
  - Required: `git`, `curl`, `jq`, `bubblewrap`, `gh`, `node`, `npm`, `go`, `tmux`
  - Recommended: `python3`, `pip`, `ripgrep`, `fd`, `fzf`, `bat`, `yq`, `direnv`, `sqlite3`, `redis-server`
  - Optional: `docker` or `podman`, `uv`, `pnpm`, `bun`, `deno`, Java, Rust
- Install actions are separated from status display.
- Dangerous/heavy installs are opt-in and describe impact.

**Implementation Notes:**
- Add `CollectAppCatalog()` that checks `command -v`, `--version`, and apt package status where useful.
- Add an Apps or Tools section under System.
- Keep one-click installs conservative: bubblewrap/gh/client tools first; Docker/Podman later.

**Verification:**
- Go tests with fake command runner for installed/missing states.
- Static test for Apps/Tools section and required tool names.
- Fresh LXC: all required tools report installed.

- [ ] Task 8 complete.

---

## Task 9: Codex Device Authorization

**Files:**
- Modify: `ccc-bootstrap.sh`
- Modify: `container-code-companion/internal/system/management.go`
- Modify: `container-code-companion/internal/server/server.go`
- Modify: `container-code-companion/web/app.js`
- Modify: `tests/container-code-companion-static.sh`

**Acceptance Criteria:**
- Codex section shows whether `codex` is installed.
- Codex section shows whether `bubblewrap` is installed.
- UI provides a Start Authorization button that runs the Codex login/device auth flow in an interactive terminal or guided command panel.
- If Codex reports missing sandbox prerequisites, the UI points to installing `bubblewrap` from the bootstrap/tooling section.

**Implementation Notes:**
- Avoid trying to fake OAuth/device auth in the backend.
- Prefer opening a terminal preloaded with `codex login` or a guided command that the user runs.
- Add a doctor check for `bwrap`.

**Verification:**
- Static test for `Codex`, `bubblewrap`, and `codex login`.
- Manual: fresh LXC starts Codex auth without the missing bubblewrap warning.

- [ ] Task 9 complete.

---

## Task 10: Navigation Polish

**Files:**
- Modify: `container-code-companion/web/index.html`
- Modify: `container-code-companion/web/styles.css`
- Modify: `tests/container-code-companion-static.sh`

**Acceptance Criteria:**
- Sidebar headings are larger/brighter than current state.
- Clickable items are visibly indented under headings.
- Active nav state remains obvious in all themes.
- Text does not wrap awkwardly on narrow viewports.

**Implementation Notes:**
- Increase `.nav-heading` contrast and size.
- Add left padding to `nav button`.
- Keep density; do not turn sidebar into a marketing nav.

**Verification:**
- Static test for relevant CSS selectors.
- Browser check at desktop and mobile widths.

- [ ] Task 10 complete.

---

## Execution Notes

- Each task should be its own commit.
- Start with Task 1 because it affects fresh LXC reliability and the Codex warning.
- Do Tasks 2 and 3 together only if the file manager changes stay small; otherwise finish upload/download first.
- Do Map Drives after the file manager is less clunky, because mapped locations need a good browser surface.
- Keep `.claude/` untracked unless explicitly requested.
