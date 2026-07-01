#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

CCC_INSTALL_MODE="${CCC_INSTALL_MODE:?CCC_INSTALL_MODE is required}"
CCC_USER="${CCC_USER:?CCC_USER is required}"
CCC_HOME="${CCC_HOME:?CCC_HOME is required}"
CCC_SELF_UPDATE_SCRIPT="${CCC_SELF_UPDATE_SCRIPT:?CCC_SELF_UPDATE_SCRIPT is required}"
CCC_MACHINE_POLICY="${CCC_MACHINE_POLICY:-workstation}"
CCC_CODE_SERVER_SERVICE="${CCC_CODE_SERVER_SERVICE:-code-server@$CCC_USER}"
CCC_SELF_UPDATE_REPO="${CCC_SELF_UPDATE_REPO:-git@github.com:oculus-pllx/CCC.git}"
CCC_SELF_UPDATE_REF="${CCC_SELF_UPDATE_REF:-main}"
CCC_SHARED_GROUP="${CCC_SHARED_GROUP:-ccc}"
CCC_SHARED_PROJECTS="${CCC_SHARED_PROJECTS:-/srv/ccc/projects}"

case "$CCC_INSTALL_MODE" in
  proxmox-lxc|linux-host) ;;
  *)
    echo "[ERROR] Unsupported CCC install mode: $CCC_INSTALL_MODE" >&2
    exit 1
    ;;
esac

if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] Shared CCC provisioner must run as root." >&2
  exit 1
fi

write_ccc_config() {
  mkdir -p /etc/ccc
  mkdir -p /etc/ccc/project-keys
  chown root:"${CCC_SHARED_GROUP:-ccc}" /etc/ccc/project-keys
  chmod 0770 /etc/ccc/project-keys
  cat > /etc/ccc/config <<EOF
CCC_INSTALL_MODE="$CCC_INSTALL_MODE"
CCC_USER="$CCC_USER"
CCC_HOME="$CCC_HOME"
CCC_CODE_SERVER_SERVICE="$CCC_CODE_SERVER_SERVICE"
CCC_SELF_UPDATE_REPO="$CCC_SELF_UPDATE_REPO"
CCC_SELF_UPDATE_REF="$CCC_SELF_UPDATE_REF"
CCC_SELF_UPDATE_SCRIPT="$CCC_SELF_UPDATE_SCRIPT"
CCC_SHARED_GROUP="$CCC_SHARED_GROUP"
CCC_SHARED_PROJECTS="$CCC_SHARED_PROJECTS"
OCULUS_CONFIGS_REPO="https://github.com/oculus-pllx/oculus-configs.git"
OCULUS_CONFIGS_REF="main"
OCULUS_CONFIGS_DIR="/opt/oculus-configs"
EOF
  chmod 0644 /etc/ccc/config
}
_STEPS=29
step() { echo ">>> [$1/${_STEPS}] $2"; }

setup_shared_projects_root() {
  groupadd -f "$CCC_SHARED_GROUP"
  mkdir -p "$CCC_SHARED_PROJECTS"
  chown root:"$CCC_SHARED_GROUP" "$CCC_SHARED_PROJECTS"
  chmod 2775 "$CCC_SHARED_PROJECTS"
  usermod -aG "$CCC_SHARED_GROUP" "$CCC_USER"

  if [[ -L "$CCC_HOME/projects" ]]; then
    ln -sfn "$CCC_SHARED_PROJECTS" "$CCC_HOME/projects"
  elif [[ -d "$CCC_HOME/projects" ]]; then
    if [[ -z "$(find "$CCC_HOME/projects" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      rmdir "$CCC_HOME/projects"
      ln -s "$CCC_SHARED_PROJECTS" "$CCC_HOME/projects"
    else
      echo "    Existing non-empty $CCC_HOME/projects left in place; run migration to move it into $CCC_SHARED_PROJECTS."
    fi
  elif [[ ! -e "$CCC_HOME/projects" ]]; then
    ln -s "$CCC_SHARED_PROJECTS" "$CCC_HOME/projects"
  else
    echo "    Existing $CCC_HOME/projects is not a directory or symlink; run migration before replacing it."
  fi
}

if [[ "${CCC_UPDATEABLE_ONLY:-0}" == "1" ]]; then
  echo ">>> Applying Container Code Companion updateable provisioner sections"
  setup_shared_projects_root
  write_ccc_config
  _ccc_updateable_tmp="$(mktemp /tmp/ccc-updateable.XXXXXX.sh)"
  awk '
    /^# CCC_UPDATEABLE_START/ { flag=1; next }
    /^# CCC_UPDATEABLE_END/ { flag=0 }
    flag
  ' "${BASH_SOURCE[0]}" > "$_ccc_updateable_tmp"
  # shellcheck source=/dev/null
  source "$_ccc_updateable_tmp"
  rm -f "$_ccc_updateable_tmp"
  exit 0
fi

# Disable IPv6 — LXC containers commonly lack IPv6 routing, causes apt/curl failures
if [[ "$CCC_INSTALL_MODE" == "proxmox-lxc" ]]; then
  cat > /etc/sysctl.d/99-disable-ipv6.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl -p /etc/sysctl.d/99-disable-ipv6.conf > /dev/null 2>&1 || true

  # Also force apt IPv4 as belt-and-suspenders
  echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
fi

# ── Locale & Timezone ─────────────────────────────────────────────────────────
step 1 "Locale & timezone"
apt-get update -qq
apt-get install -y -qq locales
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen en_US.UTF-8 > /dev/null 2>&1
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
if [[ "$CCC_MACHINE_POLICY" == "container" ]]; then
  update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
  echo "America/New_York" > /etc/timezone
  dpkg-reconfigure -f noninteractive tzdata
else
  echo "    Existing host timezone left unchanged."
fi

# ── System update ─────────────────────────────────────────────────────────────
step 2 "System update"
if [[ "$CCC_MACHINE_POLICY" == "container" ]]; then
  apt-get upgrade -y -qq
else
  echo "    Existing host package upgrade left to the machine owner."
fi

# ── Core packages ─────────────────────────────────────────────────────────────
step 3 "Core packages"
apt-get install -y -qq \
  git curl wget unzip zip \
  ca-certificates gnupg lsb-release apt-transport-https \
  bash-completion \
  htop nano vim tmux screen \
  jq tree \
  net-tools iproute2 iputils-ping dnsutils \
  openssh-server \
  bubblewrap \
  sudo \
  cron logrotate \
  httpie \
  direnv \
  entr \
  xvfb

# ── GitHub CLI ────────────────────────────────────────────────────────────────
step 4 "GitHub CLI"
mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update -qq
apt-get install -y -qq gh
echo "    gh $(gh --version | head -1 | awk '{print $3}')"

# ── Build tools & dev libraries ───────────────────────────────────────────────
step 5 "Build tools & dev libraries"
apt-get install -y -qq \
  build-essential clang make cmake pkg-config autoconf automake libtool \
  python3 python3-pip python3-venv python3-dev \
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
  libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt-dev

# ── Search & productivity tools ───────────────────────────────────────────────
step 6 "Search & productivity tools"
apt-get install -y -qq \
  ripgrep fd-find fzf bat \
  rsync \
  sqlite3

# ── Database clients + local test servers ─────────────────────────────────────
step 7 "Database clients"
apt-get install -y -qq \
  postgresql-client \
  redis-tools \
  redis-server

# Disable Redis autostart — tests manage their own instances
systemctl disable redis-server 2>/dev/null || true
systemctl stop    redis-server 2>/dev/null || true

# ── yq — mikefarah Go binary (not the apt Python wrapper) ────────────────────
step 8 "yq (mikefarah Go binary)"
YQ_VERSION=$(curl -fsSL "https://api.github.com/repos/mikefarah/yq/releases/latest" \
  | grep '"tag_name":' | cut -d'"' -f4)
curl -fsSL \
  "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
  -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq
echo "    yq $(/usr/local/bin/yq --version | awk '{print $NF}')"

# ── Node.js 22 LTS ───────────────────────────────────────────────────────────
step 9 "Node.js 22 LTS"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs
command -v npm >/dev/null 2>&1 || {
  echo "[ERROR] npm was not installed by the Node.js package."
  exit 1
}
echo "    Node $(node --version) / npm $(npm --version)"

# ── Global npm packages ───────────────────────────────────────────────────────
# Installed into the shared, group-writable prefix (/usr/local/ccc-npm) by the
# "Shared npm global prefix" step inside the updateable region below, so every
# ccc user can run `npm install -g` / `npm update -g` without EACCES.

# ── Go ────────────────────────────────────────────────────────────────────────
step 10 "Go"
GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
echo "    $(/usr/local/go/bin/go version | awk '{print $3}')"

# ── Rust (system — build tooling) ─────────────────────────────────────────────
step 11 "Rust (system)"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path

# ── Workstation user ─────────────────────────────────────────────────────────
step 12 "Creating workstation user"
useradd -m -s /bin/bash -d "$CCC_HOME" "$CCC_USER" 2>/dev/null || true
usermod -aG sudo "$CCC_USER"
echo "$CCC_USER ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$CCC_USER"
chmod 0440 "/etc/sudoers.d/$CCC_USER"
setup_shared_projects_root

write_ccc_config

# ── Rust for workstation user ────────────────────────────────────────────────
step 13 "Rust (workstation user)"
sudo -u "$CCC_USER" env HOME="$CCC_HOME" bash -c '
  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
'

# ── Python testing & linting ecosystem ───────────────────────────────────────
step 14 "Python ecosystem"
echo "    pip3 available — install packages per-project with: pip install --break-system-packages <pkg>"

# ── Claude Code ──────────────────────────────────────────────────────────────
step 15 "Claude Code"
sudo -u "$CCC_USER" env HOME="$CCC_HOME" bash -c '
  curl -fsSL https://claude.ai/install.sh | bash
'

# Claude Code is per-user (native installer, self-updating, lives in ~/.local).
# No global symlink: a /usr/local/bin wrapper (updateable section) dispatches to
# the invoking user's own install so every account runs its own binary.
if [[ -x "$CCC_HOME/.local/bin/claude" ]]; then
  echo "    Claude Code: $CCC_HOME/.local/bin/claude"
else
  echo "[ERROR] Claude binary not found after install — provision failed."
  exit 1
fi

# ── Playwright (headless browser testing) ────────────────────────────────────
# Skipped at provision time — hangs in LXC due to Chromium download size/networking.
# Install manually after provision: npx --yes playwright install --with-deps chromium
step 16 "Playwright (skipped — install manually after provision)"
echo "    Run after provision: npx --yes playwright install --with-deps chromium"

# ── code-server (web VS Code) ─────────────────────────────────────────────────
step 17 "code-server (web VS Code)"
curl -fsSL https://code-server.dev/install.sh | sh
echo "    $(code-server --version 2>/dev/null | head -1 || echo 'installed')"

sudo -u "$CCC_USER" mkdir -p "$CCC_HOME/.config/code-server"
sudo -u "$CCC_USER" mkdir -p "$CCC_HOME/projects"

# Welcome file — opens automatically in code-server on first load
sudo -u "$CCC_USER" tee "$CCC_HOME/projects/WELCOME.md" > /dev/null << 'WELCOMEMD'
# Welcome to Container Code Companion

## First Steps

| Step | Command | Where |
|------|---------|-------|
| 1 | `ccc-onboarding` | SSH terminal — git identity, SSH key, GitHub |
| 2 | `claude` | SSH terminal — authenticate Claude Code |
| 3 | `sudo ccc-sync-agent-configs` | SSH terminal — update Claude/Codex/Gemini config and skills from oculus-configs |
| 4 | `ccc-install-playwright` | SSH terminal — headless browser testing (optional) |
| 5 | `ccc-install-codex` | SSH terminal — OpenAI Codex CLI (optional) |
| 6 | `ccc-install-jcodemunch` | SSH terminal — jCodeMunch MCP, 95% token reduction (optional) |
| 7 | `ccc` | SSH terminal — full command reference |

## This Interface (code-server)

- **New terminal tab**: Terminal → New Terminal (or click **+** in terminal tab bar)
- **Split terminal**: click the split icon in the terminal tab bar
- **Switch tabs**: click tab names in the right-side tab panel
- **Open folder**: File → Open Folder → `/srv/ccc/projects`

## Shared Workspace

- **Canonical project root**: `/srv/ccc/projects`
- **Compatibility path**: `~/projects`
- **Existing installs**: use Container Code Companion → Projects → Shared Workspace → Check Migration, then Migrate Existing Projects after saving work.

CLI migration commands:

```bash
ccc-migrate-shared-workspace --status
sudo ccc-migrate-shared-workspace --apply
```

## Work Identities

Use Container Code Companion → Accounts → Setup CCC Profile for each additional Linux user. Each user keeps separate Claude, Codex, Gemini, Git, and SSH config state while sharing `/srv/ccc/projects`.

Setup CCC Profile syncs config and skills into that user's home, installs a per-user Claude Code CLI into `~/.local/bin` (Codex and Gemini CLIs are shared from `/usr/local/ccc-npm`), and repairs shared project permissions. Sign out and back in after setup so the new `ccc` group membership is active.

First-login checklist for each work identity:

```bash
claude
codex
gemini
gh auth login   # optional
```

## GitHub Machine Key

The managed repository SSH key is stored at:

```text
/etc/ccc/ssh/github_ed25519
```

Use Container Code Companion → GitHub to generate/copy/test the key, configure it for work identities, or explicitly promote an existing user key.

## tmux (SSH sessions)

```bash
tmux                  # start / attach to session
tmux new -s work      # named session
Ctrl+B c              # new window
Ctrl+B |              # split vertical
Ctrl+B -              # split horizontal
Alt+Arrow             # switch panes (no prefix)
Ctrl+B d              # detach (session keeps running)
```

## Container Code Companion UI (port 9090)

Native headless management UI for system overview, services, logs, files, projects, updates, terminal, and agent configs. Use code-server on port 8080 for full IDE workflows.

## Quick Commands

```bash
ccc-onboarding     # first-login wizard
ccc-update         # update Container Code Companion tooling + app CLIs
ccc-os-update      # update OS packages with apt
sudo ccc-sync-agent-configs # update Claude/Codex/Gemini config and skills
ccc-migrate-shared-workspace --status # inspect shared workspace migration state
ccc-doctor         # health check
ccc                # full help
```

## SSH Access

```bash
ssh <your-username>@<this-container-ip>
```
WELCOMEMD

# User-level code-server settings (applies to all workspaces)
sudo -u "$CCC_USER" mkdir -p "$CCC_HOME/.local/share/code-server/User"
sudo -u "$CCC_USER" tee "$CCC_HOME/.local/share/code-server/User/settings.json" > /dev/null << 'USERSETTINGS'
{
  "terminal.integrated.tabs.enabled": true,
  "terminal.integrated.tabs.location": "right",
  "terminal.integrated.defaultProfile.linux": "bash",
  "workbench.startupEditor": "none",
  "markdown.preview.openMarkdownLinks": "inEditor"
}
USERSETTINGS

# Workspace settings
sudo -u "$CCC_USER" mkdir -p "$CCC_HOME/projects/.vscode"
sudo -u "$CCC_USER" tee "$CCC_HOME/projects/.vscode/settings.json" > /dev/null << 'VSCSETTINGS'
{
  "workbench.startupEditor": "none"
}
VSCSETTINGS

sudo -u "$CCC_USER" tee "$CCC_HOME/projects/.vscode/extensions.json" > /dev/null << 'VSCEXT'
{
  "recommendations": []
}
VSCEXT

systemctl enable "$CCC_CODE_SERVER_SERVICE"
echo "    code-server service enabled (config injected next step)"

# ── SSH hardening ─────────────────────────────────────────────────────────────
step 18 "SSH hardening"
if [[ "$CCC_MACHINE_POLICY" == "container" ]]; then
  sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/"               /etc/ssh/sshd_config
  sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
  sed -i "s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/"     /etc/ssh/sshd_config
  grep -q "^MaxAuthTries"        /etc/ssh/sshd_config || echo "MaxAuthTries 5"          >> /etc/ssh/sshd_config
  grep -q "^LoginGraceTime"      /etc/ssh/sshd_config || echo "LoginGraceTime 30"       >> /etc/ssh/sshd_config
  grep -q "^ClientAliveInterval" /etc/ssh/sshd_config || echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config
  systemctl enable ssh
  systemctl restart ssh
else
  echo "    Existing host SSH policy left unchanged."
fi

# CCC_UPDATEABLE_START — sections below re-run by ccc-self-update
# When run standalone via self-update, step() may not be defined — provide a no-op fallback.
command -v step >/dev/null 2>&1 || step() { echo ">>> $2"; }
[[ -r /etc/ccc/config ]] && source /etc/ccc/config

# ── Shared npm global prefix (group-writable) ────────────────────────────────
# One shared, setgid, group-writable prefix so any ccc user can install/update
# global npm packages. Replaces the old root-owned system prefix that caused
# intermittent EACCES for non-root users.
step 19 "Shared npm global prefix"
CCC_NPM_PREFIX="/usr/local/ccc-npm"
mkdir -p "$CCC_NPM_PREFIX"
chown root:"${CCC_SHARED_GROUP:-ccc}" "$CCC_NPM_PREFIX"
chmod 2775 "$CCC_NPM_PREFIX"
cat > /etc/npmrc <<EOF
prefix=$CCC_NPM_PREFIX
EOF
chmod 0644 /etc/npmrc
# npm does NOT read /etc/npmrc — its global config is <node-prefix>/etc/npmrc
# (e.g. /usr/etc/npmrc for a NodeSource /usr install). Write the prefix into the
# path npm actually resolves so non-login npm invocations honor the shared prefix.
if command -v npm >/dev/null 2>&1; then
  _npm_globalcfg="$(npm config get globalconfig 2>/dev/null)"
  if [[ -n "$_npm_globalcfg" && "$_npm_globalcfg" != "undefined" ]]; then
    mkdir -p "$(dirname "$_npm_globalcfg")"
    if [[ -f "$_npm_globalcfg" ]] && grep -q '^prefix=' "$_npm_globalcfg"; then
      sed -i "s|^prefix=.*|prefix=$CCC_NPM_PREFIX|" "$_npm_globalcfg"
    else
      echo "prefix=$CCC_NPM_PREFIX" >> "$_npm_globalcfg"
    fi
    chmod 0644 "$_npm_globalcfg"
  fi
fi
cat > /etc/profile.d/ccc-npm-path.sh <<'NPMPATHEOF'
# Shared CCC npm global prefix for all users (login shells, incl. the web terminal).
# NPM_CONFIG_PREFIX is the reliable cross-user knob — npm ignores /etc/npmrc.
export NPM_CONFIG_PREFIX=/usr/local/ccc-npm
case ":$PATH:" in
  *:/usr/local/ccc-npm/bin:*) ;;
  *) export PATH="/usr/local/ccc-npm/bin:$PATH" ;;
esac
NPMPATHEOF
chmod 0644 /etc/profile.d/ccc-npm-path.sh
if command -v npm >/dev/null 2>&1; then
  npm install -g --prefix "$CCC_NPM_PREFIX" typescript ts-node tsx @openai/codex @google/gemini-cli || true
  # Keep the installed tree group-writable so any ccc user can update it later.
  chgrp -R "${CCC_SHARED_GROUP:-ccc}" "$CCC_NPM_PREFIX" 2>/dev/null || true
  chmod -R g+rwX "$CCC_NPM_PREFIX" 2>/dev/null || true
  find "$CCC_NPM_PREFIX" -type d -exec chmod g+s {} + 2>/dev/null || true
fi

# Claude Code must NOT live in the shared npm prefix — it is per-user (native
# installer in ~/.local, self-updating). Purge any npm-installed copy that would
# shadow the per-user binaries on PATH.
rm -rf "$CCC_NPM_PREFIX/lib/node_modules/@anthropic-ai/claude-code" 2>/dev/null || true
rm -f "$CCC_NPM_PREFIX/bin/claude" 2>/dev/null || true

# Codex and Gemini are the opposite: shared-prefix only. Login shells put
# ~/.local/bin ahead of /usr/local/ccc-npm/bin, so a stale per-user npm copy
# left over from the pre-shared-prefix layout shadows the shared CLI and pins
# that account (and the web UI Tools page) to an old version forever. Purge
# them; Claude Code in ~/.local stays untouched.
for _ccc_user_home in /home/*; do
  [[ -d "$_ccc_user_home" ]] || continue
  rm -f "$_ccc_user_home/.local/bin/codex" "$_ccc_user_home/.local/bin/gemini" 2>/dev/null || true
  rm -rf "$_ccc_user_home/.local/lib/node_modules/@openai/codex" \
         "$_ccc_user_home/.local/lib/node_modules/@google/gemini-cli" 2>/dev/null || true
done

# ── Per-user Claude Code dispatch wrapper ─────────────────────────────────────
# Replaces the old global symlink that pointed every account at the primary
# user's binary (unreadable to others). Each account keeps its own native
# install in ~/.local/bin; this wrapper covers non-login contexts where that
# directory is not yet on PATH.
rm -f /usr/local/bin/claude
cat > /usr/local/bin/claude <<'CLAUDEWRAP'
#!/bin/bash
# CCC: Claude Code is installed per-user via the native installer.
if [[ -x "$HOME/.local/bin/claude" ]]; then
  exec "$HOME/.local/bin/claude" "$@"
fi
echo "Claude Code is not installed for $(id -un)." >&2
echo "Install it with:  curl -fsSL https://claude.ai/install.sh | bash" >&2
exit 127
CLAUDEWRAP
chmod 0755 /usr/local/bin/claude

# ── Machine-wide shell environment ───────────────────────────────────────────
# One shared person, many accounts: env, aliases, and the ccc() helper are
# machine-wide instead of appended per-user to ~/.bashrc.
step 20 "Shell environment (machine-wide)"
cat > /etc/profile.d/ccc-env.sh <<'CCCENV'
# CCC shared environment (login shells).
export EDITOR=vim
export VISUAL=vim
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
CCCENV
chmod 0644 /etc/profile.d/ccc-env.sh

mkdir -p /etc/ccc
cat > /etc/ccc/ccc-shell.sh <<'CCCSHELL'
# CCC interactive shell helpers — sourced from /etc/bash.bashrc for every user.
[[ $- == *i* ]] || return 0

alias ll='ls -alF'
alias gs='git status'
alias gl='git log --oneline -15'
alias gd='git diff'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
command -v batcat >/dev/null 2>&1 && alias bat='batcat'
command -v fdfind >/dev/null 2>&1 && alias fd='fdfind'
alias py='python3'
alias serve='python3 -m http.server'

ccc() {
  cat <<'CCCHELP'
CCC commands:
  ccc-update                 Update CCC app + Claude/Codex/Gemini CLIs + Node.js
  ccc-os-update              OS package updates (apt)
  ccc-setup                  First-login wizard (git identity, GitHub key info)
  ccc-doctor                 Health check
  ccc-sync-agent-configs     Re-sync agent configs from oculus-configs
  ccc-install-playwright     Install Playwright + Chromium
  ccc-install-codex          Install/update Codex CLI (shared prefix)
  ccc-update-status          Check if a CCC update is available
CCCHELP
}

# Land in the shared projects workspace on new interactive logins.
if [[ -z "${CCC_NO_AUTOCD:-}" && $(id -u) -ge 1000 && "$PWD" == "$HOME" && -d "$HOME/projects" ]]; then
  cd "$HOME/projects" || true
fi

# First-login onboarding nudge.
if [[ $(id -u) -ge 1000 && ! -f "$HOME/.ccc-onboarded" && -x /usr/local/bin/ccc-setup ]]; then
  echo
  echo "  Welcome! Run 'ccc-setup' to configure your git identity."
  echo
fi
CCCSHELL
chmod 0644 /etc/ccc/ccc-shell.sh

if ! grep -q "ccc-shell.sh" /etc/bash.bashrc 2>/dev/null; then
  cat >> /etc/bash.bashrc <<'BASHHOOK'

# CCC shared shell helpers (aliases, ccc() help, login behavior)
[ -f /etc/ccc/ccc-shell.sh ] && . /etc/ccc/ccc-shell.sh
BASHHOOK
fi

# ── Shared permission model enforcement ──────────────────────────────────────
# Cheap, idempotent: keep the projects root setgid + ccc-owned so new project
# subdirs inherit group ownership. A one-time recursive repair (gated by a
# sentinel) fixes projects that predate this model on already-running machines.
step 21 "Shared permission model"
mkdir -p "$CCC_SHARED_PROJECTS"
chown root:"${CCC_SHARED_GROUP:-ccc}" "$CCC_SHARED_PROJECTS"
chmod 2775 "$CCC_SHARED_PROJECTS"
if [[ ! -f /etc/ccc/.perms-model-v1 ]]; then
  echo "    Repairing existing project permissions (one-time)..."
  chgrp -R "${CCC_SHARED_GROUP:-ccc}" "$CCC_SHARED_PROJECTS" 2>/dev/null || true
  chmod -R g+rwX "$CCC_SHARED_PROJECTS" 2>/dev/null || true
  find "$CCC_SHARED_PROJECTS" -type d -exec chmod g+s {} + 2>/dev/null || true
  mkdir -p /etc/ccc
  touch /etc/ccc/.perms-model-v1
fi
# Ensure the running service unit carries UMask=0002 so files the app writes are
# group-writable. The full unit heredoc is gated behind CCC_UPDATEABLE_ONLY!=1
# (to avoid regenerating the session token), so deliver this one directive here —
# this block DOES run under ccc-self-update. Idempotent; daemon-reload so the
# self-update restart picks it up.
_ccc_unit=/etc/systemd/system/container-code-companion.service
if [[ -f "$_ccc_unit" ]] && ! grep -q '^UMask=' "$_ccc_unit"; then
  sed -i '/^\[Service\]/a UMask=0002' "$_ccc_unit"
  systemctl daemon-reload 2>/dev/null || true
  echo "    Injected UMask=0002 into container-code-companion.service"
fi
# Project SSH keys are shared per-project keys, group-readable (0640, group ccc)
# so every team member uses one key — modern OpenSSH accepts a 0640 key. The
# catch: a group-read mode an agent OWNS is one the agent can revert. A
# long-running agent session repeatedly chmod'd a project key back to 0600,
# breaking shared access. Fix: make private keys root-owned, so a non-root agent
# physically cannot chmod them (EPERM). ccc-fix-key-perms enforces this and the
# app invokes it (via the CCC user's passwordless sudo) right after generating a
# key. Installing + sweeping here, in the ungated block, delivers it to running
# boxes via ccc-self-update.
cat > /usr/local/bin/ccc-fix-key-perms << 'KEYPERMSCRIPT'
#!/usr/bin/env bash
# Enforce ownership/permissions on CCC project SSH keys so a non-root agent
# cannot revert a shared key to owner-only.
# Usage: ccc-fix-key-perms [project-name]   (no arg = sweep all projects)
# Private key -> root:ccc 0640, public key -> root:ccc 0644, dir -> :ccc 0750.
set -u
KEYS_ROOT="/etc/ccc/project-keys"
GROUP="${CCC_SHARED_GROUP:-ccc}"
[ -d "$KEYS_ROOT" ] || exit 0

fix_one() {
  d="$1"
  [ -d "$d" ] || return 0
  case "$d" in "$KEYS_ROOT"/*) ;; *) return 0;; esac  # never escape the keys root
  chgrp "$GROUP" "$d" 2>/dev/null || true
  chmod 0750 "$d" 2>/dev/null || true
  if [ -f "$d/id_ed25519" ]; then
    chown root:"$GROUP" "$d/id_ed25519" 2>/dev/null || true
    chmod 0640 "$d/id_ed25519" 2>/dev/null || true
  fi
  if [ -f "$d/id_ed25519.pub" ]; then
    chown root:"$GROUP" "$d/id_ed25519.pub" 2>/dev/null || true
    chmod 0644 "$d/id_ed25519.pub" 2>/dev/null || true
  fi
}

if [ "$#" -ge 1 ] && [ -n "$1" ]; then
  name="$(basename -- "$1")"          # basename strips any path traversal
  fix_one "$KEYS_ROOT/$name"
else
  for d in "$KEYS_ROOT"/*/; do fix_one "$d"; done
fi
KEYPERMSCRIPT
chmod 0755 /usr/local/bin/ccc-fix-key-perms
/usr/local/bin/ccc-fix-key-perms || true
# Patch stale script name written by older provisioners without changing the active installer mode.
if [[ -f /etc/ccc/config ]] && grep -q '^CCC_SELF_UPDATE_SCRIPT="oculus-commander.sh"' /etc/ccc/config; then
  sed -i 's|^CCC_SELF_UPDATE_SCRIPT=.*|CCC_SELF_UPDATE_SCRIPT="ccc-bootstrap.sh"|' /etc/ccc/config
fi
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
if ! id "$CCC_USER" &>/dev/null; then
  if [[ -r /etc/container-code-companion/env ]]; then
    _ccc_ui_user=$(awk -F= '/^CONTAINER_CODE_COMPANION_USERNAME=/{print $2; exit}' /etc/container-code-companion/env)
    CCC_USER="${_ccc_ui_user:-$CCC_USER}"
    CCC_HOME="/home/$CCC_USER"
  fi
fi
if ! id "$CCC_USER" &>/dev/null; then
  CCC_USER="$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' /etc/passwd)"
  CCC_HOME="/home/$CCC_USER"
fi
if ! id "$CCC_USER" &>/dev/null; then
  echo "Could not determine Container Code Companion user. Set CCC_USER in /etc/ccc/config." >&2
  exit 1
fi


# Remove retired Cockpit kit and standalone dashboard helpers before Cockpit claims 9090.
rm -f /usr/local/bin/ccc-kit
systemctl disable --now ccc-kit-manager 2>/dev/null || true
rm -f /etc/systemd/system/ccc-kit-manager.service
systemctl disable --now ccc-dashboard 2>/dev/null || true
rm -f /etc/systemd/system/ccc-dashboard.service
if [[ "${CCC_UPDATEABLE_ONLY:-0}" != "1" ]]; then
  if command -v fuser >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':9090 '; then
    fuser -k 9090/tcp 2>/dev/null || true
  fi
fi
systemctl daemon-reload 2>/dev/null || true
rm -rf /usr/share/cockpit/ccc /usr/local/lib/ccc "$CCC_HOME/.ccc/kit-manager"

# ── Agent config sync command ────────────────────────────────────────────────
cat > /usr/local/bin/ccc-sync-agent-configs << 'AGENTCONFIGSYNCSCRIPT'
#!/bin/bash
set -euo pipefail
if [[ -n "${NO_COLOR:-}" ]]; then
  B=''; G=''; C=''; Y=''; R=''; N=''
else
  B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
fi
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
OCULUS_CONFIGS_REPO="${OCULUS_CONFIGS_REPO:-https://github.com/oculus-pllx/oculus-configs.git}"
OCULUS_CONFIGS_REF="${OCULUS_CONFIGS_REF:-main}"
OCULUS_CONFIGS_DIR="${OCULUS_CONFIGS_DIR:-/opt/oculus-configs}"
PULL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull) PULL=0; shift ;;
    --user)
      CCC_USER="${2:?--user requires a username}"
      CCC_HOME="$(getent passwd "$CCC_USER" | cut -d: -f6)"
      [[ -n "$CCC_HOME" ]] || { echo "Unknown user: $CCC_USER" >&2; exit 1; }
      shift 2
      ;;
    --all-users)
      getent passwd | awk -F: '$3 >= 1000 && $7 !~ /(nologin|false)$/ {print $1}' | while read -r user; do
        sudo NO_COLOR="${NO_COLOR:-}" ccc-sync-agent-configs --user "$user"
      done
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { echo -e "  $*"; }
ok()   { say "${G}✓${N} $*"; }
warn2(){ say "${Y}!${N} $*"; }
chown_if_root() { [[ "$(id -u)" -eq 0 ]] && chown "$@" || true; }

run_as_user() {
  if [[ "$(id -u)" -eq 0 && "$CCC_USER" != "root" ]]; then
    sudo -u "$CCC_USER" env HOME="$CCC_HOME" GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' "$@"
  else
    env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' "$@"
  fi
}

backup_file() {
  local dest=$1
  [[ -f "$dest" ]] || return 0
  cp "$dest" "${dest}.bak.$(date +%Y%m%d%H%M%S)"
}

copy_managed_file() {
  local src=$1 dest=$2 label=$3
  if [[ ! -f "$src" ]]; then
    warn2 "oculus-configs: $label not found, skipping"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  backup_file "$dest"
  cp "$src" "$dest"
  chown_if_root "$CCC_USER:$CCC_USER" "$dest"
  ok "$label synced"
}

copy_optional_dir() {
  local src=$1 dest=$2 label=$3
  mkdir -p "$dest"
  if [[ ! -d "$src" ]]; then
    warn2 "oculus-configs: $label not found, skipping"
    chown_if_root -R "$CCC_USER:$CCC_USER" "$dest"
    return 0
  fi
  cp -a "$src"/. "$dest"/
  chown_if_root -R "$CCC_USER:$CCC_USER" "$dest"
  ok "$label synced"
}

write_claude_baseline() {
  mkdir -p "$CCC_HOME/.claude/bin"
  if [[ ! -f "$CCC_HOME/.claude/settings.json" ]]; then
    cat > "$CCC_HOME/.claude/settings.json" << 'CLAUDESETTINGS'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "defaultMode": "bypassPermissions"
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",
    "MAX_THINKING_TOKENS": "31999"
  },
  "alwaysThinkingEnabled": true,
  "enableRemoteControl": true,
  "statusLine": {"type": "command", "command": "~/.claude/bin/statusline-command.sh"},
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true,
    "frontend-design@claude-plugins-official": true,
    "skill-creator@claude-plugins-official": true
  }
}
CLAUDESETTINGS
    chown_if_root "$CCC_USER:$CCC_USER" "$CCC_HOME/.claude/settings.json"
    ok "Claude settings written"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$CCC_HOME/.claude/settings.json" <<'MERGESETTINGS'
import json, sys
path = sys.argv[1]
try:
    data = json.loads(open(path).read())
except Exception:
    data = {}
# Older provisions wrote an invalid tool-glob allowlist (e.g. "Bash(*)") that
# Claude Code never honored. Strip it and use the supported knob instead.
legacy = {"Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "MultiEdit(*)", "WebFetch(*)", "WebSearch(*)", "TodoRead(*)", "TodoWrite(*)", "Grep(*)", "Glob(*)", "LS(*)", "Task(*)", "mcp__*"}
perms = data.setdefault("permissions", {})
allows = [a for a in perms.get("allow", []) if a not in legacy]
if allows:
    perms["allow"] = allows
else:
    perms.pop("allow", None)
perms.setdefault("defaultMode", "bypassPermissions")
env = data.setdefault("env", {})
for k, v in {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1", "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000", "MAX_THINKING_TOKENS": "31999"}.items():
    env.setdefault(k, v)
data.setdefault("alwaysThinkingEnabled", True)
data.setdefault("enableRemoteControl", True)
sl = data.get("statusLine", {})
if not isinstance(sl, dict): sl = {"command": str(sl)}
sl.setdefault("type", "command")
sl.setdefault("command", "~/.claude/bin/statusline-command.sh")
data["statusLine"] = sl
ep = data.setdefault("enabledPlugins", {})
for k in ["superpowers@claude-plugins-official", "frontend-design@claude-plugins-official", "skill-creator@claude-plugins-official"]:
    ep.setdefault(k, True)
data.setdefault("$schema", "https://json.schemastore.org/claude-code-settings.json")
open(path, "w").write(json.dumps(data, indent=2) + "\n")
MERGESETTINGS
    chown_if_root "$CCC_USER:$CCC_USER" "$CCC_HOME/.claude/settings.json"
    ok "Claude settings merged"
  fi
  if [[ ! -f "$CCC_HOME/.claude/bin/statusline-command.sh" ]]; then
    cat > "$CCC_HOME/.claude/bin/statusline-command.sh" << 'CLAUDESTATUSLINE'
#!/bin/bash
set -euo pipefail
INPUT=$(cat 2>/dev/null || echo '{}')
if command -v jq &>/dev/null; then
  MODEL=$(echo "$INPUT" | jq -r '.model.id // ""' 2>/dev/null | sed 's/claude-//;s/-[0-9]\{8\}.*//')
  THINKING=$(echo "$INPUT" | jq -r '.thinking.enabled // false' 2>/dev/null)
  CTX_USED=$(echo "$INPUT" | jq -r '.context.used // 0' 2>/dev/null)
  CTX_MAX=$(echo "$INPUT" | jq -r '.context.max // 200000' 2>/dev/null)
else
  MODEL="claude"; THINKING="false"; CTX_USED=0; CTX_MAX=200000
fi
[[ -z "$MODEL" ]] && MODEL="claude"
CTX_PCT=0
[[ "$CTX_MAX" -gt 0 ]] && CTX_PCT=$(( CTX_USED * 100 / CTX_MAX ))
CTX_WARN=""
[[ $CTX_PCT -ge 85 ]] && CTX_WARN="!!"
[[ $CTX_PCT -ge 60 && $CTX_PCT -lt 85 ]] && CTX_WARN="!"
THINK=""
[[ "$THINKING" == "true" ]] && THINK=" | think"
GIT_BRANCH=""
git rev-parse --is-inside-work-tree &>/dev/null 2>&1 && GIT_BRANCH=" ($(git branch --show-current 2>/dev/null || echo detached))"
DIR=$(pwd | sed "s|^$HOME|~|")
TIME=$(date +"%I:%M%p" | sed 's/^0//' | tr '[:upper:]' '[:lower:]')
echo "${USER}@$(hostname -s):${DIR}${GIT_BRANCH} [${MODEL}${THINK}] [ctx:${CTX_PCT}%${CTX_WARN}] ${TIME}"
CLAUDESTATUSLINE
    chmod +x "$CCC_HOME/.claude/bin/statusline-command.sh"
    chown_if_root "$CCC_USER:$CCC_USER" "$CCC_HOME/.claude/bin/statusline-command.sh"
    ok "Claude statusline written"
  fi
}

write_tmux_config() {
  cat > "$CCC_HOME/.tmux.conf" << 'TMUXCONF'
set -g mouse on
set -g default-terminal "screen-256color"
set -g history-limit 10000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# Status bar
set -g status-style bg=colour235,fg=colour136
set -g status-left "#[bold]#S #[default]"
set -g status-right "#[fg=colour136]%H:%M %d-%b#[default]"
set -g status-interval 30

# Easier splits: | and -
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# New window keeps current path
bind c new-window -c "#{pane_current_path}"

# Quick pane navigation with Alt+arrow (no prefix)
bind -n M-Left  select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up    select-pane -U
bind -n M-Down  select-pane -D
TMUXCONF
  chown_if_root "$CCC_USER:$CCC_USER" "$CCC_HOME/.tmux.conf"

  # Machine-wide clipboard for ALL users (oculus, prime, terminus, future).
  # tmux reads /etc/tmux.conf before every ~/.tmux.conf. ',*:clipboard'
  # declares the Ms (OSC 52) capability for every terminal type, so copy-mode
  # actually emits the escape over SSH instead of only filling the tmux buffer.
  # Paste stays normal terminal paste (OSC 52 read is disabled everywhere).
  if [[ "$(id -u)" -eq 0 ]]; then
    cat > /etc/tmux.conf <<'ETCTMUX'
# Managed by CCC provisioner (install/ccc-provision-workstation.sh).
# Machine-wide tmux defaults for ALL users — loaded before each ~/.tmux.conf.
# OSC 52 clipboard: lets "copy in tmux" travel over SSH to the client's native
# clipboard (e.g. Windows). Paste is ordinary terminal paste (Ctrl+Shift+V).
set -g set-clipboard on
set -g allow-passthrough on
set -ga terminal-features ',*:clipboard'
ETCTMUX
    chmod 0644 /etc/tmux.conf
    ok "/etc/tmux.conf written (machine-wide OSC 52 clipboard)"
  fi
  ok "tmux config written"
}

install_claude_plugins() {
  local cache="$CCC_HOME/.claude/plugins/cache/claude-plugins-official"
  mkdir -p "$cache"
  if [[ ! -d "$cache/superpowers" ]] || [[ -z "$(ls -A "$cache/superpowers/5.1.0" 2>/dev/null)" ]]; then
    rm -rf "$cache/superpowers"
    git clone --quiet --depth 1 --branch v5.1.0 https://github.com/obra/superpowers "$cache/superpowers/5.1.0" 2>/dev/null \
      && ok "superpowers plugin installed" \
      || warn2 "superpowers plugin install failed (network?)"
  fi
  local need_cpo=0
  [[ ! -d "$cache/frontend-design" ]] && need_cpo=1
  [[ ! -d "$cache/skill-creator" ]] && need_cpo=1
  if [[ $need_cpo -eq 1 ]]; then
    local tmp
    tmp=$(mktemp -d)
    if git clone --quiet --depth 1 --filter=blob:none --sparse https://github.com/anthropics/claude-plugins-official "$tmp" 2>/dev/null; then
      git -C "$tmp" sparse-checkout set plugins/frontend-design plugins/skill-creator 2>/dev/null
      if [[ ! -d "$cache/frontend-design" && -d "$tmp/plugins/frontend-design" ]]; then
        mkdir -p "$cache/frontend-design"
        cp -r "$tmp/plugins/frontend-design" "$cache/frontend-design/unknown"
        ok "frontend-design plugin installed"
      fi
      if [[ ! -d "$cache/skill-creator" && -d "$tmp/plugins/skill-creator" ]]; then
        mkdir -p "$cache/skill-creator"
        cp -r "$tmp/plugins/skill-creator" "$cache/skill-creator/unknown"
        ok "skill-creator plugin installed"
      fi
    else
      warn2 "anthropics plugin clone failed (network?)"
    fi
    rm -rf "$tmp"
  fi
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$CCC_HOME" <<'REGISTRYGEN'
import json, os, sys, glob
from datetime import datetime, timezone
home = sys.argv[1]
cache = home + "/.claude/plugins/cache"
plugins = {}
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
for mkt_path in sorted(glob.glob(cache + "/*")):
    if not os.path.isdir(mkt_path): continue
    mkt = os.path.basename(mkt_path)
    for plugin_path in sorted(glob.glob(mkt_path + "/*")):
        if not os.path.isdir(plugin_path): continue
        plugin = os.path.basename(plugin_path)
        try: vdirs = sorted(d for d in os.listdir(plugin_path) if os.path.isdir(os.path.join(plugin_path, d)))
        except OSError: continue
        version = vdirs[0] if vdirs else "unknown"
        install_path = os.path.join(plugin_path, version) if vdirs else plugin_path
        plugins[plugin + "@" + mkt] = [{"scope": "user", "installPath": install_path, "version": version, "installedAt": now, "lastUpdated": now}]
open(home + "/.claude/plugins/installed_plugins.json", "w").write(json.dumps({"version": 2, "plugins": plugins, "enabledPlugins": {k: True for k in plugins}}, indent=2) + "\n")
known_file = home + "/.claude/plugins/known_marketplaces.json"
try:
    with open(known_file) as f: known = json.load(f)
except Exception: known = {}
for k in list(known):
    loc = known[k].get("installLocation", "")
    if loc and not loc.startswith(home + "/"): known[k]["installLocation"] = home + "/.claude/plugins/marketplaces/" + k
if "claude-plugins-official" not in known:
    known["claude-plugins-official"] = {"source": {"source": "github", "repo": "anthropics/claude-plugins-official"}, "installLocation": home + "/.claude/plugins/marketplaces/claude-plugins-official", "lastUpdated": now}
for k in known: os.makedirs(known[k].get("installLocation", ""), exist_ok=True)
open(known_file, "w").write(json.dumps(known, indent=2) + "\n")
REGISTRYGEN
  chown_if_root -R "$CCC_USER:$CCC_USER" "$CCC_HOME/.claude/plugins"
  ok "plugin registry updated"
}

echo ""
echo -e "${B}Agent Config Sync${N}"
echo -e "  Source: ${C}${OCULUS_CONFIGS_REPO}${N} (${OCULUS_CONFIGS_REF})"
echo ""

mkdir -p "$CCC_HOME/projects" "$CCC_HOME/.claude" "$CCC_HOME/.codex" "$CCC_HOME/.gemini" "$CCC_HOME/Templates"
chown_if_root -R "$CCC_USER:$CCC_USER" "$CCC_HOME/.claude" "$CCC_HOME/.codex" "$CCC_HOME/.gemini" "$CCC_HOME/Templates"

if [[ ! -d "$OCULUS_CONFIGS_DIR/.git" ]]; then
  rm -rf "$OCULUS_CONFIGS_DIR"
  git clone --depth 1 --branch "$OCULUS_CONFIGS_REF" "$OCULUS_CONFIGS_REPO" "$OCULUS_CONFIGS_DIR"
  chown_if_root -R root:root "$OCULUS_CONFIGS_DIR"
  git config --system safe.directory "*" 2>/dev/null || true
  ok "oculus-configs cloned"
elif [[ "$PULL" -eq 1 ]]; then
  chown_if_root -R root:root "$OCULUS_CONFIGS_DIR"
  git config --system safe.directory "*" 2>/dev/null || true
  git -c "safe.directory=$OCULUS_CONFIGS_DIR" -C "$OCULUS_CONFIGS_DIR" fetch --depth 1 origin "$OCULUS_CONFIGS_REF"
  git -c "safe.directory=$OCULUS_CONFIGS_DIR" -C "$OCULUS_CONFIGS_DIR" checkout -q "$OCULUS_CONFIGS_REF" 2>/dev/null || git -c "safe.directory=$OCULUS_CONFIGS_DIR" -C "$OCULUS_CONFIGS_DIR" checkout -q -B "$OCULUS_CONFIGS_REF"
  git -c "safe.directory=$OCULUS_CONFIGS_DIR" -C "$OCULUS_CONFIGS_DIR" reset --hard "origin/$OCULUS_CONFIGS_REF" >/dev/null
  ok "oculus-configs updated"
else
  ok "oculus-configs checkout present"
fi

write_claude_baseline
write_tmux_config
copy_managed_file "$OCULUS_CONFIGS_DIR/claude/CLAUDE.md" "$CCC_HOME/.claude/CLAUDE.md" "Claude CLAUDE.md"
copy_optional_dir "$OCULUS_CONFIGS_DIR/claude/rules" "$CCC_HOME/.claude/rules" "Claude rules"

if [[ -f "$OCULUS_CONFIGS_DIR/claude/mcp.json" ]]; then
  cp "$OCULUS_CONFIGS_DIR/claude/mcp.json" "$CCC_HOME/.claude/mcp.template.json"
  chown_if_root "$CCC_USER:$CCC_USER" "$CCC_HOME/.claude/mcp.template.json"
  ok "Claude MCP template synced"
  if [[ ! -f "$CCC_HOME/.claude/mcp.json" ]]; then
    cp "$CCC_HOME/.claude/mcp.template.json" "$CCC_HOME/.claude/mcp.json"
    chown_if_root "$CCC_USER:$CCC_USER" "$CCC_HOME/.claude/mcp.json"
    ok "Claude MCP config initialized"
  else
    warn2 "Claude MCP config exists, left untouched"
  fi
else
  warn2 "oculus-configs: claude/mcp.json not found, skipping"
fi

copy_optional_dir "$OCULUS_CONFIGS_DIR/templates" "$CCC_HOME/Templates" "project templates"
copy_optional_dir "$OCULUS_CONFIGS_DIR/claude/plugins" "$CCC_HOME/.claude/plugins" "Claude default plugins"
copy_optional_dir "$OCULUS_CONFIGS_DIR/claude/skills" "$CCC_HOME/.claude/skills" "Claude default skills"
copy_optional_dir "$OCULUS_CONFIGS_DIR/claude/commands" "$CCC_HOME/.claude/commands" "Claude default commands"
copy_managed_file "$OCULUS_CONFIGS_DIR/codex/AGENTS.md" "$CCC_HOME/.codex/AGENTS.md" "Codex AGENTS.md"
copy_optional_dir "$OCULUS_CONFIGS_DIR/codex/plugins" "$CCC_HOME/.codex/plugins" "Codex default plugins"
copy_optional_dir "$OCULUS_CONFIGS_DIR/codex/skills" "$CCC_HOME/.codex/skills" "Codex skills"
copy_managed_file "$OCULUS_CONFIGS_DIR/gemini/GEMINI.md" "$CCC_HOME/.gemini/GEMINI.md" "Gemini GEMINI.md"
copy_optional_dir "$OCULUS_CONFIGS_DIR/gemini/skills" "$CCC_HOME/.gemini/skills" "Gemini skills"

install_claude_plugins
echo ""
echo -e "${G}${B}Agent config sync complete.${N}"
echo ""
AGENTCONFIGSYNCSCRIPT
chmod +x /usr/local/bin/ccc-sync-agent-configs

# ── shared workspace migration ────────────────────────────────────────────────
cat > /usr/local/bin/ccc-migrate-shared-workspace << 'MIGRATESHAREDWORKSPACESCRIPT'
#!/bin/bash
set -euo pipefail
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
CCC_SHARED_GROUP="${CCC_SHARED_GROUP:-ccc}"
CCC_SHARED_PROJECTS="${CCC_SHARED_PROJECTS:-/srv/ccc/projects}"
CCC_LEGACY_PROJECT_ROOTS="${CCC_LEGACY_PROJECT_ROOTS:-$CCC_HOME/projects:$CCC_HOME/repos}"

usage() {
  echo "Usage:"
  echo "  ccc-migrate-shared-workspace --status"
  echo "  ccc-migrate-shared-workspace --apply"
}

project_path_state() {
  if [[ -L "$CCC_HOME/projects" ]]; then
    local target
    target=$(readlink "$CCC_HOME/projects" || true)
    if [[ "$target" == "$CCC_SHARED_PROJECTS" ]]; then
      echo "symlink to shared root"
    else
      echo "symlink to $target"
    fi
  elif [[ -d "$CCC_HOME/projects" ]]; then
    echo "directory"
  elif [[ -e "$CCC_HOME/projects" ]]; then
    echo "other path"
  else
    echo "missing"
  fi
}

project_entry_count() {
  local root=$1
  if [[ -d "$root" && ! -L "$root" ]]; then
    find "$root" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l
  else
    echo 0
  fi
}

legacy_root_state() {
  local root=$1
  if [[ -L "$root" ]]; then
    echo "symlink to $(readlink "$root" || true)"
  elif [[ -d "$root" ]]; then
    echo "directory"
  elif [[ -e "$root" ]]; then
    echo "other path"
  else
    echo "missing"
  fi
}

status() {
  echo ""
  echo -e "${B}CCC Shared Workspace Migration Status${N}"
  echo ""
  if getent group "$CCC_SHARED_GROUP" >/dev/null; then
    echo -e "  Group ${C}$CCC_SHARED_GROUP${N}: ${G}present${N}"
  else
    echo -e "  Group ${C}$CCC_SHARED_GROUP${N}: ${Y}missing${N}"
  fi
  if [[ -d "$CCC_SHARED_PROJECTS" ]]; then
    echo -e "  Shared projects root ${C}$CCC_SHARED_PROJECTS${N}: ${G}present${N}"
  else
    echo -e "  Shared projects root ${C}$CCC_SHARED_PROJECTS${N}: ${Y}missing${N}"
  fi
  echo -e "  User projects path ${C}$CCC_HOME/projects${N}: $(project_path_state)"
  IFS=: read -r -a legacy_roots <<< "$CCC_LEGACY_PROJECT_ROOTS"
  for legacy_root in "${legacy_roots[@]}"; do
    [[ -n "$legacy_root" ]] || continue
    echo -e "  Legacy root ${C}$legacy_root${N}: $(legacy_root_state "$legacy_root") (${C}$(project_entry_count "$legacy_root")${N} entries)"
  done
  if [[ -f "$CCC_HOME/.ssh/id_ed25519.pub" ]]; then
    echo -e "  Current user GitHub key: ${G}present${N} ($CCC_HOME/.ssh/id_ed25519.pub)"
  else
    echo -e "  Current user GitHub key: ${Y}not found${N}"
  fi
  echo ""
}

repair_shared_permissions() {
  chown root:"$CCC_SHARED_GROUP" "$CCC_SHARED_PROJECTS"
  chmod 2775 "$CCC_SHARED_PROJECTS"
  chgrp -R "$CCC_SHARED_GROUP" "$CCC_SHARED_PROJECTS"
  chmod -R g+rwX "$CCC_SHARED_PROJECTS"
  find "$CCC_SHARED_PROJECTS" -type d -exec chmod g+s {} +
  for entry in "$CCC_SHARED_PROJECTS"/*; do
    if [[ -L "$entry" && -d "$entry" ]]; then
      chgrp -R "$CCC_SHARED_GROUP" "$entry"/
      chmod -R g+rwX "$entry"/
      find "$entry"/ -type d -exec chmod g+s {} +
    fi
  done
}

link_legacy_repos_root() {
  local root=$1
  [[ -d "$root" && ! -L "$root" ]] || return 0
  while IFS= read -r -d '' project; do
    local name dest
    name=$(basename "$project")
    dest="$CCC_SHARED_PROJECTS/$name"
    if [[ -e "$dest" || -L "$dest" ]]; then
      echo -e "  Existing shared project left unchanged: ${C}$dest${N}"
      continue
    fi
    ln -s "$project" "$dest"
    echo -e "  Linked legacy repo: ${C}$dest${N} -> $project"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

apply() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${R}Apply must run as root. Try: sudo ccc-migrate-shared-workspace --apply${N}" >&2
    exit 1
  fi

  groupadd -f "$CCC_SHARED_GROUP"
  mkdir -p "$CCC_SHARED_PROJECTS"
  usermod -aG "$CCC_SHARED_GROUP" "$CCC_USER"

  if [[ -L "$CCC_HOME/projects" ]]; then
    local target
    target=$(readlink "$CCC_HOME/projects" || true)
    if [[ "$target" != "$CCC_SHARED_PROJECTS" ]]; then
      rm "$CCC_HOME/projects"
      ln -s "$CCC_SHARED_PROJECTS" "$CCC_HOME/projects"
    fi
  elif [[ -d "$CCC_HOME/projects" ]]; then
    rsync -a "$CCC_HOME/projects/" "$CCC_SHARED_PROJECTS/"
    local backup
    backup="$CCC_HOME/projects.backup-$(date +%Y%m%d%H%M%S)"
    while [[ -e "$backup" ]]; do
      backup="${backup}.$$"
    done
    mv "$CCC_HOME/projects" "$backup"
    ln -s "$CCC_SHARED_PROJECTS" "$CCC_HOME/projects"
    echo -e "  Backup retained: ${C}$backup${N}"
  elif [[ -e "$CCC_HOME/projects" ]]; then
    local backup
    backup="$CCC_HOME/projects.backup-$(date +%Y%m%d%H%M%S)"
    mv "$CCC_HOME/projects" "$backup"
    ln -s "$CCC_SHARED_PROJECTS" "$CCC_HOME/projects"
    echo -e "  Non-directory path backed up: ${C}$backup${N}"
  else
    ln -s "$CCC_SHARED_PROJECTS" "$CCC_HOME/projects"
  fi

  link_legacy_repos_root "$CCC_HOME/repos"

  repair_shared_permissions
  echo -e "${G}${B}Shared workspace migration applied.${N}"
  echo -e "  Shared projects: ${C}$CCC_SHARED_PROJECTS${N}"
  echo -e "  Compatibility link: ${C}$CCC_HOME/projects${N}"
  echo ""
}

case "${1:-}" in
  --status) status ;;
  --apply) apply ;;
  -h|--help|"") usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
MIGRATESHAREDWORKSPACESCRIPT
chmod +x /usr/local/bin/ccc-migrate-shared-workspace

# ── ccc-update ────────────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-update << 'UPDATESCRIPT'
#!/bin/bash
set -euo pipefail
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; N='\033[0m'
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
PATH="$CCC_HOME/.local/bin:$CCC_HOME/.claude/bin:$CCC_HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export PATH

echo ""
echo -e "${B}Container Code Companion Tooling Update${N}"
echo -e "${Y}Updates Container Code Companion tooling from GitHub and app CLIs only. OS packages are not upgraded.${N}"
echo ""

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo -n "$@"; fi
}

echo -e "${C}[1/4]${N} Container Code Companion provisioner/tools from GitHub..."
if command -v ccc-self-update &>/dev/null; then
  ccc-self-update || true
else
  echo "  ccc-self-update not installed yet; skipping."
fi

echo ""
echo -e "${C}[2/4]${N} Claude Code CLI (all accounts)..."
# Claude Code is per-user (native installer in ~/.local/bin). Update every
# account that has it; secondary accounts are the same person on other
# provider logins.
getent passwd | awk -F: '$3 >= 1000 && $7 !~ /(nologin|false)$/ {print $1 ":" $6}' | while IFS=: read -r u h; do
  if [[ -x "$h/.local/bin/claude" ]]; then
    echo "  Updating Claude Code for $u..."
    as_root sudo -u "$u" env HOME="$h" "$h/.local/bin/claude" update || true
  fi
done

echo ""
echo -e "${C}[3/4]${N} Shared app CLIs (Codex, Gemini)..."
_ccc_npm_pkgs=()
[[ -x /usr/local/ccc-npm/bin/codex ]]  && _ccc_npm_pkgs+=("@openai/codex")
[[ -x /usr/local/ccc-npm/bin/gemini ]] && _ccc_npm_pkgs+=("@google/gemini-cli")
if [[ ${#_ccc_npm_pkgs[@]} -gt 0 ]]; then
  npm update -g --prefix /usr/local/ccc-npm "${_ccc_npm_pkgs[@]}" || true
  as_root chgrp -R ccc /usr/local/ccc-npm 2>/dev/null || true
  as_root chmod -R g+rwX /usr/local/ccc-npm 2>/dev/null || true
else
  echo "  No shared CLIs installed; skipping."
fi

echo ""
echo -e "${C}[4/4]${N} Node.js (current NodeSource channel)..."
if as_root apt-get update -qq 2>/dev/null; then
  as_root apt-get install -y --only-upgrade nodejs || true
  echo "  Node.js: $(node --version 2>/dev/null || echo 'not installed')"
else
  echo "  apt unavailable (need root/sudo); skipping Node.js."
fi

echo ""
echo -e "${G}${B}Application update complete.${N}"
echo -e "  OS update:           ${C}sudo ccc-os-update${N}"
echo -e "  Agent config update: ${C}sudo ccc-sync-agent-configs${N}"
echo ""
UPDATESCRIPT
chmod +x /usr/local/bin/ccc-update

# ── ccc-os-update (manual only) ───────────────────────────────────────────────
cat > /usr/local/bin/ccc-os-update << 'OSUPDATESCRIPT'
#!/bin/bash
set -euo pipefail
B='\033[1m'; C='\033[0;36m'; G='\033[0;32m'; N='\033[0m'
echo ""
echo -e "${B}Container Code Companion OS Update${N}"
echo -e "${C}[1/3]${N} apt update"
apt-get update
echo -e "${C}[2/3]${N} apt upgrade"
apt-get upgrade -y
echo -e "${C}[3/3]${N} cleanup"
apt-get autoremove -y
apt-get clean
echo -e "${G}${B}OS update complete.${N}"
echo ""
OSUPDATESCRIPT
chmod +x /usr/local/bin/ccc-os-update

# ── ccc-setup (post-install wizard) ──────────────────────────────────────────
cat > /usr/local/bin/ccc-setup << 'SETUPSCRIPT'
#!/bin/bash
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; N='\033[0m'
echo ""
echo -e "${B}Container Code Companion Post-Install Setup Wizard${N}"
echo ""

# Git identity
echo -e "${C}── Git Identity ──────────────────────────────${N}"
read -rp "  Your name (for git commits): " GIT_NAME
read -rp "  Your email (for git commits): " GIT_EMAIL
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
echo -e "  ${G}✓ Git identity set${N}"
echo ""

# GitHub SSH — one shared machine key for every account (same person, multiple
# provider logins). Per-user key generation is retired; the web UI's GitHub page
# manages the machine key and writes each account's ~/.ssh/config.
echo -e "${C}── GitHub SSH (shared machine key) ───────────${N}"
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null || true
chmod 600 ~/.ssh/known_hosts 2>/dev/null || true
if [[ -r /etc/ccc/ssh/github_ed25519.pub ]]; then
  echo -e "  ${G}✓ Machine key present:${N} /etc/ccc/ssh/github_ed25519"
  if grep -qs "github_ed25519" ~/.ssh/config 2>/dev/null; then
    echo -e "  ${G}✓ ~/.ssh/config already points at it${N}"
  else
    echo -e "  ${Y}!${N} ~/.ssh/config not configured yet — use the web UI's"
    echo -e "    GitHub page (Configure For All Work Identities), or add:"
    echo "      Host github.com"
    echo "        IdentityFile /etc/ccc/ssh/github_ed25519"
    echo "        IdentitiesOnly yes"
  fi
  echo ""
  echo -e "  ${B}Public key (add once at https://github.com/settings/ssh/new):${N}"
  echo -e "  ${C}$(cat /etc/ccc/ssh/github_ed25519.pub)${N}"
else
  echo -e "  ${Y}!${N} No machine key yet. Create one from the web UI's GitHub page."
fi
echo ""

# Test GitHub connection
echo -e "${C}── Test GitHub Connection ────────────────────${N}"
read -rp "  Test SSH connection to GitHub now? [y/N] " TEST_GH
if [[ "$TEST_GH" =~ ^[Yy]$ ]]; then
  ssh -T git@github.com 2>&1 || true
fi
echo ""
touch ~/.ccc-onboarded
echo -e "${G}${B}Setup complete. Run 'ccc' for full help.${N}"
echo ""
SETUPSCRIPT
chmod +x /usr/local/bin/ccc-setup

cat > /usr/local/bin/ccc-onboarding << 'ONBOARDINGSCRIPT'
#!/bin/bash
exec ccc-setup "$@"
ONBOARDINGSCRIPT
chmod +x /usr/local/bin/ccc-onboarding

cat > /usr/local/bin/ccc-fix-cockpit-updates << 'COCKPITFIXSCRIPT'
#!/bin/bash
set -euo pipefail
echo "ccc-fix-cockpit-updates is retired. Container Code Companion now uses container-code-companion.service on port 9090."
echo "Run: sudo systemctl restart container-code-companion.service"
COCKPITFIXSCRIPT
chmod +x /usr/local/bin/ccc-fix-cockpit-updates

cat > /usr/local/bin/ccc-verify-cockpit-updates << 'COCKPITVERIFYSCRIPT'
#!/bin/bash
set -euo pipefail
echo "ccc-verify-cockpit-updates is retired. Container Code Companion no longer uses Cockpit."
systemctl is-active --quiet container-code-companion.service
COCKPITVERIFYSCRIPT
chmod +x /usr/local/bin/ccc-verify-cockpit-updates

# ── ccc-doctor ────────────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-doctor << 'DOCTORSCRIPT'
#!/bin/bash
B='\033[1m'; G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; Y='\033[1;33m'; N='\033[0m'
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
CCC_CODE_SERVER_SERVICE="${CCC_CODE_SERVER_SERVICE:-code-server@$CCC_USER}"
ok()   { echo -e "  ${G}✓${N} $*"; }
fail() { echo -e "  ${R}✗${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; }
echo ""
echo -e "${B}Container Code Companion Doctor — System Check${N}"
echo ""

echo -e "${C}── Network ───────────────────────────────────${N}"
ping -c1 -W2 1.1.1.1 &>/dev/null     && ok "Internet (ping)" || fail "Internet unreachable"
curl -fsSL --max-time 5 https://api.github.com &>/dev/null && ok "GitHub API" || fail "GitHub unreachable"
curl -fsSL --max-time 5 https://registry.npmjs.org &>/dev/null && ok "npm registry" || fail "npm registry unreachable"
echo ""

echo -e "${C}── Runtimes ──────────────────────────────────${N}"
command -v node &>/dev/null   && ok "Node.js $(node --version)" || fail "Node.js missing"
command -v npm &>/dev/null    && ok "npm $(npm --version)" || fail "npm missing"
command -v python3 &>/dev/null && ok "Python $(python3 --version)" || fail "Python3 missing"
command -v go &>/dev/null     && ok "Go $(go version | awk '{print $3}')" || fail "Go missing"
command -v cargo &>/dev/null  && ok "Rust $(cargo --version)" || fail "Rust missing"
echo ""

echo -e "${C}── Developer Tools ───────────────────────────${N}"
command -v bwrap &>/dev/null  && ok "bubblewrap: $(which bwrap)" || fail "bubblewrap missing"
command -v gh &>/dev/null     && ok "GitHub CLI $(gh --version | head -1 | awk '{print $3}')" || fail "GitHub CLI missing"
command -v tmux &>/dev/null   && ok "tmux $(tmux -V | awk '{print $2}')" || fail "tmux missing"
command -v code-server &>/dev/null && ok "code-server $(code-server --version | head -1)" || fail "code-server missing"
echo ""

echo -e "${C}── Claude Code ───────────────────────────────${N}"
command -v claude &>/dev/null && ok "claude binary: $(which claude)" || fail "claude not in PATH"
[[ -f "$CCC_HOME/.claude/settings.json" ]] && ok "settings.json present for $CCC_USER" || fail "settings.json missing for $CCC_USER"
[[ -f "$CCC_HOME/.claude/bin/statusline-command.sh" ]] && ok "statusline script present" || warn "statusline script missing"
echo ""

echo -e "${C}── Services ──────────────────────────────────${N}"
systemctl is-active --quiet "$CCC_CODE_SERVER_SERVICE" && ok "code-server running" || fail "code-server not running — sudo systemctl start $CCC_CODE_SERVER_SERVICE"
systemctl is-active --quiet container-code-companion.service && ok "Container Code Companion UI running" || fail "Container Code Companion UI not running — sudo systemctl start container-code-companion.service"
echo ""

echo -e "${C}── Shared Permissions ────────────────────────${N}"
PROJ="${CCC_SHARED_PROJECTS:-/srv/ccc/projects}"
if [[ -d "$PROJ" ]]; then
  pperm=$(stat -c '%a %G' "$PROJ")
  [[ "$pperm" == "2775 ccc" ]] && ok "projects root $pperm" || fail "projects root is '$pperm' (want '2775 ccc') — sudo chgrp ccc $PROJ && sudo chmod 2775 $PROJ"
  bad=$(find "$PROJ" -maxdepth 1 -mindepth 1 -type d ! -perm -g+w 2>/dev/null | head -1)
  [[ -z "$bad" ]] && ok "project dirs group-writable" || fail "not group-writable: $bad — repair in the app or 'sudo chmod -R g+rwX $PROJ'"
else
  warn "projects root $PROJ missing"
fi
if [[ -d /usr/local/ccc-npm ]]; then
  nperm=$(stat -c '%a %G' /usr/local/ccc-npm)
  [[ "$nperm" == "2775 ccc" ]] && ok "npm prefix $nperm" || fail "npm prefix is '$nperm' (want '2775 ccc') — sudo ccc-self-update"
  # Perms on the dir aren't enough: npm must actually RESOLVE the global prefix
  # here, else installs land in a root-owned tree and non-root users hit EACCES.
  if command -v npm >/dev/null 2>&1; then
    nresolved=$(npm prefix -g 2>/dev/null)
    [[ "$nresolved" == "/usr/local/ccc-npm" ]] && ok "npm resolves prefix to shared dir" || fail "npm resolves prefix to '${nresolved:-?}' (want /usr/local/ccc-npm) — sudo ccc-self-update"
  fi
else
  fail "shared npm prefix /usr/local/ccc-npm missing — run: sudo ccc-self-update"
fi
sumask=$(systemctl show -p UMask --value container-code-companion.service 2>/dev/null)
[[ "$sumask" == "0002" ]] && ok "app service UMask 0002" || warn "app service UMask is '${sumask:-unset}' (want 0002) — sudo ccc-self-update"
# Project SSH keys must be root-owned 0640 so a non-root agent can't revert a
# shared key to owner-only. A key that is NOT root-owned is agent-revertible.
KEYSROOT="/etc/ccc/project-keys"
if [[ -d "$KEYSROOT" ]]; then
  badkey=$(find "$KEYSROOT" -mindepth 2 -name id_ed25519 \( ! -user root -o ! -perm 640 \) 2>/dev/null | head -1)
  if [[ -z "$badkey" ]]; then
    ok "project SSH keys root-owned 0640 (tamper-proof)"
  else
    kp=$(stat -c '%U:%G %a' "$badkey" 2>/dev/null)
    fail "project key $badkey is '$kp' (want root:ccc 640) — sudo ccc-fix-key-perms"
  fi
fi
echo ""

echo -e "${C}── Storage ───────────────────────────────────${N}"
df -h / | awk 'NR==2 {
  used=$3; avail=$4; pct=$5
  if (pct+0 > 90) printf "  \033[0;31m✗\033[0m Disk %s used (%s free) — LOW\n", pct, avail
  else            printf "  \033[0;32m✓\033[0m Disk %s used (%s free)\n", pct, avail
}'
free -h | awk '/^Mem/ {
  used=$3; avail=$7
  printf "  \033[0;32m✓\033[0m RAM %s used, %s available\n", used, avail
}'
echo ""
DOCTORSCRIPT
chmod +x /usr/local/bin/ccc-doctor

# ── ccc-install-playwright (standalone script) ───────────────────────────────
step 22 "ccc-install-playwright script"
cat > /usr/local/bin/ccc-install-playwright << 'PWSCRIPT'
#!/bin/bash
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
# The web UI Tools page captures this output through a pipe; raw ANSI escapes
# show up there as literal garbage. Color only on a real terminal.
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then B=''; G=''; C=''; Y=''; R=''; N=''; fi
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
echo ""
echo -e "${B}Installing Playwright + headless Chromium${N}"
echo -e "${Y}This downloads ~300MB and takes 5–15 minutes. Do not interrupt.${N}"
echo ""

export HOME="$CCC_HOME"
export DEBIAN_FRONTEND=noninteractive
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

if [[ -r /etc/os-release ]]; then
  source /etc/os-release
  if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "26.04" ]]; then
    echo -e "${Y}Ubuntu 26.04 Chromium support may lag Playwright releases.${N}"
    echo -e "${Y}Ubuntu's chromium-browser package is snap-transitioned, which is a poor fit for many LXC containers.${N}"
    echo -e "${Y}Debian 13 is the safer CCC path when browser automation matters.${N}"
    echo ""
  fi
fi

echo -e "${C}[1/3]${N} Installing Playwright npm package..."
npx --yes playwright install --with-deps chromium
STATUS=$?

if [[ $STATUS -eq 0 ]]; then
  echo ""
  echo -e "${G}${B}Playwright installed successfully.${N}"
  echo -e "  Run tests: ${C}npx playwright test${N}"
  echo -e "  Docs:      ${C}https://playwright.dev${N}"
else
  echo ""
  echo -e "${R}Playwright install failed (exit $STATUS).${N}"
  echo -e "  Retry: ${C}ccc-install-playwright${N}"
  echo -e "  Log:   ${C}~/.npm/_logs/${N}"
  exit 1
fi
echo ""
PWSCRIPT
chmod +x /usr/local/bin/ccc-install-playwright

# ── ccc-install-codex ─────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-install-codex << 'CODEXSCRIPT'
#!/bin/bash
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
# The web UI Tools page captures this output through a pipe; raw ANSI escapes
# show up there as literal garbage. Color only on a real terminal.
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then B=''; G=''; C=''; Y=''; R=''; N=''; fi
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
export HOME="$CCC_HOME"
export PATH="/usr/local/ccc-npm/bin:$CCC_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
echo ""
echo -e "${B}Installing OpenAI Codex CLI${N}"
echo ""

echo -e "${C}[1/2]${N} Installing @openai/codex into the shared prefix..."
npm install -g --prefix /usr/local/ccc-npm @openai/codex
STATUS=$?
# Keep the shared prefix group-writable so any ccc user can update Codex later.
chgrp -R ccc /usr/local/ccc-npm 2>/dev/null || true
chmod -R g+rwX /usr/local/ccc-npm 2>/dev/null || true

if [[ $STATUS -ne 0 ]]; then
  echo ""
  echo -e "${R}Codex install failed (exit $STATUS).${N}"
  echo -e "  Retry: ${C}ccc-install-codex${N}"
  exit 1
fi

echo ""
echo -e "${C}[2/2]${N} Setup"
echo ""
echo -e "${G}${B}Codex installed.${N}"
echo -e "  Binary: ${C}/usr/local/ccc-npm/bin/codex${N}"
echo ""
echo -e "${Y}To use Codex you need an OpenAI API key:${N}"
echo -e "  1. Get a key at ${C}https://platform.openai.com/api-keys${N}"
echo -e "  2. Add to your shell:"
echo -e "     ${C}echo 'export OPENAI_API_KEY=\"sk-...\"' >> ~/.bashrc && source ~/.bashrc${N}"
echo -e "  3. Run: ${C}codex${N}"
echo ""
CODEXSCRIPT
chmod +x /usr/local/bin/ccc-install-codex

# ── ccc-install-jcodemunch ────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-install-jcodemunch << 'JCODEMUNCHSCRIPT'
#!/bin/bash
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
export HOME="$CCC_HOME"
export PATH="$CCC_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
echo ""
echo -e "${B}Installing jCodeMunch MCP${N}"
echo -e "  Symbol-level code retrieval — cuts token usage ~95%"
echo ""

echo -e "${C}[1/3]${N} Installing pip package..."
sudo -u "$CCC_USER" env HOME="$CCC_HOME" PATH="$PATH" pip install --quiet --break-system-packages --user jcodemunch-mcp
if [[ $? -ne 0 ]]; then
  echo -e "${R}pip install failed.${N}"
  exit 1
fi

echo -e "${C}[2/3]${N} Registering MCP server with Claude Code..."
sudo -u "$CCC_USER" env HOME="$CCC_HOME" PATH="$PATH" claude mcp add -s user jcodemunch jcodemunch-mcp
if [[ $? -ne 0 ]]; then
  echo -e "${Y}Auto-register failed — run manually inside Claude Code:${N}"
  echo -e "  ${C}claude mcp add -s user jcodemunch jcodemunch-mcp${N}"
fi

echo -e "${C}[3/3]${N} Initialising index in current directory..."
sudo -u "$CCC_USER" env HOME="$CCC_HOME" PATH="$PATH" jcodemunch-mcp init 2>/dev/null || true

echo ""
echo -e "${G}${B}jCodeMunch installed.${N}"
echo ""
echo -e "  In any project dir: ${C}jcodemunch-mcp init${N}  (builds symbol index)"
echo -e "  Docs: ${C}https://github.com/jgravelle/jcodemunch-mcp${N}"
echo ""
JCODEMUNCHSCRIPT
chmod +x /usr/local/bin/ccc-install-jcodemunch

# ── ccc-update-status ─────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-update-status << 'UPDATESTATUSSCRIPT'
#!/bin/bash
set -euo pipefail
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; D='\033[2m'; N='\033[0m'
[[ ! -t 1 || -n "${NO_COLOR:-}" ]] && B='' G='' C='' Y='' R='' D='' N=''
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
REF="${CCC_SELF_UPDATE_REF:-main}"
REPO_URL="${CCC_SELF_UPDATE_REPO:-git@github.com:oculus-pllx/CCC.git}"
REPO_URL="${REPO_URL%.git}.git"
SRC="/opt/container-code-companion-src"
VERSION_FILE="${CCC_VERSION_FILE:-/etc/ccc/version}"
SHOW_ACTIONS=1
[[ "${1:-}" == "--no-actions" ]] && SHOW_ACTIONS=0
TMP_REPO=""
cleanup() { [[ -n "${TMP_REPO:-}" ]] && rm -rf "$TMP_REPO"; true; }
trap cleanup EXIT

# SSH key for GitHub — device key readable by ccc group, falls back to agent
# SSH key: use device key if present, otherwise fall back to HTTPS for public repos.
# ssh refuses a group-readable private key for its OWNER (root) but accepts it
# for group members, so the key path must not be chosen when we own the file —
# that is exactly the 3 AM cron context, and BatchMode turns the refusal into
# a silent ls-remote failure. ccc-self-update forces HTTPS as root for the
# same reason.
CCC_SSH_KEY="${CCC_GITHUB_KEY:-/etc/ccc/ssh/github_ed25519}"
if [[ -r "$CCC_SSH_KEY" && ! -O "$CCC_SSH_KEY" ]]; then
  export GIT_SSH_COMMAND="ssh -i $CCC_SSH_KEY -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  FETCH_URL="$REPO_URL"
elif [[ "$REPO_URL" == git@github.com:* ]]; then
  FETCH_URL="https://github.com/${REPO_URL#git@github.com:}"
else
  FETCH_URL="$REPO_URL"
fi

installed_commit=""
installed_date=""
[[ -r "$VERSION_FILE" ]] && {
  installed_commit=$(awk -F= '/^CCC_INSTALLED_COMMIT/{gsub(/"/,"",$2); print $2}' "$VERSION_FILE" | tail -1)
  installed_date=$(awk -F= '/^CCC_INSTALLED_DATE/{gsub(/"/,"",$2); print $2}' "$VERSION_FILE" | tail -1)
}

# Use git ls-remote — no local writes needed, works as any user, always current.
# "|| true" keeps a failed ls-remote from tripping set -e/pipefail before the
# unreachable-GitHub message below can print.
latest_commit=$(git ls-remote "$FETCH_URL" "refs/heads/$REF" 2>/dev/null | awk '{print $1}' || true)
if [[ -z "$latest_commit" && "$REPO_URL" == git@github.com:* && "$FETCH_URL" != https://* ]]; then
  # SSH auth failed; public repos still answer over HTTPS.
  latest_commit=$(env -u GIT_SSH_COMMAND git ls-remote "https://github.com/${REPO_URL#git@github.com:}" "refs/heads/$REF" 2>/dev/null | awk '{print $1}' || true)
fi
if [[ -z "$latest_commit" ]]; then
  echo -e "${R}Could not reach GitHub. Check internet connection.${N}"
  exit 1
fi
latest_short="${latest_commit:0:7}"

# Get commit details from the persistent clone (read-only) if it has this commit.
_git() { git -c "safe.directory=$SRC" "$@"; }
latest_date=""
latest_subject=""
latest_log=""
if [[ -d "$SRC/.git" ]] && _git -C "$SRC" cat-file -e "${latest_commit}^{commit}" 2>/dev/null; then
  latest_date=$(_git -C "$SRC" log -1 --format='%ci' "$latest_commit" 2>/dev/null || echo "")
  latest_subject=$(_git -C "$SRC" log -1 --format='%s' "$latest_commit" 2>/dev/null || echo "")
  if [[ -n "$installed_commit" && "${installed_commit:0:7}" != "$latest_short" ]]; then
    latest_log=$(_git -C "$SRC" log --oneline --max-count=5 "${installed_commit}..${latest_commit}" 2>/dev/null | sed 's/^/  • /' || echo "")
  fi
fi

echo ""
echo -e "${B}Container Code Companion Update Status${N}"
if [[ -n "$installed_commit" ]]; then
  echo -e "  Installed: ${C}${installed_commit:0:7}${N}${installed_date:+ — $installed_date}"
else
  echo -e "  Installed: ${Y}not recorded${N}"
fi
echo -e "  GitHub:    ${C}${latest_short}${N}${latest_date:+ — $latest_date}"
[[ -n "$latest_subject" ]] && echo -e "             ${latest_subject}"
echo ""

if [[ -z "$installed_commit" ]]; then
  echo -e "  ${Y}No version recorded. Run: sudo ccc-self-update${N}"
elif [[ "${installed_commit:0:7}" == "$latest_short" ]]; then
  echo -e "  ${G}Up to date.${N}"
else
  echo -e "  ${Y}Update available.${N}"
  [[ -n "$latest_log" ]] && echo "$latest_log"
fi

[[ "$SHOW_ACTIONS" -eq 1 ]] && { echo ""; echo -e "  Update: ${C}sudo ccc-self-update${N}"; }
echo ""
UPDATESTATUSSCRIPT
chmod +x /usr/local/bin/ccc-update-status

# ── ccc-self-update ───────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-self-update << 'SELFUPDATESCRIPT'
#!/bin/bash
set -euo pipefail
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
[[ ! -t 1 || -n "${NO_COLOR:-}" ]] && B='' G='' C='' Y='' R='' N=''
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
[[ "$(id -u)" -ne 0 ]] && exec sudo "$0" "$@"

REF="${CCC_SELF_UPDATE_REF:-main}"
REPO_URL="${CCC_SELF_UPDATE_REPO:-https://github.com/oculus-pllx/CCC.git}"
if [[ "$REPO_URL" == git@github.com:* ]]; then
  REPO_URL="https://github.com/${REPO_URL#git@github.com:}"
fi
REPO_URL="${REPO_URL%.git}.git"
SRC="/opt/container-code-companion-src"
BIN="/usr/local/bin/container-code-companion"
WEB="/opt/container-code-companion/web"
VERSION_FILE="${CCC_VERSION_FILE:-/etc/ccc/version}"
LOG_FILE="${CCC_SELF_UPDATE_LOG:-/var/log/ccc-self-update.log}"
GO="/usr/local/go/bin/go"
CCC_USER="${CCC_USER:-claude-code}"

echo ""
echo -e "${B}Container Code Companion Self-Update${N}"
echo ""

# [1/4] Sync source
echo -e "${C}[1/4]${N} Syncing source ($REPO_URL @ $REF)..."
_git() { git -c "safe.directory=$SRC" "$@"; }
git config --system safe.directory "*" 2>/dev/null || true
if [[ -d "$SRC/.git" ]]; then
  _git -C "$SRC" remote set-url origin "$REPO_URL"
  if ! timeout 120 git -c "safe.directory=$SRC" -C "$SRC" fetch --depth 1 origin "$REF" 2>&1; then
    echo "  fetch timed out or failed — re-cloning..."
    rm -rf "$SRC"
    git clone --depth 1 --branch "$REF" "$REPO_URL" "$SRC"
    git config --system safe.directory "*" 2>/dev/null || true
  else
    _git -C "$SRC" reset --hard "origin/$REF" --quiet
  fi
else
  rm -rf "$SRC"
  git clone --depth 1 --branch "$REF" "$REPO_URL" "$SRC"
  git config --system safe.directory "*" 2>/dev/null || true
fi
COMMIT=$(_git -C "$SRC" rev-parse HEAD)
echo -e "  Commit: ${C}${COMMIT:0:7}${N} — $(_git -C "$SRC" log -1 --format='%s')"

# [2/4] Build binary
echo ""
echo -e "${C}[2/4]${N} Building Container Code Companion binary..."
timeout 600 "$GO" build -C "$SRC/container-code-companion" -buildvcs=false -o "$BIN" ./cmd/server
chmod +x "$BIN"
echo -e "  OK: $BIN"

# [3/4] Re-apply updateable provisioner sections (updates system scripts in /usr/local/bin)
echo ""
echo -e "${C}[3/4]${N} Re-applying updateable provisioner sections..."
PROVISIONER="$SRC/install/ccc-provision-workstation.sh"
if [[ -f "$PROVISIONER" ]]; then
  _updateable_tmp="$(mktemp /tmp/ccc-updateable.XXXXXX.sh)"
  awk '/^# CCC_UPDATEABLE_START/{found=1; next} /^# CCC_UPDATEABLE_END/{found=0; next} found{print}' \
    "$PROVISIONER" > "$_updateable_tmp"
  CCC_LATEST_COMMIT="$COMMIT" CCC_UPDATEABLE_ONLY=1 bash "$_updateable_tmp"
  rm -f "$_updateable_tmp"
  echo -e "  OK: system scripts updated"
else
  echo "  Provisioner not found at $PROVISIONER; skipping."
fi

# [4/4] Sync web assets and management scripts
echo ""
echo -e "${C}[4/4]${N} Syncing web assets..."
rsync -a --delete "$SRC/container-code-companion/web/" "$WEB/"
echo -e "  OK: $WEB"

# Sync agent configs for every account — same person on every login, so all
# accounts should pick up config/skill updates together.
echo ""
echo -e "${C}Syncing agent configs, skills, and plugins for all accounts...${N}"
if command -v ccc-sync-agent-configs >/dev/null 2>&1; then
  NO_COLOR=1 ccc-sync-agent-configs --all-users
else
  echo "  ccc-sync-agent-configs not installed; skipping."
fi

# Update the per-user Claude Code CLI for every account. Claude Code is a
# native per-user install in ~/.local/bin, so the nightly auto-update (which
# runs ccc-self-update, not ccc-update) must bump each account here — otherwise
# only the manual `ccc-update` ever refreshes them and versions drift.
echo ""
echo -e "${C}Updating Claude Code CLI for all accounts...${N}"
getent passwd | awk -F: '$3 >= 1000 && $7 !~ /(nologin|false)$/ {print $1 ":" $6}' | while IFS=: read -r _u _h; do
  if [[ -x "$_h/.local/bin/claude" ]]; then
    echo "  Updating Claude Code for $_u..."
    sudo -u "$_u" env HOME="$_h" "$_h/.local/bin/claude" update || true
  fi
done

# [5/5] Write version + restart
echo ""
echo -e "${C}[5/5]${N} Recording version and restarting service..."
mkdir -p /etc/ccc
mkdir -p /etc/ccc/project-keys
chown root:"${CCC_SHARED_GROUP:-ccc}" /etc/ccc/project-keys
chmod 0770 /etc/ccc/project-keys
printf 'CCC_INSTALLED_COMMIT="%s"\nCCC_INSTALLED_REF="%s"\nCCC_INSTALLED_DATE="%s"\n' \
  "$COMMIT" "$REF" "$(date '+%Y-%m-%d %H:%M:%S %z')" > "$VERSION_FILE"
echo -e "  Recorded: ${C}${COMMIT:0:7}${N}"

# Detach restart from the current process group. When run from the web terminal,
# the PTY is a child of container-code-companion — a synchronous restart would kill this
# script before it exits. setsid creates a new session; the restart survives PTY teardown.
setsid systemctl restart container-code-companion.service &
disown $! 2>/dev/null || true

echo ""
echo -e "${G}${B}Self-update complete. Service restarting in background.${N}"
echo "Self-update successful: $(date '+%Y-%m-%d %H:%M:%S %z')" | tee -a "$LOG_FILE" >/dev/null
echo ""
SELFUPDATESCRIPT
chmod +x /usr/local/bin/ccc-self-update

# ── MOTD ─────────────────────────────────────────────────────────────────────
step 23 "MOTD"
if [[ "$CCC_MACHINE_POLICY" == "container" ]]; then
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
else
  echo "    Existing host MOTD scripts left enabled."
fi
cat > /etc/update-motd.d/00-ccc << 'MOTD'
#!/bin/bash
G='\033[0;32m'; C='\033[0;36m'; B='\033[1m'; Y='\033[1;33m'; D='\033[2m'; N='\033[0m'
echo ""
echo -e "${G}${B}  Container Code Companion${N}"
echo -e "  ${C}claude${N}                    Start Claude Code"
echo -e "  ${C}codex${N}                     Start Codex CLI (if installed)"
echo -e "  ${C}gemini${N}                    Start Gemini CLI (if installed)"
echo -e "  ${C}ccc${N}                       Full help + command reference"
echo -e "  ${C}tmux${N}                      Terminal multiplexer (tabs/splits in SSH)"
echo ""
echo -e "  ${Y}Setup & Maintenance${N}"
echo -e "  ${C}ccc-onboarding${N}            First-login wizard (git, SSH key, GitHub)"
echo -e "  ${C}ccc-setup${N}                 Same wizard, safe to re-run"
echo -e "  ${C}ccc-update-status${N}         Show installed vs GitHub version"
echo -e "  ${C}ccc-self-update${N}           Update Container Code Companion tooling from GitHub"
echo -e "  ${C}ccc-sync-agent-configs${N}    Update Claude/Codex/Gemini configs"
echo -e "  ${C}ccc-update${N}                Update Container Code Companion tooling + app CLIs"
echo -e "  ${C}ccc-os-update${N}             OS package update (apt)"
echo -e "  ${C}ccc-install-playwright${N}    Install Playwright + Chromium"
echo -e "  ${C}ccc-install-codex${N}         Install OpenAI Codex CLI"
echo -e "  ${C}ccc-install-jcodemunch${N}    Install jCodeMunch MCP (95% token reduction)"
echo -e "  ${C}ccc-doctor${N}                System health check"
echo ""
echo -e "  ${Y}Web Interfaces${N}"
IP=\$(hostname -I 2>/dev/null | awk '{print \$1}')
echo -e "  ${C}http://\${IP}:8080${N}   VS Code Web — multi-terminal, file editor"
echo -e "  ${C}http://\${IP}:9090${N}    Container Code Companion — native management UI"
echo -e "  ${D}Tip: use port 8080 for multiple terminal tabs (Terminal → New Terminal)${N}"
echo ""
MOTD
chmod +x /etc/update-motd.d/00-ccc

# ── Shared project umask ─────────────────────────────────────────────────────
step 24 "Shared project umask"
cat > /etc/profile.d/ccc-umask.sh << 'UMASKEOF'
# Files created by ccc group members should be group-writable (664/775)
# so all work identities can modify shared project files.
if id -nG 2>/dev/null | grep -qw ccc; then
  umask 002
fi
UMASKEOF
chmod 0644 /etc/profile.d/ccc-umask.sh

# ── Git defaults ──────────────────────────────────────────────────────────────
step 25 "Git defaults"
git config --system safe.directory "*" 2>/dev/null || true
sudo -u "$CCC_USER" git config --global init.defaultBranch main
sudo -u "$CCC_USER" git config --global core.editor nano
sudo -u "$CCC_USER" git config --global pull.rebase false
sudo -u "$CCC_USER" git config --global core.autocrlf false

# ── ccc-auto-update ───────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-auto-update << 'AUTOUPDATESCRIPT'
#!/bin/bash
set -euo pipefail
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
[[ ! -t 1 || -n "${NO_COLOR:-}" ]] && B='' G='' C='' Y='' R='' N=''

# Gate: only run if auto-update is enabled via the UI toggle.
[[ -f /etc/ccc/autoupdate-enabled ]] || exit 0

echo ""
echo -e "${B}Container Code Companion Auto-Update Check${N} — $(date -Is)"

# Smart check: only update if GitHub has a newer commit.
STATUS=$(NO_COLOR=1 ccc-update-status --no-actions 2>&1 || true)
echo "$STATUS"

if echo "$STATUS" | grep -q "Up to date\."; then
    echo -e "${G}Already up to date. No update needed.${N}"
    exit 0
fi

# Only a positive signal triggers a full update. A failed or empty status
# check (network down, auth hiccup) used to fall through here and re-install
# the same commit every night.
if ! echo "$STATUS" | grep -Eq "Update available\.|No version recorded"; then
    echo -e "${Y}Could not determine update status — skipping until the next scheduled check.${N}"
    exit 1
fi

echo ""
echo -e "${C}Update available — running ccc-self-update...${N}"
ccc-self-update
AUTOUPDATESCRIPT
chmod +x /usr/local/bin/ccc-auto-update

# ── Auto-update cron ──────────────────────────────────────────────────────────
step 26 "Application auto-update cron"
rm -f /etc/cron.d/system-update /etc/logrotate.d/system-update
cat > /etc/cron.d/ccc-app-update << 'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Container Code Companion auto-update (smart check — only updates when GitHub has a newer commit).
# Schedule can be changed from the CCC web UI (Updates > Auto-Update).
0 3 * * * root /usr/local/bin/ccc-auto-update >> /var/log/ccc-app-update.log 2>&1
CRON
chmod 0644 /etc/cron.d/ccc-app-update

cat > /etc/logrotate.d/ccc-app-update << 'LOGROTATE'
/var/log/ccc-app-update.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
LOGROTATE

# ── Container Code Companion native web UI ───────────────────────────────────────────
step 27 "Container Code Companion native web UI"

systemctl disable --now ccc-dashboard 2>/dev/null || true
systemctl disable --now cockpit.socket 2>/dev/null || true
systemctl disable --now cockpit.service 2>/dev/null || true
rm -f /etc/systemd/system/ccc-dashboard.service
rm -rf /usr/share/cockpit/ccc
if [[ "${CCC_UPDATEABLE_ONLY:-0}" != "1" ]]; then
  if command -v fuser >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':9090 '; then
    fuser -k 9090/tcp 2>/dev/null || true
  fi
fi
systemctl daemon-reload

CONTAINER_CODE_COMPANION_SRC="/opt/container-code-companion-src"
CONTAINER_CODE_COMPANION_ROOT="/opt/container-code-companion"
CONTAINER_CODE_COMPANION_ENV="/etc/container-code-companion/env"
if [[ "${CCC_UPDATEABLE_ONLY:-0}" != "1" ]]; then
  rm -rf "$CONTAINER_CODE_COMPANION_SRC"
fi
mkdir -p "$CONTAINER_CODE_COMPANION_ROOT" /etc/container-code-companion

_agent_repo="$CCC_SELF_UPDATE_REPO"
if [[ "$_agent_repo" == git@github.com:* ]]; then
  _agent_repo="https://github.com/${_agent_repo#git@github.com:}"
fi
_agent_repo="${_agent_repo%.git}.git"
if [[ "${CCC_UPDATEABLE_ONLY:-0}" != "1" ]]; then
  echo "    Cloning Container Code Companion source from $_agent_repo ($CCC_SELF_UPDATE_REF)..."
  if ! git clone --quiet --depth 1 --branch "$CCC_SELF_UPDATE_REF" "$_agent_repo" "$CONTAINER_CODE_COMPANION_SRC"; then
    echo "[WARN] Could not clone $_agent_repo branch $CCC_SELF_UPDATE_REF; trying main."
    git clone --quiet --depth 1 --branch main "$_agent_repo" "$CONTAINER_CODE_COMPANION_SRC"
  fi
fi
git config --system safe.directory "*" 2>/dev/null || true

if [[ "${CCC_UPDATEABLE_ONLY:-0}" != "1" ]]; then
  echo "    Building Container Code Companion binary..."
  timeout 600 /usr/local/go/bin/go build \
    -C "$CONTAINER_CODE_COMPANION_SRC/container-code-companion" \
    -buildvcs=false \
    -o /usr/local/bin/container-code-companion \
    ./cmd/server
  chmod +x /usr/local/bin/container-code-companion
  echo "    Syncing Container Code Companion web assets..."
  rsync -a --delete "$CONTAINER_CODE_COMPANION_SRC/container-code-companion/web/" "$CONTAINER_CODE_COMPANION_ROOT/web/"
fi

if [[ -r "$CONTAINER_CODE_COMPANION_ENV" ]]; then
  _ccc_ui_user=$(awk -F= '/^CONTAINER_CODE_COMPANION_USERNAME=/{print $2; exit}' "$CONTAINER_CODE_COMPANION_ENV")
  _ccc_ui_token=$(awk -F= '/^CONTAINER_CODE_COMPANION_SESSION_TOKEN=/{print $2; exit}' "$CONTAINER_CODE_COMPANION_ENV")
  _ccc_ui_pass=$(awk -F= '/^CONTAINER_CODE_COMPANION_PASSWORD=/{print $2; exit}' "$CONTAINER_CODE_COMPANION_ENV")
  [[ -n "${_ccc_ui_user:-}"  ]] && CCC_USER="$_ccc_ui_user"
  [[ -n "${_ccc_ui_token:-}" ]] && CONTAINER_CODE_COMPANION_SESSION_TOKEN="$_ccc_ui_token"
  [[ -n "${_ccc_ui_pass:-}"  ]] && CONTAINER_CODE_COMPANION_PASSWORD="$_ccc_ui_pass"
  CCC_HOME="/home/$CCC_USER"
fi
if ! id "$CCC_USER" &>/dev/null; then
  CCC_USER="$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' /etc/passwd)"
  CCC_HOME="/home/$CCC_USER"
fi
if ! id "$CCC_USER" &>/dev/null; then
  echo "Could not determine Container Code Companion user for systemd unit. Set CCC_USER in /etc/ccc/config." >&2
  exit 1
fi

if [[ "${CCC_UPDATEABLE_ONLY:-0}" != "1" ]]; then
  CONTAINER_CODE_COMPANION_SESSION_TOKEN="${CONTAINER_CODE_COMPANION_SESSION_TOKEN:-$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | head -c 40)}"
  CONTAINER_CODE_COMPANION_PASSWORD="${CONTAINER_CODE_COMPANION_PASSWORD:-$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)}"
  cat > "$CONTAINER_CODE_COMPANION_ENV" <<EOF
CONTAINER_CODE_COMPANION_ADDR=0.0.0.0:9090
CONTAINER_CODE_COMPANION_WEB_DIR=$CONTAINER_CODE_COMPANION_ROOT/web
CONTAINER_CODE_COMPANION_SESSION_TOKEN=$CONTAINER_CODE_COMPANION_SESSION_TOKEN
CONTAINER_CODE_COMPANION_USERNAME=$CCC_USER
CONTAINER_CODE_COMPANION_PASSWORD=$CONTAINER_CODE_COMPANION_PASSWORD
EOF
  chown root:"$CCC_USER" "$CONTAINER_CODE_COMPANION_ENV"
  chmod 640 "$CONTAINER_CODE_COMPANION_ENV"

  cat > /etc/systemd/system/container-code-companion.service <<EOF
[Unit]
Description=Container Code Companion native web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
UMask=0002
User=$CCC_USER
Group=$CCC_USER
WorkingDirectory=$CONTAINER_CODE_COMPANION_ROOT
EnvironmentFile=$CONTAINER_CODE_COMPANION_ENV
ExecStart=/usr/local/bin/container-code-companion
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable container-code-companion.service

  # Write version file before restarting — restart kills this process tree when
  # run from the web terminal (PTY is a child of container-code-companion).
  # Prefer CCC_LATEST_COMMIT injected by ccc-self-update; fall back to the HEAD
  # of the just-cloned source repo so bootstrapping via the old script still records.
  _write_commit="${CCC_LATEST_COMMIT:-}"
  if [[ -z "$_write_commit" && -d "$CONTAINER_CODE_COMPANION_SRC/.git" ]]; then
    _write_commit=$(git -c "safe.directory=$CONTAINER_CODE_COMPANION_SRC" -C "$CONTAINER_CODE_COMPANION_SRC" rev-parse HEAD 2>/dev/null || echo "")
  fi
  if [[ -n "$_write_commit" ]]; then
    mkdir -p /etc/ccc
    printf 'CCC_INSTALLED_COMMIT="%s"\nCCC_INSTALLED_REF="%s"\nCCC_INSTALLED_DATE="%s"\n' \
      "$_write_commit" "${CCC_SELF_UPDATE_REF:-main}" "$(date '+%Y-%m-%d %H:%M:%S %z')" \
      > "${CCC_VERSION_FILE:-/etc/ccc/version}"
    echo "    Recorded installed commit: ${_write_commit:0:7}"
  fi

  echo "    Restarting Container Code Companion service..."
  # Detach from the current process group so the restart survives PTY teardown.
  setsid systemctl restart container-code-companion.service &
  disown $! 2>/dev/null || true
fi

_ccc_ui_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -n "${_ccc_ui_ip:-}" ]]; then
  echo "    Container Code Companion: http://${_ccc_ui_ip}:9090 (login as $CCC_USER)"
else
  echo "    Container Code Companion: port 9090 (login as $CCC_USER)"
fi
echo "    Container Code Companion uses the $CCC_USER user password after final setup."

# Mask motd-news — disable alone leaves it visible as "static/failed" in Cockpit.
# motd-news fetches Canonical marketing content; useless and always times out in LXC.
if [[ "$CCC_MACHINE_POLICY" == "container" ]]; then
  chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null || true
  systemctl mask motd-news.service motd-news.timer 2>/dev/null || true
  systemctl reset-failed motd-news.service motd-news.timer 2>/dev/null || true
fi

# CCC_UPDATEABLE_END — sections above re-run by ccc-self-update

# ── Agent configs (initial sync) ─────────────────────────────────────────────
# The sync command was installed by the updateable section above. Run it once
# at provision time for the primary user; self-update re-runs it on upgrades.
step 28 "Agent configs (initial sync)"
NO_COLOR=1 /usr/local/bin/ccc-sync-agent-configs --user "$CCC_USER" || true

# ── Cleanup ───────────────────────────────────────────────────────────────────
step 29 "Cleanup"
apt-get autoremove -y -qq
apt-get clean -qq
rm -rf /var/lib/apt/lists/*

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       Container provisioning script done         ║"
echo "╚══════════════════════════════════════════════════╝"
