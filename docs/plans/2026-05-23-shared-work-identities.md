# Shared Work Identities Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GUI-managed shared projects, managed GitHub machine SSH key support, and per-user CCC profile setup for multiple local work identities in one personal CCC workstation.

**Architecture:** Build in phases. First introduce shared path constants and installer/migration primitives, then move Projects/GitHub/Accounts UI onto those primitives. Keep the current single `CCC_USER` web session model for this first build.

**Tech Stack:** Go system/server code, browser JavaScript/CSS, Bash provisioner scripts, existing static shell checks, Go tests.

---

## Phase 1: Shared Workspace Foundation

Status: Complete in `95be375 Add shared project workspace foundation`.

### Files

- [x] Modify `install/ccc-provision-workstation.sh`
- [x] Modify `container-code-companion/internal/system/management.go`
- [x] Modify `container-code-companion/internal/system/management_test.go`
- [x] Modify `tests/container-code-companion-static.sh`
- [x] Modify `README.md`

### Behavior

- [x] Add `CCC_SHARED_GROUP="${CCC_SHARED_GROUP:-ccc}"`.
- [x] Add `CCC_SHARED_PROJECTS="${CCC_SHARED_PROJECTS:-/srv/ccc/projects}"`.
- [x] Fresh installs create group `ccc`, create `/srv/ccc/projects`, set `root:ccc`
  and mode `2775`, add `CCC_USER` to `ccc`, and make `$CCC_HOME/projects` a
  symlink to `/srv/ccc/projects`.
- [x] Backend uses shared project root instead of `filepath.Join(workstationHome(),
  "projects")`.
- [x] Preserve compatibility if `/srv/ccc/projects` does not exist by creating it
  on demand.

### Tests

- [x] Add Go tests for a `sharedProjectsRoot()` helper returning `/srv/ccc/projects`
  by default.
- [x] Add Go tests that `RunProjectOperation` creates/clones under the shared root.
- [x] Add static checks for `CCC_SHARED_PROJECTS`, `/srv/ccc/projects`, `groupadd`,
  `usermod -aG "$CCC_SHARED_GROUP"`, and `chmod 2775`.

## Phase 2: Migration Command For Existing Installs

Status: Complete in `d1c200f Add shared workspace migration command`.

### Files

- [x] Modify `install/ccc-provision-workstation.sh`
- [x] Add generated command `/usr/local/bin/ccc-migrate-shared-workspace`
- [x] Add or modify system tests/static tests as practical
- [x] Update `README.md`

### Behavior

Generated command:

```bash
ccc-migrate-shared-workspace --status
ccc-migrate-shared-workspace --apply
```

Status reports:

- [x] whether group `ccc` exists
- [x] whether `/srv/ccc/projects` exists
- [x] whether `$CCC_HOME/projects` is a directory, symlink, missing, or already shared
- [x] whether legacy `$CCC_HOME/repos` contains existing project entries
- [x] number of entries that would move/copy
- [x] whether a current user GitHub key exists

Apply:

- [x] creates group/root path
- [x] adds `CCC_USER` to `ccc`
- [x] rsyncs existing `$CCC_HOME/projects/` into `/srv/ccc/projects/`
- [x] renames existing `$CCC_HOME/projects` to timestamped backup
- [x] symlinks `$CCC_HOME/projects` to `/srv/ccc/projects`
- [x] links existing `$CCC_HOME/repos` project directories into `/srv/ccc/projects` without moving them
- [x] repairs permissions

- [x] Do not delete the backup automatically.

## Phase 3: Managed GitHub Machine Key

Status: Complete.

### Files

- [x] Modify `container-code-companion/internal/system/management.go`
- [x] Modify `container-code-companion/internal/system/management_test.go`
- [x] Modify `container-code-companion/web/app.js`
- [x] Modify `README.md`
- [x] Modify `tests/container-code-companion-static.sh`

### Behavior

Move GitHub key workflow from per-user key path to:

```text
/etc/ccc/ssh/github_ed25519
```

Backend operations:

- [x] status: report key exists, public key, path, and configured users
- [x] generate-key: create `/etc/ccc/ssh`, group `ccc`, private key `0640`,
  public key `0644`
- [x] test-connection: run `ssh -T -i /etc/ccc/ssh/github_ed25519 git@github.com`
- [x] configure-users: write each selected user's `~/.ssh/config`
- [x] promote-current-user-key: copy `CCC_USER` key into managed path only after
  explicit GUI action

GUI:

- [x] Rename copy to "Copy Machine Public Key".
- [x] Add "Configure For All Work Identities".
- [x] Add "Promote Current User Key" when old key exists and managed key is absent.

## Phase 4: Work Identity Profile Setup

Status: Complete with direct GUI delivery.

Observed blocker:

```text
Agent Config Sync
  Source: https://github.com/oculus-pllx/oculus-configs.git (main)
  ...
  ✓ Claude CLAUDE.md synced
  ✓ Claude rules synced
  ✓ Codex AGENTS.md synced
  ✓ Codex skills synced
  ✓ Gemini GEMINI.md synced
  ✓ Gemini skills synced

Agent config sync complete.

Synced account: prime
Synced home: /home/prime

  missing file /home/prime/.claude/CLAUDE.md
```

Conclusion: the helper-reported sync path was not reliable enough for GUI
account setup/sync. GUI account setup/sync now bypasses the helper for delivery
and uses an explicit direct-copy workflow from a refreshed `oculus-configs`
source into the real home returned by `getent passwd USER`.

### Files

- [x] Modify generated `ccc-sync-agent-configs`
- [x] Modify `container-code-companion/internal/system/management.go`
- [x] Modify `container-code-companion/internal/server/server.go`
- [x] Modify `container-code-companion/web/app.js`
- [x] Add tests in `management_test.go` and `server_test.go`

### Behavior

Extend `ccc-sync-agent-configs`:

```bash
ccc-sync-agent-configs --user USER
ccc-sync-agent-configs --all-users
```

Add account operation:

```json
{ "operation": "setup-ccc-profile", "username": "work-id" }
```

Setup should:

- [x] validate user exists and UID >= 1000
- [x] add user to `ccc`
- [x] link `~/projects` to `/srv/ccc/projects`
- [x] create `~/.claude`, `~/.codex`, `~/.gemini`
- [x] grant the shared `ccc` group read/traverse access on managed work identity
  homes so the dashboard file browser can list `/home/<user>`
- [x] reliably sync baseline configs into additional account homes on existing
  LXC installs
- [x] replace current helper path with direct clone/copy from `oculus-configs`
  into the target user's resolved home
- [x] sync Claude rules, Codex skills, Gemini skills, and project templates for
  the selected work identity
- [x] mirror the primary CCC user's non-auth Claude/Codex/Gemini provider
  profile content so UI/options/add-ons/skills/plugins match across work
  identities without copying provider credential/session/history/cache data
- [x] access the root-owned `/opt/oculus-configs` checkout with Git
  `safe.directory` handling from GUI repo status and sync paths
- [x] run current-user agent config sync during self-update so default configs,
  skills, and plugin directories are applied after CCC updates
- [x] install CCC-managed Claude `settings.json` and statusline baseline for
  each synced work identity
- [x] validate expected synced files/directories before reporting account config
  sync success
- [x] print target account, real home, validation results, and created config
  inventory in GUI account sync output
- [x] install statusline script
- [x] install shell/tmux/git defaults
- [x] install shell login helper so the user starts in `~/projects`
- [x] write `~/.ssh/config` pointing to managed GitHub key if it exists
- [x] skip provider auth/session files

GUI:

- [x] Add `Setup CCC Profile` button per account.
- [x] Add `Sync Agent Configs` button per account.
- [x] Add `Sync All Agent Configs` button to push the latest shared baseline to
  every normal login user.
- [x] Show checklist: login as user, run `claude`, `codex`, `gemini`, optional
  `gh auth login`.

## Phase 5: Project Permission Health

Status: Complete.

### Files

- [x] Modify `container-code-companion/internal/system/management.go`
- [x] Modify `container-code-companion/web/app.js`
- [x] Add tests and static checks

### Behavior

Projects page should show:

- [x] shared root path
- [x] permission health summary
- [x] `Repair Permissions` action
- [x] repair follows top-level symlinked legacy project directories so linked
  repos also become group-writable by the `ccc` group

Repair command:

```bash
sudo chgrp -R ccc /srv/ccc/projects
sudo chmod -R g+rwX /srv/ccc/projects
sudo find /srv/ccc/projects -type d -exec chmod g+s {} +
for entry in /srv/ccc/projects/*; do
  if [ -L "$entry" ] && [ -d "$entry" ]; then
    sudo chgrp -R ccc "$entry"/
    sudo chmod -R g+rwX "$entry"/
    sudo find "$entry"/ -type d -exec chmod g+s {} +
  fi
done
```

## Phase 6: Documentation And Status

Status: Complete.

### Files

- [x] Modify `README.md`
- [x] Modify `PROJECT_STATUS.md`
- [x] Keep spec/plan checked in

### Behavior

Document:

- [x] personal multi-account model
- [x] shared `/srv/ccc/projects`
- [x] managed GitHub machine key
- [x] what stays per-user
- [x] how to migrate an existing install
- [x] how to setup a new work identity from the GUI

## Verification Commands

Run before each implementation commit:

```bash
bash tests/container-code-companion-static.sh
bash -n install/ccc-provision-workstation.sh
node --check container-code-companion/web/app.js
(cd container-code-companion && go test ./...)
git diff --check
```

## Completion Criteria

- [x] Fresh install creates shared workspace structure.
- [x] Existing install can migrate via GUI/command without deleting old projects.
- [x] Projects clone/pull operate against `/srv/ccc/projects`.
- [x] GitHub page manages `/etc/ccc/ssh/github_ed25519`.
- [x] Accounts page can setup a user's CCC profile without copying provider auth.
- [x] README and PROJECT_STATUS describe the new model.
