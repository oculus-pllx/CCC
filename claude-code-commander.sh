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
CCC_COMMAND_CENTER_PATH="/usr/share/cockpit/ccc"
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

# ── CLAUDE.md ─────────────────────────────────────────────────────────────────
step 18 "CLAUDE.md"
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

## Plugins & Skills
Open Cockpit at https://&lt;ip&gt;:9090 and select CCC Command Center to browse and install kits.
CLAUDEMD

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
| 3 | `ccc-kit` | SSH terminal — how to connect a GitHub kit repo |
| 4 | `ccc-install-playwright` | SSH terminal — headless browser testing (optional) |
| 5 | `ccc-install-codex` | SSH terminal — OpenAI Codex CLI (optional) |
| 6 | `ccc-install-jcodemunch` | SSH terminal — jCodeMunch MCP, 95% token reduction (optional) |
| 7 | `ccc` | SSH terminal — full command reference |

## GitHub Kits

Open Cockpit at `https://<this-container-ip>:9090`, then select **CCC Command Center**.

Public kit:

```text
https://github.com/owner/repo
```

Private kit:

```text
git@github.com:owner/repo.git
```

Private repos require `ccc-onboarding` first, then add `~/.ssh/id_ed25519.pub` to GitHub.
After connecting, copy the generated `/plugin marketplace add` and `/plugin install` commands into a running `claude` session.

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
ccc-kit            # GitHub kit repo instructions
ccc-update         # update packages + Claude Code
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
  echo -e "  ${B}KITS & PLUGINS${N}"
  echo -e "    ${C}ccc-kit${N}                   How to connect a GitHub kit repo"
  echo -e "    ${C}https://$(hostname -I | awk '{print $1}'):9090${N}  Cockpit CCC Command Center"
  echo ""
  echo -e "  ${B}MAINTENANCE${N}"
  echo -e "    ${C}ccc-onboarding${N}            First-login wizard (git identity, SSH key, GitHub)"
  echo -e "    ${C}ccc-setup${N}                 Same wizard, safe to re-run"
  echo -e "    ${C}ccc-self-update${N}           Pull latest ccc-* tools from GitHub (no reprovision)"
  echo -e "    ${C}ccc-update${N}                Update system packages + Claude Code"
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
# ── ccc-update ────────────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-update << 'UPDATESCRIPT'
#!/bin/bash
set -e
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; N='\033[0m'
[[ -r /etc/ccc/config ]] && source /etc/ccc/config
CCC_USER="${CCC_USER:-claude-code}"
CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"
echo ""
echo -e "${B}CCC Update${N}"
echo ""
echo -e "${C}[1/3]${N} System packages..."
if command -v ccc-fix-cockpit-updates &>/dev/null; then
  sudo ccc-fix-cockpit-updates --quiet || true
fi
sudo nmcli con up ccc-online 2>/dev/null || true
sudo apt-get update -qq && sudo apt-get upgrade -y
echo ""
echo -e "${C}[2/3]${N} Claude Code..."
sudo -u "$CCC_USER" env HOME="$CCC_HOME" PATH="$CCC_HOME/.local/bin:$CCC_HOME/.claude/bin:$CCC_HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin" claude update
echo ""
echo -e "${C}[3/3]${N} Plugins — managed in Cockpit at https://$(hostname -I | awk '{print $1}'):9090"
echo ""
echo -e "${G}${B}Update complete.${N}"
echo ""
UPDATESCRIPT
chmod +x /usr/local/bin/ccc-update

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

cat > /usr/local/bin/ccc-kit << 'KITSCRIPT'
#!/bin/bash
B='\033[1m'; C='\033[0;36m'; Y='\033[1;33m'; N='\033[0m'
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo -e "${B}CCC Command Center${N}"
echo ""
echo -e "  Open: ${C}https://${IP:-<container-ip>}:9090${N}"
echo -e "  Select: ${C}CCC Command Center${N}"
echo ""
echo -e "${Y}Public GitHub kit:${N}"
echo -e "  1. Paste: ${C}https://github.com/owner/repo${N}"
echo -e "  2. Click Connect"
echo -e "  3. Copy the marketplace and plugin install commands"
echo -e "  4. Paste those commands inside a running ${C}claude${N} session"
echo ""
echo -e "${Y}Private GitHub kit:${N}"
echo -e "  1. Run: ${C}ccc-onboarding${N}"
echo -e "  2. Add ${C}~/.ssh/id_ed25519.pub${N} to GitHub"
echo -e "  3. Paste an SSH URL: ${C}git@github.com:owner/repo.git${N}"
echo ""
echo -e "Manifest path required in the repo: ${C}.claude-plugin/marketplace.json${N}"
echo ""
KITSCRIPT
chmod +x /usr/local/bin/ccc-kit

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

sudo mkdir -p /etc/NetworkManager/conf.d
sudo rm -f /etc/NetworkManager/conf.d/99-unmanaged-lxc.conf
sudo tee /etc/NetworkManager/conf.d/99-ccc-managed.conf >/dev/null << 'NMGLOBAL'
[ifupdown]
managed=true

[keyfile]
unmanaged-devices=none
NMGLOBAL

sudo tee /etc/NetworkManager/conf.d/99-ccc-lxc.conf >/dev/null << 'NMLXC'
[main]
plugins=keyfile
NMLXC

if grep -q '^\[ifupdown\]' /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
  sudo sed -i 's/^managed=false/managed=true/' /etc/NetworkManager/NetworkManager.conf
fi
sudo systemctl restart NetworkManager 2>/dev/null || true
sudo nmcli con delete ccc-online 2>/dev/null || true
sudo nmcli con add type dummy con-name ccc-online ifname ccc-online0 \
  ip4 192.0.2.2/24 gw4 192.0.2.1 ipv6.method disabled autoconnect yes 2>/dev/null || true
if ! sudo nmcli con up ccc-online; then
  say "NetworkManager could not activate the dummy online marker."
  say "Check: nmcli con up ccc-online"
fi

sudo mkdir -p /etc/PackageKit
sudo touch /etc/PackageKit/PackageKit.conf
sudo awk '
  BEGIN { in_daemon=0; daemon_seen=0; wrote=0 }
  /^\[Daemon\]/ {
    if (in_daemon && !wrote) { print "UseNetworkManager=false"; wrote=1 }
    in_daemon=1; daemon_seen=1; print; next
  }
  /^\[/ {
    if (in_daemon && !wrote) { print "UseNetworkManager=false"; wrote=1 }
    in_daemon=0; print; next
  }
  in_daemon && /^UseNetworkManager=/ {
    if (!wrote) { print "UseNetworkManager=false"; wrote=1 }
    next
  }
  { print }
  END {
    if (!daemon_seen) { print "[Daemon]"; print "UseNetworkManager=false" }
    else if (in_daemon && !wrote) { print "UseNetworkManager=false" }
  }
' /etc/PackageKit/PackageKit.conf | sudo tee /etc/PackageKit/PackageKit.conf.tmp >/dev/null
sudo mv /etc/PackageKit/PackageKit.conf.tmp /etc/PackageKit/PackageKit.conf

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
systemctl is-active --quiet NetworkManager && ok "NetworkManager running" || fail "NetworkManager not running"
systemctl is-active --quiet packagekit && ok "PackageKit running" || fail "PackageKit not running"

if NetworkManager --print-config 2>/dev/null | grep -q 'managed=true'; then
  ok "NetworkManager ifupdown managed=true"
else
  warn "NetworkManager config does not show ifupdown managed=true"
fi

if nmcli con show ccc-online &>/dev/null; then
  ok "ccc-online connection exists"
else
  fail "ccc-online connection missing"
fi

if nmcli con up ccc-online &>/tmp/ccc-nm-up.log; then
  ok "ccc-online activates"
else
  fail "ccc-online failed: $(cat /tmp/ccc-nm-up.log)"
fi

STATE=$(nmcli -t -f STATE general status 2>/dev/null | head -1)
case "$STATE" in
  connected|connecting) ok "NetworkManager state: $STATE" ;;
  *) fail "NetworkManager state: ${STATE:-unknown}" ;;
esac

if [[ -f /etc/PackageKit/PackageKit.conf ]] && grep -q '^UseNetworkManager=false' /etc/PackageKit/PackageKit.conf; then
  ok "PackageKit UseNetworkManager=false"
else
  warn "PackageKit UseNetworkManager=false not set"
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
[[ -d /usr/share/cockpit/ccc ]] && ok "CCC Cockpit Command Center installed" || fail "CCC Cockpit Command Center missing"
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

# ── ccc-self-update ───────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-self-update << 'SELFUPDATESCRIPT'
#!/bin/bash
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
REPO_URL="https://raw.githubusercontent.com/oculus-pllx/CCC/main/claude-code-commander.sh"
TMP="/tmp/ccc-provisioner-$$.sh"

echo ""
echo -e "${B}CCC Self-Update${N}"
echo -e "${Y}Downloads latest provisioner and re-applies ccc-* tools and MOTD.${N}"
echo -e "${Y}Does NOT re-run apt installs, Node/Go/Rust, or user creation.${N}"
echo ""

echo -e "${C}[1/3]${N} Downloading latest provisioner..."
if ! curl -fsSL "$REPO_URL" -o "$TMP"; then
  echo -e "${R}Download failed. Check internet: ccc-doctor${N}"
  exit 1
fi
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
rm -f "$TMP"

echo ""
echo -e "${C}[3/3]${N} Applying updates..."
(echo 'step() { echo "  >>> $2"; }'; echo "$UPDATE_SCRIPT") | sudo bash
STATUS=$?

echo ""
if [[ $STATUS -eq 0 ]]; then
  echo -e "${G}${B}Self-update complete.${N}"
  echo -e "  ccc-* commands and MOTD updated to latest."
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
echo -e "  ${C}ccc-kit${N}                   How to connect a GitHub kit repo"
echo -e "  ${C}ccc-self-update${N}           Pull latest ccc-* tools from GitHub (no reprovision)"
echo -e "  ${C}ccc-update${N}                Update system packages + Claude Code"
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
echo -e "  ${C}https://\${IP}:9090${N}  CCC Command Center — kits, updates, services"
echo -e "  ${C}https://\${IP}:9090${N}  Cockpit — system monitoring, file manager"
echo -e "  ${D}Tip: use port 8080 for multiple terminal tabs (Terminal → New Terminal)${N}"
echo ""
MOTD
chmod +x /etc/update-motd.d/00-ccc

# CCC_UPDATEABLE_END — sections above re-run by ccc-self-update

# ── Git defaults ──────────────────────────────────────────────────────────────
step 25 "Git defaults"
sudo -u claude-code git config --global init.defaultBranch main
sudo -u claude-code git config --global core.editor nano
sudo -u claude-code git config --global pull.rebase false
sudo -u claude-code git config --global core.autocrlf false

# ── Auto-update cron ──────────────────────────────────────────────────────────
step 26 "Auto-update cron"
cat > /etc/cron.d/system-update << 'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * 0 root systemctl restart NetworkManager 2>/dev/null; apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq && apt-get clean -qq >> /var/log/system-update.log 2>&1
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
# NM needed for PackageKit connectivity check — without it Cockpit reports "offline"
apt-get install -y -qq --no-install-recommends network-manager > /dev/null 2>&1 || true
mkdir -p /etc/NetworkManager/conf.d
# Cockpit's PackageKit updater checks NetworkManager online state on Ubuntu.
# Let NM manage the dummy online marker while leaving the LXC-provided eth0 alone.
rm -f /etc/NetworkManager/conf.d/99-unmanaged-lxc.conf
cat > /etc/NetworkManager/conf.d/99-ccc-managed.conf << 'NMGLOBAL'
[ifupdown]
managed=true

[keyfile]
unmanaged-devices=none
NMGLOBAL
cat > /etc/NetworkManager/conf.d/99-unmanaged-lxc.conf << 'NMCONF'
[main]
plugins=keyfile
NMCONF
systemctl enable NetworkManager 2>/dev/null || true
if grep -q '^\[ifupdown\]' /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
  sed -i 's/^managed=false/managed=true/' /etc/NetworkManager/NetworkManager.conf
fi
systemctl restart NetworkManager 2>/dev/null || systemctl start NetworkManager 2>/dev/null || true
# Dummy connection — NM manages it, reports online so PackageKit/Cockpit can refresh.
nmcli con delete ccc-online 2>/dev/null || true
nmcli con add type dummy con-name ccc-online ifname ccc-online0 \
  ip4 192.0.2.2/24 gw4 192.0.2.1 ipv6.method disabled autoconnect yes 2>/dev/null || true
nmcli con up ccc-online || true
apt-get install -y cockpit > /dev/null 2>&1
apt-get install -y cockpit-files > /dev/null 2>&1 || true
apt-get install -y -qq packagekit cockpit-packagekit > /dev/null 2>&1 || true
apt-get purge -y -qq udisks2 > /dev/null 2>&1 || true
mkdir -p /etc/PackageKit
touch /etc/PackageKit/PackageKit.conf
awk '
  BEGIN { in_daemon=0; daemon_seen=0; wrote=0 }
  /^\[Daemon\]/ {
    if (in_daemon && !wrote) { print "UseNetworkManager=false"; wrote=1 }
    in_daemon=1; daemon_seen=1; print; next
  }
  /^\[/ {
    if (in_daemon && !wrote) { print "UseNetworkManager=false"; wrote=1 }
    in_daemon=0; print; next
  }
  in_daemon && /^UseNetworkManager=/ {
    if (!wrote) { print "UseNetworkManager=false"; wrote=1 }
    next
  }
  { print }
  END {
    if (!daemon_seen) { print "[Daemon]"; print "UseNetworkManager=false" }
    else if (in_daemon && !wrote) { print "UseNetworkManager=false" }
  }
' /etc/PackageKit/PackageKit.conf > /etc/PackageKit/PackageKit.conf.tmp
mv /etc/PackageKit/PackageKit.conf.tmp /etc/PackageKit/PackageKit.conf
systemctl stop packagekit 2>/dev/null || true
rm -rf /var/cache/PackageKit/* /var/lib/PackageKit/transactions.db 2>/dev/null || true
systemctl start packagekit 2>/dev/null || true
if ! /usr/local/bin/ccc-verify-cockpit-updates; then
  echo "[ERROR] Cockpit software update path is not ready."
  echo "        Inspect with: ccc-verify-cockpit-updates"
  exit 1
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
echo "    Cockpit: https://<ip>:9090 (login as claude-code)"

# ── CCC Command Center (Cockpit) ──────────────────────────────────────────────
step 28 "CCC Command Center (Cockpit)"
mkdir -p /home/claude-code/.ccc/kit-manager/public

# Server
cat > /home/claude-code/.ccc/kit-manager/server.js << 'KITSERVER'
#!/usr/bin/env node
'use strict';
const http  = require('http');
const https = require('https');
const fs    = require('fs');
const path  = require('path');
const os    = require('os');
const { execFile } = require('child_process');

const PORT   = 8090;
const PUBLIC = path.join(__dirname, 'public');
const STATE  = path.join(__dirname, 'state.json');

function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE, 'utf8')); } catch { return { repoUrl: '' }; }
}
function saveState(s) { fs.writeFileSync(STATE, JSON.stringify(s, null, 2)); }

function ghRaw(repoUrl, filePath) {
  const m = repoUrl.match(/github\.com[:/]([^/]+)\/([^/\s.]+?)(?:\.git)?(?:\/.*)?$/);
  if (!m) throw new Error('Not a valid GitHub URL');
  return `https://api.github.com/repos/${m[1]}/${m[2]}/contents/${filePath}`;
}

function run(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { timeout: 30000, maxBuffer: 1024 * 1024, ...opts }, (err, stdout, stderr) => {
      if (err) {
        err.message = `${err.message}${stderr ? `\n${stderr}` : ''}`;
        reject(err);
      } else {
        resolve(stdout);
      }
    });
  });
}

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const opts = { headers: { 'User-Agent': 'ccc-kit-manager/1.0', 'Accept': 'application/vnd.github.v3+json' } };
    https.get(url, opts, res => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => { try { resolve(JSON.parse(d)); } catch (e) { reject(e); } });
    }).on('error', reject);
  });
}

async function fetchManifest(repoUrl) {
  const content = await fetchFile(repoUrl, '.claude-plugin/marketplace.json');
  if (!content) throw new Error('Missing .claude-plugin/marketplace.json');
  return JSON.parse(content);
}

async function fetchFile(repoUrl, filePath) {
  try {
    const apiUrl = ghRaw(repoUrl, filePath);
    const raw = await fetchJson(apiUrl);
    if (!raw.message && raw.content) return Buffer.from(raw.content, 'base64').toString('utf8');
  } catch {}

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ccc-kit-'));
  try {
    const env = {
      ...process.env,
      GIT_TERMINAL_PROMPT: '0',
      GIT_SSH_COMMAND: 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new'
    };
    await run('git', ['clone', '--depth', '1', repoUrl, tmp], { env });
    const target = path.join(tmp, filePath);
    if (!fs.existsSync(target)) return null;
    return fs.readFileSync(target, 'utf8');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function readBody(req) {
  return new Promise(resolve => {
    let b = '';
    req.on('data', c => b += c);
    req.on('end', () => resolve(b));
  });
}

function json(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  const url = req.url.split('?')[0];

  if (req.method === 'GET' && url === '/') {
    fs.readFile(path.join(PUBLIC, 'index.html'), (e, d) => {
      if (e) { res.writeHead(500); res.end('Error'); return; }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(d);
    });
    return;
  }

  if (req.method === 'GET' && url === '/api/state') {
    return json(res, 200, loadState());
  }

  if (req.method === 'POST' && url === '/api/connect') {
    const body = JSON.parse(await readBody(req));
    const repoUrl = (body.repoUrl || '').trim();
    try {
      const manifest = await fetchManifest(repoUrl);
      saveState({ repoUrl });
      return json(res, 200, { manifest });
    } catch (e) {
      return json(res, 400, { error: e.message });
    }
  }

  if (req.method === 'POST' && url === '/api/template') {
    const body = JSON.parse(await readBody(req));
    const repoUrl = (body.repoUrl || '').trim();
    try {
      const content = await fetchFile(repoUrl, 'templates/project-SETUP.md');
      return json(res, 200, { content: content || '(no template found)' });
    } catch (e) {
      return json(res, 400, { error: e.message });
    }
  }

  res.writeHead(404);
  res.end('Not found');
});

server.listen(PORT, '0.0.0.0', () => console.log(`Kit Manager on http://0.0.0.0:${PORT}`));
KITSERVER

# UI
cat > /home/claude-code/.ccc/kit-manager/public/index.html << 'KITHTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CCC Kit Manager</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',system-ui,sans-serif;background:#0d1117;color:#e6edf3;min-height:100vh}
  header{background:#161b22;border-bottom:1px solid #30363d;padding:16px 24px;display:flex;align-items:center;gap:12px}
  header h1{font-size:18px;font-weight:600;color:#f0f6fc}
  header span{font-size:12px;color:#8b949e;background:#21262d;padding:2px 8px;border-radius:12px}
  .container{max-width:960px;margin:0 auto;padding:24px}
  .guide{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:18px 20px;margin-bottom:16px}
  .guide h2{font-size:14px;font-weight:600;color:#f0f6fc;margin-bottom:12px}
  .guide-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-bottom:14px}
  .guide-step{background:#0d1117;border:1px solid #21262d;border-radius:6px;padding:12px;min-height:92px}
  .guide-step b{display:block;color:#79c0ff;font-size:12px;text-transform:uppercase;letter-spacing:.04em;margin-bottom:6px}
  .guide-step p{font-size:13px;color:#8b949e;line-height:1.45}
  .examples{display:grid;grid-template-columns:1fr 1fr;gap:10px}
  .example{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:10px}
  .example-label{display:block;font-size:11px;color:#8b949e;text-transform:uppercase;letter-spacing:.05em;margin-bottom:4px}
  .example code{display:block;color:#79c0ff;font-size:13px;word-break:break-all;margin-bottom:8px}
  .example button{font-size:12px;padding:5px 10px}
  .note{font-size:13px;color:#8b949e;line-height:1.5;margin-top:12px}
  .note code{color:#79c0ff}
  .connect-bar{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px;margin-bottom:24px}
  .connect-bar h2{font-size:14px;font-weight:600;color:#8b949e;text-transform:uppercase;letter-spacing:.05em;margin-bottom:12px}
  .input-row{display:flex;gap:8px}
  input[type=text]{flex:1;background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:8px 12px;color:#e6edf3;font-size:14px;outline:none}
  input[type=text]:focus{border-color:#388bfd}
  button{background:#238636;border:none;border-radius:6px;color:#fff;padding:8px 16px;font-size:14px;cursor:pointer;white-space:nowrap}
  button:hover{background:#2ea043}
  button.secondary{background:#21262d;border:1px solid #30363d}
  button.secondary:hover{background:#30363d}
  button.copy{background:#21262d;border:1px solid #30363d;font-size:12px;padding:4px 10px}
  button.copy:hover{background:#30363d}
  .status{font-size:13px;margin-top:10px;color:#8b949e}
  .status.err{color:#f85149}
  .status.ok{color:#3fb950}
  .section-header{display:flex;align-items:center;justify-content:space-between;margin-bottom:16px}
  .section-header h2{font-size:16px;font-weight:600}
  .marketplace-cmd{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px;margin-bottom:24px}
  .marketplace-cmd h2{font-size:14px;font-weight:600;color:#8b949e;text-transform:uppercase;letter-spacing:.05em;margin-bottom:12px}
  .cmd-block{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:12px;font-family:monospace;font-size:13px;color:#79c0ff;position:relative}
  .cmd-block .copy-btn{position:absolute;top:8px;right:8px}
  .plugins-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:16px;margin-bottom:24px}
  .plugin-card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px;display:flex;flex-direction:column;gap:10px}
  .plugin-card:hover{border-color:#388bfd}
  .card-top{display:flex;align-items:flex-start;justify-content:space-between;gap:8px}
  .card-name{font-size:15px;font-weight:600;color:#f0f6fc}
  .card-version{font-size:11px;color:#8b949e;background:#21262d;padding:2px 6px;border-radius:4px;white-space:nowrap}
  .card-category{font-size:11px;color:#79c0ff;text-transform:uppercase;letter-spacing:.05em}
  .card-desc{font-size:13px;color:#8b949e;line-height:1.5;flex:1}
  .card-cmd{background:#0d1117;border:1px solid #21262d;border-radius:6px;padding:8px 10px;font-family:monospace;font-size:12px;color:#79c0ff;display:flex;align-items:center;justify-content:space-between;gap:8px;word-break:break-all}
  .install-all{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px;margin-bottom:24px}
  .install-all h2{font-size:14px;font-weight:600;color:#8b949e;text-transform:uppercase;letter-spacing:.05em;margin-bottom:12px}
  .template-section{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px}
  .template-section h2{font-size:14px;font-weight:600;color:#8b949e;text-transform:uppercase;letter-spacing:.05em;margin-bottom:12px}
  pre{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:12px;font-size:12px;color:#e6edf3;overflow-x:auto;white-space:pre-wrap;max-height:300px;overflow-y:auto}
  .hidden{display:none}
  .tag{display:inline-block;background:#21262d;color:#8b949e;border-radius:4px;padding:1px 6px;font-size:11px;margin-right:4px}
  .copied{color:#3fb950!important}
  @media(max-width:760px){.guide-grid,.examples{grid-template-columns:1fr}.input-row{flex-direction:column}}
</style>
</head>
<body>
<header>
  <svg width="20" height="20" viewBox="0 0 16 16" fill="#f78166"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
  <h1>CCC Kit Manager</h1>
  <span>port 8090</span>
</header>
<div class="container">

  <div class="guide">
    <h2>Install Plugins From a GitHub Kit</h2>
    <div class="guide-grid">
      <div class="guide-step">
        <b>1. Connect</b>
        <p>Paste a GitHub repo URL that contains <code>.claude-plugin/marketplace.json</code>.</p>
      </div>
      <div class="guide-step">
        <b>2. Copy</b>
        <p>Use the generated marketplace and plugin install commands below.</p>
      </div>
      <div class="guide-step">
        <b>3. Paste</b>
        <p>Paste those commands inside an active <code>claude</code> session in your terminal.</p>
      </div>
    </div>
    <div class="examples">
      <div class="example">
        <span class="example-label">Public repo</span>
        <code>https://github.com/owner/repo</code>
        <button class="secondary" onclick="setExample('https://github.com/owner/repo')">Use Example</button>
      </div>
      <div class="example">
        <span class="example-label">Private repo after ccc-onboarding</span>
        <code>git@github.com:owner/repo.git</code>
        <button class="secondary" onclick="setExample('git@github.com:owner/repo.git')">Use Example</button>
      </div>
    </div>
    <p class="note">Private repos need the SSH key from <code>ccc-onboarding</code> added to GitHub first. The commands generated here are Claude Code slash commands, not shell commands.</p>
  </div>

  <div class="connect-bar">
    <h2>Connect Kit Repository</h2>
    <div class="input-row">
      <input type="text" id="repoUrl" placeholder="https://github.com/owner/repo" />
      <button onclick="connect()">Connect</button>
    </div>
    <div class="status hidden" id="connectStatus"></div>
  </div>

  <div class="hidden" id="kitContent">

    <div class="marketplace-cmd">
      <h2>Step 1 — Add Marketplace to Claude Code</h2>
      <div class="cmd-block" id="marketplaceCmd">
        <button class="copy copy-btn" onclick="copyEl('marketplaceCmd', this)">Copy</button>
      </div>
      <p class="note">Paste this inside a running <code>claude</code> session.</p>
    </div>

    <div class="install-all">
      <h2>Step 2 — Install Plugins in Claude Code</h2>
      <div class="cmd-block" id="installAllCmd">
        <button class="copy copy-btn" onclick="copyEl('installAllCmd', this)">Copy</button>
      </div>
      <p class="note">Paste all lines inside the same <code>claude</code> session after Step 1.</p>
    </div>

    <div class="section-header">
      <h2>Plugins</h2>
      <button class="secondary" onclick="loadTemplate()">View Project Template</button>
    </div>
    <div class="plugins-grid" id="pluginsGrid"></div>

    <div class="template-section hidden" id="templateSection">
      <h2>Project SETUP.md Template</h2>
      <pre id="templateContent"></pre>
    </div>

  </div>
</div>
<script>
function setExample(url) {
  const input = document.getElementById('repoUrl');
  input.value = url;
  input.focus();
}

async function connect() {
  const url = document.getElementById('repoUrl').value.trim();
  const status = document.getElementById('connectStatus');
  if (!url) return;
  status.className = 'status'; status.textContent = 'Connecting...'; status.classList.remove('hidden');
  try {
    const r = await fetch('/api/connect', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ repoUrl: url }) });
    const d = await r.json();
    if (!r.ok) throw new Error(d.error || 'Failed');
    status.className = 'status ok'; status.textContent = `Connected — ${d.manifest.name || 'kit'} (${(d.manifest.plugins||[]).length} plugins)`;
    renderKit(url, d.manifest);
  } catch(e) {
    status.className = 'status err'; status.textContent = e.message;
  }
}

function renderKit(repoUrl, manifest) {
  const kitName = manifest.name || 'kit';
  const plugins = manifest.plugins || [];
  const esc = v => String(v ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const js = v => JSON.stringify(String(v ?? ''));

  const marketplaceCmd = `/plugin marketplace add ${repoUrl}`;
  document.getElementById('marketplaceCmd').innerHTML =
    `${esc(marketplaceCmd)}` +
    `<button class="copy copy-btn" onclick='copyText(${js(marketplaceCmd)}, this)'>Copy</button>`;

  const allCmds = plugins.map(p => `/plugin install ${p.name}@${kitName}`).join('\n');
  document.getElementById('installAllCmd').innerHTML =
    esc(allCmds).replace(/\n/g, '<br>') +
    `<button class="copy copy-btn" onclick='copyText(${js(allCmds)}, this)'>Copy</button>`;

  const grid = document.getElementById('pluginsGrid');
  grid.innerHTML = plugins.map(p => {
    const cmd = `/plugin install ${p.name}@${kitName}`;
    return `<div class="plugin-card">
      <div class="card-top">
        <span class="card-name">${esc(p.name)}</span>
        <span class="card-version">v${esc(p.version||'?')}</span>
      </div>
      <div class="card-category">${esc(p.category||'')}</div>
      <div class="card-desc">${esc(p.description||'')}</div>
      ${(p.keywords||[]).map(k=>`<span class="tag">${esc(k)}</span>`).join('')}
      <div class="card-cmd">
        <span>${esc(cmd)}</span>
        <button class="copy" onclick='copyText(${js(cmd)}, this)'>Copy</button>
      </div>
    </div>`;
  }).join('');

  document.getElementById('kitContent').classList.remove('hidden');
  document.getElementById('templateSection').classList.add('hidden');
  window._currentRepoUrl = repoUrl;
}

async function loadTemplate() {
  const sec = document.getElementById('templateSection');
  const pre = document.getElementById('templateContent');
  if (!sec.classList.contains('hidden')) { sec.classList.add('hidden'); return; }
  pre.textContent = 'Loading...';
  sec.classList.remove('hidden');
  try {
    const r = await fetch('/api/template', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ repoUrl: window._currentRepoUrl }) });
    const d = await r.json();
    pre.textContent = d.content || '(empty)';
  } catch(e) { pre.textContent = 'Error: ' + e.message; }
}

function copyText(text, btn) {
  navigator.clipboard.writeText(text).then(() => {
    const orig = btn.textContent; btn.textContent = 'Copied!'; btn.classList.add('copied');
    setTimeout(() => { btn.textContent = orig; btn.classList.remove('copied'); }, 1500);
  });
}
function copyEl(id, btn) {
  const el = document.getElementById(id);
  const text = el.innerText.replace(/Copy$/,'').trim();
  copyText(text, btn);
}

// Restore last URL on load
fetch('/api/state').then(r=>r.json()).then(s => {
  if (s.repoUrl) document.getElementById('repoUrl').value = s.repoUrl;
});
</script>
</body>
</html>
KITHTML

chown -R claude-code:claude-code /home/claude-code/.ccc

# Systemd service
cat > /etc/systemd/system/ccc-kit-manager.service << 'KITSVC'
[Unit]
Description=CCC Kit Manager
After=network.target

[Service]
Type=simple
User=claude-code
WorkingDirectory=/home/claude-code/.ccc/kit-manager
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
KITSVC

systemctl daemon-reload
systemctl disable --now ccc-kit-manager 2>/dev/null || true

# ── Cockpit CCC Command Center ───────────────────────────────────────────────
mkdir -p /usr/local/lib/ccc
cat > /usr/local/lib/ccc/kit-api.js << 'CCCKITAPI'
#!/usr/bin/env node
'use strict';
const https = require('https');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');

function run(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { timeout: 45000, maxBuffer: 2 * 1024 * 1024, ...opts }, (err, stdout, stderr) => {
      if (err) {
        err.stderr = stderr;
        reject(err);
      } else {
        resolve(stdout);
      }
    });
  });
}

function ghApi(repoUrl, filePath) {
  const m = repoUrl.match(/github\.com[:/]([^/]+)\/([^/\s.]+?)(?:\.git)?(?:\/.*)?$/);
  if (!m) throw new Error('Not a valid GitHub repository URL');
  return `https://api.github.com/repos/${m[1]}/${m[2]}/contents/${filePath}`;
}

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const opts = { headers: { 'User-Agent': 'ccc-command-center/1.0', 'Accept': 'application/vnd.github.v3+json' } };
    https.get(url, opts, res => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => {
        try { resolve(JSON.parse(d)); } catch (e) { reject(e); }
      });
    }).on('error', reject);
  });
}

async function fetchFile(repoUrl, filePath) {
  try {
    const raw = await fetchJson(ghApi(repoUrl, filePath));
    if (!raw.message && raw.content) return Buffer.from(raw.content, 'base64').toString('utf8');
  } catch {}

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ccc-kit-'));
  try {
    const env = {
      ...process.env,
      GIT_TERMINAL_PROMPT: '0',
      GIT_SSH_COMMAND: 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new'
    };
    await run('git', ['clone', '--depth', '1', repoUrl, tmp], { env });
    const target = path.join(tmp, filePath);
    if (!fs.existsSync(target)) return null;
    return fs.readFileSync(target, 'utf8');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

async function main() {
  const action = process.argv[2];
  const repoUrl = (process.argv[3] || '').trim();
  if (!repoUrl) throw new Error('Repository URL required');

  if (action === 'connect') {
    const content = await fetchFile(repoUrl, '.claude-plugin/marketplace.json');
    if (!content) throw new Error('Missing .claude-plugin/marketplace.json');
    const manifest = JSON.parse(content);
    const kitName = manifest.name || 'kit';
    const plugins = manifest.plugins || [];
    process.stdout.write(JSON.stringify({
      repoUrl,
      manifest,
      marketplaceCommand: `/plugin marketplace add ${repoUrl}`,
      installAllCommand: plugins.map(p => `/plugin install ${p.name}@${kitName}`).join('\n')
    }));
    return;
  }

  if (action === 'template') {
    const content = await fetchFile(repoUrl, 'templates/project-SETUP.md');
    process.stdout.write(JSON.stringify({ content: content || '(no template found)' }));
    return;
  }

  throw new Error(`Unknown action: ${action}`);
}

main().catch(err => {
  process.stderr.write(err.message + '\n');
  process.exit(1);
});
CCCKITAPI
chmod +x /usr/local/lib/ccc/kit-api.js

mkdir -p /usr/share/cockpit/ccc
cat > /usr/share/cockpit/ccc/manifest.json << 'CCCMANIFEST'
{
  "version": 0,
  "name": "ccc",
  "menu": {
    "index": {
      "label": "CCC Command Center",
      "order": 5,
      "path": "index.html"
    }
  }
}
CCCMANIFEST

cat > /usr/share/cockpit/ccc/index.html << 'CCCCOCKPITHTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>CCC Command Center</title>
  <link rel="stylesheet" href="style.css">
  <script src="../base1/cockpit.js"></script>
</head>
<body>
  <main class="shell">
    <header class="topline">
      <div>
        <div class="brand"><span class="mark">&gt;</span> CCC</div>
        <div class="subbrand">Claude Code Commander</div>
      </div>
      <nav>
        <button class="tab active" data-view="overview">Overview</button>
        <button class="tab" data-view="kits">Kits</button>
        <button class="tab" data-view="tools">Tools</button>
        <button class="tab" data-view="updates">Updates</button>
      </nav>
    </header>

    <section id="overview" class="view active">
      <div class="section-label">Workstation</div>
      <div class="metrics">
        <article class="metric orange"><span>Status</span><strong id="doctorState">Checking</strong><small>ccc-doctor</small></article>
        <article class="metric cyan"><span>Editor</span><strong>8080</strong><small>code-server</small></article>
        <article class="metric green"><span>Command Center</span><strong>9090</strong><small>Cockpit</small></article>
        <article class="metric cyan"><span>Kit Source</span><strong>GitHub</strong><small>public or SSH private</small></article>
      </div>

      <div class="panel wide">
        <div class="panel-title">Health Output</div>
        <pre id="doctorOutput">Loading...</pre>
      </div>
    </section>

    <section id="kits" class="view">
      <div class="section-label">GitHub Kits</div>
      <div class="panel">
        <div class="panel-title">Connect Repository</div>
        <p class="hint">Repo must contain <code>.claude-plugin/marketplace.json</code>. Private repos use SSH after <code>ccc-onboarding</code>.</p>
        <div class="input-row">
          <input id="repoUrl" placeholder="https://github.com/owner/repo or git@github.com:owner/repo.git">
          <button id="connectBtn">Connect</button>
        </div>
        <div class="examples">
          <button data-example="https://github.com/owner/repo">Public example</button>
          <button data-example="git@github.com:owner/repo.git">Private SSH example</button>
        </div>
        <div id="kitStatus" class="status"></div>
      </div>

      <div id="kitResults" class="hidden">
        <div class="panel command">
          <div class="panel-title">Step 1 - Add Marketplace Inside Claude</div>
          <pre id="marketplaceCommand"></pre>
          <button class="copy" data-copy="marketplaceCommand">Copy</button>
        </div>
        <div class="panel command">
          <div class="panel-title">Step 2 - Install Plugins Inside Claude</div>
          <pre id="installCommand"></pre>
          <button class="copy" data-copy="installCommand">Copy</button>
        </div>
        <div class="plugin-grid" id="pluginGrid"></div>
      </div>
    </section>

    <section id="tools" class="view">
      <div class="section-label">Token-Saving Tools</div>
      <div class="quick-grid">
        <button class="quick" data-run="ccc-install-codex"><strong>Codex</strong><span>Install OpenAI Codex CLI</span></button>
        <button class="quick" data-run="ccc-install-jcodemunch"><strong>jCodeMunch</strong><span>Install symbol-level MCP</span></button>
        <button class="quick" data-run="ccc-install-playwright"><strong>Playwright</strong><span>Install browser test runtime</span></button>
        <button class="quick" data-run="ccc-onboarding"><strong>Onboarding</strong><span>Git identity and GitHub SSH</span></button>
      </div>
      <div class="panel wide">
        <div class="panel-title">Command Output</div>
        <pre id="toolOutput">Select a tool to run.</pre>
      </div>
    </section>

    <section id="updates" class="view">
      <div class="section-label">Updates</div>
      <div class="quick-grid">
        <button class="quick" data-run="ccc-verify-cockpit-updates"><strong>Verify GUI Updates</strong><span>Check Cockpit update path</span></button>
        <button class="quick" data-run="ccc-fix-cockpit-updates"><strong>Repair GUI Updates</strong><span>Fix PackageKit/NM online state</span></button>
        <button class="quick" data-run="ccc-update"><strong>CCC Update</strong><span>Update packages and Claude</span></button>
        <a class="quick link" href="/system/updates"><strong>Cockpit Updates</strong><span>Open native updater</span></a>
      </div>
      <div class="panel wide">
        <div class="panel-title">Update Output</div>
        <pre id="updateOutput">Run a check or open Cockpit updates.</pre>
      </div>
    </section>
  </main>
  <script src="app.js"></script>
</body>
</html>
CCCCOCKPITHTML

cat > /usr/share/cockpit/ccc/style.css << 'CCCCOCKPITCSS'
:root{--bg:#050c14;--panel:#0b1829;--line:#12314f;--muted:#7590b7;--text:#d8e9ff;--cyan:#00d9ff;--green:#2bd67b;--orange:#ff9f1a;--pink:#ff4fa3}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;letter-spacing:.01em}.shell{min-height:100vh}.topline{height:45px;border-bottom:1px solid var(--line);background:#0a1626;display:flex;align-items:center;padding:0 20px;gap:34px}.brand{color:var(--cyan);font-size:20px;font-weight:800;letter-spacing:.08em}.mark{font-weight:400;margin-right:8px}.subbrand{font-size:9px;text-transform:uppercase;color:var(--muted);letter-spacing:.18em}nav{display:flex;height:100%;gap:18px}.tab{border:0;border-bottom:2px solid transparent;background:transparent;color:var(--muted);padding:0 4px;font:inherit;text-transform:uppercase;letter-spacing:.12em;cursor:pointer}.tab.active{color:var(--cyan);border-bottom-color:var(--cyan)}.view{display:none;padding:24px}.view.active{display:block}.section-label{color:var(--muted);text-transform:uppercase;letter-spacing:.18em;font-size:11px;margin:0 0 14px 1px}.metrics{display:grid;grid-template-columns:repeat(4,minmax(180px,250px));gap:12px;margin-bottom:28px}.metric{background:var(--panel);border-left:3px solid var(--cyan);border-radius:6px;padding:16px 20px}.metric.orange{border-color:var(--orange)}.metric.green{border-color:var(--green)}.metric span,.panel-title{display:block;color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.14em;margin-bottom:8px}.metric strong{display:block;color:var(--cyan);font-size:22px;line-height:1.1}.metric small{color:var(--muted)}.panel{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:16px;margin-bottom:16px;max-width:1040px}.panel.wide{max-width:1040px}.hint{color:var(--muted);margin-top:-2px}.hint code,.note code{color:var(--cyan)}pre{margin:0;white-space:pre-wrap;color:#b8d7ff;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;max-height:360px;overflow:auto}.input-row{display:flex;gap:10px;margin:12px 0}input{flex:1;background:#07111e;border:1px solid var(--line);border-radius:5px;color:var(--text);padding:10px 12px;font:inherit}button,.quick{background:#0b2037;border:1px solid #17456d;border-radius:5px;color:var(--text);padding:10px 14px;font:inherit;cursor:pointer;text-decoration:none}button:hover,.quick:hover{border-color:var(--cyan);color:var(--cyan)}.examples{display:flex;gap:8px}.examples button{font-size:12px;padding:6px 10px}.status{color:var(--muted);min-height:22px}.status.err{color:#ff6b6b}.status.ok{color:var(--green)}.hidden{display:none}.command{position:relative}.copy{position:absolute;right:14px;top:14px;padding:5px 10px;font-size:12px}.plugin-grid,.quick-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:12px;max-width:1040px}.plugin,.quick{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:14px}.plugin strong,.quick strong{display:block;color:var(--cyan);font-size:14px;margin-bottom:6px}.plugin span,.quick span{color:var(--muted);font-size:12px}.link{display:block}
@media(max-width:900px){.topline{height:auto;align-items:flex-start;flex-direction:column;padding:14px 16px;gap:12px}nav{height:auto;flex-wrap:wrap}.metrics{grid-template-columns:1fr}.view{padding:16px}.input-row{flex-direction:column}}
CCCCOCKPITCSS

cat > /usr/share/cockpit/ccc/app.js << 'CCCCOCKPITJS'
const $ = id => document.getElementById(id);
const show = id => {
  document.querySelectorAll('.view').forEach(v => v.classList.toggle('active', v.id === id));
  document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.dataset.view === id));
};
const esc = v => String(v ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));

function spawnText(cmd, target) {
  const out = $(target);
  out.textContent = `Running ${cmd}...`;
  cockpit.spawn(['bash', '-lc', cmd], { superuser: 'try', err: 'out' })
    .then(text => out.textContent = text || 'Done.')
    .catch(ex => out.textContent = ex.message || String(ex));
}

document.querySelectorAll('.tab').forEach(btn => btn.addEventListener('click', () => show(btn.dataset.view)));
document.querySelectorAll('[data-example]').forEach(btn => btn.addEventListener('click', () => { $('repoUrl').value = btn.dataset.example; $('repoUrl').focus(); }));
document.querySelectorAll('[data-copy]').forEach(btn => btn.addEventListener('click', () => navigator.clipboard.writeText($(btn.dataset.copy).textContent)));
document.querySelectorAll('[data-run]').forEach(btn => btn.addEventListener('click', () => {
  const view = btn.closest('.view').id;
  spawnText(btn.dataset.run, view === 'updates' ? 'updateOutput' : 'toolOutput');
}));

$('connectBtn').addEventListener('click', () => {
  const repo = $('repoUrl').value.trim();
  if (!repo) return;
  $('kitStatus').className = 'status';
  $('kitStatus').textContent = 'Connecting...';
  cockpit.spawn(['/usr/bin/node', '/usr/local/lib/ccc/kit-api.js', 'connect', repo], { superuser: 'try', err: 'message' })
    .then(raw => {
      const data = JSON.parse(raw);
      const plugins = data.manifest.plugins || [];
      $('marketplaceCommand').textContent = data.marketplaceCommand;
      $('installCommand').textContent = data.installAllCommand || '(no plugins listed)';
      $('pluginGrid').innerHTML = plugins.map(p => `<div class="plugin"><strong>${esc(p.name)}</strong><span>${esc(p.description || p.category || '')}</span></div>`).join('');
      $('kitResults').classList.remove('hidden');
      $('kitStatus').className = 'status ok';
      $('kitStatus').textContent = `Connected: ${data.manifest.name || 'kit'} (${plugins.length} plugins)`;
    })
    .catch(ex => {
      $('kitStatus').className = 'status err';
      $('kitStatus').textContent = ex.message || String(ex);
    });
});

cockpit.spawn(['ccc-doctor'], { superuser: 'try', err: 'out' })
  .then(text => { $('doctorState').textContent = 'Ready'; $('doctorOutput').textContent = text; })
  .catch(ex => { $('doctorState').textContent = 'Check'; $('doctorOutput').textContent = ex.message || String(ex); });
CCCCOCKPITJS

echo "    CCC Command Center: https://<ip>:9090 (Cockpit sidebar)"

# ── Cleanup ───────────────────────────────────────────────────────────────────
step 29 "Cleanup"
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
  echo -e "  ${BOLD}Plugins:${NC}      https://<ip>:9090 — CCC Command Center in Cockpit"
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
