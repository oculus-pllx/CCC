# Design: oculus-configs + Prism CCC Cockpit Plugin

**Date:** 2026-05-15  
**Repo:** oculus-pllx/CCC  
**Status:** Approved — ready for implementation planning

---

## Summary

Integrate oculus-configs (https://github.com/oculus-pllx/oculus-configs) into CCC's provisioning pipeline. CCC clones the repo to supply CLAUDE.md, rules, and templates. A native Cockpit plugin — styled with the Prism dark theme and taking over the full Cockpit page — replaces both the current stock Cockpit UI and configure.py's standalone web server. No port 4827. No Python service. Cockpit at :9090 is the single management interface.

---

## Architecture

```
Proxmox LXC Container
├── code-server        :8080   Web VS Code (unchanged)
└── Cockpit            :9090   Auth layer + CCC plugin (management UI)
    └── /usr/share/cockpit/ccc/
        ├── manifest.json      full-page plugin declaration
        └── index.html         Prism-dark UI — HTML + CSS + JS, self-contained
```

oculus-configs is cloned to `/opt/oculus-configs` (root-owned, read by claude-code). Its files are copied into place during provisioning. `install.sh` is **not** executed — CCC owns the provisioning flow end-to-end.

All Cockpit plugin file operations use `cockpit.file()` and `cockpit.spawn()`, routed through the cockpit bridge. Privileged ops run as `claude-code` via `cockpit.spawn(['sudo', '-u', 'claude-code', ...])`.

---

## Changes to claude-code-commander.sh

### Step numbering

Old steps 18–28 shift to 19–29. Total steps: 29.

### New step 18 — oculus-configs clone + file install

Inserted after step 17 (settings.json), before the old step 18 (CLAUDE.md, now removed).

```
step 18 "oculus-configs"
```

Actions (run as root inside provisioner):
1. `git clone --depth 1 https://github.com/oculus-pllx/oculus-configs /opt/oculus-configs`
2. `sudo -u claude-code cp /opt/oculus-configs/claude/CLAUDE.md /home/claude-code/.claude/CLAUDE.md`
3. `sudo -u claude-code cp -r /opt/oculus-configs/claude/rules/. /home/claude-code/.claude/rules/`
4. `sudo -u claude-code mkdir -p /home/claude-code/Templates`
5. `sudo -u claude-code cp -r /opt/oculus-configs/templates/. /home/claude-code/Templates/`
6. `sudo -u claude-code mkdir -p /home/claude-code/.codex && sudo -u claude-code cp /opt/oculus-configs/codex/skills/AGENTS.md /home/claude-code/.codex/AGENTS.md`
7. `sudo -u claude-code mkdir -p /home/claude-code/.gemini && sudo -u claude-code cp /opt/oculus-configs/gemini/skills/GEMINI.md /home/claude-code/.gemini/GEMINI.md`

Error handling: fatal on clone failure (network required). File copies (steps 2–7) are non-fatal if source paths don't exist (warn and continue) — guards against future oculus-configs restructuring. Codex/Gemini skill files are copied unconditionally; they sit inert until the respective CLI is installed via `ccc-install-codex` or manually.

### Remove old step 18 — inline CLAUDE.md heredoc

The entire `sudo -u claude-code tee /home/claude-code/.claude/CLAUDE.md` heredoc block (~55 lines) is deleted. oculus-configs supplies CLAUDE.md.

### Step 20 — code-server (was 20, stays 20 after renumber)

No changes.

### Step 28 — Cockpit plugin (within existing step 27, now step 28)

After `systemctl enable --now cockpit.socket`, add a new block that writes the CCC Cockpit plugin:

```bash
mkdir -p /usr/share/cockpit/ccc
cat > /usr/share/cockpit/ccc/manifest.json << 'MANIFEST'
{ ... }
MANIFEST

cat > /usr/share/cockpit/ccc/index.html << 'COCKPITUI'
<!DOCTYPE html>
...full Prism-dark single-page app...
COCKPITUI
```

All HTML/CSS/JS is a single self-contained heredoc. No external CDN dependencies — all styles and scripts inline.

### Step 24 — MOTD update

Change Cockpit line from:
```
ccc-fix-cockpit-updates   Fix Cockpit offline update cache error
```
to include the configure UI entry:
```
  http://${IP}:8080    Web VS Code — multi-terminal, file editor
  https://${IP}:9090   Cockpit — config, projects, MCP, updates
```

(Removes the old "system monitoring, file manager" description; reflects the new plugin.)

### ccc-self-update compatibility

`ccc-self-update` re-runs steps between `CCC_UPDATEABLE_START` and `CCC_UPDATEABLE_END`. The Cockpit plugin write block must be inside that range so `ccc-self-update` can push a new plugin version without reprovisioning.

---

## Cockpit Plugin Design

### manifest.json

```json
{
  "version": 0,
  "name": "ccc",
  "priority": 1,
  "menu": {
    "index": {
      "label": "Claude Code Commander",
      "order": 0
    }
  }
}
```

Full-page: the plugin does not declare a `"framing"` entry, so Cockpit renders it in a full iframe with no sidebar. The Prism nav bar is the only chrome.

### index.html — structure

Single HTML file, fully self-contained (no external requests):

```
<html>
  <head> — Prism dark CSS (custom properties for colors, all inline) </head>
  <body>
    <nav>  — Prism nav bar: CCC logo + triangle icon, 6 tab buttons, user@host right-aligned </nav>
    <main> — tab panels, one visible at a time via JS show/hide </main>
    <script> — cockpit.js import + all tab logic </script>
  </body>
</html>
```

### Visual design — Prism dark tokens

| Token | Value | Use |
|---|---|---|
| `--bg` | `#0b0f1a` | Page background |
| `--nav-bg` | `#0d1220` | Nav bar |
| `--card-bg` | `#0f1624` | Stat cards, list items |
| `--border` | `#1a2233` | All borders |
| `--text` | `#cdd6f4` | Body text |
| `--muted` | `#4a6080` | Labels, secondary text |
| `--cyan` | `#00e5ff` | Active tab, accent, links |
| `--green` | `#00ff88` | OK status, service dots |
| `--yellow` | `#f5c518` | Warning |
| `--purple` | `#a78bfa` | Plugin count, secondary accent |
| `--orange` | `#fb923c` | Error, danger actions |
| `--font-mono` | `monospace` | All labels and values |

Section labels: 9px monospace uppercase, `letter-spacing: 1.5px`, `color: var(--muted)`.  
Stat cards: `border-left: 3px solid <accent>`, no border-radius beyond 3px.

### Tab: Overview

Status cards (2×2 grid):
- CLAUDE.md — present/missing, last modified
- Rules — count of files in `~/.claude/rules/`
- MCP Servers — count of configured servers
- Plugins — enabled / total

Service pills (horizontal row):
- code-server :8080 — green dot if `systemctl is-active code-server`
- cockpit :9090 — always green (we're in it)
- claude — green dot if `which claude` resolves

Quick links:
- Web VS Code → opens `http://<ip>:8080` in new tab
- New Project → switches to Projects tab and opens wizard

### Tab: Projects

- Lists `~/projects/` directories via `cockpit.spawn(['ls', '-1', '/home/claude-code/projects'])`
- "New Project" button opens a 4-step inline wizard:
  1. Name — text input, validated for filesystem safety
  2. Location — defaults to `~/projects/<name>`, overridable
  3. Template — radio list from `~/Templates/`, or blank
  4. GitHub remote — optional; runs `gh repo create` via cockpit.spawn()
- Each listed project has an "Open in VS Code" link (`http://<ip>:8080/?folder=/home/claude-code/projects/<name>`)

### Tab: CLAUDE.md

- Reads `/home/claude-code/.claude/CLAUDE.md` via `cockpit.file()`
- Textarea (monospace, full height) for raw editing
- Save button writes back via `cockpit.file().replace()`
- "Reload from oculus-configs" button re-copies from `/opt/oculus-configs/claude/CLAUDE.md` (with confirmation prompt)

### Tab: MCP

- Reads `~/.claude/mcp.json`
- Table of configured MCP servers: name, command, status
- Add server form: name + command fields
- Remove button per row (with confirmation)
- GitHub token field: reads/writes `GITHUB_TOKEN` env from `~/.bashrc` or MCP env config

### Tab: Plugins

- Reads `enabled` array from `~/.claude/settings.json`
- Lists known plugins (from `/opt/oculus-configs` manifest or hardcoded list)
- Toggle switch per plugin — writes back to settings.json via cockpit.file()
- Shows installed path and version if available

### Tab: Updates

Two sections:

**CCC provisioner:**
- Runs `ccc-update-status` via cockpit.spawn(), displays output
- "Run ccc-self-update" button with confirmation

**oculus-configs:**
- Runs `git -C /opt/oculus-configs fetch origin --dry-run 2>&1` then `git -C /opt/oculus-configs log HEAD..origin/main --oneline`
- Shows installed commit vs latest, list of pending commits
- "Apply Update" button: `git -C /opt/oculus-configs pull` then re-copies CLAUDE.md, rules/, templates/

---

## File Operations — Security Notes

- All `cockpit.spawn()` calls use array form (no shell string interpolation)
- Project name input sanitized before use in paths: strip `../`, leading `/`, whitespace
- CLAUDE.md and settings.json writes go through `cockpit.file().replace()` (atomic)
- "Delete" operations in Projects tab show a confirmation modal before proceeding
- Protected paths (home dir, `~/.claude/`, `/opt/oculus-configs`) cannot be deleted or renamed from the UI

---

## MOTD

Replace Cockpit description line:

```bash
echo -e "  ${C}https://\${IP}:9090${N}  Cockpit — config, projects, MCP, updates"
```

Remove the separate `ccc-fix-cockpit-updates` and `ccc-verify-cockpit-updates` lines from the "Setup & Maintenance" section of the MOTD (they remain as CLI commands, just not promoted in the MOTD).

---

## What is NOT changed

- code-server setup (step 20) — unchanged
- ccc-* CLI tools — unchanged
- settings.json (step 17) — unchanged
- statusline (step 19) — unchanged
- SSH hardening, shell env, git defaults, auto-update cron — unchanged
- Cockpit install + NetworkManager + PackageKit fix — unchanged; plugin is additive

---

## Out of Scope

- Dark/light theme toggle (deferred — Prism dark only for now)
- configure.py Python service — not installed, not referenced
- Port 4827 — not opened, not mentioned anywhere in the provisioner
- oculus-configs `install.sh` — not executed
- Codex/Gemini CLI installation — still on-demand via `ccc-install-codex`; skill files are pre-copied, CLIs are not pre-installed
