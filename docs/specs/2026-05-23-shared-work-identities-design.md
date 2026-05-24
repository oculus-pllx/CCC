# Shared Work Identities Design

Date: 2026-05-23
Status: Approved blueprint for next build

## Goal

Let a single personal CCC workstation support multiple local Linux users as
separate agent/auth identities while sharing the same project source of truth,
system tools, and baseline `oculus-configs`.

This is for one owner using multiple accounts or provider identities, not for
multi-tenant security. If another person needs a workstation, build them a
separate container.

## Product Model

- `CCC_USER` remains the primary machine/workstation admin user.
- Additional Linux users are "work identities" for separate auth/session state.
- Projects are shared across identities through one shared root.
- Agent/provider auth stays per user.
- `oculus-configs` remains shared through `/opt/oculus-configs`.
- GitHub repository SSH access can use one managed machine key shared by all
  work identities.

## Shared Resources

### Shared Project Root

Use:

```text
/srv/ccc/projects
```

Permissions:

```text
owner: root:ccc
mode: 2775
```

All CCC work identities should be members of the `ccc` group. The setgid bit on
the directory keeps new files group-owned by `ccc`.

For compatibility, the installer and migration should link:

```text
/home/<user>/projects -> /srv/ccc/projects
```

Project APIs should use `/srv/ccc/projects` as the canonical project root. Any
old `~/projects` references in docs, welcome text, statusline examples, and
tests should be updated or made compatibility-safe.

### Shared GitHub Machine Key

Use:

```text
/etc/ccc/ssh/github_ed25519
/etc/ccc/ssh/github_ed25519.pub
```

Permissions:

```text
/etc/ccc/ssh              root:ccc 0750
/etc/ccc/ssh/github_*     root:ccc private key 0640, public key 0644
```

Each work identity gets `~/.ssh/config` with:

```sshconfig
Host github.com
  HostName github.com
  User git
  IdentityFile /etc/ccc/ssh/github_ed25519
  IdentitiesOnly yes
```

The GUI GitHub page should become a "managed machine GitHub key" page:

- Generate key.
- Copy public key.
- Test GitHub connection.
- Configure all work identities to use the key.
- Detect and optionally promote the current `CCC_USER` GitHub key into the
  managed machine-key path.

Do not silently move or delete an existing user key. Migration should require an
explicit action.

## Per-User Resources

Each work identity gets the minimum local profile needed for independent auth:

- `~/.claude/`
- `~/.codex/`
- `~/.gemini/`
- `~/.ssh/config` pointing at the managed machine GitHub key
- `~/.gitconfig`
- `~/.tmux.conf`
- shell helper/profile block
- `~/Templates` if templates remain per-user, or a link to a shared template
  root if templates are moved later

Do not copy provider auth/session/cache state from `CCC_USER`:

- Claude auth/session files stay per user.
- Codex auth/session files stay per user.
- Gemini auth/session files stay per user.
- npm/cache directories stay per user or regenerate.
- raw `~/.ssh` directories are not cloned.

Each user performs first-run auth as themselves:

```bash
claude
codex
gemini
gh auth login   # optional if HTTPS/PAT flows are needed
```

## GUI Workflows

### Accounts / Work Identities

Extend Accounts with actions:

- Create Account.
- Setup CCC Profile.
- Sync Agent Configs.
- Configure Shared GitHub Key.
- Add to `ccc` group.
- Show first-login/auth checklist.

`Setup CCC Profile` should be idempotent. It should create/repair the profile
without copying provider auth material.

### Projects

Projects page should use the shared project root. Add health/repair affordances:

- Show project root path `/srv/ccc/projects`.
- Clone into shared root.
- Pull latest from shared root.
- Repair project permissions for `root:ccc` or `<owner>:ccc` plus group write.
- Permission repair must also traverse top-level symlinked project directories
  created for legacy `~/repos` compatibility, because those targets can
  otherwise remain `oculus:oculus` and block another work identity.
- Make old per-user project roots visible only as compatibility links.

### Migration

Existing installs need a GUI-driven migration path:

- Detect old `~/projects`.
- Detect whether `/srv/ccc/projects` exists.
- Detect current user GitHub key at `~/.ssh/id_ed25519`.
- Offer "Migrate to shared workspace".
- Create `ccc` group.
- Add `CCC_USER` and selected work identities to `ccc`.
- Move or rsync old projects to `/srv/ccc/projects`.
- Replace old `~/projects` with symlink after backup/confirmation.
- Configure shared GitHub key if user approves.
- Repair permissions.
- Restart services if needed.

Migration should be reversible enough to avoid data loss: make backups or leave
old paths intact until the shared root is verified.

## Installer Changes

Fresh installs should:

- Create `ccc` group.
- Create `/srv/ccc/projects` with `2775`.
- Add `CCC_USER` to `ccc`.
- Link `$CCC_HOME/projects` to `/srv/ccc/projects`.
- Write welcome/code-server workspace references to `/srv/ccc/projects`.
- Generate or defer managed GitHub machine key setup through the GUI.
- Install `ccc-sync-agent-configs` with `--user USER` and `--all-users`
  support.
- Keep `/opt/oculus-configs` as a shared root-owned checkout; per-user sync
  copies managed Claude rules, Codex skills, Gemini skills, and templates into
  the selected user's home.
- Per-user sync also installs the CCC-managed Claude `settings.json` and
  `~/.claude/bin/statusline-command.sh` baseline so additional accounts get the
  same provider permission/statusline behavior as the original user.
- Account profile setup and Sync Agent Configs should validate that the expected
  per-user config/skills files exist before reporting success. Profile setup
  should also validate provider CLI binaries under `~/.local/bin`.
- Accounts should expose a `Sync All Agent Configs` action that runs
  `ccc-sync-agent-configs --all-users`, allowing updates from the shared
  `/opt/oculus-configs` source checkout to be pushed to every normal login user.

## Update/Migration Changes

Existing installs should receive a command callable by the GUI:

```bash
ccc-migrate-shared-workspace
```

The command should support dry-run/status first:

```bash
ccc-migrate-shared-workspace --status
ccc-migrate-shared-workspace --apply
```

The GUI should call status before apply and display planned changes.

## Non-Goals

This first build does not need:

- Full per-user CCC web sessions.
- Per-user web terminal switching.
- Per-user code-server instances.
- Hard security isolation between users.
- Automatic copying of provider auth tokens.
- Automatic GitHub API registration of SSH keys.

Those can come later if needed.

## Risks

- Shared working trees can still have Git file ownership edge cases if commands
  run under different users. Use the `ccc` group, setgid directories, and
  permission repair to reduce this.
- Git commits may use whichever user's `~/.gitconfig` is active. That is
  intended for separate identity lanes, but the GUI should make it visible.
- A shared GitHub SSH key grants repo access to every local user in `ccc`. This
  matches the personal workstation model but is not appropriate for untrusted
  users.
