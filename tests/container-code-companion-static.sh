#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_file_contains() {
  local file=$1
  local pattern=$2
  grep -Fq -- "$pattern" "$file" || fail "$file missing: $pattern"
}

require_file_not_contains() {
  local file=$1
  local pattern=$2
  if grep -Fq "$pattern" "$file"; then
    fail "$file still contains: $pattern"
  fi
}

legacy_bootstrap='claude-code-''commander'
if git grep -n "$legacy_bootstrap" -- . ':!container-code-companion/web/vendor/*'; then
  fail "tracked files still reference the legacy bootstrap name"
fi
[[ -f ccc-bootstrap.sh ]] || fail "missing ccc-bootstrap.sh"
[[ ! -e "${legacy_bootstrap}.sh" ]] || fail "legacy bootstrap file still exists"
[[ -f ccc-install-linux.sh ]] || fail "missing Linux host installer"
require_file_contains ccc-install-linux.sh 'Container Code Companion Linux Host Installer'
require_file_contains ccc-install-linux.sh 'Only Debian and Ubuntu are supported.'
require_file_not_contains ccc-install-linux.sh '99-disable-ipv6'
require_file_not_contains ccc-install-linux.sh 'PermitRootLogin'
require_file_contains ccc-install-linux.sh 'CCC_INSTALL_MODE=linux-host'
require_file_contains ccc-install-linux.sh 'Current user'
require_file_contains ccc-install-linux.sh 'Create a dedicated CCC user'
require_file_contains ccc-install-linux.sh 'ccc-provision-workstation.sh'
require_file_contains ccc-install-linux.sh 'CONTAINER_CODE_COMPANION_ADDR=0.0.0.0:9090'
require_file_contains ccc-install-linux.sh 'bind-addr: 0.0.0.0:8080'
require_file_contains ccc-install-linux.sh 'ccc-sync-agent-configs'
require_file_not_contains ccc-install-linux.sh 'pct '
require_file_not_contains ccc-install-linux.sh 'pvesh '
bash -n ccc-install-linux.sh
[[ -f install/ccc-provision-workstation.sh ]] || fail "missing shared workstation provisioner"
require_file_contains install/ccc-provision-workstation.sh 'CCC_INSTALL_MODE="${CCC_INSTALL_MODE:?'
require_file_contains install/ccc-provision-workstation.sh 'CCC_USER="${CCC_USER:?'
require_file_contains install/ccc-provision-workstation.sh 'CCC_HOME="${CCC_HOME:?'
require_file_contains install/ccc-provision-workstation.sh 'CCC_SELF_UPDATE_SCRIPT="${CCC_SELF_UPDATE_SCRIPT:?'
require_file_contains install/ccc-provision-workstation.sh 'CCC_MACHINE_POLICY="${CCC_MACHINE_POLICY:-workstation}"'
require_file_contains install/ccc-provision-workstation.sh 'CCC_UPDATEABLE_ONLY'
require_file_contains install/ccc-provision-workstation.sh 'source "$_ccc_updateable_tmp"'
require_file_contains install/ccc-provision-workstation.sh 'REPO_URL="${CCC_SELF_UPDATE_REPO:-https://github.com/oculus-pllx/CCC.git}"'
require_file_contains install/ccc-provision-workstation.sh 'REPO_URL="https://github.com/${REPO_URL#git@github.com:}"'
require_file_contains install/ccc-provision-workstation.sh 'git -C "$SRC" remote set-url origin "$REPO_URL"'
require_file_contains install/ccc-provision-workstation.sh 'latest_commit=$(git ls-remote "$FETCH_URL" "refs/heads/$REF"'
require_file_contains install/ccc-provision-workstation.sh 'cleanup() { [[ -n "${TMP_REPO:-}" ]] && rm -rf "$TMP_REPO"; true; }'
require_file_contains install/ccc-provision-workstation.sh 'CCC_SHARED_GROUP="${CCC_SHARED_GROUP:-ccc}"'
require_file_contains install/ccc-provision-workstation.sh 'CCC_SHARED_PROJECTS="${CCC_SHARED_PROJECTS:-/srv/ccc/projects}"'
require_file_contains install/ccc-provision-workstation.sh 'CCC_INSTALL_MODE="$CCC_INSTALL_MODE"'
require_file_contains install/ccc-provision-workstation.sh 'CCC_SHARED_GROUP="$CCC_SHARED_GROUP"'
require_file_contains install/ccc-provision-workstation.sh 'CCC_SHARED_PROJECTS="$CCC_SHARED_PROJECTS"'
require_file_contains install/ccc-provision-workstation.sh 'case "$CCC_INSTALL_MODE" in'
require_file_contains install/ccc-provision-workstation.sh 'proxmox-lxc|linux-host)'
require_file_contains install/ccc-provision-workstation.sh 'groupadd -f "$CCC_SHARED_GROUP"'
require_file_contains install/ccc-provision-workstation.sh 'usermod -aG "$CCC_SHARED_GROUP" "$CCC_USER"'
require_file_contains install/ccc-provision-workstation.sh 'chown root:"$CCC_SHARED_GROUP" "$CCC_SHARED_PROJECTS"'
require_file_contains install/ccc-provision-workstation.sh 'chmod 2775 "$CCC_SHARED_PROJECTS"'
require_file_contains install/ccc-provision-workstation.sh 'ln -s "$CCC_SHARED_PROJECTS" "$CCC_HOME/projects"'
require_file_contains install/ccc-provision-workstation.sh 'cat > /usr/local/bin/ccc-migrate-shared-workspace'
require_file_contains install/ccc-provision-workstation.sh 'ccc-migrate-shared-workspace --status'
require_file_contains install/ccc-provision-workstation.sh 'ccc-migrate-shared-workspace --apply'
require_file_contains install/ccc-provision-workstation.sh 'CCC_LEGACY_PROJECT_ROOTS="${CCC_LEGACY_PROJECT_ROOTS:-$CCC_HOME/projects:$CCC_HOME/repos}"'
require_file_contains install/ccc-provision-workstation.sh 'rsync -a "$CCC_HOME/projects/" "$CCC_SHARED_PROJECTS/"'
require_file_contains install/ccc-provision-workstation.sh 'mv "$CCC_HOME/projects" "$backup"'
require_file_contains install/ccc-provision-workstation.sh 'link_legacy_repos_root "$CCC_HOME/repos"'
require_file_contains install/ccc-provision-workstation.sh 'find "$CCC_SHARED_PROJECTS" -type d -exec chmod g+s {} +'
require_file_contains install/ccc-provision-workstation.sh 'if [[ -L "$entry" && -d "$entry" ]]; then'
require_file_contains install/ccc-provision-workstation.sh 'chgrp -R "$CCC_SHARED_GROUP" "$entry"/'
require_file_contains install/ccc-provision-workstation.sh '[[ -f "$CCC_HOME/.ssh/id_ed25519.pub" ]]'
require_file_contains install/ccc-provision-workstation.sh 'ccc-sync-agent-configs --user "$user"'
require_file_contains install/ccc-provision-workstation.sh '--all-users)'
require_file_contains install/ccc-provision-workstation.sh '--user requires a username'
require_file_contains install/ccc-provision-workstation.sh '# Land in the shared projects workspace on new interactive logins.'
# Multi-user permission model (delivered inside the updateable region)
require_file_contains install/ccc-provision-workstation.sh 'UMask=0002'
require_file_contains install/ccc-provision-workstation.sh '/usr/local/ccc-npm'
require_file_contains install/ccc-provision-workstation.sh 'prefix=$CCC_NPM_PREFIX'
require_file_contains install/ccc-provision-workstation.sh 'export NPM_CONFIG_PREFIX=/usr/local/ccc-npm'
require_file_contains install/ccc-provision-workstation.sh 'npm resolves prefix to shared dir'
require_file_contains install/ccc-provision-workstation.sh '/etc/ccc/.perms-model-v1'
require_file_contains install/ccc-provision-workstation.sh '── Shared Permissions'
# Project SSH keys: root-owned so a non-root agent can't revert a shared key.
require_file_contains install/ccc-provision-workstation.sh '/usr/local/bin/ccc-fix-key-perms'
require_file_contains install/ccc-provision-workstation.sh 'project SSH keys root-owned 0640'
bash -n install/ccc-provision-workstation.sh

# Project SSH key tamper-proofing (Go app)
require_file_contains container-code-companion/internal/system/ssh_keys.go 'func hardenProjectKeyOwnership'
require_file_contains container-code-companion/internal/system/ssh_keys.go 'ccc-fix-key-perms'

# Multi-user permission model (Go app)
require_file_contains container-code-companion/cmd/server/main.go 'syscall.Umask(0o002)'
require_file_contains container-code-companion/cmd/server/main.go 'system.EnsureSharedProjectsRoot()'
require_file_contains container-code-companion/internal/system/management.go 'func ensureSharedDirPerms'
require_file_contains container-code-companion/internal/system/management.go 'func EnsureSharedProjectsRoot'

legacy_product='agent-''workstation'
if git grep -n "$legacy_product" -- . ':!container-code-companion/web/vendor/*'; then
  fail "tracked files still reference the legacy product name"
fi
[[ ! -d "$legacy_product" ]] || fail "legacy product directory still exists"

require_file_contains ccc-bootstrap.sh "Container Code Companion"
require_file_contains README.md "Container Code Companion"
require_file_contains README.md "New Proxmox LXC"
require_file_contains README.md "Existing Debian or Ubuntu"
require_file_contains README.md "ccc-install-linux.sh"
require_file_contains README.md "does not change host networking or SSH hardening"
require_file_contains README.md "clone SSH or HTTPS Git repos"
require_file_contains README.md "pull fast-forward Git updates"
require_file_contains LICENSE "MIT License"
require_file_contains LICENSE "Copyright (c) 2026 Parallax Group"
require_file_contains container-code-companion/web/index.html "Container Code Companion"
require_file_contains container-code-companion/web/index.html "C.C.C"
require_file_contains container-code-companion/web/index.html "by Parallax Group"
require_file_contains container-code-companion/web/index.html "pllx.group"
require_file_contains container-code-companion/web/index.html "MIT License"
require_file_contains container-code-companion/web/index.html "custom-title-display"
require_file_contains container-code-companion/web/index.html "top-preferences-button"
require_file_contains container-code-companion/web/index.html "login-shell"
require_file_contains container-code-companion/web/index.html "login-brand-lockup"
require_file_contains container-code-companion/web/index.html "top-update-alert"
require_file_contains container-code-companion/web/index.html "app-shell"
require_file_contains container-code-companion/web/app.js "CCC_CUSTOM_TITLE_STORAGE_KEY"
require_file_contains container-code-companion/web/app.js "bindCustomTitle"
require_file_contains container-code-companion/web/app.js "/api/time-settings"
require_file_contains container-code-companion/web/app.js "renderTimeSettings"
require_file_contains container-code-companion/web/app.js "bindTimeSettings"
require_file_contains container-code-companion/web/app.js "timezone-input"
require_file_contains container-code-companion/web/app.js "document.body.classList.toggle('signed-out'"
require_file_contains container-code-companion/web/app.js "document.getElementById('app-shell').hidden = !signedIn"
require_file_contains container-code-companion/web/app.js "document.getElementById('login-shell').hidden = signedIn"
require_file_contains container-code-companion/web/styles.css ".brand-lockup"
require_file_contains container-code-companion/web/styles.css ".login-shell"
require_file_contains container-code-companion/web/styles.css ".login-brand-lockup"
require_file_contains container-code-companion/web/styles.css ".top-update-alert"
require_file_contains container-code-companion/web/styles.css "[hidden]"
require_file_contains container-code-companion/web/styles.css "display: none !important"
require_file_contains container-code-companion/web/styles.css "body.signed-out .topbar"
require_file_contains container-code-companion/web/styles.css ".custom-title-display"
require_file_contains container-code-companion/web/styles.css ".app-footer"
require_file_contains install/ccc-provision-workstation.sh "ccc-sync-agent-configs"
require_file_contains install/ccc-provision-workstation.sh "Shared Workspace"
require_file_contains install/ccc-provision-workstation.sh "ccc-migrate-shared-workspace --status"
require_file_contains install/ccc-provision-workstation.sh 'CCC_HOME="${CCC_HOME:-/home/$CCC_USER}"'
# Provider profiles (auth, sessions, history) are never mirrored between accounts.
require_file_not_contains install/ccc-provision-workstation.sh 'mirror_provider_profile'
require_file_contains install/ccc-provision-workstation.sh 'copy_optional_dir "$OCULUS_CONFIGS_DIR/claude/plugins" "$CCC_HOME/.claude/plugins" "Claude default plugins"'
require_file_contains install/ccc-provision-workstation.sh 'copy_optional_dir "$OCULUS_CONFIGS_DIR/claude/skills" "$CCC_HOME/.claude/skills" "Claude default skills"'
require_file_contains install/ccc-provision-workstation.sh 'copy_optional_dir "$OCULUS_CONFIGS_DIR/codex/plugins" "$CCC_HOME/.codex/plugins" "Codex default plugins"'
require_file_contains install/ccc-provision-workstation.sh 'git config --system safe.directory "*"'
require_file_contains install/ccc-provision-workstation.sh 'git -c "safe.directory=$OCULUS_CONFIGS_DIR" -C "$OCULUS_CONFIGS_DIR" fetch'
require_file_contains install/ccc-provision-workstation.sh 'step 28 "Agent configs (initial sync)"'
require_file_contains install/ccc-provision-workstation.sh 'NO_COLOR=1 /usr/local/bin/ccc-sync-agent-configs --user "$CCC_USER"'
require_file_contains install/ccc-provision-workstation.sh "/etc/ccc/ssh/github_ed25519"
require_file_contains install/ccc-provision-workstation.sh "Setup CCC Profile"
require_file_contains README.md "ccc-sync-agent-configs"
require_file_contains install/ccc-provision-workstation.sh "codex/AGENTS.md"
require_file_contains install/ccc-provision-workstation.sh "codex/skills"
require_file_contains install/ccc-provision-workstation.sh "gemini/GEMINI.md"
require_file_contains install/ccc-provision-workstation.sh "gemini/skills"
require_file_contains install/ccc-provision-workstation.sh "mcp.template.json"
require_file_contains install/ccc-provision-workstation.sh "NO_COLOR"
require_file_contains install/ccc-provision-workstation.sh "write_claude_baseline"
require_file_contains install/ccc-provision-workstation.sh "Claude settings written"
require_file_contains install/ccc-provision-workstation.sh "Claude statusline written"
require_file_contains install/ccc-provision-workstation.sh "bubblewrap"
require_file_contains install/ccc-provision-workstation.sh "GitHub CLI"
require_file_contains install/ccc-provision-workstation.sh "githubcli-archive-keyring.gpg"
require_file_contains install/ccc-provision-workstation.sh "/etc/apt/sources.list.d/github-cli.list"
require_file_contains install/ccc-provision-workstation.sh "https://cli.github.com/packages"
require_file_contains install/ccc-provision-workstation.sh "apt-get install -y -qq gh"
require_file_contains install/ccc-provision-workstation.sh 'command -v bwrap'
require_file_contains install/ccc-provision-workstation.sh 'command -v gh'
require_file_contains install/ccc-provision-workstation.sh 'command -v npm'
require_file_contains install/ccc-provision-workstation.sh "apt-get install -y -qq nodejs"
require_file_contains install/ccc-provision-workstation.sh 'command -v npm'
require_file_not_contains install/ccc-provision-workstation.sh "apt-get install -y -qq nodejs npm"
require_file_not_contains container-code-companion/internal/system/management.go "apt-get install -y nodejs npm"
require_file_contains install/ccc-provision-workstation.sh 'command -v tmux'
require_file_contains install/ccc-provision-workstation.sh 'command -v code-server'
require_file_contains README.md "bubblewrap"
require_file_contains README.md "GitHub CLI"
require_file_contains install/ccc-provision-workstation.sh "Ubuntu 26.04 Chromium support may lag Playwright releases"
require_file_contains install/ccc-provision-workstation.sh 'VERSION_ID:-}" == "26.04"'
require_file_contains README.md "Debian 13 is the safer CCC path when browser automation matters"
require_file_contains ccc-bootstrap.sh "1) Ubuntu 24.04 LTS  (default)"
require_file_contains ccc-bootstrap.sh "2) Ubuntu 26.04 LTS"
require_file_contains ccc-bootstrap.sh "3) Debian 13 (Trixie)"
require_file_contains ccc-bootstrap.sh 'ubuntu-24\.04-standard_24\.04-[0-9]+_amd64\.tar\.zst'
require_file_contains ccc-bootstrap.sh 'ubuntu-26\.04-standard_26\.04-[0-9]+_amd64\.tar\.zst'
require_file_contains ccc-bootstrap.sh 'debian-13-standard_13\.[0-9]+-[0-9]+_amd64\.tar\.zst'
require_file_contains README.md "Ubuntu 24.04 LTS (default), Ubuntu 26.04 LTS, or Debian 13"
require_file_contains install/ccc-provision-workstation.sh '"$schema": "https://json.schemastore.org/claude-code-settings.json"'
require_file_not_contains install/ccc-provision-workstation.sh "oculus-settings.json"
require_file_contains install/ccc-provision-workstation.sh '"statusLine": {'
require_file_contains install/ccc-provision-workstation.sh '"command": "~/.claude/bin/statusline-command.sh"'
require_file_not_contains install/ccc-provision-workstation.sh '"statusLine": "~/.claude/bin/statusline-command.sh"'
require_file_contains install/ccc-provision-workstation.sh 'if [[ ! -f "$CCC_HOME/.claude/settings.json" ]]'
require_file_contains install/ccc-provision-workstation.sh 'data["statusLine"] = sl'
require_file_contains install/ccc-provision-workstation.sh 'data.setdefault("$schema", "https://json.schemastore.org/claude-code-settings.json")'
require_file_contains install/ccc-provision-workstation.sh 'perms.setdefault("defaultMode", "bypassPermissions")'
require_file_contains install/ccc-provision-workstation.sh 'CCC_USER="${CCC_USER:-claude-code}"'
require_file_contains install/ccc-provision-workstation.sh 'mkdir -p "$CCC_HOME/.claude/bin"'
require_file_contains install/ccc-provision-workstation.sh 'cat > "$CCC_HOME/.claude/bin/statusline-command.sh"'
require_file_contains install/ccc-provision-workstation.sh 'chown_if_root "$CCC_USER:$CCC_USER" "$CCC_HOME/.claude/bin/statusline-command.sh"'
require_file_not_contains install/ccc-provision-workstation.sh 'cat > /home/claude-code/.claude/bin/statusline-command.sh'
require_file_contains install/ccc-provision-workstation.sh 'jq -r '\''.model.id // ""'\'''
require_file_contains install/ccc-provision-workstation.sh 'jq -r '\''.thinking.enabled // false'\'''
require_file_contains install/ccc-provision-workstation.sh 'jq -r '\''.context.used // 0'\'''
require_file_contains install/ccc-provision-workstation.sh 'jq -r '\''.context.max // 200000'\'''
require_file_contains install/ccc-provision-workstation.sh 'CTX_PCT=$(( CTX_USED * 100 / CTX_MAX ))'
require_file_contains install/ccc-provision-workstation.sh 'CTX_WARN="!!"'
require_file_contains install/ccc-provision-workstation.sh 'TIME=$(date +"%I:%M%p"'
require_file_contains container-code-companion/web/index.html "Terminal"
require_file_contains container-code-companion/web/index.html "Projects"
require_file_contains container-code-companion/web/index.html "mobile-menu-button"
require_file_contains container-code-companion/web/index.html "mobile-nav-overlay"
require_file_contains container-code-companion/web/index.html 'aria-controls="mobile-sidebar"'
require_file_contains container-code-companion/web/index.html "App Catalog"
require_file_contains container-code-companion/web/index.html "Map Drives"
require_file_contains container-code-companion/web/index.html 'data-section="notes"'
require_file_contains container-code-companion/web/index.html 'data-section="apps"'
require_file_contains container-code-companion/web/index.html 'data-section="drives"'
require_file_contains container-code-companion/web/index.html "oculus-configs"
require_file_contains container-code-companion/web/index.html "Dashboard"
require_file_contains container-code-companion/web/index.html "Workstation"
require_file_contains container-code-companion/web/index.html "System"
require_file_not_contains container-code-companion/web/index.html "Agents"
require_file_not_contains container-code-companion/web/index.html "Connections"
require_file_contains container-code-companion/web/index.html "Settings"
require_file_contains container-code-companion/web/index.html "Preferences"
require_file_contains install/ccc-provision-workstation.sh "container-code-companion.service"
require_file_contains install/ccc-provision-workstation.sh "/usr/local/bin/container-code-companion"
require_file_contains install/ccc-provision-workstation.sh "CONTAINER_CODE_COMPANION_USERNAME"
require_file_contains install/ccc-provision-workstation.sh "CONTAINER_CODE_COMPANION_PASSWORD"
require_file_contains install/ccc-provision-workstation.sh 'Container Code Companion uses the $CCC_USER user password'
require_file_contains install/ccc-provision-workstation.sh 'http://${_ccc_ui_ip}:9090'
require_file_not_contains install/ccc-provision-workstation.sh 'http://<ip>:9090'
require_file_contains install/ccc-provision-workstation.sh "CONTAINER_CODE_COMPANION_ADDR=0.0.0.0:9090"
require_file_contains install/ccc-provision-workstation.sh "systemctl disable --now ccc-dashboard"
require_file_contains install/ccc-provision-workstation.sh "fuser -k 9090/tcp"
require_file_contains install/ccc-provision-workstation.sh "systemctl disable --now cockpit.socket"
require_file_contains install/ccc-provision-workstation.sh "systemctl enable container-code-companion.service"
require_file_contains install/ccc-provision-workstation.sh "/var/log/ccc-self-update.log"
require_file_contains install/ccc-provision-workstation.sh "timeout 600 /usr/local/go/bin/go build"
require_file_contains install/ccc-provision-workstation.sh "CONTAINER_CODE_COMPANION_USERNAME"
require_file_contains install/ccc-provision-workstation.sh "Set CCC_USER in /etc/ccc/config"
require_file_contains install/ccc-provision-workstation.sh 'NO_COLOR'
require_file_contains install/ccc-provision-workstation.sh 'setsid systemctl restart container-code-companion.service'
require_file_contains install/ccc-provision-workstation.sh 'CCC_INSTALLED_COMMIT'
require_file_contains install/ccc-provision-workstation.sh 'Update available'
require_file_contains install/ccc-provision-workstation.sh "Self-update successful"
# ccc-self-update must also refresh the per-user Claude Code CLI for every
# account — the nightly auto-update runs ccc-self-update (not ccc-update), so
# without this each account's ~/.local/bin/claude never gets updated.
require_file_contains install/ccc-provision-workstation.sh 'Updating Claude Code CLI for all accounts'
require_file_contains install/ccc-provision-workstation.sh 'sudo -u "$_u" env HOME="$_h" "$_h/.local/bin/claude" update'
# Non-native (npm-style / dangling) installs must be migrated to the native
# installer, and Claude Code must never remain in the shared npm prefix.
require_file_contains install/ccc-provision-workstation.sh 'Migrating $_u to native Claude Code'
require_file_contains install/ccc-provision-workstation.sh 'curl -fsSL https://claude.ai/install.sh | bash'
require_file_contains install/ccc-provision-workstation.sh 'Removing Claude Code from the shared npm prefix'
require_file_contains install/ccc-provision-workstation.sh '/usr/local/ccc-npm/lib/node_modules/@anthropic-ai/claude-code'
require_file_contains install/ccc-provision-workstation.sh "-buildvcs=false"
require_file_contains install/ccc-provision-workstation.sh "Building Container Code Companion binary"
require_file_contains install/ccc-provision-workstation.sh 'timeout 600 "$GO" build -C "$SRC/container-code-companion"'
require_file_contains install/ccc-provision-workstation.sh '-C "$CONTAINER_CODE_COMPANION_SRC/container-code-companion"'
require_file_contains install/ccc-provision-workstation.sh 'git config --system safe.directory "*" 2>/dev/null || true'
require_file_contains install/ccc-provision-workstation.sh 'git -C "$SRC" remote set-url origin "$REPO_URL"'
require_file_not_contains install/ccc-provision-workstation.sh 'pct exec'
require_file_not_contains install/ccc-provision-workstation.sh 'pvesh '
require_file_contains install/ccc-provision-workstation.sh 'if [[ "$CCC_INSTALL_MODE" == "proxmox-lxc" ]]; then'
require_file_contains install/ccc-provision-workstation.sh 'if [[ "$CCC_MACHINE_POLICY" == "container" ]]; then'
require_file_contains install/ccc-provision-workstation.sh 'CCC_MACHINE_POLICY="${CCC_MACHINE_POLICY:-workstation}"'
require_file_contains install/ccc-provision-workstation.sh 'systemctl enable "$CCC_CODE_SERVER_SERVICE"'
require_file_contains install/ccc-provision-workstation.sh "Existing host timezone left unchanged."
require_file_contains install/ccc-provision-workstation.sh "Existing host package upgrade left to the machine owner."
require_file_contains install/ccc-provision-workstation.sh "Existing host MOTD scripts left enabled."
require_file_contains ccc-bootstrap.sh 'stage_workstation_provisioner'
require_file_contains ccc-bootstrap.sh '/tmp/ccc-provision-workstation.sh'
require_file_contains ccc-bootstrap.sh 'CCC_INSTALL_MODE=proxmox-lxc'
require_file_contains ccc-bootstrap.sh 'CCC_SELF_UPDATE_SCRIPT=ccc-bootstrap.sh'
require_file_contains container-code-companion/web/app.js "let activeUpdateTab = 'app'"
require_file_contains container-code-companion/web/app.js "let snapshotPollTimer = null"
require_file_contains container-code-companion/web/app.js "startSnapshotPolling"
require_file_contains container-code-companion/web/app.js "stopSnapshotPolling"
require_file_contains container-code-companion/web/app.js "pollSnapshot"
require_file_contains container-code-companion/web/app.js "setInterval(pollSnapshot, 30000)"
require_file_contains container-code-companion/web/app.js "currentSection === 'updates'"
require_file_contains container-code-companion/web/app.js "currentSection === 'overview'"
require_file_contains container-code-companion/web/app.js "refreshCCCUpdateStatus"
require_file_contains container-code-companion/web/app.js "maybeRefreshCCCUpdateStatus"
require_file_contains container-code-companion/web/app.js "lastCCCUpdateStatusCheck"
require_file_contains container-code-companion/web/app.js "cccUpdateStatusMessage"
require_file_contains container-code-companion/web/app.js "update-check-state"
require_file_contains container-code-companion/web/app.js "Checking GitHub with ccc-update-status"
require_file_contains container-code-companion/web/app.js "Last checked"
require_file_contains container-code-companion/web/app.js "summarizeCCCUpdateStatus"
require_file_contains container-code-companion/web/app.js "updateOverviewUpdateStatusPanel"
require_file_contains container-code-companion/web/app.js "updateTopbarUpdateAlert"
require_file_contains container-code-companion/web/app.js "\${statusTile('SSH'"
require_file_contains container-code-companion/web/styles.css "repeat(6, minmax(0, 1fr))"
require_file_not_contains container-code-companion/web/app.js "SSH Connections"
require_file_not_contains container-code-companion/web/app.js "renderSSHSessionRows"
require_file_contains container-code-companion/web/app.js "currentSection === 'overview'"
require_file_contains container-code-companion/web/app.js "Checking Container Code Companion update status"
require_file_contains container-code-companion/web/app.js "runActionForSnapshot('update-status')"
require_file_contains container-code-companion/web/app.js "data-update-tab=\"app\""
require_file_contains container-code-companion/web/app.js "data-update-tab=\"os\""
require_file_contains container-code-companion/web/app.js "Update App"
require_file_contains container-code-companion/web/app.js "Update OS"
require_file_contains container-code-companion/web/app.js "renderUpdateConsole"
require_file_not_contains container-code-companion/web/app.js "Refresh Container Code Companion Status"
require_file_contains container-code-companion/web/app.js "/api/self-update"
require_file_contains container-code-companion/web/app.js 'stripANSI'
require_file_contains container-code-companion/web/app.js "updateStatusBadge"
require_file_contains container-code-companion/web/app.js "runSelfUpdateStream"
require_file_contains container-code-companion/web/app.js "monitorReconnect"
require_file_contains container-code-companion/web/app.js "formatOSPackageStatus"
require_file_contains container-code-companion/web/app.js "No OS package updates available."
require_file_contains container-code-companion/web/app.js "Service restarting"
require_file_contains container-code-companion/web/app.js "Update finished successfully."
require_file_contains container-code-companion/web/app.js "Update finished successfully"
require_file_contains container-code-companion/web/app.js "data-config-edit"
require_file_contains container-code-companion/web/app.js "openAgentConfig"
require_file_contains container-code-companion/web/app.js "config-editor-panel"
require_file_contains container-code-companion/web/app.js "showConfigEditor"
require_file_contains container-code-companion/web/app.js "saveConfigFile"
require_file_contains container-code-companion/web/app.js "/api/file-upload"
require_file_contains container-code-companion/web/app.js "/api/file-download"
require_file_contains container-code-companion/web/app.js 'type="file"'
require_file_contains container-code-companion/web/app.js "uploadCurrentDirectory"
require_file_contains container-code-companion/web/app.js "downloadCurrentFile"
require_file_contains container-code-companion/web/app.js "file-upload-input"
require_file_contains container-code-companion/web/app.js "file-selection-download"
require_file_contains container-code-companion/web/app.js "downloadZip"
require_file_contains container-code-companion/web/app.js "file-copy-button"
require_file_contains container-code-companion/web/app.js "file-chmod-button"
require_file_contains container-code-companion/web/app.js "copyCurrentFile"
require_file_contains container-code-companion/web/app.js "chmodCurrentFile"
require_file_contains container-code-companion/web/app.js "selectedFilePath"
require_file_contains container-code-companion/web/app.js "renderFileBreadcrumbs"
require_file_contains container-code-companion/web/app.js "file-breadcrumbs"
require_file_contains container-code-companion/web/app.js "file-home-button"
require_file_contains container-code-companion/web/app.js "file-projects-button"
require_file_contains container-code-companion/web/app.js "file-refresh-button"
require_file_contains container-code-companion/web/app.js "data-file-breadcrumb"
require_file_contains container-code-companion/web/app.js "selectFileEntry"
require_file_contains container-code-companion/web/app.js "file-section-header"
require_file_contains container-code-companion/web/app.js "file-count"
require_file_contains container-code-companion/web/app.js "file-table-header"
require_file_contains container-code-companion/web/app.js "file-selected-detail"
require_file_contains container-code-companion/web/app.js "renderFileEntry"
require_file_contains container-code-companion/web/app.js "updateSelectedFileDetail"
require_file_contains container-code-companion/web/styles.css ".file-manager"
require_file_contains container-code-companion/web/styles.css ".file-breadcrumbs"
require_file_contains container-code-companion/web/styles.css ".file-row.selected"
require_file_contains container-code-companion/web/styles.css ".file-table-header"
require_file_contains container-code-companion/web/styles.css ".file-selected-detail"
require_file_contains container-code-companion/web/app.js "notes: 'Notes'"
require_file_contains container-code-companion/web/app.js "renderNotes"
require_file_contains container-code-companion/web/app.js "bindNotes"
require_file_contains container-code-companion/web/app.js "/api/notes"
require_file_contains container-code-companion/web/app.js "notes-list"
require_file_contains container-code-companion/web/app.js "notes-editor"
require_file_contains container-code-companion/web/app.js "notes-title-input"
require_file_contains container-code-companion/web/app.js "notes-save-button"
require_file_contains container-code-companion/web/app.js "notes-delete-button"
require_file_contains container-code-companion/web/app.js "Unsaved changes."
require_file_contains container-code-companion/web/app.js "Discard unsaved note changes?"
require_file_contains container-code-companion/web/styles.css ".notes-layout"
require_file_contains container-code-companion/web/styles.css ".note-row.active"
require_file_contains container-code-companion/internal/server/server.go "/api/notes"
require_file_contains container-code-companion/internal/server/server.go "handleNotes"
require_file_contains container-code-companion/internal/server/server.go "/api/time-settings"
require_file_contains container-code-companion/internal/server/server.go "handleTimeSettings"
require_file_contains container-code-companion/internal/system/notes.go "type Note struct"
require_file_contains container-code-companion/internal/system/notes.go 'filepath.Join(workstationHome(), ".ccc", "notes.json")'
require_file_contains container-code-companion/internal/system/notes.go "os.Rename"
require_file_contains container-code-companion/internal/system/time.go "type TimeSettings struct"
require_file_contains container-code-companion/internal/system/time.go "sudo timedatectl set-timezone"
require_file_contains container-code-companion/web/app.js "resetTerminalConnection"
require_file_contains container-code-companion/web/app.js "removeEventListener('resize', resizeTerminal)"
require_file_contains container-code-companion/web/app.js "terminalTabs"
require_file_contains container-code-companion/web/app.js "New Tab"
require_file_contains container-code-companion/web/app.js "stopTerminalSessions"
require_file_contains container-code-companion/web/app.js "TERMINAL_HEIGHT_STORAGE_KEY"
require_file_contains container-code-companion/web/app.js "terminal-height-slider"
require_file_contains container-code-companion/web/app.js "applyTerminalHeight"
require_file_contains container-code-companion/web/app.js "bindTerminalHeightControls"
require_file_contains container-code-companion/web/app.js "fitTerminalToPane"
require_file_contains container-code-companion/web/app.js "terminalCellSize"
require_file_contains container-code-companion/web/app.js "requestAnimationFrame(resizeTerminal)"
require_file_contains container-code-companion/web/app.js "tab.terminal.resize(cols, rows)"
require_file_contains container-code-companion/web/styles.css "--terminal-height"
require_file_contains container-code-companion/web/styles.css ".terminal-pane .xterm"
require_file_not_contains container-code-companion/web/styles.css ".terminal-pane .xterm-screen {"
require_file_contains container-code-companion/web/app.js "addExistingProject"
require_file_contains container-code-companion/web/app.js "add-existing"
require_file_contains container-code-companion/web/app.js "existing-project-name"
require_file_contains container-code-companion/web/app.js "existing-project-path"
require_file_contains container-code-companion/web/app.js "Add Existing Directory"
require_file_contains container-code-companion/web/app.js "Clone Repository"
require_file_contains container-code-companion/web/app.js "project-clone-remote"
require_file_contains container-code-companion/web/app.js "project-clone-controls"
require_file_contains container-code-companion/web/app.js "cloneProject"
require_file_contains container-code-companion/web/app.js "data-project-pull"
require_file_contains container-code-companion/web/app.js "pullProject"
require_file_contains container-code-companion/web/app.js "Project root"
require_file_contains container-code-companion/web/app.js "Permission health"
require_file_contains container-code-companion/web/app.js "Shared Workspace"
require_file_contains container-code-companion/web/app.js "Check Migration"
require_file_contains container-code-companion/web/app.js "Migrate Existing Projects"
require_file_contains container-code-companion/web/app.js "Migrate existing projects into the shared workspace?"
require_file_contains container-code-companion/web/app.js "shared-workspace-status"
require_file_contains container-code-companion/web/app.js "shared-workspace-apply"
require_file_contains container-code-companion/web/app.js "showProjectOutput"
require_file_contains container-code-companion/web/app.js "Repair Permissions"
require_file_contains container-code-companion/web/app.js "repair-permissions"
require_file_contains container-code-companion/web/index.html "custom-title-edit"
require_file_contains container-code-companion/web/app.js "focusHeaderMessageEditor"
require_file_contains container-code-companion/internal/system/management.go 'Path      string `json:"path"`'
require_file_contains container-code-companion/internal/system/management.go 'Mode      string `json:"mode"`'
require_file_contains container-code-companion/internal/system/management.go 'case "copy"'
require_file_contains container-code-companion/internal/system/management.go 'case "chmod"'
require_file_contains container-code-companion/internal/system/management.go 'case "add-existing"'
require_file_contains container-code-companion/internal/system/management.go 'case "clone"'
require_file_contains container-code-companion/internal/system/management.go 'case "pull"'
require_file_contains container-code-companion/internal/system/management.go 'func projectListingRoot'
require_file_contains container-code-companion/internal/system/management.go 'filepath.Join(home, "repos")'
require_file_contains container-code-companion/internal/system/management.go 'case "repair-permissions"'
require_file_contains container-code-companion/internal/system/management.go 'sudo chgrp -R'
require_file_contains container-code-companion/internal/system/management.go 'sudo chmod -R g+rwX'
require_file_contains container-code-companion/internal/system/management.go 'sudo find'
require_file_contains container-code-companion/internal/system/management.go 'sharedProjectPermissionRepairCommand'
require_file_contains container-code-companion/internal/system/management.go 'if [ -L \"$entry\" ] && [ -d \"$entry\" ]; then sudo chgrp -R'
require_file_contains container-code-companion/internal/system/management.go "os.Symlink"
require_file_contains container-code-companion/internal/server/server.go "/api/tools"
require_file_contains container-code-companion/internal/server/server.go "/api/drive"
require_file_contains container-code-companion/internal/system/management.go "type ToolStatus struct"
require_file_contains container-code-companion/internal/system/management.go "func CollectToolStatuses"
require_file_contains container-code-companion/internal/system/management.go 'UpdateAvailable bool'
require_file_contains container-code-companion/internal/system/management.go 'UpdateStatus    string'
require_file_contains container-code-companion/internal/system/management.go 'SSHSessions   SSHSessionSummary'
require_file_contains container-code-companion/internal/system/management.go 'type SSHSessionSummary struct'
require_file_contains container-code-companion/internal/system/management.go 'parseWhoSSHSessions'
require_file_contains container-code-companion/internal/system/management.go 'parseSSHDSessionProcesses'
require_file_contains container-code-companion/internal/system/management.go 'ps", "-eo", "args"'
require_file_contains container-code-companion/internal/system/management.go 'sshd(?:-session)?'
require_file_contains container-code-companion/internal/system/management.go 'notty'
require_file_contains container-code-companion/internal/system/management.go 'func aptUpdateCheck'
require_file_contains container-code-companion/internal/system/management.go 'func toolUpdateAvailable'
require_file_contains container-code-companion/internal/system/management.go 'Name: "uv"'
require_file_contains container-code-companion/internal/system/management.go 'Name: "claude"'
require_file_contains container-code-companion/internal/system/management.go 'Name: "gemini"'
require_file_not_contains container-code-companion/internal/system/management.go 'Name: "ollama"'
require_file_contains container-code-companion/internal/system/management.go 'Name: "aider"'
require_file_contains container-code-companion/internal/system/management.go 'Name: "ripgrep"'
require_file_contains container-code-companion/internal/system/management.go "func RunDriveOperation"
require_file_contains container-code-companion/internal/system/management.go "func explainDriveMountFailure"
require_file_contains container-code-companion/internal/system/management.go "LXC mount note"
require_file_contains container-code-companion/internal/system/management.go "Linux host mount note"
require_file_contains container-code-companion/internal/system/management.go "CCC_INSTALL_MODE"
require_file_contains container-code-companion/internal/system/management.go "drive mount failed"
require_file_not_contains container-code-companion/web/app.js "section !== 'terminal') {"
require_file_contains container-code-companion/web/app.js "username is required"
require_file_contains container-code-companion/web/app.js "Setup CCC Profile"
require_file_contains container-code-companion/web/app.js "Sync Account Configs"
require_file_contains container-code-companion/web/app.js "Sync All Account Configs"
require_file_contains container-code-companion/web/app.js "showAccountOutput"
require_file_contains container-code-companion/web/app.js "account updated"
require_file_contains container-code-companion/web/app.js "setup-ccc-profile"
require_file_contains container-code-companion/web/app.js "sync-agent-configs"
require_file_contains container-code-companion/web/app.js "gh auth login"
require_file_contains container-code-companion/web/app.js "data-nav-updates"
require_file_contains container-code-companion/web/app.js "copyTextToClipboard"
require_file_contains container-code-companion/web/app.js "fallbackCopyText"
require_file_contains container-code-companion/web/app.js "Copy Failed"
require_file_contains container-code-companion/web/app.js "copyGitHubPublicKey"
require_file_contains container-code-companion/web/app.js "github-action-row"
require_file_contains container-code-companion/internal/system/management.go 'return "/etc/ccc/ssh/github_ed25519"'
require_file_contains container-code-companion/internal/system/management.go 'case "configure-users"'
require_file_contains container-code-companion/internal/system/management.go 'case "promote-current-user-key"'
require_file_contains container-code-companion/internal/system/management.go 'case "setup-ccc-profile"'
require_file_contains container-code-companion/internal/system/management.go 'case "sync-agent-configs"'
require_file_contains container-code-companion/internal/system/management.go 'case "sync-all-agent-configs"'
require_file_contains container-code-companion/internal/system/management.go 'case "shared-workspace-status"'
require_file_contains container-code-companion/internal/system/management.go 'case "shared-workspace-apply"'
require_file_contains container-code-companion/internal/system/management.go 'CCC shell projects login'
require_file_contains container-code-companion/internal/system/management.go 'CCC shell environment'
require_file_contains container-code-companion/internal/system/management.go 'https://claude.ai/install.sh | bash'
require_file_contains container-code-companion/internal/system/management.go 'Profile ready. First-login checklist'
require_file_contains container-code-companion/internal/system/management.go 'agentConfigSyncCommand'
require_file_contains container-code-companion/internal/system/management.go 'allAgentConfigSyncCommand'
require_file_contains container-code-companion/internal/system/management.go '/usr/local/bin/ccc-sync-agent-configs --user '
require_file_contains container-code-companion/internal/system/management.go '/usr/local/bin/ccc-sync-agent-configs --all-users'
require_file_contains container-code-companion/internal/system/management.go 'sudo chgrp " + shellQuote(group) + " " + shellQuote(home)'
require_file_contains container-code-companion/internal/system/management.go 'sudo chmod g+rx " + shellQuote(home)'
require_file_contains container-code-companion/internal/system/management.go 'sudo test -x " + shellQuote(home+"/.local/bin/claude")'
require_file_contains container-code-companion/internal/system/management.go 'test -x /usr/local/ccc-npm/bin/codex'
require_file_contains container-code-companion/internal/system/management.go 'test -x /usr/local/ccc-npm/bin/gemini'
# Tool catalog: Codex/Gemini are shared CLIs — versions and update checks must
# target /usr/local/ccc-npm, never a per-user "$HOME/.local" npm prefix.
require_file_contains container-code-companion/internal/system/management.go 'func npmSharedUpdateCheck'
require_file_contains container-code-companion/internal/system/management.go 'npm outdated -g --prefix /usr/local/ccc-npm'
require_file_contains container-code-companion/internal/system/management.go '/usr/local/ccc-npm/bin/codex --version'
require_file_contains container-code-companion/internal/system/management.go '/usr/local/ccc-npm/bin/gemini --version'
require_file_not_contains container-code-companion/internal/system/management.go 'prefix \"$HOME/.local\"'
# Self-update purges stale per-user Codex/Gemini copies that shadow the shared
# prefix, and the UI-invoked installers suppress ANSI colors off-terminal.
require_file_contains install/ccc-provision-workstation.sh '"$_ccc_user_home/.local/bin/codex" "$_ccc_user_home/.local/bin/gemini"'
require_file_contains install/ccc-provision-workstation.sh 'if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then'
# ccc-update-status must not pick the device SSH key when running as its owner
# (root/cron) — ssh refuses group-readable keys for the owner, which used to
# kill the status check silently and made the 3 AM cron re-install nightly.
require_file_contains install/ccc-provision-workstation.sh 'if [[ -r "$CCC_SSH_KEY" && ! -O "$CCC_SSH_KEY" ]]; then'
require_file_contains install/ccc-provision-workstation.sh 'env -u GIT_SSH_COMMAND git ls-remote "https://github.com/${REPO_URL#git@github.com:}"'
# ccc-auto-update needs an affirmative update signal; a failed status check
# must skip, not trigger a full self-update.
require_file_contains install/ccc-provision-workstation.sh 'grep -Eq "Update available\.|No version recorded"'
# The web UI delegates sync to the installed script — no inlined copy, and
# provider profiles (auth, sessions, history) are never mirrored between accounts.
require_file_not_contains container-code-companion/internal/system/management.go 'directAgentConfigSyncScript'
require_file_not_contains container-code-companion/internal/system/management.go 'mirror_provider_profile'
require_file_contains container-code-companion/internal/system/management.go 'git config --system safe.directory \"*\"'
require_file_contains container-code-companion/internal/system/management.go 'safe.directory=" + dir'
require_file_contains container-code-companion/internal/system/management.go 'listFilesWithError'
require_file_contains container-code-companion/internal/system/management.go 'Codex skills'
require_file_contains container-code-companion/internal/system/management.go 'Gemini skills'
require_file_contains container-code-companion/web/app.js 'c.isDir'
require_file_contains container-code-companion/web/app.js 'function stripANSI'
require_file_contains container-code-companion/web/app.js 'replace(/\[(?:\d{1,2};)*\d{1,2}m/g,'
require_file_contains install/ccc-provision-workstation.sh 'cd "$HOME/projects" || true'
require_file_contains container-code-companion/internal/system/management.go 'sharedWorkspaceMigrationCommand'
require_file_contains container-code-companion/internal/system/management.go 'Migration command is not installed yet'
require_file_contains container-code-companion/internal/system/management.go 'IdentityFile " + keyPath'
require_file_contains container-code-companion/internal/system/management.go 'ssh", "-T", "-o", "StrictHostKeyChecking=accept-new"'
require_file_contains container-code-companion/web/app.js '<button class="small-button" id="github-copy-btn" disabled>Copy Machine Public Key</button>'
require_file_contains container-code-companion/web/app.js 'id="github-configure-btn"'
require_file_contains container-code-companion/web/app.js 'id="github-promote-btn"'
require_file_contains container-code-companion/web/app.js 'Configure For All Work Identities'
require_file_contains container-code-companion/web/app.js 'Promote Current User Key'
require_file_not_contains container-code-companion/web/app.js ".catch(() => {})"
require_file_contains container-code-companion/web/app.js "network-legend"
require_file_contains container-code-companion/web/app.js "Persistent network changes"
require_file_contains container-code-companion/web/app.js "Proxmox host"
require_file_contains container-code-companion/web/app.js "/api/account"
require_file_contains container-code-companion/web/app.js "/api/network-activity"
require_file_contains container-code-companion/web/app.js "drawNetworkGraph"
require_file_contains container-code-companion/internal/server/server.go "handleAccount"
require_file_contains container-code-companion/internal/server/server.go "handleNetworkActivity"
require_file_contains container-code-companion/internal/server/server.go "handleSelfUpdate"
require_file_contains container-code-companion/internal/system/management.go "func RunAccountOperation"
require_file_contains container-code-companion/internal/system/management.go "func CollectNetworkActivity"
require_file_contains container-code-companion/internal/system/management.go "func StartSelfUpdate"
require_file_contains container-code-companion/internal/system/management.go "Container Code Companion self-update started."
require_file_contains container-code-companion/internal/system/management.go "setsid env NO_COLOR=1 ccc-self-update"
require_file_contains container-code-companion/internal/system/management.go "sudo tail -120 /var/log/ccc-self-update.log"
require_file_contains container-code-companion/internal/server/server.go "Cache-Control"
require_file_contains container-code-companion/web/app.js '\x1b\['
require_file_not_contains container-code-companion/web/app.js '(?:\x1b)?'
require_file_not_contains container-code-companion/web/app.js '`http://${location.hostname}'
require_file_not_contains container-code-companion/web/app.js 'formatPercent'

require_file_contains install/ccc-provision-workstation.sh 'CCC_SELF_UPDATE_REF="${CCC_SELF_UPDATE_REF:-main}"'
require_file_not_contains install/ccc-provision-workstation.sh 'container-code-companion-native-ui'
require_file_not_contains install/ccc-provision-workstation.sh "/opt/ccc-dashboard"
require_file_not_contains install/ccc-provision-workstation.sh "node-pty"
require_file_not_contains install/ccc-provision-workstation.sh "dashboard-token"
require_file_not_contains install/ccc-provision-workstation.sh "oculus-configure"
require_file_not_contains install/ccc-provision-workstation.sh "configure.py"
require_file_not_contains install/ccc-provision-workstation.sh "localhost:4827"
require_file_not_contains README.md "localhost:4827"

require_ordered_patterns() {
  local file=$1
  shift
  local previous=0
  local pattern line
  for pattern in "$@"; do
    line=$(grep -nF "$pattern" "$file" | head -1 | cut -d: -f1)
    [[ -n "$line" ]] || fail "$file missing ordered pattern: $pattern"
    if (( line <= previous )); then
      fail "$file has pattern out of order: $pattern"
    fi
    previous=$line
  done
}

require_ordered_patterns container-code-companion/web/index.html \
  '<div class="nav-heading">Dashboard</div>' 'data-section="overview"' 'data-section="updates"' \
  '<div class="nav-heading">Workstation</div>' 'data-section="apps"' 'data-section="files"' 'data-section="drives"' 'data-section="notes"' 'data-section="projects"' 'data-section="terminal"' \
  '<div class="nav-heading">System</div>' 'data-section="accounts"' 'data-section="logs"' 'data-section="network"' 'data-section="services"' \
  '<div class="nav-heading">Settings</div>' 'data-section="github"' 'data-section="ssh-keys"' 'data-section="oculus"' 'data-section="settings"' 'data-section="configs"'

require_ordered_patterns container-code-companion/web/app.js \
  '<p id="tool-status"' '<pre id="tool-output"' '<div id="tool-catalog"'

require_ordered_patterns container-code-companion/web/app.js \
  'id="github-copy-btn"' 'id="github-test-btn"' 'id="github-generate-btn"'

awk '/SELFUPDATESCRIPT/{flag=!flag; next} flag{print}' install/ccc-provision-workstation.sh > /tmp/ccc-self-update.syntax
bash -n /tmp/ccc-self-update.syntax
awk '/UPDATESTATUSSCRIPT/{flag=!flag; next} flag{print}' install/ccc-provision-workstation.sh > /tmp/ccc-update-status.syntax
bash -n /tmp/ccc-update-status.syntax
node tests/update-status-ui.test.mjs

awk '/cat > .*statusline-command.sh.*CLAUDESTATUSLINE/{flag=1; next} /^CLAUDESTATUSLINE$/{flag=0} flag{print}' install/ccc-provision-workstation.sh > /tmp/ccc-statusline.syntax
bash -n /tmp/ccc-statusline.syntax
statusline_test_bin=$(mktemp -d)
cat > "$statusline_test_bin/jq" <<'FAKEJQ'
#!/usr/bin/env bash
case "$*" in
  *".model.id"*) echo "claude-sonnet-4-20250514" ;;
  *".thinking.enabled"*) echo "true" ;;
  *".context.used"*) echo "120000" ;;
  *".context.max"*) echo "200000" ;;
  *) echo "" ;;
esac
FAKEJQ
chmod +x "$statusline_test_bin/jq"
statusline_output=$(
  printf '%s\n' '{"model":{"id":"claude-sonnet-4-20250514"},"thinking":{"enabled":true},"context":{"used":120000,"max":200000}}' \
    | PATH="$statusline_test_bin:$PATH" USER=test HOME="$PWD" bash /tmp/ccc-statusline.syntax
)
rm -rf "$statusline_test_bin"
[[ "$statusline_output" == test@* ]] || fail "statusline output missing user/host prefix"
[[ "$statusline_output" == *"[sonnet-4 | think] [ctx:60%!]"* ]] || fail "statusline output missing model/thinking/context warning: $statusline_output"

# Task 1: CSS Prism palette
require_file_contains container-code-companion/web/styles.css '--topbar'
require_file_contains container-code-companion/web/styles.css '--panel2'
require_file_contains container-code-companion/web/styles.css '--accent-bg'
require_file_contains container-code-companion/web/styles.css '#060d16'
require_file_contains container-code-companion/web/styles.css 'IBM Plex Mono'
require_file_contains container-code-companion/web/styles.css 'settings-swatch-row'
require_file_contains container-code-companion/web/styles.css 'grid-template-columns: repeat(auto-fit'
require_file_contains container-code-companion/web/styles.css '.time-settings-grid'
require_file_contains container-code-companion/web/styles.css '.update-tabs'
require_file_contains container-code-companion/web/styles.css '.update-console'
require_file_not_contains container-code-companion/web/styles.css '#17191c'
require_file_not_contains container-code-companion/web/styles.css '#24282d'
require_file_not_contains container-code-companion/web/styles.css '#3f454d'
require_file_not_contains container-code-companion/web/styles.css '#a7adb5'
require_file_not_contains container-code-companion/web/styles.css '#111316'
require_file_not_contains container-code-companion/web/styles.css '#1b1e22'
require_file_not_contains container-code-companion/web/styles.css '#050608'

# Task 2: index.html
require_file_contains container-code-companion/web/index.html 'IBM+Plex+Mono'
require_file_contains container-code-companion/web/index.html 'data-section="settings"'

# Task 3: JS theme engine
require_file_contains container-code-companion/web/app.js 'const THEMES'
require_file_contains container-code-companion/web/app.js 'applyTheme'
require_file_contains container-code-companion/web/app.js 'loadTheme'
require_file_contains container-code-companion/web/app.js 'ccc-theme'
require_file_contains container-code-companion/web/app.js 'hexToRgb'

# Task 4: Settings page
require_file_contains container-code-companion/web/app.js 'renderSettings'
require_file_contains container-code-companion/web/app.js 'bindSettings'
require_file_contains container-code-companion/web/index.html 'data-section="ssh-keys"'
require_file_contains container-code-companion/web/app.js "'ssh-keys': 'SSH Key Inventory'"
require_file_contains container-code-companion/web/app.js "'ssh-keys': renderSSHKeyInventoryPage"
require_file_contains container-code-companion/web/app.js "if (section === 'ssh-keys')"
require_file_contains container-code-companion/web/app.js 'function renderSSHKeyInventoryPage()'
require_file_contains container-code-companion/web/app.js 'function bindSSHKeyInventoryPage()'
projects_renderer=$(sed -n '/^function renderProjects()/,/^function renderConfigs()/p' container-code-companion/web/app.js)
projects_binder=$(sed -n '/^function bindProjects()/,/^async function repairProjectPermissions()/p' container-code-companion/web/app.js)
[[ "$projects_renderer" != *'ssh-key-inventory-placeholder'* ]] || fail "Projects renderer still contains SSH Key Inventory"
[[ "$projects_binder" != *'loadSSHKeyInventory()'* ]] || fail "Projects binder still loads SSH Key Inventory"
require_file_contains container-code-companion/web/app.js 'renderAppCatalog'
require_file_contains container-code-companion/web/app.js 'renderMapDrives'
require_file_contains container-code-companion/web/app.js 'loadToolCatalog'
require_file_contains container-code-companion/web/app.js 'tool-refresh-button'
require_file_contains container-code-companion/web/app.js 'tool-status'
require_file_contains container-code-companion/web/app.js 'tool.updateStatus'
require_file_contains container-code-companion/web/app.js 'tool.updateAvailable'
require_file_not_contains container-code-companion/web/app.js "panel.textContent = 'Checking installed tools and updates...'"
require_file_contains container-code-companion/web/app.js 'mountDrive'
require_file_contains container-code-companion/web/app.js 'For Proxmox LXC containers'
require_file_contains container-code-companion/web/app.js 'mount fails with permission denied'
require_file_contains container-code-companion/web/app.js '/api/tools'
require_file_contains container-code-companion/web/app.js '/api/drive'
require_file_contains container-code-companion/web/app.js 'data-tmux-command'
require_file_contains container-code-companion/web/app.js 'tmux split-window -h'
require_file_contains container-code-companion/web/app.js 'updateOverviewLive'
require_file_contains container-code-companion/web/app.js 'updateGauge'
require_file_contains container-code-companion/web/app.js 'settings-swatch'
require_file_contains container-code-companion/web/app.js 'bindCustomTitleEditor'
require_file_contains container-code-companion/web/app.js 'custom-title-input'
require_file_contains container-code-companion/web/app.js 'custom-title-reset'
require_file_contains container-code-companion/web/app.js 'top-preferences-button'
require_file_contains container-code-companion/web/app.js 'toggleMobileNav'
require_file_contains container-code-companion/web/app.js 'closeMobileNav'
require_file_contains container-code-companion/web/app.js 'mobile-nav-open'
require_file_contains container-code-companion/web/app.js "settings: 'Preferences'"
require_file_contains container-code-companion/web/app.js "configs: 'Provider Configs'"
require_file_contains container-code-companion/web/app.js "apps: 'App Catalog'"
require_file_contains container-code-companion/web/app.js "drives: 'Map Drives'"
require_file_contains container-code-companion/web/index.html "Provider Configs"
require_file_not_contains container-code-companion/web/index.html "Agent Configs"
require_file_contains container-code-companion/web/app.js 'DISPLAY_EFFECTS_STORAGE_KEY'
require_file_contains container-code-companion/web/app.js 'ccc-display-effects'
require_file_contains container-code-companion/web/app.js 'loadDisplayEffects'
require_file_contains container-code-companion/web/app.js 'applyDisplayEffects'
require_file_contains container-code-companion/web/styles.css '.tool-catalog'
require_file_contains container-code-companion/web/styles.css '.tool-meta'
require_file_contains container-code-companion/web/styles.css '.settings-title-form'
require_file_contains container-code-companion/web/styles.css '.github-action-row'
require_file_contains container-code-companion/web/styles.css '.small-button:disabled'
require_file_contains container-code-companion/web/styles.css '.mobile-menu-button'
require_file_contains container-code-companion/web/styles.css '.mobile-menu-button span:nth-child(1)'
require_file_contains container-code-companion/web/styles.css '.mobile-nav-overlay'
require_file_contains container-code-companion/web/styles.css 'body.mobile-nav-open .sidebar'
require_file_contains container-code-companion/web/styles.css 'transform: translateX(-104%)'
require_file_contains container-code-companion/web/styles.css '.drive-form'
require_file_contains container-code-companion/web/app.js 'effect-flicker'
require_file_contains container-code-companion/web/app.js 'effect-sync-drift'
require_file_contains container-code-companion/web/app.js 'terminal-effects-suppressed'
require_file_contains container-code-companion/web/app.js "section === 'terminal'"
require_file_contains container-code-companion/web/app.js 'data-display-effect="flicker"'
require_file_contains container-code-companion/web/app.js 'data-display-effect="syncDrift"'
require_file_contains container-code-companion/web/styles.css 'crt-flicker'
require_file_contains container-code-companion/web/styles.css 'crt-sync-drift'
require_file_contains container-code-companion/web/styles.css 'body.effect-flicker::before'
require_file_contains container-code-companion/web/styles.css 'body.effect-sync-drift .layout::after'
require_file_contains container-code-companion/web/styles.css 'body.terminal-effects-suppressed.effect-flicker::before'
require_file_contains container-code-companion/web/styles.css 'body.terminal-effects-suppressed::after'
require_file_contains container-code-companion/web/styles.css 'body.terminal-effects-suppressed.effect-sync-drift .layout::after'
require_file_contains container-code-companion/web/styles.css '@media (prefers-reduced-motion: reduce)'

# Task 5: Network graph accent
require_file_not_contains container-code-companion/web/app.js "'#68a6f8'"
require_file_not_contains container-code-companion/web/styles.css '#68a6f8'

# Visual polish
require_file_contains container-code-companion/web/styles.css 'pulse-dot'
require_file_contains container-code-companion/web/styles.css 'section-fade'
require_file_contains container-code-companion/web/styles.css 'section-enter'
require_file_contains container-code-companion/web/styles.css 'drop-shadow'
require_file_contains container-code-companion/web/styles.css 'scanlines'
require_file_contains container-code-companion/web/app.js 'animateGauges'
require_file_contains container-code-companion/web/app.js '--accent-rgb'
require_file_contains container-code-companion/web/app.js 'section-enter'
require_file_contains container-code-companion/web/app.js 'health.online'

echo "container-code-companion static checks passed"
