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
require_file_contains docs/cockpit-plugin/index.html "Agent Workstation"
require_file_contains claude-code-commander.sh "ccc-sync-agent-configs"
require_file_contains README.md "ccc-sync-agent-configs"
require_file_contains claude-code-commander.sh "codex/AGENTS.md"
require_file_contains claude-code-commander.sh "gemini/GEMINI.md"
require_file_contains claude-code-commander.sh "mcp.template.json"
require_file_contains docs/cockpit-plugin/index.html "runAgentConfigSync"
require_file_contains docs/cockpit-plugin/index.html "ccc-sync-agent-configs"
require_file_contains docs/cockpit-plugin/index.html "/cockpit/base1/cockpit.js"
require_file_contains docs/cockpit-plugin/index.html "../base1/patternfly.css"

require_file_not_contains claude-code-commander.sh "/opt/ccc-dashboard"
require_file_not_contains claude-code-commander.sh "node-pty"
require_file_not_contains claude-code-commander.sh "dashboard-token"
require_file_not_contains claude-code-commander.sh "oculus-configure"
require_file_not_contains claude-code-commander.sh "configure.py"
require_file_not_contains claude-code-commander.sh "localhost:4827"
require_file_not_contains README.md "localhost:4827"

echo "agent-workstation static checks passed"
