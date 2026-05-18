#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_file_contains() {
  local file=$1
  local pattern=$2
  grep -Fq "$pattern" "$file" || fail "$file missing: $pattern"
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
require_file_contains agent-workstation/web/app.js "formatSelfUpdateProgress"
require_file_contains agent-workstation/web/app.js "Latest self-update log"
require_file_contains agent-workstation/web/app.js "Update finished successfully."
require_file_contains agent-workstation/web/app.js "Update finished successfully"
require_file_contains agent-workstation/web/app.js "Update still running"
require_file_contains agent-workstation/web/app.js "data-config-edit"
require_file_contains agent-workstation/web/app.js "openAgentConfig"
require_file_contains agent-workstation/web/app.js "resetTerminalConnection"
require_file_contains agent-workstation/web/app.js "removeEventListener('resize', resizeTerminal)"
require_file_contains agent-workstation/web/app.js "terminalTabs"
require_file_contains agent-workstation/web/app.js "New Tab"
require_file_contains agent-workstation/web/app.js "stopTerminalSessions"
require_file_contains agent-workstation/web/app.js "/api/account"
require_file_contains agent-workstation/web/app.js "/api/network-activity"
require_file_contains agent-workstation/web/app.js "drawNetworkGraph"
require_file_contains agent-workstation/internal/server/server.go "handleAccount"
require_file_contains agent-workstation/internal/server/server.go "handleNetworkActivity"
require_file_contains agent-workstation/internal/system/management.go "func RunAccountOperation"
require_file_contains agent-workstation/internal/system/management.go "func CollectNetworkActivity"
require_file_contains agent-workstation/internal/system/management.go "func StartSelfUpdate"
require_file_contains agent-workstation/internal/system/management.go "env NO_COLOR=1 ccc-self-update"
require_file_contains agent-workstation/internal/system/management.go "sudo tail -120 /var/log/ccc-self-update.log"

require_file_not_contains claude-code-commander.sh "/opt/ccc-dashboard"
require_file_not_contains claude-code-commander.sh "node-pty"
require_file_not_contains claude-code-commander.sh "dashboard-token"
require_file_not_contains claude-code-commander.sh "oculus-configure"
require_file_not_contains claude-code-commander.sh "configure.py"
require_file_not_contains claude-code-commander.sh "localhost:4827"
require_file_not_contains README.md "localhost:4827"

awk '/SELFUPDATESCRIPT/{flag=!flag; next} flag{print}' claude-code-commander.sh > /tmp/ccc-self-update.syntax
bash -n /tmp/ccc-self-update.syntax

echo "agent-workstation static checks passed"
