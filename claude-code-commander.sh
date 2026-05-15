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
#    • Weekly application self-updates from GitHub (no unattended OS upgrades)
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
  echo "    2) Debian 13 (Trixie)"
  echo ""
  read -rp "OS [1]: " _os_choice
  _os_choice="${_os_choice:-1}"

  case "$_os_choice" in
    2)
      CT_OS="debian"
      CT_OSTYPE="debian"
      _tmpl_pattern='^debian-13-standard_13\.[0-9]+-[0-9]+_amd64\.tar\.zst$'
      _tmpl_label="Debian 13 (Trixie)"
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

  read -rp  "Working username [claude-code]: " CC_USER
  CC_USER="${CC_USER:-claude-code}"
  [[ "$CC_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || error "Invalid username — use lowercase letters, numbers, hyphens, underscores."

  read -rsp "Root password (temporary, setup only): " CT_PASSWORD
  echo ""
  [[ -n "$CT_PASSWORD" ]] || error "Password cannot be empty."

  read -rsp "${CC_USER} user password: " CC_PASSWORD
  echo ""
  [[ -n "$CC_PASSWORD" ]] || error "User password cannot be empty."

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
  echo "  User:         ${CC_USER} (non-root, passwordless sudo)"
  echo "  code-server:  port 8080 (web VS Code)"
  echo "  Cockpit:      port 9090 (system monitoring + file manager)"
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
  pct start "$CT_ID" || true  # HA-managed start returns non-zero (async request)

  # Poll until actually running — needed for both HA and non-HA
  info "Waiting for container to reach running state ..."
  local _run_attempts=0
  while true; do
    local _state
    _state=$(pct status "$CT_ID" 2>/dev/null | awk '{print $2}')
    [[ "$_state" == "running" ]] && break
    _run_attempts=$(( _run_attempts + 1 ))
    [[ $_run_attempts -lt 60 ]] || error "Container $CT_ID did not reach running state after 120s."
    sleep 2
  done
  success "Container $CT_ID is running."
  sleep 3

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
    attempts=$(( attempts + 1 ))
    [[ $attempts -lt 30 ]] || error "Network timeout after 60s — check gateway/DNS: ${_ping_target}"
    sleep 2
  done
  success "Container is online."
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
_STEPS=28
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
  ca-certificates gnupg lsb-release apt-transport-https \
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

# ── Global npm: TypeScript runtime only ───────────────────────────────────────
step 9 "Global npm packages"
npm install -g typescript ts-node tsx

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

# ── claude-code user ─────────────────────────────────────────────────────────
step 12 "Creating claude-code user"
useradd -m -s /bin/bash -d /home/claude-code claude-code 2>/dev/null || true
usermod -aG sudo claude-code
echo "claude-code ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/claude-code
chmod 0440 /etc/sudoers.d/claude-code

mkdir -p /etc/ccc
cat > /etc/ccc/config << 'CCCONFIG'
CCC_USER="claude-code"
CCC_HOME="/home/claude-code"
CCC_CODE_SERVER_SERVICE="code-server@claude-code"
CCC_SELF_UPDATE_REPO="git@github.com:oculus-pllx/CCC.git"
CCC_SELF_UPDATE_REF="main"
CCC_SELF_UPDATE_SCRIPT="claude-code-commander.sh"
CCCONFIG
chmod 0644 /etc/ccc/config

# ── Rust for claude-code user ─────────────────────────────────────────────────
step 13 "Rust (claude-code user)"
sudo -u claude-code bash -c '
  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
'

# ── Python testing & linting ecosystem ───────────────────────────────────────
step 14 "Python ecosystem"
echo "    pip3 available — install packages per-project with: pip install --break-system-packages <pkg>"

# ── Claude Code ──────────────────────────────────────────────────────────────
step 15 "Claude Code"
sudo -u claude-code bash -c '
  export HOME=/home/claude-code
  curl -fsSL https://claude.ai/install.sh | bash
'

CLAUDE_BIN=$(find /home/claude-code -name "claude" \( -type f -o -type l \) 2>/dev/null \
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
step 16 "Playwright (skipped — install manually after provision)"
echo "    Run after provision: npx --yes playwright install --with-deps chromium"

# ── Claude Code settings.json ─────────────────────────────────────────────────
step 17 "Claude Code settings.json"
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
  "enableRemoteControl": true,
  "statusLine": "~/.claude/bin/statusline-command.sh"
}
SETTINGS

# ── oculus-configs ────────────────────────────────────────────────────────────
step 18 "oculus-configs"
sudo -u claude-code mkdir -p /home/claude-code/projects
git clone --depth 1 https://github.com/oculus-pllx/oculus-configs /opt/oculus-configs 2>&1 | sed 's/^/  /'
chown -R claude-code:claude-code /opt/oculus-configs
# CLAUDE.md
cp /opt/oculus-configs/claude/CLAUDE.md /home/claude-code/.claude/CLAUDE.md \
  || warn "oculus-configs: CLAUDE.md not found, skipping"
# rules/
if [[ -d /opt/oculus-configs/claude/rules ]]; then
  sudo -u claude-code cp -r /opt/oculus-configs/claude/rules/. /home/claude-code/.claude/rules/
else
  warn "oculus-configs: rules/ not found, skipping"
fi
# templates/
sudo -u claude-code mkdir -p /home/claude-code/Templates
if [[ -d /opt/oculus-configs/templates ]]; then
  sudo -u claude-code cp -r /opt/oculus-configs/templates/. /home/claude-code/Templates/
else
  warn "oculus-configs: templates/ not found, skipping"
fi
# Codex skills
sudo -u claude-code mkdir -p /home/claude-code/.codex
sudo -u claude-code cp /opt/oculus-configs/codex/AGENTS.md \
  /home/claude-code/.codex/AGENTS.md 2>/dev/null \
  || warn "oculus-configs: codex/AGENTS.md not found, skipping"
# Gemini skills
sudo -u claude-code mkdir -p /home/claude-code/.gemini
sudo -u claude-code cp /opt/oculus-configs/gemini/GEMINI.md \
  /home/claude-code/.gemini/GEMINI.md 2>/dev/null \
  || warn "oculus-configs: gemini/GEMINI.md not found, skipping"
sudo -u claude-code mkdir -p /home/claude-code/.claude/skills

# ── Statusline ────────────────────────────────────────────────────────────────
step 19 "Statusline"
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
step 20 "code-server (web VS Code)"
curl -fsSL https://code-server.dev/install.sh | sh
echo "    $(code-server --version 2>/dev/null | head -1 || echo 'installed')"

sudo -u claude-code mkdir -p /home/claude-code/.config/code-server
sudo -u claude-code mkdir -p /home/claude-code/projects

# Welcome file — opens automatically in code-server on first load
sudo -u claude-code tee /home/claude-code/projects/WELCOME.md > /dev/null << 'WELCOMEMD'
# Welcome to Claude Code Commander

## First Steps

| Step | Command | Where |
|------|---------|-------|
| 1 | `ccc-onboarding` | SSH terminal — git identity, SSH key, GitHub |
| 2 | `claude` | SSH terminal — authenticate Claude Code |
| 3 | `ccc-install-playwright` | SSH terminal — headless browser testing (optional) |
| 4 | `ccc-install-codex` | SSH terminal — OpenAI Codex CLI (optional) |
| 5 | `ccc-install-jcodemunch` | SSH terminal — jCodeMunch MCP, 95% token reduction (optional) |
| 6 | `ccc` | SSH terminal — full command reference |

## This Interface (code-server)

- **New terminal tab**: Terminal → New Terminal (or click **+** in terminal tab bar)
- **Split terminal**: click the split icon in the terminal tab bar
- **Switch tabs**: click tab names in the right-side tab panel
- **Open folder**: File → Open Folder → `/home/claude-code/projects`

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

## Cockpit (port 9090)

System monitoring, file manager, and single terminal.
For multi-terminal work, use this editor (port 8080) instead.

## Quick Commands

```bash
ccc-onboarding     # first-login wizard
ccc-update         # update CCC app tools from GitHub + Claude Code
ccc-os-update      # manually update OS packages with apt
ccc-fix-cockpit-updates  # fix Cockpit offline update cache error
ccc-doctor         # health check
ccc                # full help
```

## SSH Access

```bash
ssh claude-code@<this-container-ip>
```
WELCOMEMD

# User-level code-server settings (applies to all workspaces)
sudo -u claude-code mkdir -p /home/claude-code/.local/share/code-server/User
sudo -u claude-code tee /home/claude-code/.local/share/code-server/User/settings.json > /dev/null << 'USERSETTINGS'
{
  "terminal.integrated.tabs.enabled": true,
  "terminal.integrated.tabs.location": "right",
  "terminal.integrated.defaultProfile.linux": "bash",
  "workbench.startupEditor": "none",
  "markdown.preview.openMarkdownLinks": "inEditor"
}
USERSETTINGS

# Workspace settings
sudo -u claude-code mkdir -p /home/claude-code/projects/.vscode
sudo -u claude-code tee /home/claude-code/projects/.vscode/settings.json > /dev/null << 'VSCSETTINGS'
{
  "workbench.startupEditor": "none"
}
VSCSETTINGS

sudo -u claude-code tee /home/claude-code/projects/.vscode/extensions.json > /dev/null << 'VSCEXT'
{
  "recommendations": []
}
VSCEXT

systemctl enable code-server@claude-code
echo "    code-server service enabled (config injected next step)"

# ── SSH hardening ─────────────────────────────────────────────────────────────
step 21 "SSH hardening"
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/"               /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
sed -i "s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/"     /etc/ssh/sshd_config
grep -q "^MaxAuthTries"        /etc/ssh/sshd_config || echo "MaxAuthTries 5"          >> /etc/ssh/sshd_config
grep -q "^LoginGraceTime"      /etc/ssh/sshd_config || echo "LoginGraceTime 30"       >> /etc/ssh/sshd_config
grep -q "^ClientAliveInterval" /etc/ssh/sshd_config || echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh

# ── Shell environment ─────────────────────────────────────────────────────────
step 22 "Shell environment & aliases"
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
  echo -e "${B}║               Claude Code Commander (CCC) Help                  ║${N}"
  echo -e "${B}╚══════════════════════════════════════════════════════════════════╝${N}"
  echo ""
  echo -e "  ${B}CLAUDE CODE${N}"
  echo -e "    ${C}claude${N}                   Start Claude Code session"
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
  echo -e "    ${C}ccc-self-update${N}           Pull latest ccc-* tools from GitHub (no reprovision)"
  echo -e "    ${C}ccc-update${N}                Update CCC app tools from GitHub + Claude Code"
  echo -e "    ${C}ccc-os-update${N}             Manual OS package update (apt)"
  echo -e "    ${C}ccc-fix-cockpit-updates${N}   Fix Cockpit 'cannot refresh cache whilst offline'"
  echo -e "    ${C}ccc-verify-cockpit-updates${N} Check Cockpit GUI update readiness"
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
  echo "CCC first-login onboarding is ready."
  read -rp "Run it now? [Y/n] " _ccc_run_onboarding
  if [[ -z "$_ccc_run_onboarding" || "$_ccc_run_onboarding" =~ ^[Yy]$ ]]; then
    ccc-onboarding
  else
    touch "$HOME/.ccc-onboarded"
    echo "Skipped. Run ccc-onboarding later if needed."
  fi
fi
BASHRC

chown claude-code:claude-code /home/claude-code/.bashrc

# tmux config
sudo -u claude-code tee /home/claude-code/.tmux.conf > /dev/null << 'TMUXCONF'
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
chown claude-code:claude-code /home/claude-code/.tmux.conf

# CCC_UPDATEABLE_START — sections below re-run by ccc-self-update
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"

# Remove the retired Cockpit kit UI and standalone helper.
rm -f /usr/local/bin/ccc-kit
systemctl disable --now ccc-kit-manager 2>/dev/null || true
rm -f /etc/systemd/system/ccc-kit-manager.service
systemctl daemon-reload 2>/dev/null || true
rm -rf /usr/share/cockpit/ccc /usr/local/lib/ccc "$CCC_HOME/.ccc/kit-manager"

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
echo -e "${B}CCC Application Update${N}"
echo -e "${Y}Updates CCC tooling from GitHub and app CLIs only. OS packages are not upgraded.${N}"
echo ""

echo -e "${C}[1/3]${N} CCC provisioner/tools from GitHub..."
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
echo -e "  Manual OS update, if desired: ${C}sudo ccc-os-update${N}"
echo ""
UPDATESCRIPT
chmod +x /usr/local/bin/ccc-update

# ── ccc-os-update (manual only) ───────────────────────────────────────────────
cat > /usr/local/bin/ccc-os-update << 'OSUPDATESCRIPT'
#!/bin/bash
set -euo pipefail
B='\033[1m'; C='\033[0;36m'; G='\033[0;32m'; N='\033[0m'
echo ""
echo -e "${B}CCC Manual OS Update${N}"
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
echo -e "${B}CCC Post-Install Setup Wizard${N}"
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
set -e
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" -eq 1 ]] || echo "$*"; }

enable_universe() {
  if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
    sudo sed -i '/^Components:/ {
      /universe/! s/$/ universe/
      /multiverse/! s/$/ multiverse/
    }' /etc/apt/sources.list.d/ubuntu.sources
  elif [[ -f /etc/apt/sources.list ]]; then
    sudo sed -i -E '/^deb / {
      / universe/! s/( main)( |$)/\1 universe\2/
      / multiverse/! s/( universe)( |$)/\1 multiverse\2/
    }' /etc/apt/sources.list
  fi
}

say "Fixing Cockpit/PackageKit offline update detection..."
enable_universe
sudo apt-get update -qq
sudo apt-get install -y -qq packagekit cockpit-packagekit

# PackageKit: disable NM network check
sudo mkdir -p /etc/PackageKit
printf '[Daemon]\nUseNetworkManager=false\n' | sudo tee /etc/PackageKit/PackageKit.conf >/dev/null

# GLib network monitor: force base backend (always online) via systemd drop-in
sudo mkdir -p /etc/systemd/system/packagekit.service.d
printf '[Service]\nEnvironment=GIO_USE_NETWORK_MONITOR=base\n' \
  | sudo tee /etc/systemd/system/packagekit.service.d/ccc-always-online.conf >/dev/null
sudo systemctl daemon-reload

# Ensure NM dummy connection is up
sudo nmcli con delete ccc-online 2>/dev/null || true
sudo nmcli con add type dummy con-name ccc-online ifname ccc-online0 \
  ip4 192.0.2.2/24 gw4 192.0.2.1 ipv6.method disabled autoconnect yes 2>/dev/null || true
sudo nmcli con up ccc-online 2>/dev/null || true

sudo systemctl stop packagekit 2>/dev/null || true
sudo rm -rf /var/cache/PackageKit/* /var/lib/PackageKit/transactions.db 2>/dev/null || true
sudo systemctl start packagekit 2>/dev/null || true
sudo systemctl restart cockpit.socket 2>/dev/null || true
if command -v pkcon &>/dev/null; then
  pkcon refresh force || true
fi
say "Done. Reload Cockpit and retry Software Updates."
COCKPITFIXSCRIPT
chmod +x /usr/local/bin/ccc-fix-cockpit-updates

cat > /usr/local/bin/ccc-verify-cockpit-updates << 'COCKPITVERIFYSCRIPT'
#!/bin/bash
B='\033[1m'; G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
ok() { echo -e "  ${G}✓${N} $*"; }
fail() { echo -e "  ${R}✗${N} $*"; FAILED=1; }
warn() { echo -e "  ${Y}!${N} $*"; }
FAILED=0

echo ""
echo -e "${B}Cockpit Software Updates Check${N}"
echo ""

dpkg -s packagekit &>/dev/null && ok "packagekit installed" || fail "packagekit missing"
dpkg -s cockpit-packagekit &>/dev/null && ok "cockpit-packagekit installed" || fail "cockpit-packagekit missing"
systemctl is-active --quiet packagekit && ok "PackageKit running" || fail "PackageKit not running"

ping -c1 -W2 1.1.1.1 &>/dev/null && ok "Internet reachable" || fail "Internet unreachable"
curl -fsSL --max-time 5 https://api.github.com &>/dev/null && ok "HTTPS/GitHub reachable" || fail "HTTPS/GitHub unreachable"

if [[ -f /etc/PackageKit/PackageKit.conf ]] && grep -q '^UseNetworkManager=false' /etc/PackageKit/PackageKit.conf; then
  ok "PackageKit UseNetworkManager=false"
else
  warn "PackageKit UseNetworkManager=false not set"
fi

if command -v pkcon &>/dev/null; then
  pkcon refresh force &>/dev/null && ok "PackageKit refresh works" || warn "PackageKit refresh failed; Cockpit updates may need manual repair"
fi

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo -e "${G}${B}Cockpit update path looks ready.${N}"
else
  echo -e "${R}${B}Cockpit update path needs repair.${N}"
  echo -e "  Run: ${C}sudo ccc-fix-cockpit-updates${N}"
fi
exit "$FAILED"
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
echo -e "${B}CCC Doctor — System Check${N}"
echo ""

echo -e "${C}── Network ───────────────────────────────────${N}"
ping -c1 -W2 1.1.1.1 &>/dev/null     && ok "Internet (ping)" || fail "Internet unreachable"
curl -fsSL --max-time 5 https://api.github.com &>/dev/null && ok "GitHub API" || fail "GitHub unreachable"
curl -fsSL --max-time 5 https://registry.npmjs.org &>/dev/null && ok "npm registry" || fail "npm registry unreachable"
echo ""

echo -e "${C}── Runtimes ──────────────────────────────────${N}"
command -v node &>/dev/null   && ok "Node.js $(node --version)" || fail "Node.js missing"
command -v python3 &>/dev/null && ok "Python $(python3 --version)" || fail "Python3 missing"
command -v go &>/dev/null     && ok "Go $(go version | awk '{print $3}')" || fail "Go missing"
command -v cargo &>/dev/null  && ok "Rust $(cargo --version)" || fail "Rust missing"
echo ""

echo -e "${C}── Claude Code ───────────────────────────────${N}"
command -v claude &>/dev/null && ok "claude binary: $(which claude)" || fail "claude not in PATH"
[[ -f "$CCC_HOME/.claude/settings.json" ]] && ok "settings.json present for $CCC_USER" || fail "settings.json missing for $CCC_USER"
[[ -f "$CCC_HOME/.claude/bin/statusline-command.sh" ]] && ok "statusline script present" || warn "statusline script missing"
echo ""

echo -e "${C}── Services ──────────────────────────────────${N}"
systemctl is-active --quiet "$CCC_CODE_SERVER_SERVICE" && ok "code-server running" || fail "code-server not running — sudo systemctl start $CCC_CODE_SERVER_SERVICE"
systemctl is-active --quiet cockpit.socket            && ok "cockpit running"     || fail "cockpit not running — sudo systemctl start cockpit.socket"
ccc-verify-cockpit-updates &>/dev/null && ok "Cockpit software updates ready" || warn "Cockpit software updates need repair — sudo ccc-fix-cockpit-updates"
if [[ -f /etc/PackageKit/PackageKit.conf ]] && grep -q '^UseNetworkManager=false' /etc/PackageKit/PackageKit.conf; then
  ok "PackageKit ignores NetworkManager offline state"
else
  warn "PackageKit may report offline in Cockpit — run: sudo ccc-fix-cockpit-updates"
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
step 23 "ccc-install-playwright script"
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
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
CCC_SELF_UPDATE_REPO="${CCC_SELF_UPDATE_REPO:-git@github.com:oculus-pllx/CCC.git}"
CCC_SELF_UPDATE_REF="${CCC_SELF_UPDATE_REF:-main}"
CCC_SELF_UPDATE_SCRIPT="${CCC_SELF_UPDATE_SCRIPT:-claude-code-commander.sh}"
VERSION_FILE="${CCC_VERSION_FILE:-/etc/ccc/version}"
SHOW_ACTIONS=1
[[ "${1:-}" == "--no-actions" ]] && SHOW_ACTIONS=0
TMP_REPO=""

cleanup() {
  [[ -n "${TMP_REPO:-}" ]] && rm -rf "$TMP_REPO"
}
trap cleanup EXIT

run_as_user() {
  if [[ "$(id -u)" -eq 0 && "$CCC_USER" != "root" ]]; then
    sudo -u "$CCC_USER" env HOME="$CCC_HOME" GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' "$@"
  else
    env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' "$@"
  fi
}

clone_repo() {
  TMP_REPO=$(mktemp -d /tmp/ccc-update-status.XXXXXX)
  if run_as_user git clone --quiet --depth 50 --branch "$CCC_SELF_UPDATE_REF" "$CCC_SELF_UPDATE_REPO" "$TMP_REPO"; then
    return 0
  fi
  rm -rf "$TMP_REPO"
  TMP_REPO=$(mktemp -d /tmp/ccc-update-status.XXXXXX)
  local https_repo="${CCC_SELF_UPDATE_REPO/git@github.com:/https:\/\/github.com\/}"
  https_repo="${https_repo%.git}.git"
  run_as_user git clone --quiet --depth 50 --branch "$CCC_SELF_UPDATE_REF" "$https_repo" "$TMP_REPO"
}

installed_commit=""
installed_date=""
if [[ -r "$VERSION_FILE" ]]; then
  installed_commit=$(awk -F= '$1=="CCC_INSTALLED_COMMIT"{gsub(/"/,"",$2); print $2}' "$VERSION_FILE" | tail -1)
  installed_date=$(awk -F= '$1=="CCC_INSTALLED_DATE"{gsub(/"/,"",$2); print $2}' "$VERSION_FILE" | tail -1)
fi

echo ""
echo -e "${B}CCC Update Status${N}"
echo -e "  Repo:   ${C}${CCC_SELF_UPDATE_REPO}${N}"
echo -e "  Ref:    ${C}${CCC_SELF_UPDATE_REF}${N}"
echo -e "  Script: ${C}${CCC_SELF_UPDATE_SCRIPT}${N}"
echo ""

if ! clone_repo; then
  echo -e "${R}Could not reach GitHub repo.${N}"
  echo -e "  Check internet, repo access, and SSH keys. Try: ${C}ccc-doctor${N}"
  exit 1
fi

latest_commit=$(git -C "$TMP_REPO" rev-parse HEAD)
latest_short=$(git -C "$TMP_REPO" rev-parse --short HEAD)
latest_date=$(git -C "$TMP_REPO" log -1 --date=format:'%Y-%m-%d %H:%M:%S %z' --format='%cd')
latest_subject=$(git -C "$TMP_REPO" log -1 --format='%s')

if [[ -n "$installed_commit" ]]; then
  installed_short=${installed_commit:0:7}
  echo -e "  Installed: ${C}${installed_short}${N}${installed_date:+ — $installed_date}"
else
  echo -e "  Installed: ${Y}unknown${N} ${D}(run ccc-self-update once to record it)${N}"
fi
echo -e "  GitHub:    ${C}${latest_short}${N} — ${latest_date}"
echo -e "             ${latest_subject}"
echo ""

if [[ -n "$installed_commit" ]] && git -C "$TMP_REPO" cat-file -e "$installed_commit^{commit}" 2>/dev/null; then
  behind=$(git -C "$TMP_REPO" rev-list --count "${installed_commit}..HEAD")
  if [[ "$behind" -eq 0 ]]; then
    echo -e "  ${G}Up to date with origin/${CCC_SELF_UPDATE_REF}.${N}"
  else
    echo -e "  ${Y}${behind} commit(s) behind origin/${CCC_SELF_UPDATE_REF}${N}"
    git -C "$TMP_REPO" log --oneline --max-count=5 "${installed_commit}..HEAD" | sed 's/^/  • /'
  fi
else
  echo -e "  ${Y}Behind count unknown.${N}"
  echo -e "  ${D}Recent GitHub commits:${N}"
  git -C "$TMP_REPO" log --oneline --max-count=5 | sed 's/^/  • /'
fi

if [[ "$SHOW_ACTIONS" -eq 1 ]]; then
  echo ""
  echo -e "  Check:  ${C}ccc-update-status${N}"
  echo -e "  Update: ${C}sudo ccc-self-update${N}"
fi
echo ""
UPDATESTATUSSCRIPT
chmod +x /usr/local/bin/ccc-update-status

# ── ccc-self-update ───────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-self-update << 'SELFUPDATESCRIPT'
#!/bin/bash
set -euo pipefail
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
CCC_SELF_UPDATE_REPO="${CCC_SELF_UPDATE_REPO:-git@github.com:oculus-pllx/CCC.git}"
CCC_SELF_UPDATE_REF="${CCC_SELF_UPDATE_REF:-main}"
CCC_SELF_UPDATE_SCRIPT="${CCC_SELF_UPDATE_SCRIPT:-claude-code-commander.sh}"
CCC_SELF_UPDATE_RAW_URL="${CCC_SELF_UPDATE_RAW_URL:-https://raw.githubusercontent.com/oculus-pllx/CCC/${CCC_SELF_UPDATE_REF}/${CCC_SELF_UPDATE_SCRIPT}}"
VERSION_FILE="${CCC_VERSION_FILE:-/etc/ccc/version}"
TMP="/tmp/ccc-provisioner-$$.sh"
CLONE_DIR=""
LATEST_COMMIT=""

cleanup() {
  rm -f "$TMP"
  [[ -n "${CLONE_DIR:-}" ]] && rm -rf "$CLONE_DIR"
}
trap cleanup EXIT

run_as_user() {
  if [[ "$(id -u)" -eq 0 && "$CCC_USER" != "root" ]]; then
    sudo -u "$CCC_USER" env HOME="$CCC_HOME" GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' "$@"
  else
    env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' "$@"
  fi
}

download_latest() {
  echo -e "  Raw URL: ${C}${CCC_SELF_UPDATE_RAW_URL}${N}"
  if curl -fsSL "$CCC_SELF_UPDATE_RAW_URL" -o "$TMP"; then
    return 0
  fi

  echo -e "  ${Y}Raw download failed; trying Git clone fallback.${N}"
  CLONE_DIR=$(mktemp -d /tmp/ccc-self-update.XXXXXX)
  if run_as_user git clone --depth 1 --branch "$CCC_SELF_UPDATE_REF" "$CCC_SELF_UPDATE_REPO" "$CLONE_DIR"; then
    if [[ -f "$CLONE_DIR/$CCC_SELF_UPDATE_SCRIPT" ]]; then
      cp "$CLONE_DIR/$CCC_SELF_UPDATE_SCRIPT" "$TMP"
      return 0
    fi
    echo -e "${R}Script not found in repo: ${CCC_SELF_UPDATE_SCRIPT}${N}"
    return 1
  fi

  local https_repo="${CCC_SELF_UPDATE_REPO/git@github.com:/https:\/\/github.com\/}"
  https_repo="${https_repo%.git}.git"
  echo -e "  ${Y}SSH clone failed; trying HTTPS clone: ${https_repo}${N}"
  rm -rf "$CLONE_DIR"
  CLONE_DIR=$(mktemp -d /tmp/ccc-self-update.XXXXXX)
  run_as_user git clone --depth 1 --branch "$CCC_SELF_UPDATE_REF" "$https_repo" "$CLONE_DIR"
  [[ -f "$CLONE_DIR/$CCC_SELF_UPDATE_SCRIPT" ]] || {
    echo -e "${R}Script not found in repo: ${CCC_SELF_UPDATE_SCRIPT}${N}"
    return 1
  }
  cp "$CLONE_DIR/$CCC_SELF_UPDATE_SCRIPT" "$TMP"
}

resolve_latest_commit() {
  if [[ -n "${CLONE_DIR:-}" && -d "$CLONE_DIR/.git" ]]; then
    git -C "$CLONE_DIR" rev-parse HEAD 2>/dev/null || true
    return 0
  fi
  git ls-remote "$CCC_SELF_UPDATE_REPO" "refs/heads/$CCC_SELF_UPDATE_REF" 2>/dev/null | awk '{print $1}' | head -1 && return 0
  local https_repo="${CCC_SELF_UPDATE_REPO/git@github.com:/https:\/\/github.com\/}"
  https_repo="${https_repo%.git}.git"
  git ls-remote "$https_repo" "refs/heads/$CCC_SELF_UPDATE_REF" 2>/dev/null | awk '{print $1}' | head -1 || true
}

echo ""
echo -e "${B}CCC Self-Update${N}"
echo -e "${Y}Downloads latest provisioner and re-applies ccc-* tools, MOTD, and Cockpit fixes.${N}"
echo -e "${Y}Does NOT re-run Node/Go/Rust, Claude install, or user creation.${N}"
echo ""
if command -v ccc-update-status &>/dev/null; then
  ccc-update-status --no-actions || true
fi

echo -e "${C}[1/3]${N} Downloading latest provisioner..."
echo -e "  Repo:    ${C}${CCC_SELF_UPDATE_REPO}${N}"
echo -e "  Ref:     ${C}${CCC_SELF_UPDATE_REF}${N}"
echo -e "  Script:  ${C}${CCC_SELF_UPDATE_SCRIPT}${N}"
if ! download_latest; then
  echo -e "${R}Download failed. Check internet, GitHub access, and SSH keys: ccc-doctor${N}"
  exit 1
fi
LATEST_COMMIT=$(resolve_latest_commit)
echo -e "  Downloaded $(wc -l < "$TMP") lines"

echo ""
echo -e "${C}[2/3]${N} Extracting updateable sections..."
_S="CCC_UPDATEABLE_START"; _E="CCC_UPDATEABLE_END"
UPDATE_SCRIPT=$(awk "/# $_S/,/# $_E/" "$TMP")
if [[ -z "$UPDATE_SCRIPT" ]]; then
  echo -e "${R}Could not find update markers in provisioner. Repo may be outdated.${N}"
  rm -f "$TMP"
  exit 1
fi

echo ""
echo -e "${C}[3/3]${N} Applying updates..."
(echo 'step() { echo "  >>> $2"; }'; echo "$UPDATE_SCRIPT") | sudo bash
STATUS=$?

echo ""
if [[ $STATUS -eq 0 ]]; then
  if [[ -n "$LATEST_COMMIT" ]]; then
    sudo mkdir -p /etc/ccc
    {
      echo "CCC_INSTALLED_COMMIT=\"$LATEST_COMMIT\""
      echo "CCC_INSTALLED_REF=\"$CCC_SELF_UPDATE_REF\""
      echo "CCC_INSTALLED_DATE=\"$(date '+%Y-%m-%d %H:%M:%S %z')\""
    } | sudo tee "$VERSION_FILE" >/dev/null
  fi
  echo -e "${G}${B}Self-update complete.${N}"
  echo -e "  ccc-* commands, MOTD, and Cockpit fixes updated to latest."
else
  echo -e "${R}Update script exited with errors ($STATUS). Some steps may have partially applied.${N}"
fi
echo ""
SELFUPDATESCRIPT
chmod +x /usr/local/bin/ccc-self-update

# ── MOTD ─────────────────────────────────────────────────────────────────────
step 24 "MOTD"
chmod -x /etc/update-motd.d/* 2>/dev/null || true
cat > /etc/update-motd.d/00-ccc << 'MOTD'
#!/bin/bash
G='\033[0;32m'; C='\033[0;36m'; B='\033[1m'; Y='\033[1;33m'; D='\033[2m'; N='\033[0m'
echo ""
echo -e "${G}${B}  Claude Code Commander${N}"
echo -e "  ${C}claude${N}                    Start Claude Code"
echo -e "  ${C}ccc${N}                       Full help + command reference"
echo -e "  ${C}tmux${N}                      Terminal multiplexer (tabs/splits in SSH)"
echo ""
echo -e "  ${Y}Setup & Maintenance${N}"
echo -e "  ${C}ccc-onboarding${N}            First-login wizard (git, SSH key, GitHub)"
echo -e "  ${C}ccc-setup${N}                 Same wizard, safe to re-run"
echo -e "  ${C}ccc-update-status${N}         Show installed vs GitHub version"
echo -e "  ${C}ccc-self-update${N}           Pull latest ccc-* tools from GitHub (no reprovision)"
echo -e "  ${C}ccc-update${N}                Update system packages + Claude Code"
echo -e "  ${C}ccc-os-update${N}             Manual OS package update (apt)"
echo -e "  ${C}ccc-fix-cockpit-updates${N}   Fix Cockpit offline update cache error"
echo -e "  ${C}ccc-verify-cockpit-updates${N} Check Cockpit GUI update readiness"
echo -e "  ${C}ccc-install-playwright${N}    Install Playwright + Chromium"
echo -e "  ${C}ccc-install-codex${N}         Install OpenAI Codex CLI"
echo -e "  ${C}ccc-install-jcodemunch${N}    Install jCodeMunch MCP (95% token reduction)"
echo -e "  ${C}ccc-doctor${N}                System health check"
echo ""
echo -e "  ${Y}Web Interfaces${N}"
IP=\$(hostname -I 2>/dev/null | awk '{print \$1}')
echo -e "  ${C}http://\${IP}:8080${N}   Web VS Code — multi-terminal, file editor"
echo -e "  ${C}https://\${IP}:9090${N}  Cockpit — config, projects, MCP, updates"
echo -e "  ${D}Tip: use port 8080 for multiple terminal tabs (Terminal → New Terminal)${N}"
echo ""
MOTD
chmod +x /etc/update-motd.d/00-ccc

# ── Git defaults ──────────────────────────────────────────────────────────────
step 25 "Git defaults"
sudo -u claude-code git config --global init.defaultBranch main
sudo -u claude-code git config --global core.editor nano
sudo -u claude-code git config --global pull.rebase false
sudo -u claude-code git config --global core.autocrlf false

# ── Auto-update cron ──────────────────────────────────────────────────────────
step 26 "Application auto-update cron"
rm -f /etc/cron.d/system-update /etc/logrotate.d/system-update
cat > /etc/cron.d/ccc-app-update << 'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Weekly CCC application/tooling update from GitHub. Does not run apt upgrade.
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

# ── Cockpit (web admin UI) ────────────────────────────────────────────────────
step 27 "Cockpit (web admin UI)"
# Ubuntu LXC templates can ship with only main enabled; Cockpit update add-ons are in universe.
if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
  sed -i '/^Components:/ {
    /universe/! s/$/ universe/
    /multiverse/! s/$/ multiverse/
  }' /etc/apt/sources.list.d/ubuntu.sources
elif [[ -f /etc/apt/sources.list ]]; then
  sed -i -E '/^deb / {
    / universe/! s/( main)( |$)/\1 universe\2/
    / multiverse/! s/( universe)( |$)/\1 multiverse\2/
  }' /etc/apt/sources.list
fi
apt-get update -qq

# NetworkManager is required for Cockpit Networking graphs in LXC.
apt-get install -y -qq --no-install-recommends network-manager > /dev/null 2>&1

cat > /etc/NetworkManager/NetworkManager.conf <<'EOF'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no

[keyfile]
unmanaged-devices=none
EOF

systemctl enable --now NetworkManager
systemctl restart NetworkManager

nmcli con delete ccc-online 2>/dev/null || true

apt-get install -y cockpit > /dev/null 2>&1
apt-get install -y cockpit-files > /dev/null 2>&1 || true
apt-get install -y -qq packagekit cockpit-packagekit > /dev/null 2>&1 || true
apt-get purge -y -qq udisks2 > /dev/null 2>&1 || true

# Tell PackageKit not to use NetworkManager for online detection
mkdir -p /etc/PackageKit
cat > /etc/PackageKit/PackageKit.conf << 'PKCONF'
[Daemon]
UseNetworkManager=false
PKCONF
# Disable NM's periodic connectivity portal check — prevents NM marking itself
# "limited" in LXC where no captive-portal response is available
cat >> /etc/NetworkManager/conf.d/99-ccc-managed.conf << 'NMCONN'

[connectivity]
interval=0
NMCONN
# Force GLib's network monitor (used by PackageKit) to always report online.
# GIO_USE_NETWORK_MONITOR=base bypasses NM/netlink checks entirely.
mkdir -p /etc/systemd/system/packagekit.service.d
cat > /etc/systemd/system/packagekit.service.d/ccc-always-online.conf << 'PKDROP'
[Service]
Environment=GIO_USE_NETWORK_MONITOR=base
PKDROP
# Boot service: bring up the NM dummy connection after every reboot so NM
# reports a managed interface, which some Cockpit versions also check.
cat > /etc/systemd/system/ccc-online.service << 'SVCU'
[Unit]
Description=CCC dummy online interface
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nmcli con up ccc-online
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCU
systemctl daemon-reload
systemctl enable ccc-online.service
systemctl stop packagekit 2>/dev/null || true
rm -rf /var/cache/PackageKit/* /var/lib/PackageKit/transactions.db 2>/dev/null || true
systemctl start packagekit 2>/dev/null || true

if ! /usr/local/bin/ccc-verify-cockpit-updates; then
  echo "[WARN] Cockpit software update path is not ready."
  echo "       Inspect later with: ccc-verify-cockpit-updates"
  echo "       Continuing provision anyway."
fi

mkdir -p /etc/cockpit
cat > /etc/cockpit/cockpit.conf << 'COCKPITCONF'
[WebService]
LoginTitle = Claude Code Commander
LoginTo = false

[Session]
IdleTimeout = 0
COCKPITCONF
systemctl enable --now cockpit.socket
# ── CCC Cockpit plugin ─────────────────────────────────────────────────────
mkdir -p /usr/share/cockpit/ccc
cat > /usr/share/cockpit/ccc/manifest.json << 'MANIFEST'
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
MANIFEST
cat > /usr/share/cockpit/ccc/index.html << 'COCKPITUI'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Claude Code Commander</title>
  <style>
    :root {
      --bg:      #ffffff;
      --surface: #f0f0f0;
      --card:    #ffffff;
      --border:  #d2d2d2;
      --text:    #151515;
      --muted:   #6a6e73;
      --primary: #0066cc;
      --pri-fg:  #ffffff;
      --danger:  #c9190b;
      --success: #1e8f18;
      --warn:    #f0ab00;
      --radius:  4px;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg:      #1b1d21;
        --surface: #212427;
        --card:    #292c2f;
        --border:  #444548;
        --text:    #e0e0e0;
        --muted:   #8a8d90;
        --primary: #73bcf7;
        --pri-fg:  #151515;
        --danger:  #ff6166;
        --success: #5ba352;
        --warn:    #f4c145;
      }
    }

    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: var(--bg);
      color: var(--text);
      font-family: RedHatDisplay, RedHatText, Overpass, overpass, helvetica, arial, sans-serif;
      font-size: 14px;
      line-height: 1.5;
    }

    /* ── Header ── */
    .ccc-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 10px 24px;
      border-bottom: 1px solid var(--border);
      background: var(--bg);
    }
    .ccc-header-title { font-size: 18px; font-weight: 700; }
    .ccc-header-user  { font-size: 13px; color: var(--muted); }

    /* ── Nav tabs ── */
    .ccc-nav {
      display: flex;
      gap: 0;
      border-bottom: 1px solid var(--border);
      padding: 0 24px;
      background: var(--bg);
    }
    .ccc-nav button {
      background: none;
      border: none;
      border-bottom: 3px solid transparent;
      padding: 12px 16px;
      font-size: 14px;
      color: var(--muted);
      cursor: pointer;
      margin-bottom: -1px;
    }
    .ccc-nav button:hover { color: var(--text); }
    .ccc-nav button.active { color: var(--primary); border-bottom-color: var(--primary); font-weight: 600; }

    /* ── Main content ── */
    .ccc-main { padding: 24px; }
    .ccc-section { display: none; }
    .ccc-section.active { display: block; }
    #tab-claude.active { display: flex; flex-direction: column; height: calc(100vh - 108px); }

    /* ── Cards ── */
    .ccc-grid { display: grid; gap: 16px; margin-bottom: 24px; }
    .ccc-grid-4 { grid-template-columns: repeat(4, 1fr); }
    .ccc-grid-2 { grid-template-columns: repeat(2, 1fr); }
    .ccc-card {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 16px;
    }
    .ccc-card-title { font-size: 13px; font-weight: 600; color: var(--muted); margin-bottom: 6px; text-transform: uppercase; letter-spacing: .04em; }
    .ccc-card-value { font-size: 20px; font-weight: 700; }

    /* ── Section headings ── */
    .ccc-section-title { font-size: 16px; font-weight: 600; margin-bottom: 12px; }

    /* ── Labels / pills ── */
    .ccc-pills { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 24px; }
    .ccc-pill {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 4px 10px; border: 1px solid var(--border);
      border-radius: 20px; font-size: 13px; color: var(--muted);
    }
    .ccc-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); }
    .ccc-dot.on  { background: var(--success); }
    .ccc-dot.off { background: var(--danger); }

    /* ── Buttons ── */
    .btn {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 6px 16px; border-radius: var(--radius);
      font-size: 14px; font-weight: 600; cursor: pointer;
      border: 1px solid transparent; transition: opacity .15s;
    }
    .btn:disabled { opacity: .5; cursor: not-allowed; }
    .btn-primary  { background: var(--primary); color: var(--pri-fg); border-color: var(--primary); }
    .btn-secondary{ background: transparent; color: var(--text); border-color: var(--border); }
    .btn-danger   { background: transparent; color: var(--danger); border-color: var(--danger); }
    .btn-link     { background: none; border: none; color: var(--primary); padding: 0; font-weight: 400; text-decoration: underline; cursor: pointer; }
    .btn-sm       { padding: 4px 10px; font-size: 13px; }

    /* ── Forms ── */
    .form-group   { margin-bottom: 14px; }
    .form-label   { display: block; font-size: 13px; font-weight: 600; margin-bottom: 4px; }
    .form-helper  { font-size: 12px; color: var(--muted); margin-top: 4px; }
    .form-control {
      width: 100%; padding: 7px 10px;
      background: var(--bg); color: var(--text);
      border: 1px solid var(--border); border-radius: var(--radius);
      font-size: 14px; font-family: inherit;
    }
    .form-control:focus { outline: none; border-color: var(--primary); }
    select.form-control { cursor: pointer; }
    textarea.form-control { resize: vertical; }
    .action-row { display: flex; gap: 8px; margin-top: 4px; }

    /* ── Table ── */
    table { width: 100%; border-collapse: collapse; margin-bottom: 20px; }
    th, td { padding: 10px 12px; text-align: left; border-bottom: 1px solid var(--border); font-size: 13px; }
    th { font-weight: 600; font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); background: var(--surface); }
    tr:last-child td { border-bottom: none; }

    /* ── Toggle switch ── */
    .toggle-row {
      display: flex; align-items: center; justify-content: space-between;
      padding: 14px 16px; border: 1px solid var(--border);
      border-radius: var(--radius); margin-bottom: 8px; background: var(--card);
    }
    .toggle-label   { font-weight: 600; font-size: 14px; }
    .toggle-id      { font-size: 12px; font-family: monospace; color: var(--muted); margin-top: 1px; }
    .toggle-desc    { font-size: 13px; color: var(--muted); margin-top: 3px; }
    .toggle-switch  { position: relative; flex-shrink: 0; }
    .toggle-switch input { opacity: 0; width: 0; height: 0; position: absolute; }
    .toggle-track {
      display: block; width: 40px; height: 22px;
      background: var(--border); border-radius: 11px; cursor: pointer; transition: background .2s;
    }
    .toggle-thumb {
      position: absolute; top: 3px; left: 3px;
      width: 16px; height: 16px; border-radius: 50%;
      background: #fff; transition: left .2s; pointer-events: none;
    }
    .toggle-switch input:checked ~ .toggle-track { background: var(--primary); }
    .toggle-switch input:checked ~ .toggle-thumb { left: 21px; }

    /* ── Code/output box ── */
    .ccc-output {
      font-family: 'Courier New', monospace; font-size: 12px; white-space: pre-wrap;
      background: #111316; color: #c5c8c6;
      padding: 14px; border-radius: var(--radius); max-height: 220px;
      overflow-y: auto; margin-bottom: 16px; border: 1px solid #333;
    }
    @media (prefers-color-scheme: light) {
      .ccc-output { background: #1b1d21; }
    }

    /* ── Wizard progress ── */
    .wizard-bar { height: 5px; background: var(--surface); border-radius: 3px; margin-bottom: 18px; }
    .wizard-fill { height: 100%; background: var(--primary); border-radius: 3px; transition: width .2s; }

    /* ── Toast ── */
    #toast {
      position: fixed; bottom: 20px; right: 20px; z-index: 9999;
      padding: 10px 16px; border-radius: var(--radius);
      font-size: 13px; font-weight: 600; border: 1px solid;
      display: none; box-shadow: 0 2px 8px rgba(0,0,0,.3);
    }
    #toast.show { display: block; }
    #toast.success { background: var(--card); border-color: var(--success); color: var(--success); }
    #toast.error   { background: var(--card); border-color: var(--danger);  color: var(--danger); }
    #toast.info    { background: var(--card); border-color: var(--primary); color: var(--primary); }

    /* ── Modal ── */
    .modal-backdrop {
      display: none; position: fixed; inset: 0;
      background: rgba(0,0,0,.5); z-index: 500;
      align-items: center; justify-content: center;
    }
    .modal-backdrop.show { display: flex; }
    .modal-box {
      background: var(--card); border: 1px solid var(--border);
      border-radius: var(--radius); padding: 24px; max-width: 420px; width: 90%;
      box-shadow: 0 4px 16px rgba(0,0,0,.4);
    }
    .modal-title { font-size: 16px; font-weight: 700; margin-bottom: 8px; }
    .modal-body  { font-size: 14px; color: var(--muted); margin-bottom: 20px; }
    .modal-footer { display: flex; gap: 8px; justify-content: flex-end; }

    /* ── Data list ── */
    .data-list { list-style: none; }
    .data-item {
      display: flex; align-items: center; justify-content: space-between;
      padding: 12px 16px; border: 1px solid var(--border);
      border-radius: var(--radius); margin-bottom: 6px; background: var(--card);
    }
    .data-name { font-size: 14px; font-weight: 500; }

    /* ── CLAUDE.md textarea ── */
    #claude-textarea {
      flex: 1; resize: none; font-family: 'Courier New', monospace;
      font-size: 13px; line-height: 1.6;
    }
  </style>
</head>
<body>

<div class="ccc-header">
  <span class="ccc-header-title">Claude Code Commander</span>
  <span class="ccc-header-user" id="nav-user"></span>
</div>

<nav class="ccc-nav">
  <button class="active" data-tab="overview" onclick="showTab('overview')">Overview</button>
  <button data-tab="projects"  onclick="showTab('projects')">Projects</button>
  <button data-tab="claude"    onclick="showTab('claude')">CLAUDE.md</button>
  <button data-tab="mcp"       onclick="showTab('mcp')">MCP</button>
  <button data-tab="plugins"   onclick="showTab('plugins')">Plugins</button>
  <button data-tab="updates"   onclick="showTab('updates')">Updates</button>
</nav>

<div class="ccc-main">

  <!-- ── Overview ──────────────────────────────────────────────────────── -->
  <section id="tab-overview" class="ccc-section active">
    <div class="ccc-grid ccc-grid-4">
      <div class="ccc-card">
        <div class="ccc-card-title">CLAUDE.md</div>
        <div class="ccc-card-value" id="s-claude">—</div>
      </div>
      <div class="ccc-card">
        <div class="ccc-card-title">Rules</div>
        <div class="ccc-card-value" id="s-rules">—</div>
      </div>
      <div class="ccc-card">
        <div class="ccc-card-title">MCP Servers</div>
        <div class="ccc-card-value" id="s-mcp">—</div>
      </div>
      <div class="ccc-card">
        <div class="ccc-card-title">Plugins</div>
        <div class="ccc-card-value" id="s-plugins">—</div>
      </div>
    </div>

    <div class="ccc-section-title">Services</div>
    <div class="ccc-pills">
      <span class="ccc-pill"><span class="ccc-dot" id="dot-cs"></span>code-server :8080</span>
      <span class="ccc-pill"><span class="ccc-dot on"></span>cockpit :9090</span>
      <span class="ccc-pill"><span class="ccc-dot" id="dot-claude"></span>claude</span>
    </div>

    <div class="ccc-section-title">Quick Links</div>
    <div class="ccc-grid ccc-grid-2">
      <div class="ccc-card">
        <a id="vscode-link" href="#" target="_blank" class="btn-link" style="font-size:14px;font-weight:600">Web VS Code ↗</a>
        <div style="font-size:13px;color:var(--muted);margin-top:4px">code editor + multi-terminal</div>
      </div>
      <div class="ccc-card">
        <button class="btn-link" onclick="showTab('projects')" style="font-size:14px;font-weight:600">New Project →</button>
        <div style="font-size:13px;color:var(--muted);margin-top:4px">wizard → git → github</div>
      </div>
    </div>
  </section>

  <!-- ── Projects ──────────────────────────────────────────────────────── -->
  <section id="tab-projects" class="ccc-section">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
      <span class="ccc-section-title" style="margin:0">Projects</span>
      <button class="btn btn-primary btn-sm" onclick="showWizard()">+ New Project</button>
    </div>
    <div id="project-list"></div>

    <div id="wizard" class="ccc-card" style="display:none;margin-top:16px">
      <div class="wizard-bar"><div class="wizard-fill" id="wizard-fill" style="width:25%"></div></div>
      <div id="wizard-content"></div>
      <div class="action-row" style="margin-top:16px">
        <button class="btn btn-primary btn-sm" id="wizard-next-btn" onclick="wizardNext()">Next →</button>
        <button class="btn btn-secondary btn-sm" onclick="hideWizard()">Cancel</button>
      </div>
    </div>
  </section>

  <!-- ── CLAUDE.md ──────────────────────────────────────────────────────── -->
  <section id="tab-claude" class="ccc-section">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
      <span class="ccc-section-title" style="margin:0">CLAUDE.md</span>
      <div class="action-row">
        <button class="btn btn-secondary btn-sm" onclick="reloadFromOculus()">↺ Reload from oculus-configs</button>
        <button class="btn btn-primary btn-sm" onclick="saveClaude()">Save</button>
      </div>
    </div>
    <textarea id="claude-textarea" class="form-control" placeholder="Loading..."></textarea>
  </section>

  <!-- ── MCP ────────────────────────────────────────────────────────────── -->
  <section id="tab-mcp" class="ccc-section">
    <div class="ccc-section-title">MCP Servers</div>
    <table>
      <thead><tr><th>Name</th><th>Command</th><th style="width:80px"></th></tr></thead>
      <tbody id="mcp-table-body"><tr><td colspan="3" style="color:var(--muted)">Loading...</td></tr></tbody>
    </table>

    <div class="ccc-card" style="margin-bottom:20px">
      <div class="ccc-section-title" style="font-size:14px">Add Server</div>
      <div class="form-group">
        <label class="form-label">Name</label>
        <input id="mcp-new-name" class="form-control" placeholder="e.g. github">
      </div>
      <div class="form-group">
        <label class="form-label">Command</label>
        <input id="mcp-new-cmd" class="form-control" placeholder="e.g. npx -y @modelcontextprotocol/server-github">
      </div>
      <button class="btn btn-primary btn-sm" onclick="addMCPServer()">Add Server</button>
    </div>

    <div class="ccc-section-title">GitHub Token</div>
    <div class="action-row" style="max-width:600px">
      <input id="gh-token" type="password" class="form-control" placeholder="ghp_...">
      <button class="btn btn-secondary btn-sm" style="white-space:nowrap" onclick="saveGHToken()">Save Token</button>
    </div>
  </section>

  <!-- ── Plugins ────────────────────────────────────────────────────────── -->
  <section id="tab-plugins" class="ccc-section">
    <div class="ccc-section-title">Plugin State</div>
    <div id="plugin-list">Loading...</div>
    <p style="margin-top:14px;font-size:13px;color:var(--muted)">
      Changes take effect on next <code>claude</code> session.
    </p>
  </section>

  <!-- ── Updates ───────────────────────────────────────────────────────── -->
  <section id="tab-updates" class="ccc-section">
    <div class="ccc-section-title">CCC Provisioner</div>
    <div class="ccc-output" id="ccc-update-output">Click refresh to check...</div>
    <div class="action-row" style="margin-bottom:28px">
      <button class="btn btn-secondary btn-sm" onclick="loadCCCStatus()">↺ Refresh</button>
      <button class="btn btn-primary btn-sm" onclick="runCCCSelfUpdate()">Run ccc-self-update</button>
    </div>

    <div class="ccc-section-title">oculus-configs</div>
    <div class="ccc-output" id="oculus-update-output">Click "Check for Updates" to fetch status...</div>
    <div class="action-row">
      <button class="btn btn-secondary btn-sm" onclick="checkOculusUpdate()">Check for Updates</button>
      <button class="btn btn-primary btn-sm" id="apply-btn" style="display:none" onclick="applyOculusUpdate()">Apply Update</button>
    </div>
  </section>

</div><!-- /ccc-main -->

<div id="toast"></div>

<div class="modal-backdrop" id="modal">
  <div class="modal-box">
    <div class="modal-title" id="modal-title">Confirm</div>
    <div class="modal-body"  id="modal-body"></div>
    <div class="modal-footer">
      <button class="btn btn-danger btn-sm" onclick="modalResolve(true)" id="modal-ok">Confirm</button>
      <button class="btn btn-secondary btn-sm" onclick="modalResolve(false)">Cancel</button>
    </div>
  </div>
</div>

<script src="/cockpit/base1/cockpit.js"></script>
<script>
// ── Utilities ───────────────────────────────────────────────────────────────
let _toastTimer;
function showToast(msg, type = 'info') {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'show ' + type;
  clearTimeout(_toastTimer);
  _toastTimer = setTimeout(() => { t.className = ''; }, 3500);
}

let _modalResolve;
function confirm(title, body, okLabel = 'Confirm') {
  return new Promise(resolve => {
    document.getElementById('modal-title').textContent = title;
    document.getElementById('modal-body').textContent  = body;
    document.getElementById('modal-ok').textContent    = okLabel;
    document.getElementById('modal').classList.add('show');
    _modalResolve = r => { document.getElementById('modal').classList.remove('show'); resolve(r); };
  });
}
function modalResolve(r) { _modalResolve?.(r); }

const tabLoaders = {};
function showTab(name) {
  document.querySelectorAll('.ccc-section').forEach(s => s.classList.remove('active'));
  document.querySelectorAll('.ccc-nav button').forEach(b => b.classList.remove('active'));
  document.getElementById('tab-' + name).classList.add('active');
  document.querySelector(`.ccc-nav button[data-tab="${name}"]`).classList.add('active');
  tabLoaders[name]?.();
}

// ── Overview ────────────────────────────────────────────────────────────────
let _ip = '';
async function getIP() {
  if (_ip) return _ip;
  try { _ip = (await cockpit.spawn(['hostname', '-I'])).trim().split(' ')[0]; }
  catch { _ip = location.hostname; }
  return _ip;
}

async function loadOverview() {
  try {
    await cockpit.spawn(['test', '-f', '/home/claude-code/.claude/CLAUDE.md'], {err: 'ignore'});
    document.getElementById('s-claude').textContent = '✓ Present';
  } catch {
    document.getElementById('s-claude').innerHTML = '<span style="color:var(--danger)">✗ Missing</span>';
  }
  try {
    const n = await cockpit.spawn(['bash', '-c', 'ls /home/claude-code/.claude/rules/ 2>/dev/null | wc -l']);
    document.getElementById('s-rules').textContent = n.trim() + ' files';
  } catch { document.getElementById('s-rules').textContent = '0 files'; }
  try {
    const raw = await cockpit.file('/home/claude-code/.claude/mcp.json').read();
    document.getElementById('s-mcp').textContent =
      Object.keys(JSON.parse(raw || '{"mcpServers":{}}').mcpServers || {}).length + ' servers';
  } catch { document.getElementById('s-mcp').textContent = '0 servers'; }
  try {
    const raw = await cockpit.file('/home/claude-code/.claude/settings.json').read();
    const s = JSON.parse(raw || '{}');
    document.getElementById('s-plugins').textContent =
      (Array.isArray(s.plugins?.enabled) ? s.plugins.enabled.length : '?') + ' enabled';
  } catch { document.getElementById('s-plugins').textContent = '? enabled'; }

  cockpit.spawn(['systemctl', 'is-active', 'code-server'], {err: 'ignore'})
    .then(s => { document.getElementById('dot-cs').className = 'ccc-dot ' + (s.trim() === 'active' ? 'on' : 'off'); })
    .catch(() => { document.getElementById('dot-cs').className = 'ccc-dot off'; });
  cockpit.spawn(['bash', '-c', 'which claude 2>/dev/null'], {err: 'ignore'})
    .then(p => { document.getElementById('dot-claude').className = 'ccc-dot ' + (p.trim() ? 'on' : 'off'); })
    .catch(() => { document.getElementById('dot-claude').className = 'ccc-dot off'; });
  getIP().then(ip => { document.getElementById('vscode-link').href = 'http://' + ip + ':8080'; });
}
tabLoaders.overview = loadOverview;

// ── Projects ────────────────────────────────────────────────────────────────
async function loadProjects() {
  const list = document.getElementById('project-list');
  try {
    const out = await cockpit.spawn(['bash', '-c', 'ls -1 /home/claude-code/projects/ 2>/dev/null']);
    const projects = out.trim().split('
').filter(p => p);
    const ip = await getIP();
    list.innerHTML = !projects.length
      ? '<p style="color:var(--muted)">No projects yet.</p>'
      : '<ul class="data-list">' + projects.map(p => `
          <li class="data-item">
            <span class="data-name">${p}</span>
            <a class="btn btn-secondary btn-sm"
               href="http://${ip}:8080/?folder=/home/claude-code/projects/${encodeURIComponent(p)}"
               target="_blank">Open in VS Code ↗</a>
          </li>`).join('') + '</ul>';
  } catch {
    list.innerHTML = '<p style="color:var(--danger)">Error loading projects.</p>';
  }
}
tabLoaders.projects = loadProjects;

const _wiz = { step: 1, name: '', location: '', template: '', remote: '' };
function showWizard() {
  Object.assign(_wiz, { step: 1, name: '', location: '', template: '', remote: '' });
  document.getElementById('wizard').style.display = 'block';
  renderWizardStep();
}
function hideWizard() { document.getElementById('wizard').style.display = 'none'; }

async function renderWizardStep() {
  const s = _wiz.step;
  document.getElementById('wizard-fill').style.width = (s * 25) + '%';
  document.getElementById('wizard-next-btn').textContent = s === 4 ? 'Create Project' : 'Next →';
  const labels = ['Project Name', 'Location', 'Template', 'GitHub Remote'];
  let html = `<div style="font-weight:600;margin-bottom:12px">Step ${s} of 4 — ${labels[s-1]}</div>`;
  if (s === 1) {
    html += `<div class="form-group"><label class="form-label">Project Name</label>
      <input id="w-name" class="form-control" placeholder="my-project" value="${_wiz.name}"></div>`;
  } else if (s === 2) {
    html += `<div class="form-group"><label class="form-label">Location</label>
      <input id="w-loc" class="form-control" value="${_wiz.location || '/home/claude-code/projects/' + _wiz.name}"></div>`;
  } else if (s === 3) {
    let opts = '<option value="">— None (blank project) —</option>';
    try {
      const out = await cockpit.spawn(['bash', '-c', 'ls -1 /home/claude-code/Templates/ 2>/dev/null']);
      out.trim().split('
').filter(t => t).forEach(t => {
        opts += `<option value="${t}" ${_wiz.template === t ? 'selected' : ''}>${t}</option>`;
      });
    } catch {}
    html += `<div class="form-group"><label class="form-label">Starter Template</label>
      <select id="w-tpl" class="form-control">${opts}</select></div>`;
  } else {
    html += `<div class="form-group"><label class="form-label">GitHub Remote (optional)</label>
      <input id="w-remote" class="form-control" placeholder="username/repo-name" value="${_wiz.remote}">
      <span class="form-helper">Runs: gh repo create &lt;name&gt; --private --source=. --push</span></div>`;
  }
  document.getElementById('wizard-content').innerHTML = html;
}

async function wizardNext() {
  const s = _wiz.step;
  if (s === 1) {
    const name = document.getElementById('w-name').value.trim();
    if (!name || name.includes('/') || name.includes('..') || name.startsWith('.')) {
      showToast('Invalid project name', 'error'); return;
    }
    _wiz.name = name; _wiz.step = 2; renderWizardStep();
  } else if (s === 2) {
    const loc = document.getElementById('w-loc').value.trim();
    if (!loc) { showToast('Location required', 'error'); return; }
    _wiz.location = loc; _wiz.step = 3; renderWizardStep();
  } else if (s === 3) {
    _wiz.template = document.getElementById('w-tpl').value; _wiz.step = 4; renderWizardStep();
  } else {
    _wiz.remote = document.getElementById('w-remote').value.trim(); await createProject();
  }
}

async function createProject() {
  const { name, location, template, remote } = _wiz;
  const btn = document.getElementById('wizard-next-btn');
  btn.textContent = 'Creating...'; btn.disabled = true;
  try {
    await cockpit.spawn(['mkdir', '-p', location]);
    await cockpit.spawn(['git', '-C', location, 'init']);
    if (template) await cockpit.spawn(['bash', '-c', 'cp -r "$1"/. "$2"/', '_',
      '/home/claude-code/Templates/' + template, location]);
    if (remote) await cockpit.spawn(['bash', '-c',
      'cd "$1" && gh repo create "$2" --private --source=. --push', '_', location, remote]);
    showToast('Project created: ' + name, 'success');
    hideWizard(); loadProjects();
  } catch (err) {
    showToast('Error: ' + err.message, 'error');
  } finally { btn.textContent = 'Create Project'; btn.disabled = false; }
}

// ── CLAUDE.md ───────────────────────────────────────────────────────────────
async function loadClaude() {
  try {
    document.getElementById('claude-textarea').value =
      await cockpit.file('/home/claude-code/.claude/CLAUDE.md').read() || '';
  } catch (err) { showToast('Error reading CLAUDE.md: ' + err.message, 'error'); }
}
tabLoaders.claude = loadClaude;

async function saveClaude() {
  try {
    await cockpit.file('/home/claude-code/.claude/CLAUDE.md')
      .replace(document.getElementById('claude-textarea').value);
    showToast('CLAUDE.md saved', 'success');
  } catch (err) { showToast('Error saving: ' + err.message, 'error'); }
}

async function reloadFromOculus() {
  if (!await confirm('Reload CLAUDE.md',
    'Overwrite your current CLAUDE.md with the version from oculus-configs? Your edits will be lost.',
    'Overwrite')) return;
  try {
    await cockpit.spawn(['cp', '/opt/oculus-configs/claude/CLAUDE.md', '/home/claude-code/.claude/CLAUDE.md']);
    await loadClaude(); showToast('Reloaded from oculus-configs', 'success');
  } catch (err) { showToast('Error: ' + err.message, 'error'); }
}

// ── MCP ─────────────────────────────────────────────────────────────────────
let _mcpData = { mcpServers: {} };

async function loadMCP() {
  try { _mcpData = JSON.parse(await cockpit.file('/home/claude-code/.claude/mcp.json').read() || '{"mcpServers":{}}'); }
  catch { _mcpData = { mcpServers: {} }; }
  renderMCPTable(); loadGHToken();
}
tabLoaders.mcp = loadMCP;

function renderMCPTable() {
  const entries = Object.entries(_mcpData.mcpServers || {});
  document.getElementById('mcp-table-body').innerHTML = entries.length
    ? entries.map(([name, cfg]) => {
        const cmd = [cfg.command, ...(cfg.args || [])].join(' ');
        return `<tr>
          <td><strong>${name}</strong></td>
          <td><code style="font-size:12px">${cmd}</code></td>
          <td><button class="btn btn-danger btn-sm" onclick="removeMCPServer('${name}')">Remove</button></td>
        </tr>`;
      }).join('')
    : '<tr><td colspan="3" style="color:var(--muted)">No servers configured</td></tr>';
}

async function addMCPServer() {
  const name = document.getElementById('mcp-new-name').value.trim();
  const cmdStr = document.getElementById('mcp-new-cmd').value.trim();
  if (!name || !cmdStr) { showToast('Name and command required', 'error'); return; }
  const parts = cmdStr.split(' ');
  _mcpData.mcpServers[name] = { command: parts[0], args: parts.slice(1) };
  await persistMCP();
  document.getElementById('mcp-new-name').value = '';
  document.getElementById('mcp-new-cmd').value  = '';
}

async function removeMCPServer(name) {
  if (!await confirm('Remove MCP Server', `Remove "${name}" from MCP config?`, 'Remove')) return;
  delete _mcpData.mcpServers[name]; await persistMCP();
}

async function persistMCP() {
  try {
    await cockpit.file('/home/claude-code/.claude/mcp.json').replace(JSON.stringify(_mcpData, null, 2));
    renderMCPTable(); showToast('MCP config saved', 'success');
  } catch (err) { showToast('Error: ' + err.message, 'error'); }
}

async function loadGHToken() {
  try {
    const m = (await cockpit.file('/home/claude-code/.bashrc').read() || '')
      .match(/export GITHUB_TOKEN="?([^"
]+)"?/);
    if (m) document.getElementById('gh-token').value = m[1];
  } catch {}
}

async function saveGHToken() {
  const token = document.getElementById('gh-token').value.trim();
  if (!token) { showToast('Token required', 'error'); return; }
  try {
    const bashrc = await cockpit.file('/home/claude-code/.bashrc').read() || '';
    await cockpit.file('/home/claude-code/.bashrc').replace(
      bashrc.includes('GITHUB_TOKEN')
        ? bashrc.replace(/export GITHUB_TOKEN="?[^"
]+"?/, `export GITHUB_TOKEN="${token}"`)
        : bashrc + `
export GITHUB_TOKEN="${token}"
`
    );
    showToast('GitHub token saved', 'success');
  } catch (err) { showToast('Error: ' + err.message, 'error'); }
}

// ── Plugins ──────────────────────────────────────────────────────────────────
const KNOWN_PLUGINS = [
  { id: 'superpowers@claude-plugins-official',     label: 'Superpowers',     desc: 'Core workflow skills (brainstorming, TDD, review)' },
  { id: 'frontend-design@claude-plugins-official', label: 'Frontend Design', desc: 'UI/UX component and visual layout skills' },
  { id: 'skill-creator@claude-plugins-official',   label: 'Skill Creator',   desc: 'Build custom project-specific skills' },
];

async function loadPlugins() {
  let settings = {};
  try { settings = JSON.parse(await cockpit.file('/home/claude-code/.claude/settings.json').read() || '{}'); }
  catch {}
  const enabled = new Set(settings.plugins?.enabled || []);
  document.getElementById('plugin-list').innerHTML = KNOWN_PLUGINS.map(p => `
    <div class="toggle-row">
      <div>
        <div class="toggle-label">${p.label}</div>
        <div class="toggle-id">${p.id}</div>
        <div class="toggle-desc">${p.desc}</div>
      </div>
      <label class="toggle-switch">
        <input type="checkbox" ${enabled.has(p.id) ? 'checked' : ''} onchange="togglePlugin('${p.id}',this)">
        <span class="toggle-track"></span>
        <span class="toggle-thumb"></span>
      </label>
    </div>`).join('');
}
tabLoaders.plugins = loadPlugins;

async function togglePlugin(id, input) {
  let settings = {};
  try { settings = JSON.parse(await cockpit.file('/home/claude-code/.claude/settings.json').read() || '{}'); }
  catch {}
  if (!settings.plugins) settings.plugins = {};
  if (!Array.isArray(settings.plugins.enabled)) settings.plugins.enabled = [];
  const enabled = new Set(settings.plugins.enabled);
  input.checked ? enabled.add(id) : enabled.delete(id);
  settings.plugins.enabled = [...enabled];
  try {
    await cockpit.file('/home/claude-code/.claude/settings.json').replace(JSON.stringify(settings, null, 2));
    showToast('Plugin state updated', 'success');
  } catch (err) { input.checked = !input.checked; showToast('Error: ' + err.message, 'error'); }
}

// ── Updates ──────────────────────────────────────────────────────────────────
async function loadCCCStatus() {
  const box = document.getElementById('ccc-update-output');
  box.textContent = 'Running ccc-update-status...';
  try { box.textContent = await cockpit.spawn(['/usr/local/bin/ccc-update-status'], {err: 'message'}); }
  catch (err) { box.textContent = 'Error: ' + err.message; }
}
tabLoaders.updates = loadCCCStatus;

async function runCCCSelfUpdate() {
  if (!await confirm('Run ccc-self-update',
    'Pull latest CCC tools from GitHub and re-apply MOTD, ccc-* scripts, and the Cockpit plugin. Continue?',
    'Update')) return;
  const box = document.getElementById('ccc-update-output');
  box.textContent = 'Running ccc-self-update...';
  try {
    box.textContent = await cockpit.spawn(['sudo', '/usr/local/bin/ccc-self-update'],
      {err: 'message', superuser: 'try'});
    showToast('ccc-self-update complete', 'success');
  } catch (err) { box.textContent = 'Error: ' + err.message; showToast('Update failed', 'error'); }
}

async function checkOculusUpdate() {
  const box = document.getElementById('oculus-update-output');
  box.textContent = 'Fetching from origin...';
  try {
    await cockpit.spawn(['git', '-C', '/opt/oculus-configs', 'fetch', 'origin'], {err: 'message'});
    const log = await cockpit.spawn(
      ['git', '-C', '/opt/oculus-configs', 'log', 'HEAD..origin/main', '--oneline'], {err: 'message'});
    const lines = log.trim().split('
').filter(l => l);
    if (!lines.length) {
      box.textContent = '✓ Up to date';
      document.getElementById('apply-btn').style.display = 'none';
    } else {
      box.textContent = lines.length + ' commit(s) behind:

' + lines.join('
');
      document.getElementById('apply-btn').style.display = '';
    }
  } catch (err) { box.textContent = 'Error: ' + err.message; }
}

async function applyOculusUpdate() {
  if (!await confirm('Apply oculus-configs Update',
    'Pull latest and re-copy CLAUDE.md, rules, templates, Codex and Gemini skills. Local CLAUDE.md edits will be overwritten.',
    'Update')) return;
  const box = document.getElementById('oculus-update-output');
  box.textContent = 'Applying update...';
  const script = [
    'git -C /opt/oculus-configs pull',
    'cp /opt/oculus-configs/claude/CLAUDE.md /home/claude-code/.claude/CLAUDE.md',
    'cp -r /opt/oculus-configs/claude/rules/. /home/claude-code/.claude/rules/',
    'cp -r /opt/oculus-configs/templates/. /home/claude-code/Templates/',
    'mkdir -p /home/claude-code/.codex && cp /opt/oculus-configs/codex/AGENTS.md /home/claude-code/.codex/AGENTS.md 2>/dev/null || true',
    'mkdir -p /home/claude-code/.gemini && cp /opt/oculus-configs/gemini/GEMINI.md /home/claude-code/.gemini/GEMINI.md 2>/dev/null || true',
  ].join(' && ');
  try {
    const out = await cockpit.spawn(['bash', '-c', script], {err: 'message'});
    box.textContent = 'Done.' + (out ? '
' + out : '');
    document.getElementById('apply-btn').style.display = 'none';
    showToast('oculus-configs updated', 'success');
  } catch (err) { box.textContent = 'Error: ' + err.message; showToast('Update failed', 'error'); }
}

// ── Init ─────────────────────────────────────────────────────────────────────
cockpit.user().then(u => {
  document.getElementById('nav-user').textContent = u.name + '@' + location.hostname;
}).catch(() => {});
loadOverview();
</script>
</body>
</html>

COCKPITUI
echo "    Cockpit: https://<ip>:9090 (login as claude-code)"

# CCC_UPDATEABLE_END — sections above re-run by ccc-self-update

# ── Cleanup ───────────────────────────────────────────────────────────────────
step 28 "Cleanup"
# Disable noisy motd-news fetch (fails in LXC due to permissions)
chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null || true
systemctl disable motd-news 2>/dev/null || true
apt-get autoremove -y -qq
apt-get clean -qq
rm -rf /var/lib/apt/lists/*

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       Container provisioning script done         ║"
echo "╚══════════════════════════════════════════════════╝"
PROVISION_EOF

  # Substitute username — heredoc is single-quoted so we sed before pushing
  if [[ "$CC_USER" != "claude-code" ]]; then
    sed -i "s/claude-code/${CC_USER}/g" /tmp/provision-${CT_ID}.sh
  fi
  chmod +x /tmp/provision-${CT_ID}.sh
  pct push "$CT_ID" /tmp/provision-${CT_ID}.sh /tmp/provision.sh
  pct exec "$CT_ID" -- chmod +x /tmp/provision.sh
  pct exec "$CT_ID" -- /tmp/provision.sh
  kill "$_timer_pid" 2>/dev/null; wait "$_timer_pid" 2>/dev/null || true
  rm -f /tmp/provision-${CT_ID}.sh

  # ── Passwords + code-server config (variable expansion — outside heredoc) ───
  info "Setting passwords and finalizing code-server ..."

  printf '%s:%s\n' "${CC_USER}" "${CC_PASSWORD}" | pct exec "$CT_ID" -- chpasswd

  pct exec "$CT_ID" -- bash -c "mkdir -p /home/${CC_USER}/.config/code-server"
  local _cs_password_yaml
  _cs_password_yaml=${CS_PASSWORD//\\/\\\\}
  _cs_password_yaml=${_cs_password_yaml//\"/\\\"}
  printf 'bind-addr: 0.0.0.0:8080\nauth: password\npassword: "%s"\ncert: false\nuser-data-dir: /home/%s/.local/share/code-server\nextensions-dir: /home/%s/.local/share/code-server/extensions\n' \
    "${_cs_password_yaml}" "${CC_USER}" "${CC_USER}" \
    | pct exec "$CT_ID" -- tee /home/${CC_USER}/.config/code-server/config.yaml > /dev/null
  pct exec "$CT_ID" -- chown -R "${CC_USER}:${CC_USER}" "/home/${CC_USER}/.config/code-server"

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
    pct exec "$CT_ID" -- sudo -u "${CC_USER}" \
      code-server --install-extension "$ext" 2>/dev/null || true
  done

  pct exec "$CT_ID" -- systemctl start "code-server@${CC_USER}"
  success "code-server started on port 8080."

  # ── SSH key for user ──────────────────────────────────────────────────────────
  if [[ -n "${CT_SSH_KEY:-}" && -f "$CT_SSH_KEY" ]]; then
    info "Installing SSH public key for ${CC_USER} ..."
    pct exec "$CT_ID" -- bash -c "
      sudo -u ${CC_USER} mkdir -p /home/${CC_USER}/.ssh
      sudo -u ${CC_USER} chmod 700 /home/${CC_USER}/.ssh
    "
    pct push "$CT_ID" "$CT_SSH_KEY" /tmp/authorized_keys
    pct exec "$CT_ID" -- bash -c "
      cat /tmp/authorized_keys >> /home/${CC_USER}/.ssh/authorized_keys
      chown ${CC_USER}:${CC_USER} /home/${CC_USER}/.ssh/authorized_keys
      chmod 600 /home/${CC_USER}/.ssh/authorized_keys
      rm /tmp/authorized_keys
    "
    success "SSH key installed for ${CC_USER}."
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
  echo -e "    SSH:              ${CYAN}ssh ${CC_USER}@${ct_ip}${NC}"
  [[ -n "${ct_ip:-}" ]] && \
  echo -e "    Web VS Code:      ${CYAN}http://${ct_ip}:8080${NC}  (password: $CS_PASSWORD)"
  [[ -n "${ct_ip:-}" ]] && \
  echo -e "    Cockpit:          ${CYAN}https://${ct_ip}:9090${NC}  (user: ${CC_USER})"
  echo ""
  echo -e "  ${BOLD}First steps:${NC}"
  echo -e "    1. ${CYAN}ssh ${CC_USER}@${ct_ip:-<ip>}${NC}"
  echo -e "    2. ${CYAN}claude${NC}            (authenticate + start coding)"
  echo -e "    3. ${CYAN}ccc${NC}               (full help reference)"
  echo ""
  echo -e "  ${BOLD}Languages:${NC}    Node.js 22 LTS, Python 3, Go, Rust"
  echo -e "  ${BOLD}Statusline:${NC}   ~/.claude/bin/statusline-command.sh"
  echo -e "  ${BOLD}Redis:${NC}        Server available — ${CYAN}sudo systemctl start redis-server${NC}"
  echo -e "  ${BOLD}yq:${NC}           mikefarah Go binary at /usr/local/bin/yq"
  echo -e "  ${BOLD}Permissions:${NC}  All tools pre-approved (no prompts)"
  echo -e "  ${BOLD}SSH:${NC}          Root login disabled — use ${CC_USER}"
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
