# Agent Workstation

A Proxmox LXC provisioner that creates a lean, headless dev workstation for Claude Code, OpenAI Codex, and Gemini CLI. No desktop GUI, no Docker, no bloat. Everything is installed into a browser-accessible, CLI-first Linux container.

> Built on [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment/overview) — free, open-source server virtualization (community edition).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/claude-code-commander.sh)
```

---

## What You Get

- **Ubuntu 26.04 LTS** or **Debian 13 (Trixie)** in a Proxmox LXC container
- **Non-root `claude-code` user** with passwordless sudo
- **Full dev stack** — Node.js 22 LTS, Python 3, Go, Rust, build essentials
- **Claude Code** native install, all tools pre-approved, zero permission prompts, statusline active
- **OpenAI Codex and Gemini-ready config** from the shared `oculus-configs` repo
- **First-login onboarding** — `ccc-onboarding` / `ccc-setup` for git identity, SSH keygen, GitHub
- **Three update paths** — OS packages, Agent Workstation tooling, and shared agent configs are updated separately
- **Health check** — `ccc-doctor` checks network, runtimes, services, disk
- **code-server / VS Code Web** on port 8080 — multi-terminal tabs, file editor, welcome guide
- **Cockpit** on port 9090 — Agent Workstation controls plus system monitoring, services, logs, networking, files, and terminal
- **Custom statusline** at `~/.claude/bin/statusline-command.sh`
- **`ccc` help command** — full reference available on every login
- **SSH hardened** — root login disabled, key auth ready
- **IPv6 disabled** — avoids apt/curl failures in containers without IPv6 routing
- **Optional Proxmox HA** — register with `ha-manager` at provision time (cluster only)
- **oculus-configs** — shared Claude/Codex/Gemini config, rules, skills, and templates synced from [oculus-configs](https://github.com/oculus-pllx/oculus-configs)
- **Zero Docker** — pure native toolchain, minimal overhead
- **Weekly Agent Workstation tooling updates** — Sundays 3 AM ET; OS and agent config updates stay explicit

---

## Requirements

- Proxmox VE 8.x+ host
- Run as root on the Proxmox host
- Internet access from the host and container
- Recommended: 4 vCPU / 10GB RAM / 30GB disk

---

## Install

SSH into your Proxmox host as root and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/claude-code-commander.sh)
```

Or download and inspect first:

```bash
curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/claude-code-commander.sh \
  -o /tmp/ccc.sh && bash /tmp/ccc.sh
```

The script is interactive. You'll be prompted for:

| Prompt | Default | Notes |
|---|---|---|
| Container ID | next available | Auto-detected via `pvesh` |
| Hostname | `ccc-dev` | |
| **Username** | `claude-code` | Your working user — used for SSH, Cockpit, code-server |
| Root password | — | Temporary, setup only |
| User password | — | Password for your chosen username |
| code-server password | `codeserver` | Web VS Code UI |
| CPU cores | `4` | |
| RAM | `10240` MB | |
| Swap | `2048` MB | |
| Disk | `30` GB | |
| Storage | auto-detected | Active `rootdir`-capable pools listed; defaults to `local-lvm` if present, else first found |
| IP | `dhcp` | Or `x.x.x.x/xx` for static — CIDR prefix required, re-prompts if missing |
| Gateway | — | Required for static IP — plain IPv4, re-prompts if missing or has CIDR |
| DNS | `1.1.1.1` | Plain IPv4, re-prompts on invalid format |
| SSH public key | optional | Installed for chosen username |
| High Availability | — | Cluster only — lists HA groups, optional group selection |

**OS choice** is the first prompt — Ubuntu 26.04 LTS (default) or Debian 13 (Trixie). Useful fallback when Ubuntu/Canonical is having issues.

After OS selection, the script checks:
1. Canonical status API (`status.canonical.com`) — Ubuntu only, warns on active outages, suggests switching to Debian on major/critical
2. Direct reachability of the apt mirror (`archive.ubuntu.com` or `deb.debian.org`) — prompts to abort if unreachable

Provisioning takes **10–15 minutes**. Each of the 28 steps prints `[N/28]` progress, and the host prints elapsed time every 30 seconds so you can tell it's still running.

---

## First Steps

```bash
# 1. SSH in as the working user
ssh claude-code@<container-ip>

# 2. Run first-login onboarding (auto-prompts on first interactive login)
ccc-onboarding

# 3. Authenticate Claude Code
claude

# 4. Sync shared Claude/Codex/Gemini configs from oculus-configs
ccc-sync-agent-configs

# 5. Install Playwright + headless Chromium (optional, takes 5–15 min)
ccc-install-playwright

# 6. Install Codex CLI or jCodeMunch MCP (optional)
ccc-install-codex
ccc-install-jcodemunch

# 7. Full help and command reference
ccc
```

---

## Container Specs

### Languages & Runtimes
- **Node.js 22 LTS** — npm, typescript, ts-node, tsx
- **Python 3** — pip (`--break-system-packages`), venv
- **Go** (latest) — via official tarball, on PATH
- **Rust** (latest) — via rustup, installed for claude-code user

### Tools
- **Search** — ripgrep (`rg`), fd (`fdfind`), fzf, bat (`batcat`)
- **Data** — jq, yq (mikefarah Go binary), sqlite3
- **DB clients** — psql, redis-cli
- **Env** — direnv (per-directory `.envrc`)
- **Terminal** — tmux, screen, nano, vim, htop
- **Build** — gcc, clang, make, cmake, pkg-config, autoconf
- **Redis** — server available, disabled at boot: `sudo systemctl start redis-server`

### Claude Code
- All permissions pre-approved — `Bash(*)`, `Read(*)`, `Write(*)`, `Edit(*)`, `WebFetch(*)`, `WebSearch(*)`, `Task(*)`, `mcp__*`
- Agent teams enabled
- Extended thinking always on
- 64k output tokens
- Remote control enabled
- Config at `~/.claude/settings.json`

### Shared Agent Config
- **Claude** — `~/.claude/CLAUDE.md`, `~/.claude/rules/`, and MCP template from `oculus-configs`
- **Codex** — `~/.codex/AGENTS.md` and optional `~/.codex/skills/`
- **Gemini** — `~/.gemini/GEMINI.md` and optional `~/.gemini/skills/`
- **Templates** — copied from `oculus-configs/templates/` into `~/Templates/`
- Sync manually with `ccc-sync-agent-configs`

### code-server Extensions
Python, Go, Rust Analyzer, Prettier, GitLens, TypeScript Next, Playwright, Vitest Explorer, YAML, TOML, JSON

---

## Shell Reference

The `ccc` command prints the full reference. Quick shortcuts:

```bash
# Maintenance
ccc-onboarding          # first-login wizard: git identity, SSH key, GitHub
ccc-setup               # same wizard, safe to re-run
ccc-update-status       # show installed vs GitHub provisioner version
ccc-self-update         # update Agent Workstation tooling from GitHub
ccc-update              # update Agent Workstation tooling + app CLIs
ccc-os-update           # update OS packages with apt
ccc-sync-agent-configs  # update Claude/Codex/Gemini configs from oculus-configs
ccc-fix-cockpit-updates # fix Cockpit "cannot refresh cache whilst offline"
ccc-verify-cockpit-updates # verify Cockpit GUI updater readiness
ccc-doctor              # health check: network, runtimes, services, disk
ccc-install-playwright  # install Playwright + headless Chromium (optional)
ccc-install-codex       # install OpenAI Codex CLI (optional)
ccc-install-jcodemunch  # install jCodeMunch MCP — 95% token reduction (optional)

# Git
gs    # git status
gl    # git log --oneline -20
gd    # git diff
ga    # git add -A
gc    # git commit -m
gp    # git push

# Dev
py    # python3
ll    # ls -lah

# Services
sudo systemctl status  code-server@claude-code
sudo systemctl restart code-server@claude-code
sudo systemctl start   redis-server
sudo systemctl status  cockpit.socket
sudo systemctl restart cockpit.socket
ccc-verify-cockpit-updates
```

---

## Statusline

A default statusline script is installed at `~/.claude/bin/statusline-command.sh`.

Output format:
```
claude-code@ccc-dev:~/projects (main) [sonnet-4 | think] [ctx:42%] 3:14pm
```

To replace with your own:
```bash
cp ~/my-statusline.sh ~/.claude/bin/statusline-command.sh
chmod +x ~/.claude/bin/statusline-command.sh
```

To test:
```bash
echo '{"model":{"id":"claude-sonnet-4"},"thinking":{"enabled":true}}' \
  | ~/.claude/bin/statusline-command.sh
```

---

## Updating the Container

Agent Workstation separates updates so OS packages, workstation tooling, and shared agent behavior can move independently.

```bash
sudo ccc-os-update          # OS packages only: apt update/upgrade/autoremove/clean
ccc-update-status           # show installed vs GitHub provisioner version
sudo ccc-self-update        # Agent Workstation tooling: commands, MOTD, Cockpit plugin
sudo ccc-sync-agent-configs # shared Claude/Codex/Gemini config from oculus-configs
ccc-update                  # convenience: tooling + app CLI updates, no apt upgrade
claude update               # Claude Code only
```

`ccc-update-status` shows the installed provisioner commit, latest GitHub commit, behind count, and recent commits. `ccc-self-update` uses the GitHub raw URL first, then falls back to cloning `git@github.com:oculus-pllx/CCC.git`. Override `CCC_SELF_UPDATE_REPO`, `CCC_SELF_UPDATE_REF`, or `CCC_SELF_UPDATE_SCRIPT` in `/etc/ccc/config` for forks or private repos.

`ccc-sync-agent-configs` pulls `/opt/oculus-configs` and re-copies managed Claude, Codex, Gemini, and template files. It does not run the `oculus-configs` installer, does not install `configure.py`, and does not add another web UI/service.

---

## Removing the Container

From your Proxmox host:

```bash
pct stop <CT_ID>
pct destroy <CT_ID>
```

---

## Troubleshooting

**Ubuntu 26.04 template not found**
```bash
pveam update
pveam available --section system | grep ubuntu-26
```
If still missing, check that your Proxmox host can reach `download.proxmox.com`.

**code-server not loading**
```bash
pct exec <CT_ID> -- systemctl status code-server@claude-code
pct exec <CT_ID> -- journalctl -u code-server@claude-code -n 50
```

**Playwright (not installed at provision time)**
Playwright is skipped during provisioning — Chromium download hangs in LXC. Install manually after first login:
```bash
ccc-install-playwright
```

**Claude Code binary not found after provision**
```bash
# Inside the container:
find /home/claude-code -name "claude" -type f 2>/dev/null
# Then symlink manually:
sudo ln -sf <found-path> /usr/local/bin/claude
```

**Storage pool name mismatch**
Storage pools are auto-detected via `pvesm status --content rootdir`. The prompt lists available pools and defaults to `local-lvm` if present, else the first found. If detection returns nothing, override manually — run `pvesm status` on the host to see pool names.

**Static IP: gateway required**
If you enter a static IP, you must also enter a gateway. DHCP has no such requirement.

**apt fails with IPv6 / "Network is unreachable"**
IPv6 is disabled inside the container via sysctl at provision start, and apt is forced to IPv4 via `/etc/apt/apt.conf.d/99force-ipv4`. If you see IPv6 errors in an existing container:
```bash
# Inside the container:
echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4
```

**Ubuntu infrastructure down**
Check https://status.canonical.com/ — the script checks this automatically after OS selection. If Ubuntu is down, re-run and select option 2 (Debian 13) to bypass Canonical entirely.

**HA registration failed**
Add manually from the Proxmox host:
```bash
ha-manager add ct:<CT_ID> --state started --group <group>
```

**Cockpit not loading (port 9090)**
```bash
pct exec <CT_ID> -- systemctl status cockpit.socket
pct exec <CT_ID> -- systemctl restart cockpit.socket
```
Cockpit uses a self-signed cert — accept the browser security warning on first load. Login with `claude-code` user credentials.

## Notes

- Root login is disabled. Use `ssh claude-code@<ip>`.
- The Ubuntu 26.04 LXC template is auto-resolved via `pveam` — run `pveam update` on your Proxmox host if it can't be found.
- `yq` is the [mikefarah Go binary](https://github.com/mikefarah/yq), not the apt Python wrapper.
- Redis server is installed but disabled at boot. Start it when tests need it.
- Rust is installed twice (root + claude-code user). Root install is a known cleanup candidate.

---

## Contributing

PRs welcome. Keep the design values:
- No Docker — native toolchain only
- Everything provisioned at container creation time, not lazily
- Single-file installer — the whole script must be self-contained
- Default prompts should work for a TrueNAS-backed Proxmox homelab

To test changes: provision a throwaway container, run through First Steps, verify `ccc` output and `code-server` load.

---

## License

MIT — use, modify, fork freely.
