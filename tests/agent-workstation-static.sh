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

require_file_contains claude-code-commander.sh "Agent Workstation"
require_file_contains README.md "Agent Workstation"
require_file_contains agent-workstation/web/index.html "Agent Workstation"
require_file_contains claude-code-commander.sh "ccc-sync-agent-configs"
require_file_contains README.md "ccc-sync-agent-configs"
require_file_contains claude-code-commander.sh "codex/AGENTS.md"
require_file_contains claude-code-commander.sh "gemini/GEMINI.md"
require_file_contains claude-code-commander.sh "mcp.template.json"
require_file_contains agent-workstation/web/index.html "Terminal"
require_file_contains agent-workstation/web/index.html "Projects"
require_file_contains agent-workstation/web/index.html "oculus-configs"
require_file_contains agent-workstation/web/index.html "Dashboard"
require_file_contains agent-workstation/web/index.html "Workstation"
require_file_contains agent-workstation/web/index.html "System"
require_file_contains agent-workstation/web/index.html "Agents"
require_file_contains claude-code-commander.sh "agent-workstation.service"
require_file_contains claude-code-commander.sh "/usr/local/bin/agent-workstation"
require_file_contains claude-code-commander.sh "AGENT_WORKSTATION_USERNAME"
require_file_contains claude-code-commander.sh "AGENT_WORKSTATION_PASSWORD"
require_file_contains claude-code-commander.sh 'Agent Workstation uses the $CCC_USER user password'
require_file_contains claude-code-commander.sh "AGENT_WORKSTATION_ADDR=0.0.0.0:9090"
require_file_contains claude-code-commander.sh "systemctl disable --now ccc-dashboard"
require_file_contains claude-code-commander.sh "fuser -k 9090/tcp"
require_file_contains claude-code-commander.sh "systemctl disable --now cockpit.socket"
require_file_contains claude-code-commander.sh "systemctl enable agent-workstation.service"
require_file_contains claude-code-commander.sh "/var/log/ccc-self-update.log"
require_file_contains claude-code-commander.sh "timeout 600 /usr/local/go/bin/go build"
require_file_contains claude-code-commander.sh "AGENT_WORKSTATION_USERNAME:-"
require_file_contains claude-code-commander.sh "Set CCC_USER in /etc/ccc/config"
require_file_contains claude-code-commander.sh 'NO_COLOR'
require_file_contains claude-code-commander.sh 'status=${PIPESTATUS[0]}'
require_file_contains claude-code-commander.sh "Update check: installed commit is not recorded"
require_file_contains claude-code-commander.sh "Update available: installed commit differs"
require_file_contains claude-code-commander.sh "Current: installed commit matches"
require_file_contains claude-code-commander.sh "Self-update successful"
require_file_contains agent-workstation/web/app.js "Apply Agent Workstation Update"
require_file_contains agent-workstation/web/app.js "self-update"
require_file_contains agent-workstation/web/app.js 'stripANSI'
require_file_contains agent-workstation/web/app.js "updateStatusBadge"
require_file_contains agent-workstation/web/app.js "monitorSelfUpdate"
require_file_contains agent-workstation/web/app.js "const selfUpdate = action === 'self-update'"
require_file_contains agent-workstation/web/app.js "formatSelfUpdateProgress"
require_file_contains agent-workstation/web/app.js "formatOSPackageStatus"
require_file_contains agent-workstation/web/app.js "No OS package updates available."
require_file_contains agent-workstation/web/app.js "Latest self-update log"
require_file_contains agent-workstation/web/app.js "Update finished successfully."
require_file_contains agent-workstation/web/app.js "Update finished successfully"
require_file_contains agent-workstation/web/app.js "Update still running"
require_file_contains agent-workstation/web/app.js "data-config-edit"
require_file_contains agent-workstation/web/app.js "openAgentConfig"
require_file_contains agent-workstation/web/app.js "config-editor-panel"
require_file_contains agent-workstation/web/app.js "showConfigEditor"
require_file_contains agent-workstation/web/app.js "saveConfigFile"
require_file_contains agent-workstation/web/app.js "resetTerminalConnection"
require_file_contains agent-workstation/web/app.js "removeEventListener('resize', resizeTerminal)"
require_file_contains agent-workstation/web/app.js "terminalTabs"
require_file_contains agent-workstation/web/app.js "New Tab"
require_file_contains agent-workstation/web/app.js "stopTerminalSessions"
require_file_not_contains agent-workstation/web/app.js "section !== 'terminal') {"
require_file_contains agent-workstation/web/app.js "username is required"
require_file_contains agent-workstation/web/app.js "data-nav-updates"
require_file_contains agent-workstation/web/app.js "network-legend"
require_file_contains agent-workstation/web/app.js "/api/account"
require_file_contains agent-workstation/web/app.js "/api/network-activity"
require_file_contains agent-workstation/web/app.js "drawNetworkGraph"
require_file_contains agent-workstation/internal/server/server.go "handleAccount"
require_file_contains agent-workstation/internal/server/server.go "handleNetworkActivity"
require_file_contains agent-workstation/internal/system/management.go "func RunAccountOperation"
require_file_contains agent-workstation/internal/system/management.go "func CollectNetworkActivity"
require_file_contains agent-workstation/internal/system/management.go "func StartSelfUpdate"
require_file_contains agent-workstation/internal/system/management.go "Agent Workstation self-update monitor started."
require_file_contains agent-workstation/internal/system/management.go "setsid env NO_COLOR=1 ccc-self-update"
require_file_contains agent-workstation/internal/system/management.go "sudo tail -120 /var/log/ccc-self-update.log"
require_file_contains agent-workstation/internal/server/server.go "Cache-Control"
require_file_contains agent-workstation/web/app.js '\x1b\['
require_file_not_contains agent-workstation/web/app.js '(?:\x1b)?'
require_file_not_contains agent-workstation/web/app.js '`http://${location.hostname}'
require_file_not_contains agent-workstation/web/app.js 'formatPercent'

require_file_contains claude-code-commander.sh 'CCC_SELF_UPDATE_REF="main"'
require_file_not_contains claude-code-commander.sh 'agent-workstation-native-ui'
require_file_not_contains claude-code-commander.sh "/opt/ccc-dashboard"
require_file_not_contains claude-code-commander.sh "node-pty"
require_file_not_contains claude-code-commander.sh "dashboard-token"
require_file_not_contains claude-code-commander.sh "oculus-configure"
require_file_not_contains claude-code-commander.sh "configure.py"
require_file_not_contains claude-code-commander.sh "localhost:4827"
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

require_ordered_patterns agent-workstation/web/index.html \
  '<div class="nav-heading">Dashboard</div>' 'data-section="overview"' 'data-section="updates"' \
  '<div class="nav-heading">Workstation</div>' 'data-section="files"' 'data-section="projects"' 'data-section="terminal"' \
  '<div class="nav-heading">System</div>' 'data-section="accounts"' 'data-section="logs"' 'data-section="network"' 'data-section="services"' \
  '<div class="nav-heading">Agents</div>' 'data-section="configs"' 'data-section="oculus"'

awk '/SELFUPDATESCRIPT/{flag=!flag; next} flag{print}' claude-code-commander.sh > /tmp/ccc-self-update.syntax
bash -n /tmp/ccc-self-update.syntax

# Task 1: CSS Prism palette
require_file_contains agent-workstation/web/styles.css '--topbar'
require_file_contains agent-workstation/web/styles.css '--panel2'
require_file_contains agent-workstation/web/styles.css '--accent-bg'
require_file_contains agent-workstation/web/styles.css '#060d16'
require_file_contains agent-workstation/web/styles.css 'IBM Plex Mono'
require_file_contains agent-workstation/web/styles.css 'settings-swatch-row'
require_file_not_contains agent-workstation/web/styles.css '#17191c'
require_file_not_contains agent-workstation/web/styles.css '#24282d'
require_file_not_contains agent-workstation/web/styles.css '#3f454d'
require_file_not_contains agent-workstation/web/styles.css '#a7adb5'
require_file_not_contains agent-workstation/web/styles.css '#111316'
require_file_not_contains agent-workstation/web/styles.css '#1b1e22'
require_file_not_contains agent-workstation/web/styles.css '#050608'

# Task 2: index.html
require_file_contains agent-workstation/web/index.html 'IBM+Plex+Mono'
require_file_contains agent-workstation/web/index.html 'data-section="settings"'

# Task 3: JS theme engine
require_file_contains agent-workstation/web/app.js 'const THEMES'
require_file_contains agent-workstation/web/app.js 'applyTheme'
require_file_contains agent-workstation/web/app.js 'loadTheme'
require_file_contains agent-workstation/web/app.js 'aw-theme'
require_file_contains agent-workstation/web/app.js 'hexToRgb'

# Task 4: Settings page
require_file_contains agent-workstation/web/app.js 'renderSettings'
require_file_contains agent-workstation/web/app.js 'bindSettings'
require_file_contains agent-workstation/web/app.js 'settings-swatch'
require_file_contains agent-workstation/web/app.js "settings: 'Settings'"

echo "agent-workstation static checks passed"
