# Agent Workstation Handoff

**Repo:** https://github.com/oculus-pllx/CCC  
**Branch:** `agent-workstation-native-ui`
**Date:** 2026-05-18
**Status:** Theme system complete. Prism dark base + 7-theme picker live.

Do not commit this file unless explicitly requested.

---

## Current Product Direction

CCC is now Agent Workstation: a headless Proxmox LXC dev workstation for Claude Code, OpenAI Codex, and Gemini CLI.

Hard constraints still in force:
- Keep code-server / VS Code Web on port `8080`.
- Agent Workstation native management UI owns port `9090`.
- Do not use Cockpit as the primary UI for this branch.
- Do not add a second standalone web GUI.
- Do not use iframe wrappers.
- Do not install or run `configure.py`.
- Do not use `node-pty`.
- Do not add port `4827`.
- Do not reintroduce `/opt/ccc-dashboard`.
- Keep plugin/service code self-contained in `claude-code-commander.sh` for install/self-update.

---

## Latest Commits

```text
6180c12 feat(network): make graph accent-aware — RX line tracks active theme color
6c7770a feat(settings): settings page with 7-theme swatch picker
3e54e60 feat(theme): theme engine — THEMES map, applyTheme, loadTheme, hexToRgb helpers
9a6f3f7 feat(ui): Google Fonts (IBM Plex Mono/Sans) + Settings nav item
de1cc5c feat(styles): complete Prism dark CSS variable palette
16a267e feat(styles): Prism dark base — navy backgrounds, accent green, custom properties
427e06b fix(security): use exact origin comparison in WebSocket CheckOrigin to prevent subdomain bypass
80607bf fix(security): method guard, WebSocket origin, cookie Secure flag, stripANSI, window.open protocol, remove formatPercent, ParseMemInfo tolerance
```

---

## Theme System (This Session)

### Prism Dark Base (`16a267e`, `de1cc5c`)
Full CSS custom-property palette applied: navy backgrounds (`--bg-primary: #0a0e1a`, `--bg-secondary: #0d1421`), IBM Plex Mono font, accent green default (`#00ff88`). All component colors wired to CSS variables.

### Google Fonts + Settings nav (`9a6f3f7`)
IBM Plex Mono and IBM Plex Sans loaded via Google Fonts preconnect. "Settings" added to sidebar nav (gear icon).

### Theme engine (`3e54e60`)
`THEMES` map in `app.js` defines 7 palettes: Green (default), Cyan, Purple, Gold, Red, Blue, Orange. `applyTheme(name)` writes CSS variables + stores choice to `localStorage` key `aw-theme`. `loadTheme()` restores on page load. `hexToRgb()` utility used for network graph integration.

### Settings page (`6c7770a`)
`renderSettings()` / `bindSettings()` build a swatch picker grid. Active theme highlighted with checkmark overlay. Clicking a swatch applies and persists immediately.

### Network graph accent-aware colors (`6180c12`)
RX line color reads `--accent` via `getComputedStyle` at draw time. Switches automatically when theme changes without a page reload.

---

## What Was Fixed in the Previous Session

All work is on `agent-workstation-native-ui`. The following bugs are fixed and code-reviewed:

### Terminal reconnect (`a0d13e1`)
`renderSection` now unconditionally calls `stopTerminalSessions()` before re-render. Previously the `if (section !== 'terminal')` guard left the xterm.js instance attached to detached DOM, causing a blank terminal that could not recover without a service restart.

### Self-update GUI (`e87040f`)
- Replaced `nohup` with `setsid` in `StartSelfUpdate` so the update process survives any PTY/session cleanup during the service restart.
- Removed the `catch` branch that was overwriting the monitor's live progress display with a static message.

### `CCC_SELF_UPDATE_REF` → `main` (`acd3bc4`)
All three occurrences in `claude-code-commander.sh` (global constant, embedded `ccc-self-update`, embedded `ccc-update-status`) now point to `main`. After pushing to `origin/main`, deployed workstations will self-update from the correct branch.

### Agent Configs inline editor (`4d6ab73`, `37d9206`)
Edit buttons on the Configs page now open an inline editor panel instead of navigating to the Files section. Includes Save/Cancel, loading state, error display, and disabled-during-save guard.

### Account management (`5768c86`, `4190d72`)
`createAccount` validates username before submit. `runAccountOperation` clears username, password, and shell fields after successful create. Null guards added throughout.

### Overview → Updates badge link (`5768c86`)
"Updates available" badge is now a `<button class="badge badge-link">` that navigates to the Updates section when clicked.

### Network graph legend (`5768c86`)
RX/TX legend with color-coded labels added below the canvas. `.network-graph-wrap` is responsive (`overflow-x: auto`, `max-width: 100%`).

### Security fixes (`80607bf`, `427e06b`)
- `handleOverview`: rejects non-GET with 405
- `stripANSI`: regex covers all ANSI escape sequences, not just color codes
- `window.open`: uses `location.protocol` instead of hardcoded `http://`
- Dead `formatPercent` function removed
- WebSocket `CheckOrigin`: exact host comparison (prevents subdomain bypass)
- `sessionCookie`: converted to `(s *Server)` method; `Config.SecureCookies bool` added for HTTPS deployments
- `ParseMemInfo`: `continue` on non-numeric lines instead of returning an error

---

## Push to `origin/main` — Still Pending

The user chose to push `agent-workstation-native-ui` as `main` to make deployed workstations self-update from the right branch. This has NOT been done yet. Confirm with the user before running:

```bash
git push origin agent-workstation-native-ui:main --force-with-lease
git push origin agent-workstation-native-ui
```

---

## Self-Update State

The `setsid` fix and `CCC_SELF_UPDATE_REF=main` change are in code but not yet validated against a live LXC (requires the push to `origin/main` first, then a `sudo ccc-self-update` in the container).

Relevant commands inside the LXC:

```bash
ccc-update-status
sudo ccc-self-update
sudo tail -160 /var/log/ccc-self-update.log
sudo systemctl status agent-workstation.service --no-pager -l
```

---

## Verification Run Locally (2026-05-18, post-theme)

```
cd agent-workstation && go test ./...          → all PASS (11 tests)
go build ./cmd/server                          → OK
bash tests/agent-workstation-static.sh         → passed
node --check agent-workstation/web/app.js      → OK (syntax clean)
bash -n claude-code-commander.sh               → OK
```

---

## Next Steps

1. **Push to `origin/main`** (confirm with user — already pushed to `origin/agent-workstation-native-ui`):
   ```bash
   git push origin agent-workstation-native-ui:main --force-with-lease
   ```

2. **Validate theme system in live LXC** — browser test `http://<lxc-ip>:9090`:
   - Settings page: all 7 theme swatches visible; clicking each applies accent color site-wide
   - Network graph: RX line color updates immediately when theme changes (no reload required)
   - Theme persists across page reloads (localStorage key `aw-theme`)
   - IBM Plex Mono / IBM Plex Sans fonts load (requires internet access in LXC, or bundle fonts)

3. **Validate existing features** in live LXC after theme deployment:
   - Updates page: click "Apply Agent Workstation Update", watch log, confirm no `Failed to fetch`
   - Agent Configs: Edit opens inline, Save updates file, Cancel closes panel
   - Accounts: create new user (validate username required), confirm form clears on success
   - Overview: click update badge, confirm navigates to Updates tab
   - Terminal: navigate away and back, confirm reconnects without blank screen

4. **Font bundling** (optional) — if the LXC has no outbound internet, download IBM Plex Mono/Sans
   and serve from `agent-workstation/web/fonts/` to avoid FOUT or missing fonts.

---

## Current Native UI Features

Port `9090` native Agent Workstation service (Prism dark theme, 7 accent colors):
- Overview dashboard with gauges/status tiles and clickable update badge.
- Logs.
- Network page with addresses/routes, live activity graph, and RX/TX legend.
- Accounts page with create (validated), password, shell, groups, and delete controls.
- Services page with service controls.
- Full file browser/editor with create, rename, delete.
- Updates page with update status, live self-update log/progress, OS update action.
- Terminal with Go PTY websocket, xterm.js, reconnect cleanup, and browser-side tabs.
- Projects page with create, rename, delete, browse files, open in VS Code Web.
- Agent Configs page with inline editor (load, edit, save, cancel) for Claude `CLAUDE.md`, Codex `AGENTS.md`, Gemini `GEMINI.md`, and Claude MCP config.
- `oculus-configs` status/sync page.
- Settings page with 7-theme swatch picker (Green default, Cyan, Purple, Gold, Red, Blue, Orange); persists to `localStorage` key `aw-theme`.

code-server remains on port `8080`.

---

## Theme System Files

```text
agent-workstation/web/styles.css       ← Prism dark CSS variables + full component palette
agent-workstation/web/index.html       ← Google Fonts preconnect, Settings nav item
agent-workstation/web/app.js           ← THEMES map, applyTheme, loadTheme, hexToRgb, renderSettings, bindSettings
```

---

## Dirty/Untracked File Rules

Do not touch unrelated untracked screenshots, `docs/reference/prism-brand.md`, `docs/reference/update.png`, or `.superpowers` unless explicitly asked.

If `agent-workstation/server` appears untracked, it is a Go build artifact from `go build ./cmd/server`; remove or ignore it, do not commit it.
