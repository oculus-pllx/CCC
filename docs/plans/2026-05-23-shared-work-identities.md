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
- [x] number of entries that would move/copy
- [x] whether a current user GitHub key exists

Apply:

- [x] creates group/root path
- [x] adds `CCC_USER` to `ccc`
- [x] rsyncs existing `$CCC_HOME/projects/` into `/srv/ccc/projects/`
- [x] renames existing `$CCC_HOME/projects` to timestamped backup
- [x] symlinks `$CCC_HOME/projects` to `/srv/ccc/projects`
- [x] repairs permissions

- [x] Do not delete the backup automatically.

## Phase 3: Managed GitHub Machine Key

Status: Next.

### Files

- Modify `container-code-companion/internal/system/management.go`
- Modify `container-code-companion/internal/system/management_test.go`
- Modify `container-code-companion/web/app.js`
- Modify `README.md`
- Modify `tests/container-code-companion-static.sh`

### Behavior

Move GitHub key workflow from per-user key path to:

```text
/etc/ccc/ssh/github_ed25519
```

Backend operations:

- status: report key exists, public key, path, and configured users
- generate-key: create `/etc/ccc/ssh`, group `ccc`, private key `0640`,
  public key `0644`
- test-connection: run `ssh -T -i /etc/ccc/ssh/github_ed25519 git@github.com`
- configure-users: write each selected user's `~/.ssh/config`
- promote-current-user-key: copy `CCC_USER` key into managed path only after
  explicit GUI action

GUI:

- Rename copy to "Copy Machine Public Key".
- Add "Configure For All Work Identities".
- Add "Promote Current User Key" when old key exists and managed key is absent.

## Phase 4: Work Identity Profile Setup

### Files

- Modify generated `ccc-sync-agent-configs`
- Modify `container-code-companion/internal/system/management.go`
- Modify `container-code-companion/internal/server/server.go`
- Modify `container-code-companion/web/app.js`
- Add tests in `management_test.go` and `server_test.go`

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

- validate user exists and UID >= 1000
- add user to `ccc`
- link `~/projects` to `/srv/ccc/projects`
- create `~/.claude`, `~/.codex`, `~/.gemini`
- sync baseline configs from `/opt/oculus-configs`
- install statusline script
- install shell/tmux/git defaults
- write `~/.ssh/config` pointing to managed GitHub key if it exists
- skip provider auth/session files

GUI:

- Add `Setup CCC Profile` button per account.
- Add `Sync Agent Configs` button per account.
- Show checklist: login as user, run `claude`, `codex`, `gemini`, optional
  `gh auth login`.

## Phase 5: Project Permission Health

### Files

- Modify `container-code-companion/internal/system/management.go`
- Modify `container-code-companion/web/app.js`
- Add tests and static checks

### Behavior

Projects page should show:

- shared root path
- permission health summary
- `Repair Permissions` action

Repair command:

```bash
sudo chgrp -R ccc /srv/ccc/projects
sudo chmod -R g+rwX /srv/ccc/projects
sudo find /srv/ccc/projects -type d -exec chmod g+s {} +
```

## Phase 6: Documentation And Status

### Files

- Modify `README.md`
- Modify `PROJECT_STATUS.md`
- Keep spec/plan checked in

### Behavior

Document:

- personal multi-account model
- shared `/srv/ccc/projects`
- managed GitHub machine key
- what stays per-user
- how to migrate an existing install
- how to setup a new work identity from the GUI

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

- Fresh install creates shared workspace structure.
- Existing install can migrate via GUI/command without deleting old projects.
- Projects clone/pull operate against `/srv/ccc/projects`.
- GitHub page manages `/etc/ccc/ssh/github_ed25519`.
- Accounts page can setup a user's CCC profile without copying provider auth.
- README and PROJECT_STATUS describe the new model.
