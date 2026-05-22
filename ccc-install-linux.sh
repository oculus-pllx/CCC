#!/usr/bin/env bash
# Container Code Companion Linux Host Installer
# Installs CCC onto an existing Debian or Ubuntu machine.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CCC_USER=""
CCC_HOME=""
CCC_CREATE_USER=0
CCC_UI_PASSWORD=""
CODE_SERVER_PASSWORD=""
PROVISIONER=""

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

header() {
  echo ""
  echo -e "${BOLD}Container Code Companion Linux Host Installer${NC}"
  echo "Installs the CCC workstation stack on this Debian or Ubuntu system."
  echo ""
}

preflight() {
  command -v sudo >/dev/null 2>&1 || error "sudo is required."
  command -v curl >/dev/null 2>&1 || error "curl is required."
  command -v getent >/dev/null 2>&1 || error "getent is required."
  sudo -v

  [[ -r /etc/os-release ]] || error "/etc/os-release is required."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" =~ ^(debian|ubuntu)$ ]] || error "Only Debian and Ubuntu are supported."

  if sudo test -e /etc/ccc/config; then
    error "CCC already appears installed. Use ccc-self-update on an installed workstation."
  fi

  info "Checking GitHub reachability..."
  curl -fsSL --max-time 10 https://github.com >/dev/null \
    || error "GitHub is not reachable from this host."
}

valid_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

current_login_user() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
    return
  fi
  printf '%s\n' "$USER"
}

choose_target_user() {
  local current_user choice dedicated_user
  current_user="$(current_login_user)"

  echo -e "${BOLD}Install Target${NC}"
  echo "  1) Current user: $current_user"
  echo "  2) Create a dedicated CCC user"
  read -rp "Install target [1]: " choice

  if [[ "${choice:-1}" == "2" ]]; then
    read -rp "Dedicated CCC username [ccc]: " dedicated_user
    dedicated_user="${dedicated_user:-ccc}"
    valid_username "$dedicated_user" \
      || error "Invalid username. Use lowercase letters, numbers, hyphens, or underscores."
    if getent passwd "$dedicated_user" >/dev/null; then
      error "User $dedicated_user already exists. Re-run and choose the current user path if it should own CCC."
    fi
    CCC_USER="$dedicated_user"
    CCC_HOME="/home/$CCC_USER"
    CCC_CREATE_USER=1
  else
    [[ "$current_user" != "root" ]] \
      || error "Current user resolved to root. Re-run from the workstation user or create a dedicated CCC user."
    getent passwd "$current_user" >/dev/null || error "Current user $current_user was not found."
    CCC_USER="$current_user"
    CCC_HOME="$(getent passwd "$CCC_USER" | cut -d: -f6)"
  fi

  [[ -n "$CCC_HOME" && "$CCC_HOME" != "/" ]] || error "Could not determine home directory for $CCC_USER."
}

read_secret_with_default() {
  local prompt=$1
  local default_value=$2
  local secret
  read -rsp "$prompt" secret
  echo "" >&2
  printf '%s\n' "${secret:-$default_value}"
}

read_browser_credentials() {
  echo ""
  CCC_UI_PASSWORD="$(read_secret_with_default "CCC web UI password: " "")"
  [[ -n "$CCC_UI_PASSWORD" ]] || error "CCC web UI password cannot be empty."
  CODE_SERVER_PASSWORD="$(read_secret_with_default "code-server password [codeserver]: " "codeserver")"
}

confirm_install() {
  echo ""
  echo -e "${BOLD}Install Summary${NC}"
  echo "  Mode:             existing Debian/Ubuntu Linux host"
  echo "  Target user:      $CCC_USER"
  echo "  Home directory:   $CCC_HOME"
  echo "  CCC web UI:       LAN reachable on port 9090 with login"
  echo "  code-server:      LAN reachable on port 8080 with password auth"
  echo "  Baseline stack:   CCC UI, code-server, Claude Code, Node, Go, Rust, Python, GitHub CLI"
  echo "  Config sync:      required oculus-configs sync via ccc-sync-agent-configs"
  echo ""
  warn "This installs system packages and systemd services. It leaves host networking and SSH policy unchanged."
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

stage_workstation_provisioner() {
  local dest=$1
  local local_script
  local_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/install/ccc-provision-workstation.sh"
  if [[ -f "$local_script" ]]; then
    cp "$local_script" "$dest"
  else
    curl -fsSL "https://raw.githubusercontent.com/oculus-pllx/CCC/main/install/ccc-provision-workstation.sh" -o "$dest"
  fi
  chmod +x "$dest"
}

create_dedicated_user() {
  [[ "$CCC_CREATE_USER" -eq 1 ]] || return 0
  sudo useradd -m -s /bin/bash "$CCC_USER"
  info "Set the Linux password for $CCC_USER."
  sudo passwd "$CCC_USER"
}

provision_workstation() {
  PROVISIONER="$(mktemp /tmp/ccc-provision-workstation.XXXXXX.sh)"
  trap '[[ -n "${PROVISIONER:-}" ]] && rm -f "$PROVISIONER"' EXIT
  stage_workstation_provisioner "$PROVISIONER"

  sudo env \
    CCC_INSTALL_MODE=linux-host \
    CCC_MACHINE_POLICY=workstation \
    CCC_USER="$CCC_USER" \
    CCC_HOME="$CCC_HOME" \
    CCC_SELF_UPDATE_SCRIPT=ccc-install-linux.sh \
    "$PROVISIONER"
}

escape_yaml_string() {
  local escaped=$1
  escaped=${escaped//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  printf '%s\n' "$escaped"
}

configure_browser_services() {
  local ccc_ui_token code_server_password_yaml
  ccc_ui_token="$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | head -c 40)"
  code_server_password_yaml="$(escape_yaml_string "$CODE_SERVER_PASSWORD")"

  sudo install -d -m 0750 -o root -g "$CCC_USER" /etc/container-code-companion
  printf 'CONTAINER_CODE_COMPANION_ADDR=0.0.0.0:9090\nCONTAINER_CODE_COMPANION_WEB_DIR=/opt/container-code-companion/web\nCONTAINER_CODE_COMPANION_SESSION_TOKEN=%s\nCONTAINER_CODE_COMPANION_USERNAME=%s\nCONTAINER_CODE_COMPANION_PASSWORD=%s\n' \
    "$ccc_ui_token" "$CCC_USER" "$CCC_UI_PASSWORD" \
    | sudo tee /etc/container-code-companion/env >/dev/null
  sudo chown "root:$CCC_USER" /etc/container-code-companion/env
  sudo chmod 640 /etc/container-code-companion/env

  sudo install -d -m 0755 -o "$CCC_USER" -g "$CCC_USER" "$CCC_HOME/.config/code-server"
  printf 'bind-addr: 0.0.0.0:8080\nauth: password\npassword: "%s"\ncert: false\nuser-data-dir: %s/.local/share/code-server\nextensions-dir: %s/.local/share/code-server/extensions\n' \
    "$code_server_password_yaml" "$CCC_HOME" "$CCC_HOME" \
    | sudo tee "$CCC_HOME/.config/code-server/config.yaml" >/dev/null
  sudo chown -R "$CCC_USER:$CCC_USER" "$CCC_HOME/.config/code-server"

  sudo systemctl restart container-code-companion.service
  sudo systemctl start "code-server@$CCC_USER"
}

primary_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

print_summary() {
  local ip
  ip="$(primary_ip)"
  echo ""
  success "Container Code Companion host install finished."
  echo ""
  echo "  Target user:       $CCC_USER"
  if [[ -n "$ip" ]]; then
    echo "  CCC web UI:        http://$ip:9090"
    echo "  code-server:       http://$ip:8080"
  else
    echo "  CCC web UI:        port 9090"
    echo "  code-server:       port 8080"
  fi
  echo "  Config refresh:    ccc-sync-agent-configs"
  echo "  CCC diagnostics:   ccc-doctor"
  echo ""
  echo "Open the CCC UI with user $CCC_USER and the CCC web UI password entered above."
}

main() {
  header
  preflight
  choose_target_user
  read_browser_credentials
  confirm_install
  create_dedicated_user
  provision_workstation
  configure_browser_services
  print_summary
}

main "$@"
