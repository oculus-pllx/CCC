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

# ── Global npm: TypeScript runtime only ───────────────────────────────────────
step 10 "Global npm packages"
npm install -g typescript ts-node tsx

# ── Go ────────────────────────────────────────────────────────────────────────
step 11 "Go"
GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
echo "    $(/usr/local/go/bin/go version | awk '{print $3}')"

# ── Rust (system — build tooling) ─────────────────────────────────────────────
step 12 "Rust (system)"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path

# ── Workstation user ─────────────────────────────────────────────────────────
step 13 "Creating workstation user"
useradd -m -s /bin/bash -d "$CCC_HOME" "$CCC_USER" 2>/dev/null || true
usermod -aG sudo "$CCC_USER"
echo "$CCC_USER ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$CCC_USER"
chmod 0440 "/etc/sudoers.d/$CCC_USER"
setup_shared_projects_root

write_ccc_config

# ── Rust for workstation user ────────────────────────────────────────────────
step 14 "Rust (workstation user)"
sudo -u "$CCC_USER" env HOME="$CCC_HOME" bash -c '
  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
'

# ── Python testing & linting ecosystem ───────────────────────────────────────
step 15 "Python ecosystem"
echo "    pip3 available — install packages per-project with: pip install --break-system-packages <pkg>"

# ── Claude Code ──────────────────────────────────────────────────────────────
step 16 "Claude Code"
sudo -u "$CCC_USER" env HOME="$CCC_HOME" bash -c '
  curl -fsSL https://claude.ai/install.sh | bash
'

CLAUDE_BIN=$(find "$CCC_HOME" -name "claude" \( -type f -o -type l \) 2>/dev/null \
  | grep -v node_modules | head -1 || true)
if [[ -n "$CLAUDE_BIN" ]]; then
  ln -sf "$CLAUDE_BIN" /usr/local/bin/claude
  echo "    Claude Code: $CLAUDE_BIN"
else
  echo "[ERROR] Claude binary not found after install — provision failed."
  exit 1
fi

# ── Playwright (headless browser testing) ────────────────────────────────────
# Skipped at provision time — hangs in LXC due to Chromium download size/networking.
# Install manually after provision: npx --yes playwright install --with-deps chromium
step 17 "Playwright (skipped — install manually after provision)"
echo "    Run after provision: npx --yes playwright install --with-deps chromium"

# ── Claude Code settings.json ─────────────────────────────────────────────────
step 18 "Claude Code settings.json"
sudo -u "$CCC_USER" mkdir -p "$CCC_HOME/.claude/bin"

sudo -u "$CCC_USER" tee "$CCC_HOME/.claude/settings.json" > /dev/null << 'SETTINGS'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)",
      "MultiEdit(*)",
      "WebFetch(*)",
      "WebSearch(*)",
      "TodoRead(*)",
      "TodoWrite(*)",
      "Grep(*)",
      "Glob(*)",
      "LS(*)",
      "Task(*)",
      "mcp__*"
    ]
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",
    "MAX_THINKING_TOKENS": "31999"
  },
  "alwaysThinkingEnabled": true,
  "enableRemoteControl": true,
  "statusLine": {
    "type": "command",
    "command": "~/.claude/bin/statusline-command.sh"
  },
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true,
    "frontend-design@claude-plugins-official": true,
    "skill-creator@claude-plugins-official": true
  }
}
SETTINGS

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
PRIMARY_CCC_USER="${CCC_USER:-claude-code}"
PRIMARY_CCC_HOME="${CCC_HOME:-/home/$PRIMARY_CCC_USER}"
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
        sudo ccc-sync-agent-configs --user "$user"
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

mirror_provider_profile() {
  local provider_dir=$1 label=$2
  local src="$PRIMARY_CCC_HOME/$provider_dir"
  local dest="$CCC_HOME/$provider_dir"
  if [[ "$PRIMARY_CCC_HOME" == "$CCC_HOME" ]]; then
    return 0
  fi
  if [[ ! -d "$src" ]]; then
    warn2 "provider profile: $label not found, skipping"
    return 0
  fi
  mkdir -p "$dest"
  rsync -a --delete \
    --exclude=.git/ \
    --exclude=.credentials.json \
    --exclude=credentials.json \
    --exclude=auth.json \
    --exclude='auth*' \
    --exclude='oauth*' \
    --exclude='token*' \
    --exclude=sessions/ \
    --exclude=session-env/ \
    --exclude=projects/ \
    --exclude=/cache/ \
    --exclude=plugins/cache/ \
    --exclude=logs/ \
    --exclude=backups/ \
    --exclude=shell-snapshots/ \
    --exclude=file-history/ \
    --exclude='history*' \
    --exclude='*.log' \
    "$src"/ "$dest"/
  chown_if_root -R "$CCC_USER:$CCC_USER" "$dest"
  ok "$label profile mirrored"
}

write_claude_baseline() {
  mkdir -p "$CCC_HOME/.claude/bin"
  if [[ ! -f "$CCC_HOME/.claude/settings.json" ]]; then
    cat > "$CCC_HOME/.claude/settings.json" << 'CLAUDESETTINGS'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "allow": [
      "Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "MultiEdit(*)",
      "WebFetch(*)", "WebSearch(*)", "TodoRead(*)", "TodoWrite(*)",
      "Grep(*)", "Glob(*)", "LS(*)", "Task(*)", "mcp__*"
    ]
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
required = ["Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "MultiEdit(*)", "WebFetch(*)", "WebSearch(*)", "TodoRead(*)", "TodoWrite(*)", "Grep(*)", "Glob(*)", "LS(*)", "Task(*)", "mcp__*"]
perms = data.setdefault("permissions", {})
allows = list(perms.get("allow", []))
for a in required:
    if a not in allows:
        allows.append(a)
perms["allow"] = allows
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

mirror_provider_profile ".claude" "Claude"
mirror_provider_profile ".codex" "Codex"
mirror_provider_profile ".gemini" "Gemini"
write_claude_baseline
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

# ── oculus-configs ────────────────────────────────────────────────────────────
step 19 "oculus-configs agent config"
/usr/local/bin/ccc-sync-agent-configs

# ── Statusline ────────────────────────────────────────────────────────────────
step 20 "Statusline"
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
if ! id "$CCC_USER" &>/dev/null; then
  echo "[ERROR] Statusline user '$CCC_USER' does not exist. Check /etc/ccc/config." >&2
  exit 1
fi
sudo -u "$CCC_USER" mkdir -p "$CCC_HOME/.claude/bin"
cat > "$CCC_HOME/.claude/bin/statusline-command.sh" << 'STATUSLINE'
#!/bin/bash
# CCC Statusline — Claude Code session prompt line
# Receives JSON session context from Claude Code on stdin
#
# Output: user@host:path (branch) [model | think] [ctx:N%] HH:MMam
#
# To replace with your own:
#   cp ~/my-statusline.sh ~/.claude/bin/statusline-command.sh
#
# Usage in Claude Code: claude statusline-command

set -euo pipefail

INPUT=$(cat 2>/dev/null || echo '{}')

if command -v jq &>/dev/null; then
  MODEL=$(echo "$INPUT"   | jq -r '.model.id    // ""'     2>/dev/null \
    | sed 's/claude-//;s/-[0-9]\{8\}.*//')
  THINKING=$(echo "$INPUT" | jq -r '.thinking.enabled // false' 2>/dev/null)
  CTX_USED=$(echo "$INPUT" | jq -r '.context.used  // 0'        2>/dev/null)
  CTX_MAX=$(echo "$INPUT"  | jq -r '.context.max   // 200000'   2>/dev/null)
else
  MODEL="claude"; THINKING="false"; CTX_USED=0; CTX_MAX=200000
fi

[[ -z "$MODEL" ]] && MODEL="claude"

# Context %
CTX_PCT=0
[[ "$CTX_MAX" -gt 0 ]] && CTX_PCT=$(( CTX_USED * 100 / CTX_MAX ))

# Warning indicator
CTX_WARN=""
[[ $CTX_PCT -ge 85 ]] && CTX_WARN="!!"
[[ $CTX_PCT -ge 60 && $CTX_PCT -lt 85 ]] && CTX_WARN="!"

# Thinking
THINK=""
[[ "$THINKING" == "true" ]] && THINK=" | think"

# Git branch
GIT_BRANCH=""
if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  _b=$(git branch --show-current 2>/dev/null || echo "detached")
  GIT_BRANCH=" (${_b})"
fi

# Shorten cwd
DIR=$(pwd | sed "s|^$HOME|~|")

# Time (no leading zero)
TIME=$(date +"%I:%M%p" | sed 's/^0//' | tr '[:upper:]' '[:lower:]')

echo "${USER}@$(hostname -s):${DIR}${GIT_BRANCH} [${MODEL}${THINK}] [ctx:${CTX_PCT}%${CTX_WARN}] ${TIME}"
STATUSLINE

chmod +x "$CCC_HOME/.claude/bin/statusline-command.sh"
chown "$CCC_USER:$CCC_USER" "$CCC_HOME/.claude/bin/statusline-command.sh"
echo "    Statusline: ~/.claude/bin/statusline-command.sh"

# ── code-server (web VS Code) ─────────────────────────────────────────────────
step 21 "code-server (web VS Code)"
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

Setup CCC Profile syncs config and skills into that user's home, installs provider CLIs into `~/.local/bin`, and repairs shared project permissions. Sign out and back in after setup so the new `ccc` group membership is active.

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
ssh claude-code@<this-container-ip>
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
step 22 "SSH hardening"
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

# ── Shell environment ─────────────────────────────────────────────────────────
step 23 "Shell environment & aliases"
cat >> "$CCC_HOME/.bashrc" << 'BASHRC'

# ── Container Code Companion ─────────────────────────────────────────────────────
export EDITOR=nano
export LANG=en_US.UTF-8
export TZ=America/New_York
export PATH="$HOME/.local/bin:$HOME/.claude/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH"

# direnv hook
command -v direnv &>/dev/null && eval "$(direnv hook bash)"

# Aliases — navigation
alias ll="ls -lah --color=auto"
alias cls="clear"
alias ..="cd .."
alias ...="cd ../.."
alias grep="grep --color=auto"

# Aliases — git
alias gs="git status"
alias gl="git log --oneline -20"
alias gd="git diff"
alias ga="git add -A"
alias gc="git commit -m"
alias gp="git push"

# bat/fd have different binary names on Ubuntu vs Debian
command -v batcat &>/dev/null && alias bat='batcat'
command -v bat    &>/dev/null && alias cat='bat'
command -v fdfind &>/dev/null && alias fd='fdfind'

# Aliases — dev
alias pytest="python3 -m pytest"
alias py="python3"
alias serve="http-server -p 8000"

# ── ccc help ─────────────────────────────────────────────────────────────────
ccc() {
  local C='\033[0;36m' B='\033[1m' G='\033[0;32m' Y='\033[1;33m' N='\033[0m'
  echo ""
  echo -e "${B}╔══════════════════════════════════════════════════════════════════╗${N}"
  echo -e "${B}║                    Container Code Companion Help                    ║${N}"
  echo -e "${B}╚══════════════════════════════════════════════════════════════════╝${N}"
  echo ""
  echo -e "  ${B}AGENT CLIS${N}"
  echo -e "    ${C}claude${N}                   Start Claude Code session"
  echo -e "    ${C}codex${N}                    Start Codex CLI (after ccc-install-codex)"
  echo -e "    ${C}gemini${N}                   Start Gemini CLI (if installed)"
  echo -e "    ${C}claude --version${N}          Check version"
  echo -e "    ${C}ccc-install-playwright${N}    Install Playwright + headless Chromium"
  echo -e "    ${C}ccc-install-codex${N}         Install OpenAI Codex CLI"
  echo -e "    ${C}ccc-install-jcodemunch${N}    Install jCodeMunch MCP (95% token reduction)"
  echo ""
  echo -e "  ${B}PLUGINS${N}"
  echo -e "    ${C}/plugin${N}                   Manage plugins inside a running Claude Code session"
  echo ""
  echo -e "  ${B}MAINTENANCE${N}"
  echo -e "    ${C}ccc-onboarding${N}            First-login wizard (git identity, SSH key, GitHub)"
  echo -e "    ${C}ccc-setup${N}                 Same wizard, safe to re-run"
  echo -e "    ${C}ccc-update-status${N}         Show installed vs GitHub provisioner version"
  echo -e "    ${C}ccc-self-update${N}           Update Container Code Companion tooling from GitHub"
  echo -e "    ${C}ccc-sync-agent-configs${N}    Update Claude/Codex/Gemini configs from oculus-configs"
  echo -e "    ${C}ccc-update${N}                Update Container Code Companion tooling + app CLIs"
  echo -e "    ${C}ccc-os-update${N}             OS package update (apt)"
  echo -e "    ${C}ccc-doctor${N}                System health check (network, runtimes, services)"
  echo ""
  echo -e "  ${B}SERVICES${N}"
  echo -e "    ${C}sudo systemctl status  code-server@claude-code${N}   Web VS Code status"
  echo -e "    ${C}sudo systemctl restart code-server@claude-code${N}   Restart web VS Code"
  echo -e "    ${C}sudo systemctl start   redis-server${N}              Start local Redis"
  echo -e "    ${C}sudo journalctl -u code-server@claude-code -f${N}    Tail logs"
  echo ""
  echo -e "  ${B}TESTING${N}"
  echo -e "    ${C}pytest${N}                    Python tests"
  echo -e "    ${C}pytest --cov=. -v${N}         With coverage"
  echo -e "    ${C}npx vitest${N}                Vite-native JS/TS tests"
  echo -e "    ${C}npx jest${N}                  Jest tests"
  echo -e "    ${C}npx playwright test${N}        Headless browser tests"
  echo -e "    ${C}http :3000/api/health${N}      HTTP test with httpie"
  echo -e "    ${C}nodemon app.js${N}             Watch + auto-restart"
  echo -e "    ${C}entr sh -c 'pytest' <<< *.py${N}   Re-run tests on file change"
  echo ""
  echo -e "  ${B}DEV TOOLS${N}"
  echo -e "    ${C}rg <pattern>${N}              ripgrep search"
  echo -e "    ${C}fd <name>${N}                 find files (alias → fdfind/fd)"
  echo -e "    ${C}fzf${N}                       fuzzy finder  (pipe with |)"
  echo -e "    ${C}bat <file>${N}                syntax-highlighted cat"
  echo -e "    ${C}jq '.field' file.json${N}      JSON processor"
  echo -e "    ${C}yq '.field' file.yaml${N}      YAML processor (mikefarah binary)"
  echo -e "    ${C}direnv allow${N}               Load .envrc in current dir"
  echo -e "    ${C}pm2 start app.js${N}           Start Node process with pm2"
  echo -e "    ${C}pm2 list${N}                   Show managed processes"
  echo -e "    ${C}serve${N}                      http-server on port 8000"
  echo ""
  echo -e "  ${B}STATUSLINE${N}"
  echo -e "    Location: ${C}~/.claude/bin/statusline-command.sh${N}"
  echo -e "    Replace:  ${C}cp ~/my-statusline.sh ~/.claude/bin/statusline-command.sh${N}"
  echo -e "    Test:     ${C}echo '{\"model\":{\"id\":\"claude-sonnet-4\"}}' | ~/.claude/bin/statusline-command.sh${N}"
  echo ""
  echo -e "  ${B}SHORTCUTS${N}"
  echo -e "    ${C}gs${N}  git status    ${C}gl${N}  git log     ${C}gd${N}  git diff"
  echo -e "    ${C}ga${N}  git add -A    ${C}gc${N}  git commit  ${C}gp${N}  git push"
  echo -e "    ${C}ll${N}  ls -lah       ${C}py${N}  python3     ${C}ccc${N} this screen"
  echo ""
}

# Start in projects dir on login
[[ "$PWD" == "$HOME" ]] && cd ~/projects 2>/dev/null || true

# First interactive login onboarding
if [[ $- == *i* && ! -f "$HOME/.ccc-onboarded" && -z "${CCC_ONBOARDING_SHOWN:-}" ]]; then
  export CCC_ONBOARDING_SHOWN=1
  echo ""
  echo "Container Code Companion first-login onboarding is ready."
  read -rp "Run it now? [Y/n] " _ccc_run_onboarding
  if [[ -z "$_ccc_run_onboarding" || "$_ccc_run_onboarding" =~ ^[Yy]$ ]]; then
    ccc-onboarding
  else
    touch "$HOME/.ccc-onboarded"
    echo "Skipped. Run ccc-onboarding later if needed."
  fi
fi
BASHRC

chown "$CCC_USER:$CCC_USER" "$CCC_HOME/.bashrc"

# tmux config
sudo -u "$CCC_USER" tee "$CCC_HOME/.tmux.conf" > /dev/null << 'TMUXCONF'
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
chown "$CCC_USER:$CCC_USER" "$CCC_HOME/.tmux.conf"

# CCC_UPDATEABLE_START — sections below re-run by ccc-self-update
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
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

CLAUDE_SETTINGS="$CCC_HOME/.claude/settings.json"
if [[ -f "$CLAUDE_SETTINGS" ]] && command -v python3 >/dev/null 2>&1; then
  python3 - "$CLAUDE_SETTINGS" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except Exception:
    raise SystemExit(0)

changed = False
if data.get("$schema") != "https://json.schemastore.org/claude-code-settings.json":
    data["$schema"] = "https://json.schemastore.org/claude-code-settings.json"
    changed = True

status_line = data.get("statusLine")
if isinstance(status_line, str):
    data["statusLine"] = {"type": "command", "command": status_line}
    changed = True
elif isinstance(status_line, dict):
    if status_line.get("type") != "command":
        data["statusLine"]["type"] = "command"
        changed = True
    if not status_line.get("command"):
        data["statusLine"]["command"] = "~/.claude/bin/statusline-command.sh"
        changed = True
ep = data.setdefault("enabledPlugins", {})
for k in ["superpowers@claude-plugins-official", "frontend-design@claude-plugins-official", "skill-creator@claude-plugins-official"]:
    if k not in ep:
        ep[k] = True
        changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n")
PY
  chown "$CCC_USER:$CCC_USER" "$CLAUDE_SETTINGS"
fi

# Remove retired Cockpit kit and standalone dashboard helpers before Cockpit claims 9090.
rm -f /usr/local/bin/ccc-kit
systemctl disable --now ccc-kit-manager 2>/dev/null || true
rm -f /etc/systemd/system/ccc-kit-manager.service
systemctl disable --now ccc-dashboard 2>/dev/null || true
rm -f /etc/systemd/system/ccc-dashboard.service
if command -v fuser >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':9090 '; then
  fuser -k 9090/tcp 2>/dev/null || true
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
PRIMARY_CCC_USER="${CCC_USER:-claude-code}"
PRIMARY_CCC_HOME="${CCC_HOME:-/home/$PRIMARY_CCC_USER}"
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
        sudo ccc-sync-agent-configs --user "$user"
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

mirror_provider_profile() {
  local provider_dir=$1 label=$2
  local src="$PRIMARY_CCC_HOME/$provider_dir"
  local dest="$CCC_HOME/$provider_dir"
  if [[ "$PRIMARY_CCC_HOME" == "$CCC_HOME" ]]; then
    return 0
  fi
  if [[ ! -d "$src" ]]; then
    warn2 "provider profile: $label not found, skipping"
    return 0
  fi
  mkdir -p "$dest"
  rsync -a --delete \
    --exclude=.git/ \
    --exclude=.credentials.json \
    --exclude=credentials.json \
    --exclude=auth.json \
    --exclude='auth*' \
    --exclude='oauth*' \
    --exclude='token*' \
    --exclude=sessions/ \
    --exclude=session-env/ \
    --exclude=projects/ \
    --exclude=/cache/ \
    --exclude=plugins/cache/ \
    --exclude=logs/ \
    --exclude=backups/ \
    --exclude=shell-snapshots/ \
    --exclude=file-history/ \
    --exclude='history*' \
    --exclude='*.log' \
    "$src"/ "$dest"/
  chown_if_root -R "$CCC_USER:$CCC_USER" "$dest"
  ok "$label profile mirrored"
}

write_claude_baseline() {
  mkdir -p "$CCC_HOME/.claude/bin"
  if [[ ! -f "$CCC_HOME/.claude/settings.json" ]]; then
    cat > "$CCC_HOME/.claude/settings.json" << 'CLAUDESETTINGS'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "allow": [
      "Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "MultiEdit(*)",
      "WebFetch(*)", "WebSearch(*)", "TodoRead(*)", "TodoWrite(*)",
      "Grep(*)", "Glob(*)", "LS(*)", "Task(*)", "mcp__*"
    ]
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
required = ["Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "MultiEdit(*)", "WebFetch(*)", "WebSearch(*)", "TodoRead(*)", "TodoWrite(*)", "Grep(*)", "Glob(*)", "LS(*)", "Task(*)", "mcp__*"]
perms = data.setdefault("permissions", {})
allows = list(perms.get("allow", []))
for a in required:
    if a not in allows:
        allows.append(a)
perms["allow"] = allows
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

mirror_provider_profile ".claude" "Claude"
mirror_provider_profile ".codex" "Codex"
mirror_provider_profile ".gemini" "Gemini"
write_claude_baseline
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

echo -e "${C}[1/3]${N} Container Code Companion provisioner/tools from GitHub..."
if command -v ccc-self-update &>/dev/null; then
  ccc-self-update || true
else
  echo "  ccc-self-update not installed yet; skipping."
fi

echo ""
echo -e "${C}[2/3]${N} Claude Code CLI..."
if command -v claude &>/dev/null; then
  sudo -u "$CCC_USER" env HOME="$CCC_HOME" PATH="$PATH" claude update || true
else
  echo "  claude binary not found; skipping."
fi

echo ""
echo -e "${C}[3/3]${N} Optional user-level app CLIs..."
if [[ -x "$CCC_HOME/.local/bin/codex" ]]; then
  sudo -u "$CCC_USER" env HOME="$CCC_HOME" PATH="$PATH" npm update -g --prefix "$CCC_HOME/.local" @openai/codex || true
else
  echo "  Codex CLI not installed; skipping."
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

# SSH key
echo -e "${C}── SSH Key for GitHub ────────────────────────${N}"
if [[ -f ~/.ssh/id_ed25519.pub ]]; then
  echo -e "  ${Y}Existing key found:${N}"
else
  echo "  Generating ed25519 SSH key..."
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f ~/.ssh/id_ed25519 -N ""
  echo -e "  ${G}✓ Key generated${N}"
fi
ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null || true
chmod 600 ~/.ssh/known_hosts 2>/dev/null || true
echo ""
echo -e "  ${B}Add this public key to GitHub:${N}"
echo -e "  ${Y}https://github.com/settings/ssh/new${N}"
echo ""
echo -e "  ${C}$(cat ~/.ssh/id_ed25519.pub)${N}"
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
step 24 "ccc-install-playwright script"
cat > /usr/local/bin/ccc-install-playwright << 'PWSCRIPT'
#!/bin/bash
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
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
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
export HOME="$CCC_HOME"
export PATH="$CCC_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
echo ""
echo -e "${B}Installing OpenAI Codex CLI${N}"
echo ""

echo -e "${C}[1/2]${N} Installing @openai/codex..."
mkdir -p "$CCC_HOME/.local"
chown -R "$CCC_USER:$CCC_USER" "$CCC_HOME/.local"
sudo -u "$CCC_USER" env HOME="$CCC_HOME" PATH="$PATH" npm install -g --prefix "$CCC_HOME/.local" @openai/codex
STATUS=$?

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
echo -e "  Binary: ${C}$CCC_HOME/.local/bin/codex${N}"
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
CCC_SSH_KEY="${CCC_GITHUB_KEY:-/etc/ccc/ssh/github_ed25519}"
if [[ -r "$CCC_SSH_KEY" ]]; then
  export GIT_SSH_COMMAND="ssh -i $CCC_SSH_KEY -o StrictHostKeyChecking=no -o BatchMode=yes"
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
latest_commit=$(git ls-remote "$FETCH_URL" "refs/heads/$REF" 2>/dev/null | awk '{print $1}')
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
  if ! timeout 120 _git -C "$SRC" fetch --depth 1 origin "$REF" 2>&1; then
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

# [3/4] Sync web assets and management scripts
echo ""
echo -e "${C}[3/4]${N} Syncing web assets..."
rsync -a --delete "$SRC/container-code-companion/web/" "$WEB/"
echo -e "  OK: $WEB"

# Sync current user agent configs
echo ""
echo -e "${C}Syncing current user agent configs, skills, and plugins...${N}"
if command -v ccc-sync-agent-configs >/dev/null 2>&1; then
  NO_COLOR=1 ccc-sync-agent-configs --user "$CCC_USER"
else
  echo "  ccc-sync-agent-configs not installed; skipping."
fi

# [4/4] Write version + restart
echo ""
echo -e "${C}[4/4]${N} Recording version and restarting service..."
mkdir -p /etc/ccc
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
step 25 "MOTD"
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
step 26 "Shared project umask"
cat > /etc/profile.d/ccc-umask.sh << 'UMASKEOF'
# Files created by ccc group members should be group-writable (664/775)
# so all work identities can modify shared project files.
if id -nG 2>/dev/null | grep -qw ccc; then
  umask 002
fi
UMASKEOF
chmod 0644 /etc/profile.d/ccc-umask.sh

# ── Git defaults ──────────────────────────────────────────────────────────────
step 27 "Git defaults"
git config --system safe.directory "*" 2>/dev/null || true
sudo -u "$CCC_USER" git config --global init.defaultBranch main
sudo -u "$CCC_USER" git config --global core.editor nano
sudo -u "$CCC_USER" git config --global pull.rebase false
sudo -u "$CCC_USER" git config --global core.autocrlf false

# ── Auto-update cron ──────────────────────────────────────────────────────────
step 27 "Application auto-update cron"
rm -f /etc/cron.d/system-update /etc/logrotate.d/system-update
cat > /etc/cron.d/ccc-app-update << 'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Weekly Container Code Companion tooling update from GitHub. Does not run apt upgrade.
0 3 * * 0 root /usr/local/bin/ccc-update >> /var/log/ccc-app-update.log 2>&1
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
step 28 "Container Code Companion native web UI"

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

echo "    Building Container Code Companion binary..."
timeout 600 /usr/local/go/bin/go build \
  -C "$CONTAINER_CODE_COMPANION_SRC/container-code-companion" \
  -buildvcs=false \
  -o /usr/local/bin/container-code-companion \
  ./cmd/server
chmod +x /usr/local/bin/container-code-companion
echo "    Syncing Container Code Companion web assets..."
rsync -a --delete "$CONTAINER_CODE_COMPANION_SRC/container-code-companion/web/" "$CONTAINER_CODE_COMPANION_ROOT/web/"

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

# ── Cleanup ───────────────────────────────────────────────────────────────────
step 29 "Cleanup"
apt-get autoremove -y -qq
apt-get clean -qq
rm -rf /var/lib/apt/lists/*

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       Container provisioning script done         ║"
echo "╚══════════════════════════════════════════════════╝"
