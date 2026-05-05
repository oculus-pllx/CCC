#!/usr/bin/env bash
# ============================================================================
#  Claude Code Commander (CCC) — Proxmox LXC Provisioner
#  Creates a lean, production-ready Ubuntu 26.04 LXC container for Claude Code
#
#  Run on your Proxmox host:
#    bash claude-code-commander.sh
#
#  Design values:
#    • No Docker — pure native toolchain, minimal overhead
#    • Non-root claude-code user with passwordless sudo
#    • Full dev + test stack pre-installed at provision time
#    • code-server (web VS Code) via native systemd on port 8080
#    • Claude Code + all tools pre-approved, skills pre-cloned
#    • SSH hardened — root login disabled
#    • ccc help command + MOTD on every login
#    • Weekly auto-updates
# ============================================================================
set -euo pipefail

# ── Colors & Helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║         Claude Code Commander (Proxmox)          ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
preflight() {
  [[ $(id -u) -eq 0 ]] || error "Must be run as root on the Proxmox host."
  command -v pct    &>/dev/null || error "pct not found. Run this on a Proxmox host."
  command -v pveam  &>/dev/null || error "pveam not found. Run this on a Proxmox host."
  command -v pvesh  &>/dev/null || error "pvesh not found. Run this on a Proxmox host."
}

# ── APT mirror / OS status check ──────────────────────────────────────────────
check_apt_connectivity() {
  # CT_OS set by get_config: "ubuntu" or "debian"
  local apt_mirror status_url status_label

  if [[ "${CT_OS:-ubuntu}" == "debian" ]]; then
    apt_mirror="http://deb.debian.org"
    status_url=""   # No public Debian status API — skip
    status_label="deb.debian.org"
  else
    apt_mirror="http://archive.ubuntu.com"
    status_url="https://status.canonical.com/api/v2/status.json"
    status_label="archive.ubuntu.com"
  fi

  # 1. Canonical status API (Ubuntu only)
  if [[ -n "$status_url" ]]; then
    info "Checking Canonical infrastructure status ..."
    local status_json indicator description
    status_json=$(curl -fsSL --max-time 8 --ipv4 "$status_url" 2>/dev/null || echo "")
    if [[ -n "$status_json" ]]; then
      indicator=$(echo "$status_json" | grep -o '"indicator":"[^"]*"' | cut -d'"' -f4)
      description=$(echo "$status_json" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
      case "$indicator" in
        none)
          success "Canonical status: ${description:-All Systems Operational}" ;;
        minor)
          warn "Canonical status: MINOR OUTAGE — ${description}"
          warn "Some packages may fail. Check https://status.canonical.com/"
          read -rp "Continue anyway? (y/N): " _cont
          [[ "$_cont" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; } ;;
        major|critical)
          warn "Canonical status: ${indicator^^} OUTAGE — ${description}"
          warn "Consider using Debian instead: re-run and select option 2."
          warn "See https://status.canonical.com/"
          read -rp "Continue anyway? (y/N): " _cont
          [[ "$_cont" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; } ;;
        *)
          warn "Canonical status API returned unknown indicator: '${indicator}'" ;;
      esac
    else
      warn "Could not reach status.canonical.com — skipping status check."
    fi
  fi

  # 2. Direct mirror reachability
  info "Checking ${status_label} reachability from this host ..."
  if curl -fsSL --max-time 8 --ipv4 "$apt_mirror" &>/dev/null; then
    success "${status_label} is reachable."
  else
    warn "${status_label} is NOT reachable from this Proxmox host."
    warn "Provisioning will likely fail at the apt install steps."
    read -rp "Continue anyway? (y/N): " _cont
    [[ "$_cont" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi
}

# ── Configuration ─────────────────────────────────────────────────────────────
get_config() {
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

  echo -e "${BOLD}Container Configuration${NC}"
  echo "─────────────────────────────────────────────────"

  # ── OS selection ─────────────────────────────────────────────────────────────
  echo "  OS options:"
  echo "    1) Ubuntu 26.04 LTS  (default)"
  echo "    2) Debian 12 (Bookworm)"
  echo ""
  read -rp "OS [1]: " _os_choice
  _os_choice="${_os_choice:-1}"

  case "$_os_choice" in
    2)
      CT_OS="debian"
      CT_OSTYPE="debian"
      _tmpl_pattern='^debian-12-standard_12\.[0-9]+-[0-9]+_amd64\.tar\.zst$'
      _tmpl_label="Debian 12"
      ;;
    *)
      CT_OS="ubuntu"
      CT_OSTYPE="ubuntu"
      _tmpl_pattern='^ubuntu-26\.04-standard_26\.04-[0-9]+_amd64\.tar\.zst$'
      _tmpl_label="Ubuntu 26.04"
      ;;
  esac

  # Resolve template
  TEMPLATE=$(pveam available --section system 2>/dev/null \
    | awk '{print $2}' | grep -E "$_tmpl_pattern" | sort -V | tail -1)

  if [[ -z "$TEMPLATE" ]]; then
    warn "${_tmpl_label} template not in local index. Running pveam update ..."
    pveam update 2>/dev/null || true
    TEMPLATE=$(pveam available --section system 2>/dev/null \
      | awk '{print $2}' | grep -E "$_tmpl_pattern" | sort -V | tail -1)
    [[ -n "$TEMPLATE" ]] \
      || error "${_tmpl_label} LXC template not found. Ensure Proxmox can reach download.proxmox.com."
  fi

  read -rp "Container ID [$next_id]: " CT_ID
  CT_ID="${CT_ID:-$next_id}"
  [[ "$CT_ID" =~ ^[0-9]+$ ]] || error "Container ID must be a number."
  pct status "$CT_ID" &>/dev/null && error "Container ID $CT_ID already exists."

  read -rp "Hostname [ccc-dev]: " CT_HOSTNAME
  CT_HOSTNAME="${CT_HOSTNAME:-ccc-dev}"

  read -rsp "Root password (temporary, setup only): " CT_PASSWORD
  echo ""
  [[ -n "$CT_PASSWORD" ]] || error "Password cannot be empty."

  read -rsp "claude-code user password: " CC_PASSWORD
  echo ""
  [[ -n "$CC_PASSWORD" ]] || error "claude-code password cannot be empty."

  read -rsp "code-server web UI password [default: codeserver]: " CS_PASSWORD
  echo ""
  CS_PASSWORD="${CS_PASSWORD:-codeserver}"

  read -rp "CPU cores [4]: " CT_CORES
  CT_CORES="${CT_CORES:-4}"

  read -rp "RAM in MB [10240]: " CT_RAM
  CT_RAM="${CT_RAM:-10240}"

  read -rp "Swap in MB [2048]: " CT_SWAP
  CT_SWAP="${CT_SWAP:-2048}"

  read -rp "Disk size in GB [30]: " CT_DISK
  CT_DISK="${CT_DISK:-30}"

  # Detect storage pools that can hold LXC rootfs
  local _storage_list _default_storage
  _storage_list=$(pvesm status --content rootdir 2>/dev/null \
    | awk 'NR>1 && $2=="active" {print $1}' | sort)

  if echo "$_storage_list" | grep -q "^local-lvm$"; then
    _default_storage="local-lvm"
  elif [[ -n "$_storage_list" ]]; then
    _default_storage=$(echo "$_storage_list" | head -1)
  else
    _default_storage="local-lvm"
  fi

  if [[ -n "$_storage_list" ]]; then
    echo "  Available storage pools (rootdir):"
    echo "$_storage_list" | while read -r _s; do echo "    $_s"; done
    echo ""
  fi

  read -rp "Storage [$_default_storage]: " CT_STORAGE
  CT_STORAGE="${CT_STORAGE:-$_default_storage}"

  while true; do
    read -rp "IP address (dhcp or x.x.x.x/xx) [dhcp]: " CT_IP
    CT_IP="${CT_IP:-dhcp}"
    if [[ "$CT_IP" == "dhcp" ]]; then
      break
    elif [[ "$CT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
      break
    elif [[ "$CT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      warn "Missing CIDR prefix — use x.x.x.x/xx (e.g. ${CT_IP}/24)"
    else
      warn "Invalid format — enter 'dhcp' or x.x.x.x/xx (e.g. 192.168.0.50/24)"
    fi
  done

  if [[ "$CT_IP" != "dhcp" ]]; then
    while true; do
      read -rp "Gateway (x.x.x.x): " CT_GW
      if [[ "$CT_GW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
      elif [[ -z "$CT_GW" ]]; then
        warn "Gateway required for static IP."
      elif [[ "$CT_GW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        warn "Gateway must be a plain IP — no CIDR prefix (e.g. 192.168.0.1)"
      else
        warn "Invalid format — enter a plain IPv4 address (e.g. 192.168.0.1)"
      fi
    done
  fi

  while true; do
    read -rp "DNS server [1.1.1.1]: " CT_DNS
    CT_DNS="${CT_DNS:-1.1.1.1}"
    if [[ "$CT_DNS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      break
    elif [[ "$CT_DNS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
      warn "DNS must be a plain IP — no CIDR prefix (e.g. 1.1.1.1)"
    else
      warn "Invalid format — enter a plain IPv4 address (e.g. 1.1.1.1)"
    fi
  done

  read -rp "Path to SSH public key (optional, Enter to skip): " CT_SSH_KEY

  # ── HA (cluster only) ────────────────────────────────────────────────────────
  HA_ENABLED=0
  HA_GROUP=""
  local _in_cluster
  _in_cluster=$(pvesh get /cluster/status --output-format json 2>/dev/null \
    | grep -c '"type":"cluster"' || true)

  if [[ "$_in_cluster" -gt 0 ]]; then
    echo ""
    read -rp "Enable High Availability for this container? (y/N): " _ha
    if [[ "$_ha" =~ ^[Yy]$ ]]; then
      HA_ENABLED=1
      local _ha_groups
      _ha_groups=$(pvesh get /cluster/ha/groups --output-format json 2>/dev/null \
        | grep -o '"group":"[^"]*"' | cut -d'"' -f4 || true)
      if [[ -n "$_ha_groups" ]]; then
        echo "  Available HA groups:"
        echo "$_ha_groups" | while read -r _g; do echo "    $_g"; done
        read -rp "HA group (Enter to skip): " HA_GROUP
      else
        warn "No HA groups found — container will be added to HA without a group."
      fi
    fi
  fi

  echo ""
  echo -e "${BOLD}Summary${NC}"
  echo "─────────────────────────────────────────────────"
  echo "  OS:           ${_tmpl_label}"
  echo "  CT ID:        $CT_ID"
  echo "  Hostname:     $CT_HOSTNAME"
  echo "  Template:     $TEMPLATE"
  echo "  CPU:          $CT_CORES cores"
  echo "  RAM:          $CT_RAM MB ($(( CT_RAM / 1024 )) GB)"
  echo "  Swap:         $CT_SWAP MB"
  echo "  Disk:         ${CT_DISK}G on $CT_STORAGE"
  echo "  Network:      $CT_IP"
  echo "  DNS:          $CT_DNS"
  if [[ "$HA_ENABLED" -eq 1 ]]; then
    echo "  HA:           enabled${HA_GROUP:+ (group: $HA_GROUP)}"
  else
    echo "  HA:           disabled"
  fi
  echo "  User:         claude-code (non-root, passwordless sudo)"
  echo "  code-server:  port 8080 (web VS Code)"
  echo "─────────────────────────────────────────────────"
  echo ""
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ── Download Ubuntu 26.04 Template ───────────────────────────────────────────
get_template() {
  info "Checking for template: $TEMPLATE"
  if ! pveam list local 2>/dev/null | grep -q "$TEMPLATE"; then
    info "Downloading $TEMPLATE ..."
    pveam download local "$TEMPLATE" \
      || error "Template download failed. Try: pveam update && pveam download local $TEMPLATE"
  else
    success "Template already present: $TEMPLATE"
  fi
  TEMPLATE_PATH="local:vztmpl/$TEMPLATE"
}

# ── Create Container ──────────────────────────────────────────────────────────
create_container() {
  info "Creating LXC container $CT_ID ..."

  local net_str="name=eth0,bridge=vmbr0"
  if [[ "$CT_IP" == "dhcp" ]]; then
    net_str+=",ip=dhcp"
  else
    net_str+=",ip=$CT_IP,gw=$CT_GW"
  fi

  local cmd=(
    pct create "$CT_ID" "$TEMPLATE_PATH"
    --hostname     "$CT_HOSTNAME"
    --password     "$CT_PASSWORD"
    --cores        "$CT_CORES"
    --memory       "$CT_RAM"
    --swap         "$CT_SWAP"
    --rootfs       "$CT_STORAGE:$CT_DISK"
    --net0         "$net_str"
    --nameserver   "$CT_DNS"
    --ostype       "$CT_OSTYPE"
    --unprivileged 1
    --features     nesting=1,keyctl=1
    --onboot       1
    --start        0
  )

  if [[ -n "${CT_SSH_KEY:-}" && -f "$CT_SSH_KEY" ]]; then
    cmd+=(--ssh-public-keys "$CT_SSH_KEY")
  fi

  "${cmd[@]}"
  success "Container $CT_ID created."
}

# ── Configure HA ──────────────────────────────────────────────────────────────
configure_ha() {
  [[ "$HA_ENABLED" -eq 1 ]] || return 0
  info "Registering CT $CT_ID with HA manager ..."
  local ha_cmd=(ha-manager add "ct:$CT_ID" --state started)
  [[ -n "$HA_GROUP" ]] && ha_cmd+=(--group "$HA_GROUP")
  if "${ha_cmd[@]}"; then
    success "HA enabled for CT $CT_ID${HA_GROUP:+ in group '$HA_GROUP'}."
  else
    warn "HA registration failed — add manually: ha-manager add ct:$CT_ID --state started${HA_GROUP:+ --group $HA_GROUP}"
  fi
}

# ── Start & Wait for Network ──────────────────────────────────────────────────
start_container() {
  info "Starting container $CT_ID ..."
  pct start "$CT_ID"
  sleep 4

  # For static IP ping the gateway first (local reachability), then DNS (internet).
  # For DHCP ping the configured DNS server.
  local _ping_target
  if [[ "$CT_IP" == "dhcp" ]]; then
    _ping_target="$CT_DNS"
  else
    _ping_target="$CT_GW"
  fi

  info "Waiting for network (pinging ${_ping_target}) ..."
  local attempts=0
  while ! pct exec "$CT_ID" -- ping -c1 -W2 "$_ping_target" &>/dev/null; do
    (( attempts++ ))
    [[ $attempts -lt 30 ]] || error "Network timeout after 60s — check gateway/DNS: ${_ping_target}"
    sleep 2
  done
  success "Container is online (local)."

  # Verify actual internet — LXC containers often have local routing but no IPv6/internet
  info "Verifying internet access (archive.ubuntu.com) ..."
  attempts=0
  while ! pct exec "$CT_ID" -- curl -fsSL --max-time 5 --ipv4 \
      "http://archive.ubuntu.com" &>/dev/null; do
    (( attempts++ ))
    if [[ $attempts -ge 10 ]]; then
      error "Container cannot reach archive.ubuntu.com — check router/firewall or gateway ${_ping_target}"
    fi
    sleep 3
  done
  success "Internet access confirmed."
}

# ── Provision Container ───────────────────────────────────────────────────────
provision_container() {
  info "Provisioning container (10–15 minutes) ..."

  # Background elapsed timer — prints every 30s so you know it's not hung
  _provision_start=$SECONDS
  ( while true; do
      sleep 30
      printf "  ... still provisioning [%dm%02ds elapsed]\n" \
        $(( (SECONDS - _provision_start) / 60 )) \
        $(( (SECONDS - _provision_start) % 60 ))
    done ) &
  _timer_pid=$!

  # Single-quoted heredoc — no variable expansion inside
  cat > /tmp/provision-${CT_ID}.sh << 'PROVISION_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
_STEPS=29
step() { echo ">>> [$1/${_STEPS}] $2"; }

# Disable IPv6 — LXC containers commonly lack IPv6 routing, causes apt/curl failures
cat > /etc/sysctl.d/99-disable-ipv6.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf > /dev/null 2>&1 || true

# Also force apt IPv4 as belt-and-suspenders
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

# ── Locale & Timezone ─────────────────────────────────────────────────────────
step 1 "Locale & timezone"
apt-get update -qq
apt-get install -y -qq locales
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen en_US.UTF-8 > /dev/null 2>&1
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo "America/New_York" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

# ── System update ─────────────────────────────────────────────────────────────
step 2 "System update"
apt-get upgrade -y -qq

# ── Core packages ─────────────────────────────────────────────────────────────
step 3 "Core packages"
apt-get install -y -qq \
  git curl wget unzip zip \
  ca-certificates gnupg lsb-release apt-transport-https software-properties-common \
  bash-completion \
  htop nano vim tmux screen \
  jq tree \
  net-tools iproute2 iputils-ping dnsutils \
  openssh-server \
  sudo \
  cron logrotate \
  httpie \
  direnv \
  entr \
  xvfb

# ── Build tools & dev libraries ───────────────────────────────────────────────
step 4 "Build tools & dev libraries"
apt-get install -y -qq \
  build-essential clang make cmake pkg-config autoconf automake libtool \
  python3 python3-pip python3-venv python3-dev \
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
  libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt-dev

# ── Search & productivity tools ───────────────────────────────────────────────
step 5 "Search & productivity tools"
apt-get install -y -qq \
  ripgrep fd-find fzf bat \
  rsync \
  sqlite3

# ── Database clients + local test servers ─────────────────────────────────────
step 6 "Database clients"
apt-get install -y -qq \
  postgresql-client \
  redis-tools \
  redis-server

# Disable Redis autostart — tests manage their own instances
systemctl disable redis-server 2>/dev/null || true
systemctl stop    redis-server 2>/dev/null || true

# ── yq — mikefarah Go binary (not the apt Python wrapper) ────────────────────
step 7 "yq (mikefarah Go binary)"
YQ_VERSION=$(curl -fsSL "https://api.github.com/repos/mikefarah/yq/releases/latest" \
  | grep '"tag_name":' | cut -d'"' -f4)
curl -fsSL \
  "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
  -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq
echo "    yq $(/usr/local/bin/yq --version | awk '{print $NF}')"

# ── Node.js 22 LTS ───────────────────────────────────────────────────────────
step 8 "Node.js 22 LTS"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs
echo "    Node $(node --version) / npm $(npm --version)"

# ── Global npm: dev, test, and Claude ecosystem ───────────────────────────────
step 9 "Global npm packages"
npm install -g \
  typescript ts-node tsx \
  eslint prettier \
  jest vitest \
  nodemon concurrently \
  http-server \
  pm2

# ── get-shit-done-cc ──────────────────────────────────────────────────────────
step 10 "get-shit-done-cc"
npx get-shit-done-cc --claude --global 2>/dev/null \
  || echo "    [WARN] get-shit-done-cc — run manually: npx get-shit-done-cc --claude --global"

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

# ── claude-code user ─────────────────────────────────────────────────────────
step 13 "Creating claude-code user"
useradd -m -s /bin/bash -d /home/claude-code claude-code 2>/dev/null || true
usermod -aG sudo claude-code
echo "claude-code ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/claude-code
chmod 0440 /etc/sudoers.d/claude-code

# ── Rust for claude-code user ─────────────────────────────────────────────────
step 14 "Rust (claude-code user)"
sudo -u claude-code bash -c '
  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
'

# ── Python testing & linting ecosystem ───────────────────────────────────────
step 15 "Python ecosystem"
pip3 install --break-system-packages --quiet \
  pytest pytest-asyncio pytest-cov pytest-mock pytest-xdist \
  black ruff mypy \
  httpx requests python-dotenv \
  rich typer \
  pyyaml toml
echo "    pytest, black, ruff, mypy, httpx, rich, typer installed"

# ── Claude Code ──────────────────────────────────────────────────────────────
step 16 "Claude Code"
sudo -u claude-code bash -c '
  export HOME=/home/claude-code
  curl -fsSL https://claude.ai/install.sh | bash
'

CLAUDE_BIN=$(find /home/claude-code/.local/bin /home/claude-code/.claude/bin \
  -name "claude" -type f 2>/dev/null | head -1 || true)
if [[ -n "$CLAUDE_BIN" ]]; then
  ln -sf "$CLAUDE_BIN" /usr/local/bin/claude
  echo "    Claude Code: $CLAUDE_BIN"
else
  echo "    [WARN] Claude binary not found — symlink skipped."
fi

# ── Playwright (headless browser testing) ────────────────────────────────────
step 17 "Playwright (headless Chromium)"
sudo -u claude-code bash -c '
  export HOME=/home/claude-code
  export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
  npx playwright install --with-deps chromium 2>&1 | tail -3
' || echo "    [WARN] Playwright had errors — run: npx playwright install --with-deps chromium"

# ── Claude Code settings.json ─────────────────────────────────────────────────
step 18 "Claude Code settings.json"
sudo -u claude-code mkdir -p /home/claude-code/.claude/bin

sudo -u claude-code tee /home/claude-code/.claude/settings.json > /dev/null << 'SETTINGS'
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
  "enableRemoteControl": true
}
SETTINGS

# ── CLAUDE.md ─────────────────────────────────────────────────────────────────
step 19 "CLAUDE.md"
sudo -u claude-code mkdir -p /home/claude-code/projects
sudo -u claude-code tee /home/claude-code/.claude/CLAUDE.md > /dev/null << 'CLAUDEMD'
# Claude Code Workspace

## Environment
- **OS**: Ubuntu 26.04 LXC on Proxmox (no Docker)
- **User**: claude-code (non-root, passwordless sudo)
- **Home**: /home/claude-code
- **Projects**: ~/projects/
- **Timezone**: America/New_York
- **Web editor**: code-server at http://<ip>:8080

## Languages & Runtimes
- Node.js 22 LTS — npm, typescript, ts-node, tsx
- Python 3 — pip (--break-system-packages), venv
- Go (latest) — go install
- Rust (latest) — cargo

## Testing
- **Python**: pytest, pytest-asyncio, pytest-cov, pytest-mock, pytest-xdist
- **JS/TS**: jest, vitest, nodemon (watch), concurrently
- **Browser**: Playwright + headless Chromium — `npx playwright test`
- **HTTP**: httpie (`http` command), httpx (Python async), curl
- **Redis**: `sudo systemctl start redis-server` for local test instance
- **Postgres**: psql client — connect to external or provision local server

## Tools
- **Search**: ripgrep (rg), fd (fdfind), fzf, bat (batcat)
- **DB**: psql, redis-cli, sqlite3, redis-server (local test)
- **Process**: pm2 (Node.js), concurrently, nodemon
- **File watch**: entr (run cmd on file change)
- **Env**: direnv (per-directory .envrc — run `direnv allow`)
- **Formatting**: prettier, eslint, black, ruff, mypy
- **Build**: gcc, clang, make, cmake, pkg-config, autoconf
- **Terminal**: tmux, screen, nano, vim, htop

## Permissions
All tools pre-approved — no permission prompts ever.

## Agent Teams
Enabled (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1).
Use tmux for split-pane team visualization.

## Remote Control
Controllable from claude.ai/code or Claude mobile app.
Use /remote-control or press spacebar to show QR code.

## Conventions
- Create files over printing long code blocks
- git for version control under ~/projects/
- Python packages: pip install --break-system-packages <pkg>
- Extended thinking always on

## Skills (pre-cloned at ~/.claude/skills/)
- anthropic-skills      — Official Anthropic skill library
- karpathy-skills       — Andrej Karpathy ML/AI skills
- mattpocock-skills     — TypeScript/FP skills (Matt Pocock)
- caveman               — Foundational development skills (Julius Brussee)

## Plugins (run inside Claude after first login)
Run `ccc-setup-plugins` in shell, then paste into Claude session:
  /plugin install skill-creator@claude-plugins-official
  /plugin install superpowers@claude-plugins-official
  /plugin install frontend-design@claude-plugins-official
  /plugin marketplace add mksglu/context-mode
  /plugin install context-mode@context-mode
  /plugin marketplace add thedotmack/claude-mem
  /plugin install claude-mem
CLAUDEMD

# ── Skill repos ───────────────────────────────────────────────────────────────
step 20 "Skill repos"
sudo -u claude-code mkdir -p /home/claude-code/.claude/skills
cd /home/claude-code/.claude/skills

sudo -u claude-code git clone --depth 1 \
  https://github.com/anthropics/skills.git anthropic-skills 2>/dev/null \
  || echo "    [SKIP] anthropic-skills"

sudo -u claude-code git clone --depth 1 \
  https://github.com/forrestchang/andrej-karpathy-skills.git karpathy-skills 2>/dev/null \
  || echo "    [SKIP] karpathy-skills"

sudo -u claude-code git clone --depth 1 \
  https://github.com/mattpocock/skills.git mattpocock-skills 2>/dev/null \
  || echo "    [SKIP] mattpocock-skills"

sudo -u claude-code git clone --depth 1 \
  https://github.com/juliusbrussee/caveman.git caveman 2>/dev/null \
  || echo "    [SKIP] caveman"

cd /root

# ── Statusline ────────────────────────────────────────────────────────────────
step 21 "Statusline"
sudo -u claude-code mkdir -p /home/claude-code/.claude/bin
cat > /home/claude-code/.claude/bin/statusline-command.sh << 'STATUSLINE'
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

chmod +x /home/claude-code/.claude/bin/statusline-command.sh
chown claude-code:claude-code /home/claude-code/.claude/bin/statusline-command.sh
echo "    Statusline: ~/.claude/bin/statusline-command.sh"

# ── code-server (web VS Code) ─────────────────────────────────────────────────
step 22 "code-server (web VS Code)"
curl -fsSL https://code-server.dev/install.sh | sh
echo "    $(code-server --version 2>/dev/null | head -1 || echo 'installed')"

sudo -u claude-code mkdir -p /home/claude-code/.config/code-server
sudo -u claude-code mkdir -p /home/claude-code/projects
systemctl enable code-server@claude-code
echo "    code-server service enabled (config injected next step)"

# ── SSH hardening ─────────────────────────────────────────────────────────────
step 23 "SSH hardening"
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/"               /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
sed -i "s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/"     /etc/ssh/sshd_config
grep -q "^MaxAuthTries"        /etc/ssh/sshd_config || echo "MaxAuthTries 5"          >> /etc/ssh/sshd_config
grep -q "^LoginGraceTime"      /etc/ssh/sshd_config || echo "LoginGraceTime 30"       >> /etc/ssh/sshd_config
grep -q "^ClientAliveInterval" /etc/ssh/sshd_config || echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh

# ── Shell environment ─────────────────────────────────────────────────────────
step 24 "Shell environment & aliases"
cat >> /home/claude-code/.bashrc << 'BASHRC'

# ── Claude Code Commander ─────────────────────────────────────────────────────
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

# Aliases — Ubuntu binary naming (batcat/fdfind are the Ubuntu binary names)
command -v batcat  &>/dev/null && alias cat='batcat'
command -v fdfind  &>/dev/null && alias fd='fdfind'

# Aliases — dev
alias pytest="python3 -m pytest"
alias py="python3"
alias serve="http-server -p 8000"

# ── ccc help ─────────────────────────────────────────────────────────────────
ccc() {
  local C='\033[0;36m' B='\033[1m' G='\033[0;32m' Y='\033[1;33m' N='\033[0m'
  echo ""
  echo -e "${B}╔══════════════════════════════════════════════════════════════════╗${N}"
  echo -e "${B}║               Claude Code Commander (CCC) Help                  ║${N}"
  echo -e "${B}╚══════════════════════════════════════════════════════════════════╝${N}"
  echo ""
  echo -e "  ${B}CLAUDE CODE${N}"
  echo -e "    ${C}claude${N}                   Start Claude Code session"
  echo -e "    ${C}claude --version${N}          Check version"
  echo -e "    ${C}ccc-setup-plugins${N}         Print plugin slash-commands for Claude"
  echo ""
  echo -e "  ${B}PLUGINS${N} ${Y}— paste inside a Claude Code session${N}"
  echo -e "    ${C}/plugin install skill-creator@claude-plugins-official${N}"
  echo -e "    ${C}/plugin install superpowers@claude-plugins-official${N}"
  echo -e "    ${C}/plugin install frontend-design@claude-plugins-official${N}"
  echo -e "    ${C}/plugin marketplace add mksglu/context-mode${N}"
  echo -e "    ${C}/plugin install context-mode@context-mode${N}"
  echo -e "    ${C}/plugin marketplace add thedotmack/claude-mem${N}"
  echo -e "    ${C}/plugin install claude-mem${N}"
  echo ""
  echo -e "  ${B}SKILLS${N} ${G}(pre-cloned at ~/.claude/skills/)${N}"
  echo -e "    anthropic-skills   karpathy-skills   mattpocock-skills   caveman"
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
  echo -e "    ${C}fdfind <name>${N}              find files"
  echo -e "    ${C}fzf${N}                       fuzzy finder  (pipe with |)"
  echo -e "    ${C}batcat <file>${N}              syntax-highlighted cat"
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
BASHRC

chown claude-code:claude-code /home/claude-code/.bashrc

# ── ccc-setup-plugins (standalone script) ────────────────────────────────────
step 25 "ccc-setup-plugins script"
cat > /usr/local/bin/ccc-setup-plugins << 'PLUGINSCRIPT'
#!/bin/bash
B='\033[1m'; C='\033[0;36m'; Y='\033[1;33m'; N='\033[0m'
echo ""
echo -e "${B}CCC Plugin Setup${N}"
echo -e "${Y}Start Claude Code (run: claude), then paste these one at a time:${N}"
echo ""
echo -e "  ${C}/plugin install skill-creator@claude-plugins-official${N}"
echo -e "  ${C}/plugin install superpowers@claude-plugins-official${N}"
echo -e "  ${C}/plugin install frontend-design@claude-plugins-official${N}"
echo -e "  ${C}/plugin marketplace add mksglu/context-mode${N}"
echo -e "  ${C}/plugin install context-mode@context-mode${N}"
echo -e "  ${C}/plugin marketplace add thedotmack/claude-mem${N}"
echo -e "  ${C}/plugin install claude-mem${N}"
echo ""
echo -e "  ${Y}Pre-configured in settings.json (no action needed):${N}"
echo "  • All tool permissions (Bash, Read, Write, Edit, WebFetch, Task, mcp__*)"
echo "  • Agent teams + extended thinking + 64k output + remote control"
echo ""
PLUGINSCRIPT
chmod +x /usr/local/bin/ccc-setup-plugins

# ── MOTD ─────────────────────────────────────────────────────────────────────
step 26 "MOTD"
chmod -x /etc/update-motd.d/* 2>/dev/null || true
cat > /etc/update-motd.d/00-ccc << 'MOTD'
#!/bin/bash
G='\033[0;32m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
echo ""
echo -e "${G}${B}  Claude Code Commander${N}"
echo -e "  ${C}claude${N}               Start Claude Code"
echo -e "  ${C}ccc${N}                  Full help + command reference"
echo -e "  ${C}ccc-setup-plugins${N}    Plugin install commands"
echo -e "  ${C}http://<ip>:8080${N}     Web VS Code (code-server)"
echo ""
MOTD
chmod +x /etc/update-motd.d/00-ccc

# ── Git defaults ──────────────────────────────────────────────────────────────
step 27 "Git defaults"
sudo -u claude-code git config --global init.defaultBranch main
sudo -u claude-code git config --global core.editor nano
sudo -u claude-code git config --global pull.rebase false
sudo -u claude-code git config --global core.autocrlf false

# ── Auto-update cron ──────────────────────────────────────────────────────────
step 28 "Auto-update cron"
cat > /etc/cron.d/system-update << 'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * 0 root apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq && apt-get clean -qq >> /var/log/system-update.log 2>&1
CRON
chmod 0644 /etc/cron.d/system-update

cat > /etc/logrotate.d/system-update << 'LOGROTATE'
/var/log/system-update.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
LOGROTATE

# ── Cleanup ───────────────────────────────────────────────────────────────────
step 29 "Cleanup"
apt-get autoremove -y -qq
apt-get clean -qq
rm -rf /var/lib/apt/lists/*

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║          Base provisioning complete              ║"
echo "╚══════════════════════════════════════════════════╝"
PROVISION_EOF

  chmod +x /tmp/provision-${CT_ID}.sh
  pct push "$CT_ID" /tmp/provision-${CT_ID}.sh /tmp/provision.sh
  pct exec "$CT_ID" -- chmod +x /tmp/provision.sh
  pct exec "$CT_ID" -- /tmp/provision.sh
  kill "$_timer_pid" 2>/dev/null; wait "$_timer_pid" 2>/dev/null || true
  rm -f /tmp/provision-${CT_ID}.sh

  # ── Passwords + code-server config (variable expansion — outside heredoc) ───
  info "Setting passwords and finalizing code-server ..."

  pct exec "$CT_ID" -- bash -c "echo 'claude-code:${CC_PASSWORD}' | chpasswd"

  pct exec "$CT_ID" -- bash -c "
    sudo -u claude-code mkdir -p /home/claude-code/.config/code-server
    cat > /home/claude-code/.config/code-server/config.yaml << 'YAML'
bind-addr: 0.0.0.0:8080
auth: password
password: ${CS_PASSWORD}
cert: false
user-data-dir: /home/claude-code/.local/share/code-server
extensions-dir: /home/claude-code/.local/share/code-server/extensions
YAML
    chown -R claude-code:claude-code /home/claude-code/.config/code-server
  "

  # ── code-server extensions ────────────────────────────────────────────────
  info "Installing code-server extensions (best-effort) ..."
  local extensions=(
    ms-python.python
    golang.go
    rust-lang.rust-analyzer
    esbenp.prettier-vscode
    eamodio.gitlens
    ms-vscode.vscode-typescript-next
    ms-playwright.playwright
    vitest.explorer
    redhat.vscode-yaml
    tamasfe.even-better-toml
    ms-vscode.vscode-json
  )
  for ext in "${extensions[@]}"; do
    pct exec "$CT_ID" -- sudo -u claude-code \
      code-server --install-extension "$ext" 2>/dev/null || true
  done

  pct exec "$CT_ID" -- systemctl start "code-server@claude-code"
  success "code-server started on port 8080."

  # ── SSH key for claude-code user ─────────────────────────────────────────────
  if [[ -n "${CT_SSH_KEY:-}" && -f "$CT_SSH_KEY" ]]; then
    info "Installing SSH public key for claude-code user ..."
    pct exec "$CT_ID" -- bash -c "
      sudo -u claude-code mkdir -p /home/claude-code/.ssh
      sudo -u claude-code chmod 700 /home/claude-code/.ssh
    "
    pct push "$CT_ID" "$CT_SSH_KEY" /tmp/authorized_keys
    pct exec "$CT_ID" -- bash -c "
      cat /tmp/authorized_keys >> /home/claude-code/.ssh/authorized_keys
      chown claude-code:claude-code /home/claude-code/.ssh/authorized_keys
      chmod 600 /home/claude-code/.ssh/authorized_keys
      rm /tmp/authorized_keys
    "
    success "SSH key installed for claude-code."
  fi
}

# ── Print Summary ─────────────────────────────────────────────────────────────
print_summary() {
  local ct_ip
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║          Claude Code Commander — Ready!          ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Container:${NC}    $CT_ID ($CT_HOSTNAME) — $CT_OS"
  echo -e "  ${BOLD}IP:${NC}           ${ct_ip:-pending (DHCP)}"
  echo -e "  ${BOLD}Resources:${NC}    ${CT_CORES} vCPU / $(( CT_RAM / 1024 )) GB RAM / ${CT_DISK} GB disk"
  echo -e "  ${BOLD}Storage:${NC}      $CT_STORAGE"
  if [[ "$HA_ENABLED" -eq 1 ]]; then
    echo -e "  ${BOLD}HA:${NC}           enabled${HA_GROUP:+ — group: $HA_GROUP}"
  fi
  echo -e "  ${BOLD}Timezone:${NC}     America/New_York"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}"
  echo -e "    Proxmox console:  ${CYAN}pct enter $CT_ID${NC}"
  [[ -n "${ct_ip:-}" ]] && \
  echo -e "    SSH:              ${CYAN}ssh claude-code@${ct_ip}${NC}"
  [[ -n "${ct_ip:-}" ]] && \
  echo -e "    Web VS Code:      ${CYAN}http://${ct_ip}:8080${NC}  (password: $CS_PASSWORD)"
  echo ""
  echo -e "  ${BOLD}First steps:${NC}"
  echo -e "    1. ${CYAN}ssh claude-code@${ct_ip:-<ip>}${NC}"
  echo -e "    2. ${CYAN}claude${NC}            (authenticate + start coding)"
  echo -e "    3. ${CYAN}ccc-setup-plugins${NC} (plugin install commands)"
  echo -e "    4. ${CYAN}ccc${NC}               (full help reference)"
  echo ""
  echo -e "  ${BOLD}Languages:${NC}    Node.js 22 LTS, Python 3, Go, Rust"
  echo -e "  ${BOLD}Testing:${NC}      pytest, jest, vitest, Playwright, httpie, nodemon, entr"
  echo -e "  ${BOLD}Skills:${NC}       anthropic, karpathy, mattpocock, caveman"
  echo -e "  ${BOLD}Statusline:${NC}   ~/.claude/bin/statusline-command.sh"
  echo -e "  ${BOLD}Plugins:${NC}      Run ${CYAN}ccc-setup-plugins${NC} after first claude login"
  echo -e "  ${BOLD}Redis:${NC}        Server available — ${CYAN}sudo systemctl start redis-server${NC}"
  echo -e "  ${BOLD}yq:${NC}           mikefarah Go binary at /usr/local/bin/yq"
  echo -e "  ${BOLD}Permissions:${NC}  All tools pre-approved (no prompts)"
  echo -e "  ${BOLD}SSH:${NC}          Root login disabled — use claude-code user"
  echo -e "  ${BOLD}Auto-updates:${NC} Sundays 3 AM ET"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  header
  preflight
  get_config
  check_apt_connectivity
  get_template
  create_container
  configure_ha
  start_container
  provision_container
  print_summary
}

main "$@"
