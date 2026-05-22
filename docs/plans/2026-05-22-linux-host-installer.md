# Linux Host Installer Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Debian/Ubuntu Linux-host installer for the integrated Container Code Companion workstation while keeping the Proxmox LXC installer working from its raw GitHub entrypoint.

**Architecture:** Keep `ccc-bootstrap.sh` as the Proxmox entrypoint and add `ccc-install-linux.sh` as the existing-host entrypoint. Extract the workstation setup into a repo-owned shared provisioner that either entrypoint can use from an adjacent checkout or fetch from GitHub when the entrypoint itself was launched from a raw URL, and persist `CCC_INSTALL_MODE` so the Go UI can vary host-specific guidance.

**Tech Stack:** Bash, Debian/Ubuntu `apt`, systemd, Go CCC server/system package, static shell checks, Go tests, Markdown docs.

---

## File Map

- Create `install/ccc-provision-workstation.sh`: shared root-run workstation provisioner extracted from the current in-container heredoc.
- Modify `ccc-bootstrap.sh`: stage the shared provisioner into the new LXC, pass LXC mode inputs, and keep Proxmox-only finalization outside the shared script.
- Create `ccc-install-linux.sh`: existing Debian/Ubuntu host installer, preflight, target-user choice, credential prompts, provisioner fetch, and completion summary.
- Modify `tests/container-code-companion-static.sh`: lock down shared-provisioner/bootstrap/Linux-installer boundaries and run syntax checks for all installer scripts.
- Modify `container-code-companion/internal/system/management.go`: vary drive mount failure guidance by CCC install mode.
- Modify `container-code-companion/internal/system/management_test.go`: cover LXC and Linux-host drive guidance.
- Modify `README.md`: put the two supported install paths at the top and state what each changes.
- Modify `PROJECT_STATUS.md`: replace the installer follow-up with the shipped Linux-host installer status after implementation.

### Task 1: Add A Shared Provisioner Contract

**Files:**
- Create: `install/ccc-provision-workstation.sh`
- Modify: `tests/container-code-companion-static.sh`

- [x] **Step 1: Write failing static checks for the shared provisioner contract**

Add checks near the existing bootstrap checks in `tests/container-code-companion-static.sh`:

```bash
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
```

- [x] **Step 2: Run the static test and confirm the new contract fails**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: failure stating `install/ccc-provision-workstation.sh` is missing.

- [x] **Step 3: Create the provisioner header and mode validation**

Create `install/ccc-provision-workstation.sh` with the contract first:

```bash
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
  *) echo "[ERROR] Unsupported CCC install mode: $CCC_INSTALL_MODE" >&2; exit 1 ;;
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
```

- [x] **Step 4: Run syntax/static checks for the scaffold**

Run:

```bash
bash -n install/ccc-provision-workstation.sh
bash tests/container-code-companion-static.sh
```

Expected: both commands exit `0`; the original bootstrap still satisfies the
existing workstation checks until Task 2 moves them.

- [x] **Step 5: Commit the provisioner contract**

```bash
git add install/ccc-provision-workstation.sh tests/container-code-companion-static.sh
git commit -m "test(installer): define workstation provisioner contract"
```

### Task 2: Move LXC Workstation Setup Into The Shared Provisioner

**Files:**
- Modify: `install/ccc-provision-workstation.sh`
- Modify: `ccc-bootstrap.sh`
- Modify: `tests/container-code-companion-static.sh`

- [x] **Step 1: Move static expectations from the bootstrap to the shared script**

For checks that assert installed workstation contents, switch the checked file
from `ccc-bootstrap.sh` to `install/ccc-provision-workstation.sh`. Keep Proxmox
entrypoint checks on `ccc-bootstrap.sh`. The migrated expectations include:

```bash
require_file_contains install/ccc-provision-workstation.sh "ccc-sync-agent-configs"
require_file_contains install/ccc-provision-workstation.sh "CCC Statusline"
require_file_contains install/ccc-provision-workstation.sh "container-code-companion.service"
require_file_contains install/ccc-provision-workstation.sh "/usr/local/bin/container-code-companion"
require_file_contains install/ccc-provision-workstation.sh "/var/log/ccc-self-update.log"
require_file_contains install/ccc-provision-workstation.sh "CONTAINER_CODE_COMPANION_ADDR=0.0.0.0:9090"
require_file_contains install/ccc-provision-workstation.sh 'git config --system --add safe.directory "$SRC"'
require_file_not_contains install/ccc-provision-workstation.sh 'pct exec'
require_file_not_contains install/ccc-provision-workstation.sh 'pvesh '
```

Add bootstrap checks for the shared handoff:

```bash
require_file_contains ccc-bootstrap.sh 'stage_workstation_provisioner'
require_file_contains ccc-bootstrap.sh '/tmp/ccc-provision-workstation.sh'
require_file_contains ccc-bootstrap.sh 'CCC_INSTALL_MODE=proxmox-lxc'
require_file_contains ccc-bootstrap.sh 'CCC_SELF_UPDATE_SCRIPT=ccc-bootstrap.sh'
```

- [x] **Step 2: Run the static test and confirm the extraction checks fail**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: failure because bootstrap still embeds the provisioning heredoc and
the shared provisioner does not yet contain the moved workstation steps.

- [x] **Step 3: Extract the current in-container provisioning body**

Move the content currently written between:

```bash
cat > /tmp/provision-${CT_ID}.sh << 'PROVISION_EOF'
...
PROVISION_EOF
```

into `install/ccc-provision-workstation.sh`, then replace hardcoded
`claude-code` path/user uses with `"$CCC_USER"` and `"$CCC_HOME"` where the
current bootstrap already substitutes usernames by `sed`.

Keep these LXC-only blocks behind explicit guards:

```bash
if [[ "$CCC_INSTALL_MODE" == "proxmox-lxc" ]]; then
  cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1 || true
  echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
fi
```

and:

```bash
if [[ "$CCC_MACHINE_POLICY" == "container" ]]; then
  sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
  sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
  sed -i "s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
  systemctl enable ssh
  systemctl restart ssh
fi
```

Call `write_ccc_config` when the original script currently writes
`/etc/ccc/config`, and keep all CCC updateable command/service bodies in the
shared script.

- [x] **Step 4: Teach the Proxmox bootstrap to stage the shared script**

Add a local-or-raw fetch helper in `ccc-bootstrap.sh`:

```bash
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
```

Replace the heredoc execution inside `provision_container()` with staging and
the explicit mode env:

```bash
stage_workstation_provisioner "/tmp/ccc-provision-${CT_ID}.sh"
pct push "$CT_ID" "/tmp/ccc-provision-${CT_ID}.sh" /tmp/ccc-provision-workstation.sh
pct exec "$CT_ID" -- chmod +x /tmp/ccc-provision-workstation.sh
pct exec "$CT_ID" -- env \
  CCC_INSTALL_MODE=proxmox-lxc \
  CCC_MACHINE_POLICY=container \
  CCC_USER="$CC_USER" \
  CCC_HOME="/home/$CC_USER" \
  CCC_SELF_UPDATE_SCRIPT=ccc-bootstrap.sh \
  /tmp/ccc-provision-workstation.sh
rm -f "/tmp/ccc-provision-${CT_ID}.sh"
```

- [x] **Step 5: Run installer static checks and Go regression checks**

Run:

```bash
bash -n ccc-bootstrap.sh
bash -n install/ccc-provision-workstation.sh
bash tests/container-code-companion-static.sh
(cd container-code-companion && go test ./...)
```

Expected: all commands exit `0`.

- [x] **Step 6: Commit the extraction**

```bash
git add ccc-bootstrap.sh install/ccc-provision-workstation.sh tests/container-code-companion-static.sh
git commit -m "refactor(installer): share workstation provisioner"
```

### Task 3: Make The Shared Provisioner Host-Safe

**Files:**
- Modify: `install/ccc-provision-workstation.sh`
- Modify: `tests/container-code-companion-static.sh`

- [x] **Step 1: Add failing checks for Linux-host policy boundaries**

Add these checks:

```bash
require_file_contains install/ccc-provision-workstation.sh 'if [[ "$CCC_INSTALL_MODE" == "proxmox-lxc" ]]; then'
require_file_contains install/ccc-provision-workstation.sh 'if [[ "$CCC_MACHINE_POLICY" == "container" ]]; then'
require_file_contains install/ccc-provision-workstation.sh 'CCC_MACHINE_POLICY="${CCC_MACHINE_POLICY:-workstation}"'
require_file_contains install/ccc-provision-workstation.sh 'systemctl enable "$CCC_CODE_SERVER_SERVICE"'
```

- [x] **Step 2: Run the static suite and confirm the Linux-host boundary fails**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: failure until the shared provisioner uses `CCC_CODE_SERVER_SERVICE`
instead of a hardcoded user-specific systemd unit.

- [x] **Step 3: Normalize target-user and policy-specific operations**

Keep package/dev/tool/service installation in the shared script, but ensure
these operations use `CCC_USER`, `CCC_HOME`, and `CCC_CODE_SERVER_SERVICE`:

```bash
install -d -o "$CCC_USER" -g "$CCC_USER" "$CCC_HOME/projects"
sudo -u "$CCC_USER" mkdir -p "$CCC_HOME/.config/code-server"
systemctl enable "$CCC_CODE_SERVER_SERVICE"
sudo -u "$CCC_USER" git config --global init.defaultBranch main
```

Leave machine-owner policy blocks guarded:

```bash
[[ "$CCC_MACHINE_POLICY" == "container" ]] && chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null || true
```

Set Linux mode self-update script support in emitted config by preserving the
passed `CCC_SELF_UPDATE_SCRIPT` value; do not force it back to
`ccc-bootstrap.sh` inside shared updateable sections.

- [x] **Step 4: Re-run the shared provisioner checks**

Run:

```bash
bash -n install/ccc-provision-workstation.sh
bash tests/container-code-companion-static.sh
```

Expected: both commands exit `0`.

- [x] **Step 5: Commit host-safe shared provisioning**

```bash
git add install/ccc-provision-workstation.sh tests/container-code-companion-static.sh
git commit -m "refactor(installer): separate host policy from provisioning"
```

### Task 4: Add The Debian/Ubuntu Linux Host Entrypoint

**Files:**
- Create: `ccc-install-linux.sh`
- Modify: `tests/container-code-companion-static.sh`

- [x] **Step 1: Add failing static checks for the Linux entrypoint**

Add:

```bash
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
```

- [x] **Step 2: Run the static suite and confirm the entrypoint checks fail**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: failure saying `missing Linux host installer`.

- [x] **Step 3: Implement Linux-host preflight and target-user selection**

Create `ccc-install-linux.sh` with these key functions:

```bash
#!/usr/bin/env bash
set -euo pipefail

preflight() {
  command -v sudo >/dev/null 2>&1 || error "sudo is required."
  sudo -v
  [[ -r /etc/os-release ]] || error "/etc/os-release is required."
  . /etc/os-release
  [[ "${ID:-}" =~ ^(debian|ubuntu)$ ]] || error "Only Debian and Ubuntu are supported."
  [[ ! -e /etc/ccc/config ]] || error "CCC already appears installed. Use ccc-self-update for an installed workstation."
  curl -fsSL --max-time 10 https://github.com >/dev/null || error "GitHub is not reachable."
}

choose_target_user() {
  CURRENT_USER="${SUDO_USER:-$USER}"
  echo "  1) Current user: $CURRENT_USER"
  echo "  2) Create a dedicated CCC user"
  read -rp "Install target [1]: " choice
  if [[ "${choice:-1}" == "2" ]]; then
    read -rp "Dedicated CCC username [ccc]: " CCC_USER
    CCC_USER="${CCC_USER:-ccc}"
    sudo useradd -m -s /bin/bash "$CCC_USER"
    sudo passwd "$CCC_USER"
  else
    CCC_USER="$CURRENT_USER"
  fi
  CCC_HOME="$(getent passwd "$CCC_USER" | cut -d: -f6)"
}
```

Do not put Proxmox checks, SSH hardening edits, or IPv6 sysctl edits in this
entrypoint.

- [x] **Step 4: Stage the shared provisioner and invoke Linux-host mode**

Use the same adjacent-or-raw lookup pattern as the Proxmox entrypoint:

```bash
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

sudo env \
  CCC_INSTALL_MODE=linux-host \
  CCC_MACHINE_POLICY=workstation \
  CCC_USER="$CCC_USER" \
  CCC_HOME="$CCC_HOME" \
  CCC_SELF_UPDATE_SCRIPT=ccc-install-linux.sh \
  "$PROVISIONER"
```

- [x] **Step 5: Configure host credentials and print completion URLs**

After provisioning, write CCC UI credentials and code-server config from Linux
installer prompts:

```bash
printf 'CONTAINER_CODE_COMPANION_ADDR=0.0.0.0:9090\nCONTAINER_CODE_COMPANION_WEB_DIR=/opt/container-code-companion/web\nCONTAINER_CODE_COMPANION_SESSION_TOKEN=%s\nCONTAINER_CODE_COMPANION_USERNAME=%s\nCONTAINER_CODE_COMPANION_PASSWORD=%s\n' \
  "$CCC_UI_TOKEN" "$CCC_USER" "$CCC_UI_PASSWORD" \
  | sudo tee /etc/container-code-companion/env >/dev/null

printf 'bind-addr: 0.0.0.0:8080\nauth: password\npassword: "%s"\ncert: false\nuser-data-dir: %s/.local/share/code-server\nextensions-dir: %s/.local/share/code-server/extensions\n' \
  "$CODE_SERVER_PASSWORD" "$CCC_HOME" "$CCC_HOME" \
  | sudo tee "$CCC_HOME/.config/code-server/config.yaml" >/dev/null
```

Restart `container-code-companion.service`, start `code-server@$CCC_USER`, and
print URLs using `hostname -I | awk '{print $1}'`.

- [x] **Step 6: Run syntax and static checks**

Run:

```bash
bash -n ccc-install-linux.sh
bash tests/container-code-companion-static.sh
```

Expected: both commands exit `0`.

- [x] **Step 7: Commit the Linux-host entrypoint**

```bash
git add ccc-install-linux.sh tests/container-code-companion-static.sh
git commit -m "feat(installer): add debian ubuntu host installer"
```

### Task 5: Make Host-Specific Drive Guidance Mode-Aware

**Files:**
- Modify: `container-code-companion/internal/system/management.go`
- Modify: `container-code-companion/internal/system/management_test.go`
- Modify: `tests/container-code-companion-static.sh`

- [x] **Step 1: Write failing Go tests for LXC and Linux-host mount failures**

Replace the single guidance test in
`container-code-companion/internal/system/management_test.go` with mode-specific
tests that pass explicit install modes:

```go
func TestExplainDriveMountFailureAddsLXCContext(t *testing.T) {
	output := explainDriveMountFailure("mount: /mnt/share: permission denied.", "proxmox-lxc")
	if !strings.Contains(output, "LXC mount note") || !strings.Contains(output, "Proxmox host") {
		t.Fatalf("expected LXC guidance, got %q", output)
	}
}

func TestExplainDriveMountFailureAddsLinuxHostContext(t *testing.T) {
	output := explainDriveMountFailure("mount: /mnt/share: permission denied.", "linux-host")
	if strings.Contains(output, "Proxmox host") {
		t.Fatalf("did not expect Proxmox guidance, got %q", output)
	}
	if !strings.Contains(output, "Linux host mount note") {
		t.Fatalf("expected Linux host guidance, got %q", output)
	}
}
```

- [x] **Step 2: Run the focused Go test and confirm the signature change fails**

Run:

```bash
(cd container-code-companion && go test ./internal/system -run 'TestExplainDriveMountFailure' -v)
```

Expected: compile failure because `explainDriveMountFailure` still accepts one
argument.

- [x] **Step 3: Implement install-mode guidance**

Change `RunDriveOperation` to pass an install mode into
`explainDriveMountFailure`, with a small config reader that defaults to the LXC
guidance for older installs:

```go
func cccInstallMode() string {
	data, err := os.ReadFile("/etc/ccc/config")
	if err != nil {
		return "proxmox-lxc"
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "CCC_INSTALL_MODE=") {
			return strings.Trim(strings.TrimPrefix(line, "CCC_INSTALL_MODE="), "\"")
		}
	}
	return "proxmox-lxc"
}
```

Use the mode in the explanation:

```go
func explainDriveMountFailure(output, installMode string) string {
	text := strings.TrimSpace(output)
	if strings.Contains(strings.ToLower(text), "permission denied") {
		if installMode == "linux-host" {
			text += "\n\nLinux host mount note: confirm the share credentials, mount path permissions, CIFS support, and sudo/mount policy on this machine."
		} else {
			text += "\n\nLXC mount note: CIFS mounts require mount capability from the Proxmox host/container configuration. If this is an unprivileged LXC, update the container options on the Proxmox side or mount the share on the host and bind-mount it into the container. The GUI cannot grant kernel mount permission from inside the container."
		}
	}
	return text
}
```

- [x] **Step 4: Update static checks for both notes**

Add:

```bash
require_file_contains container-code-companion/internal/system/management.go "Linux host mount note"
require_file_contains container-code-companion/internal/system/management.go "CCC_INSTALL_MODE"
```

- [x] **Step 5: Run focused and full Go tests**

Run:

```bash
(cd container-code-companion && go test ./internal/system -run 'TestExplainDriveMountFailure' -v)
(cd container-code-companion && go test ./...)
bash tests/container-code-companion-static.sh
```

Expected: all commands exit `0`.

- [x] **Step 6: Commit mode-aware drive guidance**

```bash
git add container-code-companion/internal/system/management.go container-code-companion/internal/system/management_test.go tests/container-code-companion-static.sh
git commit -m "fix(drives): vary mount guidance by install mode"
```

### Task 6: Document The Two Install Paths

**Files:**
- Modify: `README.md`
- Modify: `PROJECT_STATUS.md`
- Modify: `tests/container-code-companion-static.sh`

- [x] **Step 1: Add failing README expectations**

Add:

```bash
require_file_contains README.md "New Proxmox LXC"
require_file_contains README.md "Existing Debian or Ubuntu"
require_file_contains README.md "ccc-install-linux.sh"
require_file_contains README.md "does not change host networking or SSH hardening"
```

- [x] **Step 2: Run the static suite and confirm the README checks fail**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: failure because the README still describes CCC only as a Proxmox LXC
provisioner at the top.

- [x] **Step 3: Rewrite the README opening and install section**

Replace the Proxmox-only opening with:

```markdown
Container Code Companion by Parallax Group builds a browser-accessible,
CLI-first dev workstation for Claude Code, OpenAI Codex, Gemini-ready configs,
and the shared `oculus-configs` integration.

| I want to... | Supported path |
|---|---|
| Create a new Proxmox LXC workstation | Run `ccc-bootstrap.sh` on the Proxmox host |
| Install CCC on an existing Debian or Ubuntu workstation | Run `ccc-install-linux.sh` on that Linux machine |
```

Add Linux-host install command and boundary text:

````markdown
### Existing Debian or Ubuntu

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/ccc-install-linux.sh)
```

The Linux-host installer installs CCC services, code-server, baseline dev tools,
and required `oculus-configs` integration. It does not change host networking or
SSH hardening policy.
````

Keep the existing Proxmox prompts under a Proxmox-specific install subsection.

- [x] **Step 4: Update project status**

Replace the current tracked follow-up in `PROJECT_STATUS.md` with a completed
note:

```markdown
- Added a Debian/Ubuntu Linux-host installer path alongside the Proxmox LXC bootstrap.
```

- [x] **Step 5: Run docs/static checks**

Run:

```bash
bash tests/container-code-companion-static.sh
git diff --check
```

Expected: both commands exit `0`.

- [ ] **Step 6: Commit docs**

```bash
git add README.md PROJECT_STATUS.md tests/container-code-companion-static.sh
git commit -m "docs: explain linux host install path"
```

### Task 7: Run Full Verification Before Field Testing

**Files:**
- Verify: all changed installer, Go, UI, and docs files

- [ ] **Step 1: Run the repository verification set**

Run:

```bash
bash -n ccc-bootstrap.sh
bash -n ccc-install-linux.sh
bash -n install/ccc-provision-workstation.sh
bash tests/container-code-companion-static.sh
node --check container-code-companion/web/app.js
(cd container-code-companion && go test ./...)
(cd container-code-companion && go build -buildvcs=false -o /tmp/container-code-companion-test ./cmd/server)
git diff --check
```

Expected: all commands exit `0`.

- [ ] **Step 2: Inspect the install-path diff**

Run:

```bash
git diff --stat HEAD~6..HEAD
git grep -n -E 'pct |pvesh |99-disable-ipv6|PermitRootLogin' -- ccc-install-linux.sh
git grep -n 'CCC_INSTALL_MODE' -- ccc-bootstrap.sh ccc-install-linux.sh install/ccc-provision-workstation.sh container-code-companion/internal/system/management.go
```

Expected: the Linux installer grep for Proxmox/host-policy strings has no
matches; install mode is present in both entrypoints, shared provisioner, and
mode-aware Go logic.

- [ ] **Step 3: Record field-test commands for fresh systems**

Use fresh test systems for commands that make system changes:

```bash
# Proxmox host:
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/ccc-bootstrap.sh)

# Fresh Debian/Ubuntu VM:
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/ccc-install-linux.sh)
```

Expected manual evidence after each install: CCC UI on port `9090`, code-server
on port `8080`, `ccc-sync-agent-configs` succeeds, and `/etc/ccc/config`
records the correct `CCC_INSTALL_MODE`.
