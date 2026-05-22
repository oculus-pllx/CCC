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
[[ -f install/ccc-provision-workstation.sh ]] || fail "missing shared workstation provisioner"
require_file_contains install/ccc-provision-workstation.sh 'CCC_INSTALL_MODE="${CCC_INSTALL_MODE:?'
require_file_contains install/ccc-provision-workstation.sh 'CCC_USER="${CCC_USER:?'
require_file_contains install/ccc-provision-workstation.sh 'CCC_HOME="${CCC_HOME:?'
require_file_contains install/ccc-provision-workstation.sh 'CCC_SELF_UPDATE_SCRIPT="${CCC_SELF_UPDATE_SCRIPT:?'
require_file_contains install/ccc-provision-workstation.sh 'CCC_MACHINE_POLICY="${CCC_MACHINE_POLICY:-workstation}"'
require_file_contains install/ccc-provision-workstation.sh 'CCC_INSTALL_MODE="$CCC_INSTALL_MODE"'
require_file_contains install/ccc-provision-workstation.sh 'case "$CCC_INSTALL_MODE" in'
require_file_contains install/ccc-provision-workstation.sh 'proxmox-lxc|linux-host)'
bash -n install/ccc-provision-workstation.sh

legacy_product='agent-''workstation'
if git grep -n "$legacy_product" -- . ':!container-code-companion/web/vendor/*'; then
  fail "tracked files still reference the legacy product name"
fi
[[ ! -d "$legacy_product" ]] || fail "legacy product directory still exists"

require_file_contains ccc-bootstrap.sh "Container Code Companion"
require_file_contains README.md "Container Code Companion"
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
require_file_contains container-code-companion/web/styles.css "[hidden]"
require_file_contains container-code-companion/web/styles.css "display: none !important"
require_file_contains container-code-companion/web/styles.css "body.signed-out .topbar"
require_file_contains container-code-companion/web/styles.css ".custom-title-display"
require_file_contains container-code-companion/web/styles.css ".app-footer"
require_file_contains install/ccc-provision-workstation.sh "ccc-sync-agent-configs"
require_file_contains README.md "ccc-sync-agent-configs"
require_file_contains install/ccc-provision-workstation.sh "codex/AGENTS.md"
require_file_contains install/ccc-provision-workstation.sh "gemini/GEMINI.md"
require_file_contains install/ccc-provision-workstation.sh "mcp.template.json"
require_file_contains install/ccc-provision-workstation.sh "bubblewrap"
require_file_contains install/ccc-provision-workstation.sh "GitHub CLI"
require_file_contains install/ccc-provision-workstation.sh "githubcli-archive-keyring.gpg"
require_file_contains install/ccc-provision-workstation.sh "/etc/apt/sources.list.d/github-cli.list"
require_file_contains install/ccc-provision-workstation.sh "https://cli.github.com/packages"
require_file_contains install/ccc-provision-workstation.sh "apt-get install -y -qq gh"
require_file_contains install/ccc-provision-workstation.sh 'command -v bwrap'
require_file_contains install/ccc-provision-workstation.sh 'command -v gh'
require_file_contains install/ccc-provision-workstation.sh 'command -v npm'
require_file_contains install/ccc-provision-workstation.sh 'command -v tmux'
require_file_contains install/ccc-provision-workstation.sh 'command -v code-server'
require_file_contains README.md "bubblewrap"
require_file_contains README.md "GitHub CLI"
require_file_contains install/ccc-provision-workstation.sh '"$schema": "https://json.schemastore.org/claude-code-settings.json"'
require_file_not_contains install/ccc-provision-workstation.sh "oculus-settings.json"
require_file_contains install/ccc-provision-workstation.sh '"statusLine": {'
require_file_contains install/ccc-provision-workstation.sh '"command": "~/.claude/bin/statusline-command.sh"'
require_file_not_contains install/ccc-provision-workstation.sh '"statusLine": "~/.claude/bin/statusline-command.sh"'
require_file_contains install/ccc-provision-workstation.sh 'CLAUDE_SETTINGS="$CCC_HOME/.claude/settings.json"'
require_file_contains install/ccc-provision-workstation.sh 'data["statusLine"] = {"command": status_line}'
require_file_contains install/ccc-provision-workstation.sh 'data["$schema"] = "https://json.schemastore.org/claude-code-settings.json"'
require_file_contains install/ccc-provision-workstation.sh "CCC Statusline"
require_file_contains install/ccc-provision-workstation.sh 'step 20 "Statusline"'
require_file_contains install/ccc-provision-workstation.sh 'CCC_USER="${CCC_USER:-claude-code}"'
require_file_contains install/ccc-provision-workstation.sh "Statusline user"
require_file_contains install/ccc-provision-workstation.sh 'sudo -u "$CCC_USER" mkdir -p "$CCC_HOME/.claude/bin"'
require_file_contains install/ccc-provision-workstation.sh 'cat > "$CCC_HOME/.claude/bin/statusline-command.sh"'
require_file_contains install/ccc-provision-workstation.sh 'chown "$CCC_USER:$CCC_USER" "$CCC_HOME/.claude/bin/statusline-command.sh"'
require_file_not_contains install/ccc-provision-workstation.sh 'cat > /home/claude-code/.claude/bin/statusline-command.sh'
require_file_contains install/ccc-provision-workstation.sh "claude statusline-command"
require_file_contains install/ccc-provision-workstation.sh 'jq -r '\''.model.id    // ""'\'''
require_file_contains install/ccc-provision-workstation.sh 'jq -r '\''.thinking.enabled // false'\'''
require_file_contains install/ccc-provision-workstation.sh 'jq -r '\''.context.used  // 0'\'''
require_file_contains install/ccc-provision-workstation.sh 'jq -r '\''.context.max   // 200000'\'''
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
require_file_contains install/ccc-provision-workstation.sh "-buildvcs=false"
require_file_contains install/ccc-provision-workstation.sh 'timeout 600 "$GO" build -C "$SRC/container-code-companion" -buildvcs=false'
require_file_contains install/ccc-provision-workstation.sh '-C "$CONTAINER_CODE_COMPANION_SRC/container-code-companion"'
require_file_contains install/ccc-provision-workstation.sh 'git config --system --add safe.directory "$CONTAINER_CODE_COMPANION_SRC"'
require_file_contains install/ccc-provision-workstation.sh 'git config --system --add safe.directory "$SRC"'
require_file_not_contains install/ccc-provision-workstation.sh 'pct exec'
require_file_not_contains install/ccc-provision-workstation.sh 'pvesh '
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
require_file_contains container-code-companion/web/app.js "file-download-button"
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
require_file_contains container-code-companion/web/styles.css ".file-entry.selected"
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
require_file_contains container-code-companion/internal/system/management.go 'Path      string `json:"path"`'
require_file_contains container-code-companion/internal/system/management.go 'Mode      string `json:"mode"`'
require_file_contains container-code-companion/internal/system/management.go 'case "copy"'
require_file_contains container-code-companion/internal/system/management.go 'case "chmod"'
require_file_contains container-code-companion/internal/system/management.go 'case "add-existing"'
require_file_contains container-code-companion/internal/system/management.go "os.Symlink"
require_file_contains container-code-companion/internal/server/server.go "/api/tools"
require_file_contains container-code-companion/internal/server/server.go "/api/drive"
require_file_contains container-code-companion/internal/system/management.go "type ToolStatus struct"
require_file_contains container-code-companion/internal/system/management.go "func CollectToolStatuses"
require_file_contains container-code-companion/internal/system/management.go 'UpdateAvailable bool'
require_file_contains container-code-companion/internal/system/management.go 'UpdateStatus    string'
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
require_file_contains container-code-companion/internal/system/management.go "drive mount failed"
require_file_not_contains container-code-companion/web/app.js "section !== 'terminal') {"
require_file_contains container-code-companion/web/app.js "username is required"
require_file_contains container-code-companion/web/app.js "data-nav-updates"
require_file_contains container-code-companion/web/app.js "copyTextToClipboard"
require_file_contains container-code-companion/web/app.js "fallbackCopyText"
require_file_contains container-code-companion/web/app.js "Copy Failed"
require_file_contains container-code-companion/web/app.js "copyGitHubPublicKey"
require_file_contains container-code-companion/web/app.js "github-action-row"
require_file_contains container-code-companion/web/app.js '<button class="small-button" id="github-copy-btn" disabled>Copy Public Key</button>'
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
  '<div class="nav-heading">Settings</div>' 'data-section="github"' 'data-section="oculus"' 'data-section="settings"' 'data-section="configs"'

require_ordered_patterns container-code-companion/web/app.js \
  '<p id="tool-status"' '<pre id="tool-output"' '<div id="tool-catalog"'

require_ordered_patterns container-code-companion/web/app.js \
  'id="github-copy-btn"' 'id="github-test-btn"' 'id="github-generate-btn"'

awk '/SELFUPDATESCRIPT/{flag=!flag; next} flag{print}' install/ccc-provision-workstation.sh > /tmp/ccc-self-update.syntax
bash -n /tmp/ccc-self-update.syntax

awk '/^cat > .*statusline-command.sh.*STATUSLINE/{flag=1; next} /^STATUSLINE$/{flag=0} flag{print}' install/ccc-provision-workstation.sh > /tmp/ccc-statusline.syntax
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
require_file_contains container-code-companion/web/app.js 'data-display-effect="flicker"'
require_file_contains container-code-companion/web/app.js 'data-display-effect="syncDrift"'
require_file_contains container-code-companion/web/styles.css 'crt-flicker'
require_file_contains container-code-companion/web/styles.css 'crt-sync-drift'
require_file_contains container-code-companion/web/styles.css 'body.effect-flicker::before'
require_file_contains container-code-companion/web/styles.css 'body.effect-sync-drift .layout::after'
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
