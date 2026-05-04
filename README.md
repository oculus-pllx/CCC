# Claude Code Commander (CCC)

A Proxmox LXC provisioner that creates a lean, production-ready **Ubuntu 26.04** container for agentic coding with Claude Code. No Docker. No bloat. Everything pre-installed and pre-approved at provision time.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/claude-code-commander.sh)
```

---

## What You Get

- **Ubuntu 26.04 LTS** in a Proxmox LXC container
- **Non-root `claude-code` user** with passwordless sudo
- **Full dev stack** — Node.js 22 LTS, Python 3, Go, Rust, build essentials
- **Full test stack** — pytest, Jest, Vitest, Playwright (headless Chromium), httpie, nodemon, pm2
- **Claude Code** native install, all tools pre-approved, zero permission prompts
- **4 skill repos** pre-cloned (Anthropic, Karpathy, Pocock, Caveman)
- **code-server** (web VS Code) on port 8080 via native systemd
- **Custom statusline** at `~/.claude/bin/statusline-command.sh`
- **`ccc` help command** — full reference available on every login
- **SSH hardened** — root login disabled, key auth ready
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
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/claude-code-commander.sh \
  -o /tmp/ccc.sh && bash /tmp/ccc.sh
```

The script is interactive. You'll be prompted for:

| Prompt | Default | Notes |
|---|---|---|
| Container ID | next available | Auto-detected via `pvesh` |
| Hostname | `ccc-dev` | |
| Root password | — | Temporary, setup only |
| claude-code password | — | Your working user |
| code-server password | `codeserver` | Web VS Code UI |
| CPU cores | `4` | |
| RAM | `10240` MB | |
| Swap | `2048` MB | |
| Disk | `30` GB | |
| Storage | `truenas-lvm` | Match your Proxmox storage ID |
| IP | `dhcp` | Or `x.x.x.x/xx` for static |
| DNS | `1.1.1.1` | |
| SSH public key | optional | Installed for claude-code user |

Provisioning takes **10–15 minutes**.

---

## First Steps

```bash
# 1. SSH in as the working user
ssh claude-code@<container-ip>

# 2. Authenticate Claude Code
claude

# 3. Install plugins (see commands printed by this)
ccc-setup-plugins

# 4. Full help and command reference
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

### Skills (pre-cloned at `~/.claude/skills/`)
| Repo | Source |
|---|---|
| `anthropic-skills` | github.com/anthropics/skills |
| `karpathy-skills` | github.com/forrestchang/andrej-karpathy-skills |
| `mattpocock-skills` | github.com/mattpocock/skills |
| `caveman` | github.com/juliusbrussee/caveman |

### code-server Extensions
Python, Go, Rust Analyzer, Prettier, GitLens, TypeScript Next, Playwright, Vitest Explorer, YAML, TOML, JSON

---

## Shell Reference

The `ccc` command prints the full reference. Quick shortcuts:

```bash
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

## Notes

- Root login is disabled. Use `ssh claude-code@<ip>`.
- The Ubuntu 26.04 LXC template is auto-resolved via `pveam` — run `pveam update` on your Proxmox host if it can't be found.
- `yq` is the [mikefarah Go binary](https://github.com/mikefarah/yq), not the apt Python wrapper.
- Redis server is installed but disabled at boot. Start it when tests need it.
- Playwright browser deps are installed via `--with-deps`. If it failed during provisioning, re-run: `npx playwright install --with-deps chromium`

---

## License

MIT — use, modify, fork freely.
