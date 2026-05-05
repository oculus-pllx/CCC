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
_STEPS=31
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
npx --yes get-shit-done-cc --claude --global 2>/dev/null \
  || echo "    [WARN] get-shit-done-cc — run manually: npx --yes get-shit-done-cc --claude --global"

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
pip3 install --break-system-packages --quiet --no-warn-script-location \
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
step 17 "Playwright (skipped — install manually after provision)"
echo "    Run after provision: npx --yes playwright install --with-deps chromium"

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
  "enableRemoteControl": true,
  "statusLine": "~/.claude/bin/statusline-command.sh"
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
# Clone repos to skill-repos/ (full repo kept for git pull updates).
# Copy all .md files up to skills/ so Claude Code discovers them directly.
step 20 "Skill repos"
sudo -u claude-code mkdir -p /home/claude-code/.claude/skills
sudo -u claude-code mkdir -p /home/claude-code/.claude/skill-repos
cd /home/claude-code/.claude/skill-repos

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

# Copy .md skill files to ~/.claude/skills/ and inject frontmatter if missing
find /home/claude-code/.claude/skill-repos -name "*.md" \
  ! -name "README.md" ! -name "CHANGELOG.md" ! -name "LICENSE.md" \
  ! -name "THIRD_PARTY_NOTICES.md" ! -name "SECURITY.md" ! -name "CONTRIBUTING.md" \
  | while read -r f; do
    base=$(basename "$f" .md)
    repo=$(echo "$f" | awk -F'skill-repos/' '{print $2}' | cut -d'/' -f1)
    dest="/home/claude-code/.claude/skills/${repo}-${base}.md"

    # Inject frontmatter if file doesn't already have it
    if head -1 "$f" | grep -q '^---'; then
      sudo -u claude-code cp "$f" "$dest"
    else
      # Derive description from first non-empty line of content
      desc=$(grep -m1 -v '^\s*$' "$f" | sed 's/^#\+\s*//' | cut -c1-80)
      [[ -z "$desc" ]] && desc="$base skill"
      sudo -u claude-code bash -c "cat > '$dest' << 'FRONTMATTER'
---
name: $base
description: $desc
---
FRONTMATTER
cat '$f' >> '$dest'"
    fi
  done

skill_count=$(find /home/claude-code/.claude/skills -maxdepth 1 -name "*.md" | wc -l)
echo "    $skill_count skill files installed to ~/.claude/skills/"

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

# Welcome file — opens automatically in code-server on first load
sudo -u claude-code tee /home/claude-code/projects/WELCOME.md > /dev/null << 'WELCOMEMD'
# Welcome to Claude Code Commander

## First Steps

| Step | Command | Where |
|------|---------|-------|
| 1 | `ccc-setup` | SSH terminal — git identity, SSH key, GitHub |
| 2 | `claude` | SSH terminal — authenticate Claude Code |
| 3 | `ccc-setup-plugins` | SSH terminal — plugin & skill install menu |
| 4 | `ccc-install-playwright` | SSH terminal — headless browser testing (optional) |
| 5 | `ccc-install-codex` | SSH terminal — OpenAI Codex CLI (optional) |
| 6 | `ccc` | SSH terminal — full command reference |

## This Interface (code-server)

- **Multiple terminals**: Terminal → New Terminal  (or `Ctrl+\``)
- **Split terminal**: click the split icon in the terminal toolbar
- **Open folder**: File → Open Folder → `/home/claude-code/projects`

## Cockpit (port 9090)

System monitoring, file manager, and single terminal.
For multi-terminal work, use this editor (port 8080) instead.

## Quick Commands

```bash
ccc-setup          # post-install wizard
ccc-update         # update packages + Claude Code + skills
ccc-doctor         # health check
ccc-setup-plugins  # plugin & skill menu
ccc                # full help
```

## SSH Access

```bash
ssh claude-code@<this-container-ip>
```
WELCOMEMD

# Workspace settings — auto-open WELCOME.md on first launch
sudo -u claude-code mkdir -p /home/claude-code/projects/.vscode
sudo -u claude-code tee /home/claude-code/projects/.vscode/settings.json > /dev/null << 'VSCSETTINGS'
{
  "workbench.startupEditor": "none",
  "markdown.preview.openMarkdownLinks": "inEditor"
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
  echo -e "    ${C}ccc-setup-plugins${N}         Print plugin slash-commands for Claude"
  echo -e "    ${C}ccc-install-playwright${N}    Install Playwright + headless Chromium"
  echo -e "    ${C}ccc-install-codex${N}         Install OpenAI Codex CLI"
  echo ""
  echo -e "  ${B}MAINTENANCE${N}"
  echo -e "    ${C}ccc-setup${N}                 Post-install wizard (git identity, SSH key, GitHub)"
  echo -e "    ${C}ccc-self-update${N}           Pull latest ccc-* tools from GitHub (no reprovision)"
  echo -e "    ${C}ccc-update${N}                Update system packages + Claude Code"
  echo -e "    ${C}ccc-doctor${N}                System health check (network, runtimes, services)"
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

# CCC_UPDATEABLE_START — sections below re-run by ccc-self-update
# ── ccc-setup-plugins (standalone script) ────────────────────────────────────
step 25 "ccc-setup-plugins script"
cat > /usr/local/bin/ccc-setup-plugins << 'PLUGINSCRIPT'
#!/bin/bash
B='\033[1m'; C='\033[0;36m'; Y='\033[1;33m'; G='\033[0;32m'; D='\033[2m'; R='\033[0;31m'; N='\033[0m'

# Plugins — require manual /plugin install inside Claude Code session
# Format: "Name|description|step1|step2|..."
PLUGINS=(
  "Skill Creator|Create and manage reusable Claude skills|/plugin install skill-creator@claude-plugins-official"
  "Superpowers|Agent teams, code review, TDD, debugging workflows|/plugin install superpowers@claude-plugins-official"
  "Frontend Design|UI/UX design and component workflows|/plugin install frontend-design@claude-plugins-official"
  "Context Mode|Fine-grained control over Claude context|/plugin marketplace add mksglu/context-mode|/plugin install context-mode@context-mode"
  "Claude Mem|Persistent memory across Claude sessions|/plugin marketplace add thedotmack/claude-mem|/plugin install claude-mem"
)

# Pre-installed skills — already cloned to ~/.claude/skills/ at provision time
# Format: "Name|description|path|source"
SKILLS=(
  "Anthropic Skills|Official Anthropic prompt and workflow skills|~/.claude/skills/anthropic-skills|github.com/anthropics/skills"
  "Karpathy Skills|Andrej Karpathy AI/ML workflow skills|~/.claude/skills/karpathy-skills|github.com/forrestchang/andrej-karpathy-skills"
  "Matt Pocock Skills|TypeScript and developer workflow skills|~/.claude/skills/mattpocock-skills|github.com/mattpocock/skills"
  "Caveman|Terse caveman-mode communication skill|~/.claude/skills/caveman|github.com/juliusbrussee/caveman"
)

show_how_to_plugin() {
  echo ""
  echo -e "${Y}How to install plugins:${N}"
  echo -e "  1. Open a terminal and run ${C}claude${N} to start Claude Code"
  echo -e "  2. Copy the command shown below"
  echo -e "  3. Paste it into the Claude Code prompt and press Enter"
  echo -e "  4. Wait for the confirmation message before the next step"
  echo -e "  ${D}Plugins require an authenticated Claude Code session.${N}"
  echo ""
}

show_plugin() {
  local idx=$1
  local entry="${PLUGINS[$idx]}"
  local name=$(echo "$entry" | cut -d'|' -f1)
  local desc=$(echo "$entry" | cut -d'|' -f2)
  local cmds=$(echo "$entry" | cut -d'|' -f3-)
  echo ""
  echo -e "${B}$name${N}"
  echo -e "${D}$desc${N}"
  echo ""
  echo -e "${Y}Paste into Claude Code (run: claude):${N}"
  IFS='|' read -ra steps <<< "$cmds"
  local i=1
  for cmd in "${steps[@]}"; do
    echo -e "  ${G}Step $i:${N} ${C}${cmd}${N}"
    i=$(( i + 1 ))
  done
  echo ""
}

show_skill() {
  local idx=$1
  local entry="${SKILLS[$idx]}"
  local name=$(echo "$entry"  | cut -d'|' -f1)
  local desc=$(echo "$entry"  | cut -d'|' -f2)
  local path=$(echo "$entry"  | cut -d'|' -f3)
  local src=$(echo "$entry"   | cut -d'|' -f4)
  echo ""
  echo -e "${B}$name${N} ${G}[pre-installed]${N}"
  echo -e "${D}$desc${N}"
  echo -e "  Location: ${C}$path${N}"
  echo -e "  Source:   ${C}https://$src${N}"
  echo ""
  if [[ -d "${path/\~/$HOME}" ]]; then
    echo -e "  ${G}✓ Present on disk${N}"
  else
    echo -e "  ${R}✗ Not found — re-run: git clone https://$src ${path/\~/$HOME}${N}"
  fi
  echo ""
}

show_all_plugins() {
  show_how_to_plugin
  echo -e "${B}Full plugin install sequence — paste into Claude Code in order:${N}"
  echo ""
  for entry in "${PLUGINS[@]}"; do
    local name=$(echo "$entry" | cut -d'|' -f1)
    local cmds=$(echo "$entry" | cut -d'|' -f3-)
    echo -e "  ${G}── $name${N}"
    IFS='|' read -ra steps <<< "$cmds"
    for cmd in "${steps[@]}"; do
      echo -e "     ${C}$cmd${N}"
    done
    echo ""
  done
}

show_all_skills() {
  echo ""
  echo -e "${B}Pre-installed Skills${N} ${D}(already on disk — no install needed)${N}"
  echo ""
  for entry in "${SKILLS[@]}"; do
    local name=$(echo "$entry" | cut -d'|' -f1)
    local path=$(echo "$entry" | cut -d'|' -f3)
    local src=$(echo "$entry"  | cut -d'|' -f4)
    if [[ -d "${path/\~/$HOME}" ]]; then
      echo -e "  ${G}✓${N} ${B}$name${N} — ${C}$path${N}"
    else
      echo -e "  ${R}✗${N} ${B}$name${N} — missing (${D}https://$src${N})"
    fi
  done
  echo ""
  echo -e "  ${D}Also pre-installed: get-shit-done-cc (global npm package)${N}"
  echo ""
}

plugin_count=${#PLUGINS[@]}
skill_count=${#SKILLS[@]}

while true; do
  echo ""
  echo -e "${B}╔════════════════════════════════════════════════╗${N}"
  echo -e "${B}║        CCC Plugins & Skills Menu               ║${N}"
  echo -e "${B}╚════════════════════════════════════════════════╝${N}"
  echo ""
  echo -e "  ${Y}── Plugins (require manual install in Claude Code) ──${N}"
  for i in "${!PLUGINS[@]}"; do
    local_name=$(echo "${PLUGINS[$i]}" | cut -d'|' -f1)
    local_desc=$(echo "${PLUGINS[$i]}" | cut -d'|' -f2)
    echo -e "  ${C}$((i+1))${N}. ${B}$local_name${N} — ${D}$local_desc${N}"
  done
  echo ""
  echo -e "  ${Y}── Pre-installed Skills (already on disk) ──${N}"
  for i in "${!SKILLS[@]}"; do
    local_name=$(echo "${SKILLS[$i]}" | cut -d'|' -f1)
    local_desc=$(echo "${SKILLS[$i]}" | cut -d'|' -f2)
    local_path=$(echo "${SKILLS[$i]}" | cut -d'|' -f3)
    if [[ -d "${local_path/\~/$HOME}" ]]; then
      echo -e "  ${C}$((i+plugin_count+1))${N}. ${B}$local_name${N} ${G}✓${N} — ${D}$local_desc${N}"
    else
      echo -e "  ${C}$((i+plugin_count+1))${N}. ${B}$local_name${N} ${R}✗ missing${N} — ${D}$local_desc${N}"
    fi
  done
  echo ""
  echo -e "  ${C}a${N}. Install all plugins (full sequence)"
  echo -e "  ${C}s${N}. Show all pre-installed skills"
  echo -e "  ${C}h${N}. How to install plugins"
  echo -e "  ${C}q${N}. Quit"
  echo ""
  read -rp "  Choice: " CHOICE

  if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= plugin_count )); then
    show_plugin $(( CHOICE - 1 ))
  elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= plugin_count+1 && CHOICE <= plugin_count+skill_count )); then
    show_skill $(( CHOICE - plugin_count - 1 ))
  else
    case "$CHOICE" in
      a|A) show_all_plugins ;;
      s|S) show_all_skills ;;
      h|H) show_how_to_plugin ;;
      q|Q) echo ""; exit 0 ;;
      *) echo -e "  ${Y}Enter 1–$((plugin_count+skill_count)), a, s, h, or q${N}" ;;
    esac
  fi

  read -rp "  Press Enter to return to menu..." _
done
PLUGINSCRIPT
chmod +x /usr/local/bin/ccc-setup-plugins

# ── ccc-update ────────────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-update << 'UPDATESCRIPT'
#!/bin/bash
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; N='\033[0m'
echo ""
echo -e "${B}CCC Update${N}"
echo ""
echo -e "${C}[1/3]${N} System packages..."
sudo systemctl restart NetworkManager 2>/dev/null || true
sudo apt-get update -qq && sudo apt-get upgrade -y
echo ""
echo -e "${C}[2/3]${N} Claude Code..."
claude update
echo ""
echo -e "${C}[3/3]${N} Skill repos..."
SKILL_REPOS="$HOME/.claude/skill-repos"
SKILLS_DIR="$HOME/.claude/skills"
if [[ -d "$SKILL_REPOS" ]]; then
  for repo in "$SKILL_REPOS"/*/; do
    [[ -d "$repo/.git" ]] || continue
    name=$(basename "$repo")
    printf "    pulling %s... " "$name"
    git -C "$repo" pull -q 2>/dev/null && echo "done" || echo "skipped"
  done
  # Re-sync .md files with frontmatter injection
  find "$SKILL_REPOS" -name "*.md" \
    ! -name "README.md" ! -name "CHANGELOG.md" ! -name "LICENSE.md" \
    ! -name "THIRD_PARTY_NOTICES.md" ! -name "SECURITY.md" ! -name "CONTRIBUTING.md" \
    | while read -r f; do
      base=$(basename "$f" .md)
      repo=$(echo "$f" | awk -F'skill-repos/' '{print $2}' | cut -d'/' -f1)
      dest="$SKILLS_DIR/${repo}-${base}.md"
      if head -1 "$f" | grep -q '^---'; then
        cp "$f" "$dest" 2>/dev/null || true
      else
        desc=$(grep -m1 -v '^\s*$' "$f" | sed 's/^#\+\s*//' | cut -c1-80)
        [[ -z "$desc" ]] && desc="$base skill"
        { printf -- '---\nname: %s\ndescription: %s\n---\n' "$base" "$desc"; cat "$f"; } > "$dest" 2>/dev/null || true
      fi
    done
  echo "    skills synced"
else
  echo "    no skill-repos dir found — skipping"
fi
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
  ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f ~/.ssh/id_ed25519 -N ""
  echo -e "  ${G}✓ Key generated${N}"
fi
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
echo -e "${G}${B}Setup complete. Run 'ccc' for full help.${N}"
echo ""
SETUPSCRIPT
chmod +x /usr/local/bin/ccc-setup

# ── ccc-doctor ────────────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-doctor << 'DOCTORSCRIPT'
#!/bin/bash
B='\033[1m'; G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; Y='\033[1;33m'; N='\033[0m'
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
[[ -f ~/.claude/settings.json ]] && ok "settings.json present" || fail "settings.json missing"
[[ -f ~/.claude/bin/statusline-command.sh ]] && ok "statusline script present" || warn "statusline script missing"
echo ""

echo -e "${C}── Services ──────────────────────────────────${N}"
systemctl is-active --quiet "code-server@claude-code" && ok "code-server running" || fail "code-server not running — sudo systemctl start code-server@claude-code"
systemctl is-active --quiet cockpit.socket            && ok "cockpit running"     || fail "cockpit not running — sudo systemctl start cockpit.socket"
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
step 26 "ccc-install-playwright script"
cat > /usr/local/bin/ccc-install-playwright << 'PWSCRIPT'
#!/bin/bash
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
echo ""
echo -e "${B}Installing Playwright + headless Chromium${N}"
echo -e "${Y}This downloads ~300MB and takes 5–15 minutes. Do not interrupt.${N}"
echo ""

export HOME=/home/claude-code
export DEBIAN_FRONTEND=noninteractive
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

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
echo ""
echo -e "${B}Installing OpenAI Codex CLI${N}"
echo ""

echo -e "${C}[1/2]${N} Installing @openai/codex..."
npm install -g @openai/codex
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
echo ""
echo -e "${Y}To use Codex you need an OpenAI API key:${N}"
echo -e "  1. Get a key at ${C}https://platform.openai.com/api-keys${N}"
echo -e "  2. Add to your shell:"
echo -e "     ${C}echo 'export OPENAI_API_KEY=\"sk-...\"' >> ~/.bashrc && source ~/.bashrc${N}"
echo -e "  3. Run: ${C}codex${N}"
echo ""
CODEXSCRIPT
chmod +x /usr/local/bin/ccc-install-codex

# ── ccc-self-update ───────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-self-update << 'SELFUPDATESCRIPT'
#!/bin/bash
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
REPO_URL="https://raw.githubusercontent.com/oculus-pllx/CCC/main/claude-code-commander.sh"
TMP="/tmp/ccc-provisioner-$$.sh"

echo ""
echo -e "${B}CCC Self-Update${N}"
echo -e "${Y}Downloads latest provisioner and re-applies ccc-* tools, MOTD, and skill sync.${N}"
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
  echo -e "  ccc-* commands, MOTD, and skill sync updated to latest."
else
  echo -e "${R}Update script exited with errors ($STATUS). Some steps may have partially applied.${N}"
fi
echo ""
SELFUPDATESCRIPT
chmod +x /usr/local/bin/ccc-self-update

# ── MOTD ─────────────────────────────────────────────────────────────────────
step 27 "MOTD"
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
echo -e "  ${C}ccc-setup${N}                 Post-install wizard (git, SSH key, GitHub)"
echo -e "  ${C}ccc-self-update${N}           Pull latest ccc-* tools from GitHub (no reprovision)"
echo -e "  ${C}ccc-update${N}                Update system packages + Claude Code"
echo -e "  ${C}ccc-setup-plugins${N}         Plugin & skill install menu"
echo -e "  ${C}ccc-install-playwright${N}    Install Playwright + Chromium"
echo -e "  ${C}ccc-install-codex${N}         Install OpenAI Codex CLI"
echo -e "  ${C}ccc-doctor${N}                System health check"
echo ""
echo -e "  ${Y}Web Interfaces${N}"
IP=\$(hostname -I 2>/dev/null | awk '{print \$1}')
echo -e "  ${C}http://\${IP}:8080${N}   Web VS Code — multi-terminal, file editor"
echo -e "  ${C}https://\${IP}:9090${N}  Cockpit — system monitoring, file manager"
echo -e "  ${D}Tip: use port 8080 for multiple terminal tabs (Terminal → New Terminal)${N}"
echo ""
MOTD
chmod +x /etc/update-motd.d/00-ccc

# CCC_UPDATEABLE_END — sections above re-run by ccc-self-update

# ── Git defaults ──────────────────────────────────────────────────────────────
step 28 "Git defaults"
sudo -u claude-code git config --global init.defaultBranch main
sudo -u claude-code git config --global core.editor nano
sudo -u claude-code git config --global pull.rebase false
sudo -u claude-code git config --global core.autocrlf false

# ── Auto-update cron ──────────────────────────────────────────────────────────
step 29 "Auto-update cron"
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
step 30 "Cockpit (web admin UI)"
# network-manager needed for PackageKit (Cockpit updates) to detect online state in LXC
apt-get install -y -qq --no-install-recommends network-manager > /dev/null 2>&1 || true
# Keep NM from touching LXC interfaces — systemd-networkd owns them
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-unmanaged-lxc.conf << 'NMCONF'
[main]
plugins=keyfile

[keyfile]
unmanaged-devices=interface-name:eth*;interface-name:en*
NMCONF
systemctl enable NetworkManager 2>/dev/null || true
systemctl start  NetworkManager 2>/dev/null || true
apt-get install -y cockpit > /dev/null 2>&1
apt-get install -y cockpit-files > /dev/null 2>&1 || true
apt-get purge -y -qq udisks2 > /dev/null 2>&1 || true
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

# ── Cleanup ───────────────────────────────────────────────────────────────────
step 31 "Cleanup"
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

  pct exec "$CT_ID" -- bash -c "echo '${CC_USER}:${CC_PASSWORD}' | chpasswd"

  pct exec "$CT_ID" -- bash -c "
    sudo -u ${CC_USER} mkdir -p /home/${CC_USER}/.config/code-server
    cat > /home/${CC_USER}/.config/code-server/config.yaml << YAML
bind-addr: 0.0.0.0:8080
auth: password
password: ${CS_PASSWORD}
cert: false
user-data-dir: /home/${CC_USER}/.local/share/code-server
extensions-dir: /home/${CC_USER}/.local/share/code-server/extensions
YAML
    chown -R ${CC_USER}:${CC_USER} /home/${CC_USER}/.config/code-server
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
