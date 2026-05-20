# Agent Workstation Handoff

**Repo:** https://github.com/oculus-pllx/CCC  
**Branch:** `main` (dev work on `agent-workstation-native-ui`, fully merged)  
**Date:** 2026-05-19  
**Status:** All features shipped, tested, and on `main`. Ready for live LXC validation.

Do not commit this file unless explicitly requested.

---

## Resumption Prompt

> "Continue Agent Workstation development. Everything is on `main` at `0ba7990`. Last session completed: SSE self-update, visual polish (9 cyberpunk-glow effects), panel color fix, GitHub SSH section, Debian compatibility audit, README update. Next priority: live LXC validation via `sudo ccc-self-update` — confirm GUI update, gauge animations, themes, section fade, pulsing dot."

---

## Current Product Direction

CCC is Agent Workstation: a headless Proxmox LXC dev workstation for Claude Code, OpenAI Codex, and Gemini CLI.

Hard constraints:
- Agent Workstation native UI owns port `9090`; code-server on `8080`
- No Cockpit, no iframe wrappers, no `configure.py`, no `node-pty`, no port `4827`
- No `/opt/ccc-dashboard`; keep all plugin/service code in `ccc-bootstrap.sh`
- `CCC_SELF_UPDATE_REF="main"` in all three places in `ccc-bootstrap.sh`
- Panel colors must be theme-derived via `applyTheme()`, not hardcoded hex
- Do not hardcode `agent-workstation-native-ui` branch name in `ccc-bootstrap.sh`

---

## What Shipped (This Session)

### Self-Update — SSE Streaming (`8752ce2`)
- **Problem:** Fire-and-forget `cmd.Output()` blocked the pipe; browser got `Failed to fetch`
- **Fix:** `handleSelfUpdate` in `server.go` streams `ccc-self-update` stdout/stderr via `io.Pipe()` as SSE events. Client (`runSelfUpdateStream`) reads with `ReadableStream`; disconnect-after-output = service restarted = success. `monitorReconnect` polls `/api/workstation` every 5s until back up. Session token preserved across restarts.

### GitHub Connections Section (`22cb0a1`)
- Page at sidebar "Connections → GitHub"
- Generates `~/.ssh/id_ed25519` + displays public key
- Tests `ssh -T git@github.com` (exit code 1 = authenticated, as GitHub does)
- Server: `handleGitHub` (GET status, POST action) in `server.go`; `CollectGitHubStatus`, `RunGitHubOperation` in `management.go`

### Visual Polish — 9 Cyberpunk-Glow Effects (`faa325b`–`924004a`)
All effects use `rgba(var(--accent-rgb), alpha)` — theme-aware.
1. `--accent-rgb` variable added to `applyTheme()`
2. Topbar neon 3-layer `box-shadow`
3. Gauge `filter: drop-shadow` + stronger on hover
4. Scanlines: `body::after` repeating-linear-gradient, `pointer-events:none`
5. Sidebar active left bar: `inset 3px 0 0 var(--accent)`
6. Hover glows + lift on `.panel`, `.status-tile`, `.gauge-card`
7. Section fade-in: `@keyframes section-fade` + `.section-enter` in `renderSection`
8. Pulsing health dot: `@keyframes pulse-dot` + `#health.online::before`; `loadHealth` toggles `.online`
9. Gauge sweep: `animateGauges()` sweeps `--value` 0→target over 1100ms via RAF + cubic ease-out

### Panel Color Fix (`924004a`)
`--panel`/`--panel2` were hardcoded blue. Now: `rgba(${rgb}, 0.04)` / `rgba(${rgb}, 0.07)` set in `applyTheme()`. Neutral dark fallbacks in `:root`.

### Pushed to `origin/main`
Both `agent-workstation-native-ui` and `main` are at `0ba7990`. `ccc-self-update` deploys the full stack.

---

## Current `main` Tip

```
0ba7990 docs: update README and HANDOFF for main branch release
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

## Verified

```
bash tests/agent-workstation-static.sh    → agent-workstation static checks passed
go build -C agent-workstation ./cmd/server → BUILD OK
node --check agent-workstation/web/app.js  → OK
bash -n ccc-bootstrap.sh           → SYNTAX OK
Debian 13 compatibility                    → all clear (no Ubuntu-only deps)
```

---

## Next Steps

1. **Live LXC validation** — `sudo ccc-self-update` in the container, then smoke-test:
   - Updates page: "Apply Agent Workstation Update" → streams output → reconnects
   - Overview: gauges sweep in on load; hover lifts tiles/cards
   - Topbar: pulsing green dot when Online
   - Settings: theme swatches change accent color site-wide
   - Navigation: section fades in on each sidebar click
   - GitHub section: generate SSH key, test connection to GitHub

2. **Font bundling** (optional) — if LXC has no outbound internet, IBM Plex Mono won't load from Google Fonts. Download and serve from `agent-workstation/web/fonts/`.

3. **DECISIONS.md** (optional) — document architecture decisions: SSE update pattern, theme system, port ownership, session token design.

---

## File Map

```
agent-workstation/
  cmd/server/main.go
  internal/server/server.go          ← HTTP routes, SSE self-update, GitHub, session
  internal/system/
    management.go                    ← StartSelfUpdate, GitHub ops, service/account cmds
    overview.go                      ← /proc/* reads, df, CPU/mem/disk stats
  web/
    index.html                       ← shell, Google Fonts, sidebar nav
    styles.css                       ← Prism dark palette + all 9 visual polish effects
    app.js                           ← theme engine, SSE update, animateGauges, renderers
tests/agent-workstation-static.sh    ← grep-based CI assertions
```

---

## In-LXC Debug Commands

```bash
sudo ccc-self-update
ccc-update-status
sudo tail -160 /var/log/ccc-self-update.log
sudo systemctl status agent-workstation.service --no-pager -l
sudo systemctl restart agent-workstation.service
```
