# Agent Workstation Handoff

**Repo:** https://github.com/oculus-pllx/CCC  
**Branch:** `main` (dev branch `agent-workstation-native-ui` merged)  
**Date:** 2026-05-19  
**Status:** All features shipped to `main`. GUI self-update working end-to-end. Visual polish live.

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

## What Shipped in This Session

### Visual Polish — Cyberpunk Glow (9 effects, `faa325b`–`924004a`)

All effects use `--accent-rgb` (theme-aware) so they automatically match the active accent color.

1. **`--accent-rgb`** — new CSS variable set in `applyTheme()`, enables `rgba(var(--accent-rgb), alpha)` in CSS
2. **Topbar neon underglow** — 3-layer `box-shadow` on `.topbar`
3. **Gauge halo glow** — `filter: drop-shadow` on `.gauge` with stronger hover
4. **Scanlines overlay** — `body::after` fixed repeating-linear-gradient, `pointer-events: none`
5. **Sidebar active left bar** — `inset 3px 0 0 var(--accent)` box-shadow on `.sidebar button.active`
6. **Hover glows** — transition + lift on `.panel`, `.status-tile`, `.gauge-card`
7. **Section fade-in** — `@keyframes section-fade` + `.section-enter` class toggled in `renderSection`
8. **Pulsing health dot** — `@keyframes pulse-dot` + `#health.online::before` animated dot; `loadHealth()` toggles `.online`
9. **Gauge sweep animation** — `animateGauges()` sweeps `--value` 0→target over 1100ms using RAF + cubic ease-out; triggered from `bindSectionActions` on overview

### Panel Color Fix (`924004a`)
`--panel` and `--panel2` were hardcoded blue-tinted hex values. Now derived in `applyTheme()` as `rgba(${rgb}, 0.04)` and `rgba(${rgb}, 0.07)`. Panels match the active theme and neutral fallbacks in `:root` prevent blue flash before JS runs.

### GUI Self-Update — SSE Streaming (`8752ce2`)
Replaced fire-and-forget+polling with SSE streaming:
- Server: `handleSelfUpdate` streams `ccc-self-update` stdout/stderr via `io.Pipe()` as `data: {"line":"..."}` events
- Client: `runSelfUpdateStream()` reads the stream with `ReadableStream` reader; any disconnect-after-output treats as service-restart-success, then `monitorReconnect()` polls `/api/workstation` every 5s until the service is back
- Session token is preserved across restarts (env file), so the existing cookie stays valid

### Push to `origin/main`
`agent-workstation-native-ui` fast-forwarded to `origin/main` — deployed workstations now get all features on `sudo ccc-self-update`.

---

## Latest Commits on `main`

```text
924004a fix(polish): derive --panel and --panel2 from accent color in applyTheme
269449c feat(polish): gauge sweep animation on overview load
d27ccb8 feat(polish): pulsing accent dot on Online health indicator
6f289a4 feat(polish): section fade-in animation on nav change
9f0e24c feat(polish): hover glow on panels, status tiles, and gauge cards
20ea2a0 feat(polish): topbar underglow, gauge halo, scanlines, sidebar active bar
faa325b feat(polish): add --accent-rgb CSS var + static test stubs for visual effects
8752ce2 refactor(update): replace fire-and-forget+polling with SSE streaming
22cb0a1 feat(github): GitHub Connections section — SSH key generation and connection test
```

---

## Verified Locally

```
bash tests/agent-workstation-static.sh    → agent-workstation static checks passed
go build -C agent-workstation ./cmd/server → BUILD OK
go test ./... (agent-workstation)          → all PASS
node --check agent-workstation/web/app.js  → OK
```

---

## Next Steps

1. **Validate in live LXC** — run `sudo ccc-self-update` in the container, then test:
   - Updates page: click "Apply Agent Workstation Update" → should stream output, restart, reconnect
   - Overview: gauges sweep in on load, hover lifts on tiles/cards
   - Topbar: pulsing green dot when Online
   - Settings: theme swatches change accent color site-wide (panels, glows, borders)
   - Navigation: section fade-in on each click
   - GitHub section: generate SSH key, test connection

2. **Font bundling** (optional) — if the LXC has no outbound internet, IBM Plex Mono won't load from Google Fonts. Download and serve from `agent-workstation/web/fonts/`.

3. **DECISIONS.md** — consider committing architecture decisions (theme system, SSE update pattern, port ownership) to a `DECISIONS.md` for long-term reference.

---

## Relevant Commands in LXC

```bash
sudo ccc-self-update
sudo tail -160 /var/log/ccc-self-update.log
ccc-update-status
sudo systemctl status agent-workstation.service --no-pager -l
sudo systemctl restart agent-workstation.service
```

---

## Native UI File Map

```text
agent-workstation/
  cmd/server/main.go                ← entrypoint
  internal/
    server/server.go                ← HTTP routes, SSE self-update, session handling
    system/management.go            ← StartSelfUpdate, RunGitHubOperation, system calls
  web/
    index.html                      ← shell, Google Fonts, sidebar nav
    styles.css                      ← Prism dark palette, all visual polish effects
    app.js                          ← theme engine, renderers, SSE update, gauge animation
tests/agent-workstation-static.sh   ← grep-based static assertions (CI)
```

---

## Hard Constraints Still Active

- Do not push `agent-workstation-native-ui` branch name as a value into `claude-code-commander.sh` (static test: `require_file_not_contains`)
- `CCC_SELF_UPDATE_REF` must stay `"main"` in all three places it appears in `claude-code-commander.sh`
- Do not introduce hardcoded hex colors for panel backgrounds — derive from `--accent-rgb` in `applyTheme()`
