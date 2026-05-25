# Container Code Companion

Container Code Companion by Parallax Group builds a lean, browser-accessible, CLI-first dev workstation for Claude Code, OpenAI Codex, Gemini-ready configs, and the shared `oculus-configs` integration. It can create a new Proxmox LXC workstation or install the CCC workstation stack onto an existing Debian or Ubuntu machine.

Parallax Group: [pllx.group](https://pllx.group)

| I want to... | Supported path |
|---|---|
| Create a **New Proxmox LXC** workstation | Run `ccc-bootstrap.sh` on the Proxmox host |
| Install CCC on **Existing Debian or Ubuntu** Linux | Run `ccc-install-linux.sh` on that Linux machine |

```bash
# New Proxmox LXC
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/ccc-bootstrap.sh)

# Existing Debian or Ubuntu Linux host
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/ccc-install-linux.sh)
```

---

## What You Get

- **Ubuntu 24.04 LTS (default), Ubuntu 26.04 LTS, or Debian 13** Proxmox LXC path, plus an existing Debian/Ubuntu Linux-host installer
- **Non-root working user** — `claude-code` in the LXC path, current user or an optional dedicated CCC user on existing Linux
- **Full dev stack** — Node.js 22 LTS, Python 3, Go, Rust, build essentials
- **Claude Code** native install, all tools pre-approved, zero permission prompts, statusline active
- **OpenAI Codex and Gemini-ready config** from the shared `oculus-configs` repo
- **First-login onboarding** — `ccc-onboarding` / `ccc-setup` for git identity, SSH keygen, GitHub
- **Shared project workspace** — projects live at `/srv/ccc/projects`, with `~/projects` linked there for compatibility
- **Shared work identities** — local Linux users keep separate Claude/Codex/Gemini auth state while sharing projects, baseline configs, and a managed GitHub machine key
- **Three update paths** — OS packages, Container Code Companion tooling, and shared agent configs are updated separately
- **Health check** — `ccc-doctor` checks network, runtimes, services, disk
- **code-server / VS Code Web** on port 8080 — multi-terminal tabs, file editor, welcome guide
- **Container Code Companion UI** on port 9090 — native headless management dashboard with Parallax branding, mobile drawer navigation, 7 accent color presets, optional CRT display effects, system overview, SSH connection counts, services, logs, networking, accounts, files, notes, terminal, projects, updates, app catalog, map drives, provider configs, and GitHub SSH key management
- **Projects Git actions** — clone SSH or HTTPS Git repos into `/srv/ccc/projects` and pull fast-forward Git updates for existing Git projects
- **Native terminal tabs** — browser PTY sessions backed by Go, xterm.js, and tmux-capable shells
- **Custom statusline** at `~/.claude/bin/statusline-command.sh`
- **`ccc` help command** — full reference available on every login
- **SSH hardened LXC path** — root login disabled, key auth ready
- **LXC IPv6 workaround** — avoids apt/curl failures in containers without IPv6 routing
- **Optional Proxmox HA** — register with `ha-manager` at provision time (cluster only)
- **oculus-configs** — shared Claude/Codex/Gemini config, rules, skills, and templates synced from [oculus-configs](https://github.com/oculus-pllx/oculus-configs)
- **Zero Docker** — pure native toolchain, minimal overhead
- **Weekly Container Code Companion tooling updates** — Sundays 3 AM ET; OS and agent config updates stay explicit

---

## Requirements

For a new Proxmox LXC:

- Proxmox VE 8.x+ host
- Run as root on the Proxmox host
- Internet access from the host and container
- Recommended: 4 vCPU / 10GB RAM / 30GB disk

For an existing Linux host:

- Debian or Ubuntu with `sudo` access
- Internet access for package and GitHub downloads
- A user that should own CCC, or permission to create a dedicated CCC user

---

## Install

### New Proxmox LXC

SSH into your Proxmox host as root and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/ccc-bootstrap.sh)
```

Or download and inspect first:

```bash
curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/ccc-bootstrap.sh \
  -o /tmp/ccc.sh && bash /tmp/ccc.sh
```

The script is interactive. You'll be prompted for:

| Prompt | Default | Notes |
|---|---|---|
| Container ID | next available | Auto-detected via `pvesh` |
| Hostname | `ccc-dev` | |
| **Username** | `claude-code` | Your working user — used for SSH, Container Code Companion, code-server |
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

**OS choice** is the first prompt — Ubuntu 24.04 LTS (default), Ubuntu 26.04 LTS, or Debian 13 (Trixie). Ubuntu 24.04 is the compatibility default, Ubuntu 26.04 is available for newer-LTS testing, and Debian 13 is the safer choice when browser automation matters.

After OS selection, the script checks:
1. Canonical status API (`status.canonical.com`) — Ubuntu only, warns on active outages, suggests switching to Debian on major/critical
2. Direct reachability of the apt mirror (`archive.ubuntu.com` or `deb.debian.org`) — prompts to abort if unreachable

Provisioning takes **10–15 minutes**. Each of the 29 steps prints `[N/29]` progress, and the host prints elapsed time every 30 seconds so you can tell it's still running.

### Existing Debian or Ubuntu

Run this on the Debian or Ubuntu machine that should host CCC:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/ccc-install-linux.sh)
```

The Linux-host installer installs CCC services, code-server, baseline dev tools, and required `oculus-configs` integration. It asks whether CCC should use the current user or a dedicated CCC user. It does not change host networking or SSH hardening policy.

---

## Shared Workspace Migration

Fresh installs use `/srv/ccc/projects` as the canonical project root and link `~/projects` there for compatibility.

The generated `~/projects/WELCOME.md` also points new users at the shared workspace, migration commands, per-user CCC profile setup, and the managed GitHub machine key path.

Existing installs can inspect and apply the migration after updating CCC tooling:

```bash
ccc-migrate-shared-workspace --status
sudo ccc-migrate-shared-workspace --apply
```

Before applying migration on an active workstation, save/commit/stash any work and close editors or terminals whose current directory is inside the old project root, such as `/home/oculus/projects`. This prevents new writes from landing in the timestamped backup after the rsync step.

The status command reports whether the `ccc` group and shared root exist, what `~/projects` currently points to, any legacy `~/projects` or `~/repos` entries, and whether the current user has an existing GitHub SSH public key. Apply creates the shared root, adds `CCC_USER` to the `ccc` group, rsyncs old `~/projects/` content into `/srv/ccc/projects/`, renames the old path to a timestamped backup, links `~/projects`, links existing `~/repos` project directories into the shared root without moving them, and repairs group-write/setgid permissions. Permission repair also follows top-level symlinked project directories so legacy repos linked into the shared root become writable by users in the `ccc` group. Backups are retained.

The Projects page also exposes a Shared Workspace panel with Check Migration, Migrate Existing Projects, and Repair Permissions actions for the shared root.

Compatibility note: if `/srv/ccc/projects` is missing or empty but legacy `~/projects` or `~/repos` contains entries, the Projects page lists the legacy root so existing work remains visible before migration is applied. New clone/create operations still target the canonical shared root.

If Check Migration reports that `ccc-migrate-shared-workspace` is not installed, run `sudo ccc-self-update` first. Older installs can receive the newer GUI before the helper command has been written to `/usr/local/bin`.

Migration and account setup output stays visible after the page refreshes. If an action fails, leave the output open and use it as the first troubleshooting source.

## Work Identities

CCC supports multiple local Linux work identities on one personal workstation. Each identity gets its own provider auth/session directories:

- `~/.claude/`
- `~/.codex/`
- `~/.gemini/`
- `~/.gitconfig`
- `~/.ssh/config`

Projects stay shared at `/srv/ccc/projects`. Setup CCC Profile adds the user to `ccc`, grants the shared `ccc` group read/traverse access on that managed home so the dashboard file browser can list it, links `~/projects`, directly syncs Claude/Codex/Gemini config and skills into that user's home from `oculus-configs`, overlays allowlisted provider runtime assets such as Claude/Codex plugins and skills from the primary CCC user, installs the Claude settings/statusline baseline, installs the provider CLIs into `~/.local/bin`, validates those files exist, and repairs shared project permissions. The managed GitHub machine key lives at `/etc/ccc/ssh/github_ed25519`; the GitHub page can generate it, copy the public key, test SSH access, configure work identities, or explicitly promote an existing current-user key. Provider auth tokens are not copied between users. After setup, sign out and back in as the work identity so the new `ccc` group membership is active, then run `claude`, `codex`, `gemini`, and optionally `gh auth login`.

`Setup CCC Profile` also installs the shell environment/PATH helper, installs the Claude Code, Codex, and Gemini CLI binaries into that user's `~/.local`, and adds the login helper so interactive shells that start in the user's home directory automatically enter `~/projects`, which points at `/srv/ccc/projects`.

GitHub CLI authentication is per Linux user. Run `gh auth login` while signed in as that work identity when that user needs `gh pr`, `gh repo`, or other GitHub API commands; Git SSH access can still use the shared machine key configured by CCC.

---

## First Steps

```bash
# 1. SSH in as the working user
ssh claude-code@<container-ip>

# 2. Run first-login onboarding (auto-prompts on first interactive login)
ccc-onboarding

# 3. Authenticate Claude Code
claude

# 4. Sync shared Claude/Codex/Gemini configs and skills from oculus-configs
sudo ccc-sync-agent-configs

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
- **Node.js 22 LTS** — NodeSource `nodejs` with bundled npm verified, plus typescript, ts-node, tsx
- **Python 3** — pip (`--break-system-packages`), venv
- **Go** (latest) — via official tarball, on PATH
- **Rust** (latest) — via rustup, installed for claude-code user

### Tools
- **Search** — ripgrep (`rg`), fd (`fdfind`), fzf, bat (`batcat`)
- **Data** — jq, yq (mikefarah Go binary), sqlite3
- **GitHub CLI** — official `gh` package from `cli.github.com`
- **Codex sandboxing** — bubblewrap (`bwrap`) installed for Codex sandbox prerequisites
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
- **Claude** — CCC-managed `~/.claude/settings.json`, `~/.claude/bin/statusline-command.sh`, plus `~/.claude/CLAUDE.md`, `~/.claude/rules/`, and MCP template from `oculus-configs`
- **Codex** — `~/.codex/AGENTS.md` and `~/.codex/skills/` from `oculus-configs/codex/`
- **Gemini** — `~/.gemini/GEMINI.md` and `~/.gemini/skills/` from `oculus-configs/gemini/`
- **Templates** — copied from `oculus-configs/templates/` into `~/Templates/`
- Sync the current CCC user with `sudo ccc-sync-agent-configs`
- Sync another work identity with `sudo ccc-sync-agent-configs --user <username>`
- Sync all normal login users with `sudo ccc-sync-agent-configs --all-users`
- The Accounts page has `Sync All Agent Configs` for pushing the latest shared config baseline to every normal login user.

### code-server Extensions
Python, Go, Rust Analyzer, Prettier, GitLens, TypeScript Next, Playwright, Vitest Explorer, YAML, TOML, JSON

---

## Native Web UI

Open `http://<container-ip>:9090` after provisioning and sign in with the working user and password you entered during install.

The native UI is built into the Go service, not Cockpit and not a Node dashboard. It currently includes:

- **Overview** — host, IP, uptime, services, projects, SSH session count, resource gauges, update status, and recent logs. SSH counts use login records when available and fall back to `sshd` or `sshd-session` process titles on hosts where `who` is empty.
- **Updates** — separate App and OS tabs; App updates stream `ccc-self-update` output and reconnect after service restart
- **App Catalog** — install/update common workstation tools: Node.js, Go, Python, uv, Playwright, Codex, Claude Code, Gemini CLI, GitHub CLI, bubblewrap, ripgrep, jq, fzf, build-essential, and Aider
- **Files** — browse directories, open/edit text files, create files/folders, rename, and delete
- **Map Drives** — CIFS mount helper with LXC/Proxmox guidance for permission-denied mount failures
- **Projects** — create projects under `/srv/ccc/projects` from templates, initialize git, open in Files, open in code-server, rename, delete, inspect migration status, and repair permissions, including legacy top-level symlinked project directories
- **Terminal** — browser PTY tabs backed by xterm.js, adjustable terminal height, and tmux quick actions
- **Notes** — persistent notes stored in the workstation home directory
- **Accounts** — create users, change passwords, shells, groups, setup CCC profiles, sync agent configs, and delete users
- **Logs, Network, Services** — inspect service state, live network activity, and system logs; network configuration changes should be made from the Proxmox side for LXC containers
- **Provider Configs** — edit Claude, Codex, Gemini, and MCP config files inline
- **GitHub** — manage the shared machine key at `/etc/ccc/ssh/github_ed25519`, copy its public key, test GitHub SSH access, configure work identities, and explicitly promote an existing user key when needed
- **Settings** — theme swatches, editable header message, time/location, mobile-friendly controls, and CRT display effects

Display effects are local browser preferences. Monitor flicker is enabled by default; sync drift can be enabled from Settings.

---

## Project Status

The original GUI punchlist is implemented and the current build is functional for daily workstation use. The remaining work should come from fresh field-testing notes, not the original cleanup list.

Current state:
- Bootstrap provisions the LXC, native UI, code-server, shell helpers, update scripts, and agent config sync.
- Native UI replaces the old Cockpit-style/backend remnants.
- App and OS updates are separated.
- App Catalog can query installed tools and run install/update actions.
- Mobile navigation uses a collapsible drawer.
- GitHub SSH key workflow now uses a managed machine key under `/etc/ccc/ssh` for shared repository access across work identities.
- Map Drives documents the Proxmox/LXC mount limitation and reports CIFS permission failures clearly.

---

## Shell Reference

The `ccc` command prints the full reference. Quick shortcuts:

```bash
# Maintenance
ccc-onboarding          # first-login wizard: git identity, SSH key, GitHub
ccc-setup               # same wizard, safe to re-run
ccc-update-status       # show installed vs GitHub provisioner version
ccc-self-update         # update Container Code Companion tooling from GitHub
ccc-update              # update Container Code Companion tooling + app CLIs
ccc-os-update           # update OS packages with apt
sudo ccc-sync-agent-configs # update Claude/Codex/Gemini configs and skills from oculus-configs
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
sudo systemctl status  container-code-companion.service
sudo systemctl restart container-code-companion.service
```

---

## Statusline

A default statusline script is installed at `~/.claude/bin/statusline-command.sh`.

Output format:
```
claude-code@ccc-dev:/srv/ccc/projects/app (main) [sonnet-4 | think] [ctx:42%] 3:14pm
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

Container Code Companion separates updates so OS packages, workstation tooling, and shared agent behavior can move independently.

Update cadence:
- CCC tooling auto-update runs weekly from cron on Sundays at 3:00 AM ET via `/etc/cron.d/ccc-app-update`.
- `ccc-update-status` checks GitHub when you run it, when the MOTD/status flow invokes it, when Overview refreshes its update panel, or when the Updates page requests status.
- OS package updates and `oculus-configs` agent config sync are manual; run `sudo ccc-os-update` and `sudo ccc-sync-agent-configs` when you want them applied.
- App Catalog package/version checks run on demand from the native UI, not continuously in the background.

The top bar, Overview, and Updates pages show when CCC is checking GitHub with `ccc-update-status`, the most recent browser-session check time, and whether that check returned current, update-available, not-recorded, or failed status. Overview updates this status in place so the dashboard does not redraw after a check completes. Fresh `ccc-update-status` output takes precedence over older self-update logs, and the checker refreshes the persistent source clone from the normalized HTTPS GitHub remote before comparing installed and latest commits.

```bash
sudo ccc-os-update          # OS packages only: apt update/upgrade/autoremove/clean
ccc-update-status           # show installed vs GitHub provisioner version
sudo ccc-self-update        # Container Code Companion tooling: commands, MOTD, native UI service
sudo ccc-sync-agent-configs # shared Claude/Codex/Gemini config from oculus-configs
ccc-migrate-shared-workspace --status # inspect existing ~/projects migration state
ccc-update                  # convenience: tooling + app CLI updates, no apt upgrade
claude update               # Claude Code only
```

`ccc-update-status` shows the installed provisioner commit, latest GitHub commit, behind count, and recent commits. `ccc-self-update` fetches the latest CCC repo, then re-runs the provisioner's marked updateable section so `/usr/local/bin` helper commands, cron, MOTD, the native UI binary/assets, service files, and `/etc/ccc/version` move together. Override `CCC_SELF_UPDATE_REPO`, `CCC_SELF_UPDATE_REF`, or `CCC_SELF_UPDATE_SCRIPT` in `/etc/ccc/config` for forks or private repos.

`ccc-self-update` can be run from the CLI or triggered from the native Updates page in the GUI. The GUI streams live update output via SSE and automatically reconnects after the service restarts. A successful tooling update records `/etc/ccc/version`; a failed build or provisioner step exits non-zero and leaves the error in the log.

Older installs whose `ccc-self-update` predates the updateable-section runner may need a one-time helper refresh:

```bash
curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/install/ccc-provision-workstation.sh \
  -o /tmp/ccc-provision-workstation.sh
sudo bash -lc 'set -a; . /etc/ccc/config; set +a; CCC_UPDATEABLE_ONLY=1 bash /tmp/ccc-provision-workstation.sh'
```

`ccc-sync-agent-configs` keeps `/opt/oculus-configs` as a shared root-owned checkout for the primary CLI sync path. In the GUI, Accounts > Sync Agent Configs and Setup CCC Profile use a direct delivery path: resolve the account home with `getent`, grant the shared `ccc` group read/traverse access on that managed home for dashboard browsing, refresh `oculus-configs`, copy known Claude/Codex/Gemini files and directories into that home, overlay allowlisted runtime asset directories from the primary CCC user, write the CCC-managed Claude `settings.json` and statusline script, chown touched directories, validate the result, and print a created config inventory. The runtime overlay includes directories such as `.claude/plugins`, `.claude/skills`, `.claude/commands`, `.codex/plugins`, `.codex/skills`, and `.gemini/skills`; it does not copy top-level provider credential/session/history files. Accounts > Sync All Agent Configs runs the same direct delivery for every normal login user; Provider Configs shows the managed files plus the synced rules/skills/template directories.

---

## Removing the Container

From your Proxmox host:

```bash
pct stop <CT_ID>
pct destroy <CT_ID>
```

---

## Troubleshooting

**Selected LXC template not found**
```bash
pveam update
pveam available --section system | grep ubuntu-24
pveam available --section system | grep ubuntu-26
pveam available --section system | grep debian-13
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
On Ubuntu 26.04, Chromium/Playwright support can lag upstream releases and Ubuntu's `chromium-browser` package is snap-transitioned. Debian 13 is the safer CCC path when browser automation matters.

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
Check https://status.canonical.com/ — the script checks this automatically after OS selection. If Ubuntu is down, re-run and select option 3 (Debian 13) to bypass Canonical entirely.

**HA registration failed**
Add manually from the Proxmox host:
```bash
ha-manager add ct:<CT_ID> --state started --group <group>
```

**Container Code Companion UI not loading (port 9090)**
```bash
pct exec <CT_ID> -- systemctl status container-code-companion.service
pct exec <CT_ID> -- systemctl restart container-code-companion.service
```
If `container-code-companion.service` cannot bind port 9090, check what owns the port:
```bash
pct exec <CT_ID> -- ss -ltnp | grep ':9090'
```
Older CCC installers used a standalone Node dashboard on port 9090. Container Code Companion does not use that service. Remove the legacy service/process, then start the native UI:
```bash
pct exec <CT_ID> -- systemctl disable --now ccc-dashboard cockpit.socket cockpit.service
pct exec <CT_ID> -- rm -f /etc/systemd/system/ccc-dashboard.service
pct exec <CT_ID> -- systemctl daemon-reload
pct exec <CT_ID> -- systemctl restart container-code-companion.service
```
Open `http://<container-ip>:9090` and sign in with the workstation username and the user password entered during install. The service stores those credentials in `/etc/container-code-companion/env` so the native UI and LXC user stay aligned.

**Self-update fails during "Building Container Code Companion binary"**
The failing compiler output is the real error. Inspect the log:
```bash
sudo tail -160 /var/log/ccc-self-update.log
```
Then rerun:
```bash
sudo ccc-self-update
ccc-update-status
```

**Map Drives fails with `mount: /mnt/share: permission denied`**
This usually means the LXC container is not allowed to perform CIFS mounts. The GUI can call `sudo mount`, but Proxmox controls whether the container has the required mount capability.

Recommended options:
- Mount the SMB/CIFS share on the Proxmox host and bind-mount it into the container.
- Or update the LXC configuration on the Proxmox side to allow the needed mount behavior.

If the error mentions `unknown filesystem type` or `bad option`, confirm `cifs-utils` is installed inside the container.

## Notes

- Root login is disabled. Use `ssh claude-code@<ip>`.
- The selected LXC template is auto-resolved via `pveam` — run `pveam update` on your Proxmox host if it can't be found.
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

Copyright 2026 Parallax Group.

MIT — use, modify, fork freely.
