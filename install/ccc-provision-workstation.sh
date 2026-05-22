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
OCULUS_CONFIGS_REPO="https://github.com/oculus-pllx/oculus-configs.git"
OCULUS_CONFIGS_REF="main"
OCULUS_CONFIGS_DIR="/opt/oculus-configs"
EOF
  chmod 0644 /etc/ccc/config
}
