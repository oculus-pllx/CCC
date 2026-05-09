# Claude Code Commander (CCC)

A Proxmox LXC provisioner that creates a lean, production-ready **Ubuntu 26.04** container for agentic coding with Claude Code. No Docker. No bloat. Everything pre-installed and pre-approved at provision time.

> Built on [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment/overview) — free, open-source server virtualization (community edition).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/claude-code-commander.sh)
```

---

## What You Get

- **Ubuntu 26.04 LTS** or **Debian 13 (Trixie)** in a Proxmox LXC container
- **Non-root `claude-code` user** with passwordless sudo
- **Full dev stack** — Node.js 22 LTS, Python 3, Go, Rust, build essentials
- **Full test stack** — pytest, Jest, Vitest, httpie, nodemon, pm2
- **Claude Code** native install, all tools pre-approved, zero permission prompts, statusline active
- **4 skill repos** pre-cloned and auto-discovered (Anthropic, Karpathy, Pocock, Caveman)
- **Interactive plugin menu** — `ccc-setup-plugins` with install instructions for all plugins and skills
- **Post-install wizard** — `ccc-setup` for git identity, SSH keygen, GitHub
- **Update command** — `ccc-update` syncs packages, Claude Code, and skill repos
- **Health check** — `ccc-doctor` checks network, runtimes, services, disk
- **code-server** (web VS Code) on port 8080 — multi-terminal tabs, file editor, welcome guide
- **Kit Manager** on port 8090 — connect a GitHub plugin repo, browse plugins, copy Claude Code install commands
- **Cockpit** on port 9090 — system monitoring, file manager with upload/download, browser terminal
- **Custom statusline** at `~/.claude/bin/statusline-command.sh`
- **`ccc` help command** — full reference available on every login
- **SSH hardened** — root login disabled, key auth ready
- **IPv6 disabled** — avoids apt/curl failures in containers without IPv6 routing
- **Optional Proxmox HA** — register with `ha-manager` at provision time (cluster only)
- **Zero Docker** — pure native toolchain, minimal overhead
- **Weekly auto-updates** — Sundays 3 AM ET

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

Provisioning takes **10–15 minutes**. Each of the 32 steps prints `[N/32]` progress, and the host prints elapsed time every 30 seconds so you can tell it's still running.

---

## First Steps

```bash
# 1. SSH in as the working user
ssh claude-code@<container-ip>

# 2. Run post-install wizard (git identity, SSH key, GitHub)
ccc-setup

# 3. Authenticate Claude Code
claude

# 4. Install plugins (see commands printed by this)
ccc-setup-plugins

# 5. Connect your plugin kit (see Kit Manager below)
# Open http://<container-ip>:8090 in a browser

# 6. Install Playwright + headless Chromium (optional, takes 5–15 min)
ccc-install-playwright

# 7. Install jCodeMunch MCP — 95% token reduction via symbol-level retrieval (optional)
ccc-install-jcodemunch

# 8. Full help and command reference
ccc
```

---

## Plugin Setup

Plugins require an authenticated Claude Code session. After running `claude` for the first time, paste these inside the Claude Code interface:

```
/plugin install skill-creator@claude-plugins-official
/plugin install superpowers@claude-plugins-official
/plugin install frontend-design@claude-plugins-official
/plugin marketplace add mksglu/context-mode
/plugin install context-mode@context-mode
/plugin marketplace add thedotmack/claude-mem
/plugin install claude-mem
```

Run `ccc-setup-plugins` at any time to reprint these.

---

## Kit Manager

The Kit Manager (port 8090) lets you connect a private GitHub plugin repository and install its contents into Claude Code with one copy-paste.

Open `http://<container-ip>:8090` in a browser after provisioning.

### What it does

- Reads a `.claude-plugin/marketplace.json` from any GitHub repo
- Lists all plugins with name, description, version, and category
- Generates the exact `/plugin marketplace add` and `/plugin install` commands
- Copy individual commands or the full install block
- Fetches project `SETUP.md` templates from the kit repo
- Remembers the last connected repo URL

### Setting up your own kit repo

1. Create a private GitHub repo (e.g. `your-org/your-claude-kit`)
2. Add a `.claude-plugin/marketplace.json`:

```json
{
  "name": "your-kit",
  "plugins": [
    {
      "name": "your-plugin",
      "source": "./plugins/your-plugin",
      "description": "What it does",
      "version": "0.1.0",
      "category": "engineering"
    }
  ]
}
```

3. Add plugin folders under `plugins/` following Claude Code plugin structure
4. **SSH access**: run `ccc-setup` first to generate an SSH key, then add the public key to GitHub (`~/.ssh/id_ed25519.pub` → GitHub → Settings → SSH Keys)
5. Open Kit Manager, paste your repo URL, hit Connect

> **Private repos** require SSH key access to be configured before the Kit Manager can reach them. Run `ccc-setup` → generate SSH key → add to GitHub first.

---

## Container Specs

### Languages & Runtimes
- **Node.js 22 LTS** — npm, typescript, ts-node, tsx
- **Python 3** — pip (`--break-system-packages`), venv
- **Go** (latest) — via official tarball, on PATH
- **Rust** (latest) — via rustup, installed for claude-code user

### Testing
- **Python** — pytest, pytest-asyncio, pytest-cov, pytest-mock, pytest-xdist
- **JS/TS** — Jest, Vitest (global), nodemon, concurrently
- **Browser** — Playwright + headless Chromium
- **HTTP** — httpie (`http` command), httpx (Python async)
- **Process** — pm2, http-server, entr (file watching)
- **Redis** — server available, disabled at boot: `sudo systemctl start redis-server`

### Tools
- **Search** — ripgrep (`rg`), fd (`fdfind`), fzf, bat (`batcat`)
- **Data** — jq, yq (mikefarah Go binary), sqlite3
- **DB clients** — psql, redis-cli
- **Env** — direnv (per-directory `.envrc`)
- **Terminal** — tmux, screen, nano, vim, htop
- **Build** — gcc, clang, make, cmake, pkg-config, autoconf

### Claude Code
- All permissions pre-approved — `Bash(*)`, `Read(*)`, `Write(*)`, `Edit(*)`, `WebFetch(*)`, `WebSearch(*)`, `Task(*)`, `mcp__*`
- Agent teams enabled
- Extended thinking always on
- 64k output tokens
- Remote control enabled
- Config at `~/.claude/settings.json`

### Skills (pre-cloned, auto-discovered)
Repos cloned to `~/.claude/skill-repos/`. Skill `.md` files copied to `~/.claude/skills/` so Claude Code discovers them automatically via `/skills`.

| Repo | Source |
|---|---|
| `anthropic-skills` | github.com/anthropics/skills |
| `karpathy-skills` | github.com/forrestchang/andrej-karpathy-skills |
| `mattpocock-skills` | github.com/mattpocock/skills |
| `caveman` | github.com/juliusbrussee/caveman |

Run `ccc-update` to pull latest from all repos and re-sync skill files.

### code-server Extensions
Python, Go, Rust Analyzer, Prettier, GitLens, TypeScript Next, Playwright, Vitest Explorer, YAML, TOML, JSON

---

## Shell Reference

The `ccc` command prints the full reference. Quick shortcuts:

```bash
# Maintenance
ccc-setup              # post-install wizard: git identity, SSH key, GitHub
ccc-self-update        # pull latest ccc-* tools from GitHub (no reprovision needed)
ccc-update             # update packages + Claude Code + skill repos
ccc-doctor             # health check: network, runtimes, services, disk
ccc-setup-plugins      # interactive plugin & skill menu
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
serve # http-server on port 8000
ll    # ls -lah

# Testing
pytest              # python3 -m pytest
pytest --cov=. -v   # with coverage
npx vitest          # Vite-native tests
npx jest            # Jest tests
npx playwright test # headless browser tests
http :3000/endpoint # httpie HTTP test

# Services
sudo systemctl status  code-server@claude-code
sudo systemctl restart code-server@claude-code
sudo systemctl start   redis-server
sudo systemctl status  cockpit.socket
sudo systemctl restart cockpit.socket
sudo systemctl status  ccc-kit-manager
sudo systemctl restart ccc-kit-manager
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

System packages update automatically every Sunday at 3 AM ET. To update manually:

```bash
sudo apt-get update && sudo apt-get upgrade -y
```

To update Claude Code:
```bash
claude update
```

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
npx --yes playwright install --with-deps chromium
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

---

## Notes

- Root login is disabled. Use `ssh claude-code@<ip>`.
- The Ubuntu 26.04 LXC template is auto-resolved via `pveam` — run `pveam update` on your Proxmox host if it can't be found.
- `yq` is the [mikefarah Go binary](https://github.com/mikefarah/yq), not the apt Python wrapper.
- Redis server is installed but disabled at boot. Start it when tests need it.
- Playwright browser deps are installed via `--with-deps`. If it failed during provisioning, re-run: `npx playwright install --with-deps chromium`
- Skill repos are cloned with `--depth 1` (shallow). Run `git fetch --unshallow` inside a repo if you need full history.
- Plugin names (`superpowers@claude-plugins-official`, etc.) are set at provision time. If Claude Code changes plugin registry format, update manually inside the session.

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
