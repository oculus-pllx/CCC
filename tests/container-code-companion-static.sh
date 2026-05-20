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

legacy_product='agent-''workstation'
if git grep -n "$legacy_product" -- . ':!container-code-companion/web/vendor/*'; then
  fail "tracked files still reference the legacy product name"
fi
[[ ! -d "$legacy_product" ]] || fail "legacy product directory still exists"

require_file_contains ccc-bootstrap.sh "Container Code Companion"
require_file_contains README.md "Container Code Companion"
require_file_contains LICENSE "MIT License"
require_file_contains LICENSE "Copyright (c) 2026 Parallax Group"
require_file_contains Pllx_group_BRAND.md "Parallax Group"
require_file_contains Pllx_group_BRAND.md "pllx.group"
require_file_contains container-code-companion/web/index.html "Container Code Companion"
require_file_contains container-code-companion/web/index.html "C.C.C"
require_file_contains container-code-companion/web/index.html "by Parallax Group"
require_file_contains container-code-companion/web/index.html "pllx.group"
require_file_contains container-code-companion/web/index.html "MIT License"
require_file_contains container-code-companion/web/index.html "custom-title-input"
require_file_contains container-code-companion/web/app.js "CCC_CUSTOM_TITLE_STORAGE_KEY"
require_file_contains container-code-companion/web/app.js "bindCustomTitle"
require_file_contains container-code-companion/web/styles.css ".brand-lockup"
require_file_contains container-code-companion/web/styles.css ".custom-title-input"
require_file_contains container-code-companion/web/styles.css ".app-footer"
require_file_contains ccc-bootstrap.sh "ccc-sync-agent-configs"
require_file_contains README.md "ccc-sync-agent-configs"
require_file_contains ccc-bootstrap.sh "codex/AGENTS.md"
require_file_contains ccc-bootstrap.sh "gemini/GEMINI.md"
require_file_contains ccc-bootstrap.sh "mcp.template.json"
require_file_contains ccc-bootstrap.sh "bubblewrap"
require_file_contains ccc-bootstrap.sh "GitHub CLI"
require_file_contains ccc-bootstrap.sh "githubcli-archive-keyring.gpg"
require_file_contains ccc-bootstrap.sh "/etc/apt/sources.list.d/github-cli.list"
require_file_contains ccc-bootstrap.sh "https://cli.github.com/packages"
require_file_contains ccc-bootstrap.sh "apt-get install -y -qq gh"
require_file_contains ccc-bootstrap.sh 'command -v bwrap'
require_file_contains ccc-bootstrap.sh 'command -v gh'
require_file_contains ccc-bootstrap.sh 'command -v npm'
require_file_contains ccc-bootstrap.sh 'command -v tmux'
require_file_contains ccc-bootstrap.sh 'command -v code-server'
require_file_contains README.md "bubblewrap"
require_file_contains README.md "GitHub CLI"
require_file_contains ccc-bootstrap.sh "CCC Statusline"
require_file_contains ccc-bootstrap.sh 'sudo -u "$CCC_USER" mkdir -p "$CCC_HOME/.claude/bin"'
require_file_contains ccc-bootstrap.sh 'cat > "$CCC_HOME/.claude/bin/statusline-command.sh"'
require_file_contains ccc-bootstrap.sh 'chown "$CCC_USER:$CCC_USER" "$CCC_HOME/.claude/bin/statusline-command.sh"'
require_file_not_contains ccc-bootstrap.sh 'cat > /home/claude-code/.claude/bin/statusline-command.sh'
require_file_contains ccc-bootstrap.sh "claude statusline-command"
require_file_contains ccc-bootstrap.sh 'jq -r '\''.model.id    // ""'\'''
require_file_contains ccc-bootstrap.sh 'jq -r '\''.thinking.enabled // false'\'''
require_file_contains ccc-bootstrap.sh 'jq -r '\''.context.used  // 0'\'''
require_file_contains ccc-bootstrap.sh 'jq -r '\''.context.max   // 200000'\'''
require_file_contains ccc-bootstrap.sh 'CTX_PCT=$(( CTX_USED * 100 / CTX_MAX ))'
require_file_contains ccc-bootstrap.sh 'CTX_WARN="!!"'
require_file_contains ccc-bootstrap.sh 'TIME=$(date +"%I:%M%p"'
require_file_contains container-code-companion/web/index.html "Terminal"
require_file_contains container-code-companion/web/index.html "Projects"
require_file_contains container-code-companion/web/index.html "oculus-configs"
require_file_contains container-code-companion/web/index.html "Dashboard"
require_file_contains container-code-companion/web/index.html "Workstation"
require_file_contains container-code-companion/web/index.html "System"
require_file_contains container-code-companion/web/index.html "Agents"
require_file_contains ccc-bootstrap.sh "container-code-companion.service"
require_file_contains ccc-bootstrap.sh "/usr/local/bin/container-code-companion"
require_file_contains ccc-bootstrap.sh "CONTAINER_CODE_COMPANION_USERNAME"
require_file_contains ccc-bootstrap.sh "CONTAINER_CODE_COMPANION_PASSWORD"
require_file_contains ccc-bootstrap.sh 'Container Code Companion uses the $CCC_USER user password'
require_file_contains ccc-bootstrap.sh 'http://${_ccc_ui_ip}:9090'
require_file_not_contains ccc-bootstrap.sh 'http://<ip>:9090'
require_file_contains ccc-bootstrap.sh "CONTAINER_CODE_COMPANION_ADDR=0.0.0.0:9090"
require_file_contains ccc-bootstrap.sh "systemctl disable --now ccc-dashboard"
require_file_contains ccc-bootstrap.sh "fuser -k 9090/tcp"
require_file_contains ccc-bootstrap.sh "systemctl disable --now cockpit.socket"
require_file_contains ccc-bootstrap.sh "systemctl enable container-code-companion.service"
require_file_contains ccc-bootstrap.sh "/var/log/ccc-self-update.log"
require_file_contains ccc-bootstrap.sh "timeout 600 /usr/local/go/bin/go build"
require_file_contains ccc-bootstrap.sh "CONTAINER_CODE_COMPANION_USERNAME"
require_file_contains ccc-bootstrap.sh "Set CCC_USER in /etc/ccc/config"
require_file_contains ccc-bootstrap.sh 'NO_COLOR'
require_file_contains ccc-bootstrap.sh 'setsid systemctl restart container-code-companion.service'
require_file_contains ccc-bootstrap.sh 'CCC_INSTALLED_COMMIT'
require_file_contains ccc-bootstrap.sh 'Update available'
require_file_contains ccc-bootstrap.sh "Self-update successful"
require_file_contains ccc-bootstrap.sh "-buildvcs=false"
require_file_contains ccc-bootstrap.sh 'timeout 600 "$GO" build -C "$SRC/container-code-companion" -buildvcs=false'
require_file_contains ccc-bootstrap.sh '-C "$CONTAINER_CODE_COMPANION_SRC/container-code-companion"'
require_file_contains ccc-bootstrap.sh 'git config --system --add safe.directory "$CONTAINER_CODE_COMPANION_SRC"'
require_file_contains ccc-bootstrap.sh 'git config --system --add safe.directory "$SRC"'
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
require_file_contains container-code-companion/web/app.js "selectedFilePath"
require_file_contains container-code-companion/web/app.js "renderFileBreadcrumbs"
require_file_contains container-code-companion/web/app.js "file-breadcrumbs"
require_file_contains container-code-companion/web/app.js "file-home-button"
require_file_contains container-code-companion/web/app.js "file-projects-button"
require_file_contains container-code-companion/web/app.js "file-refresh-button"
require_file_contains container-code-companion/web/app.js "data-file-breadcrumb"
require_file_contains container-code-companion/web/app.js "selectFileEntry"
require_file_contains container-code-companion/web/styles.css ".file-manager"
require_file_contains container-code-companion/web/styles.css ".file-breadcrumbs"
require_file_contains container-code-companion/web/styles.css ".file-entry.selected"
require_file_contains container-code-companion/web/app.js "resetTerminalConnection"
require_file_contains container-code-companion/web/app.js "removeEventListener('resize', resizeTerminal)"
require_file_contains container-code-companion/web/app.js "terminalTabs"
require_file_contains container-code-companion/web/app.js "New Tab"
require_file_contains container-code-companion/web/app.js "stopTerminalSessions"
require_file_not_contains container-code-companion/web/app.js "section !== 'terminal') {"
require_file_contains container-code-companion/web/app.js "username is required"
require_file_contains container-code-companion/web/app.js "data-nav-updates"
require_file_contains container-code-companion/web/app.js "copyTextToClipboard"
require_file_contains container-code-companion/web/app.js "fallbackCopyText"
require_file_contains container-code-companion/web/app.js "Copy Failed"
require_file_not_contains container-code-companion/web/app.js ".catch(() => {})"
require_file_contains container-code-companion/web/app.js "network-legend"
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

require_file_contains ccc-bootstrap.sh 'CCC_SELF_UPDATE_REF="main"'
require_file_not_contains ccc-bootstrap.sh 'container-code-companion-native-ui'
require_file_not_contains ccc-bootstrap.sh "/opt/ccc-dashboard"
require_file_not_contains ccc-bootstrap.sh "node-pty"
require_file_not_contains ccc-bootstrap.sh "dashboard-token"
require_file_not_contains ccc-bootstrap.sh "oculus-configure"
require_file_not_contains ccc-bootstrap.sh "configure.py"
require_file_not_contains ccc-bootstrap.sh "localhost:4827"
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
  '<div class="nav-heading">Workstation</div>' 'data-section="files"' 'data-section="projects"' 'data-section="terminal"' \
  '<div class="nav-heading">System</div>' 'data-section="accounts"' 'data-section="logs"' 'data-section="network"' 'data-section="services"' \
  '<div class="nav-heading">Agents</div>' 'data-section="configs"' 'data-section="oculus"'

awk '/SELFUPDATESCRIPT/{flag=!flag; next} flag{print}' ccc-bootstrap.sh > /tmp/ccc-self-update.syntax
bash -n /tmp/ccc-self-update.syntax

awk '/^cat > .*statusline-command.sh.*STATUSLINE/{flag=1; next} /^STATUSLINE$/{flag=0} flag{print}' ccc-bootstrap.sh > /tmp/ccc-statusline.syntax
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
require_file_contains container-code-companion/web/app.js 'settings-swatch'
require_file_contains container-code-companion/web/app.js "settings: 'Settings'"
require_file_contains container-code-companion/web/app.js 'DISPLAY_EFFECTS_STORAGE_KEY'
require_file_contains container-code-companion/web/app.js 'ccc-display-effects'
require_file_contains container-code-companion/web/app.js 'loadDisplayEffects'
require_file_contains container-code-companion/web/app.js 'applyDisplayEffects'
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
