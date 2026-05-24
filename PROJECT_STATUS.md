# Project Status

Last updated: 2026-05-24
Branch: `main`

## Current State

Container Code Companion is functional for Proxmox LXC workstation provisioning, Debian/Ubuntu host installation, and day-to-day use.

Recent work completed:
- Added shared work identity foundation: fresh installs now create the `ccc` group, `/srv/ccc/projects` as `root:ccc` with `2775`, and link the primary user's `~/projects` there.
- Moved backend Projects and default file browsing operations to the shared `/srv/ccc/projects` root.
- Added `ccc-migrate-shared-workspace --status|--apply` for existing installs, with rsync migration, retained timestamped backups, compatibility symlink creation, and permission repair.
- Moved GitHub SSH management to the managed machine key at `/etc/ccc/ssh/github_ed25519`, with GUI actions to copy, generate, test, configure work identities, and explicitly promote an existing user key.
- Added Accounts actions to setup CCC profiles and sync agent configs per work identity without copying provider auth/session state.
- Updated CCC profile setup to install Claude Code, Codex, and Gemini CLI binaries into each additional work identity's `~/.local` so provider commands launch from that account.
- Updated agent config sync/status so `oculus-configs` stays a shared root-owned checkout, per-user sync copies Claude rules plus Codex/Gemini skills, and Provider Configs shows the synced directories.
- Added the CCC-managed Claude `settings.json` and statusline baseline to per-user agent config sync so additional accounts get the same permission/statusline behavior as the original user.
- Forced account profile/config sync actions to run with `NO_COLOR=1` and added UI cleanup for malformed color remnants in account output.
- Moved malformed ANSI color cleanup into the shared browser output sanitizer so bracket-only color remnants are removed across output panels.
- Added Projects shared-root permission health and a repair action for group-write/setgid permissions.
- Extended project permission repair to follow top-level symlinked legacy project directories so linked repos outside `/srv/ccc/projects` are also changed to the shared `ccc` group and group-writable mode.
- Tightened per-account setup/sync so it validates expected Claude/Codex/Gemini config and skills files plus provider CLI binaries before reporting the profile ready.
- Added Projects GUI actions for shared workspace migration status and apply.
- Added legacy project-root compatibility so existing `~/projects` or `~/repos` work remains visible before migration, and clarified the Projects Shared Workspace controls.
- Added per-user shell login setup so additional work identities enter `~/projects` after CCC profile setup.
- Made CCC update checks visible on Overview and Updates so users can see when `ccc-update-status` is querying GitHub and when it last checked.
- Added Overview SSH connection counts grouped by user, including duplicate sessions for the same work identity.
- Improved visible CCC update checks so completed checks summarize the actual `ccc-update-status` result instead of leaving users at a generic checking message.
- Fixed SSH connection counting for hosts where `who` does not report sessions by falling back to `sshd` process titles, and kept Overview update-status refreshes in place instead of redrawing the dashboard.
- Added a top-bar CCC update alert and extended SSH counting to OpenSSH `sshd-session` and `notty` process titles.
- Moved SSH session count into the first-row Overview status strip so desktop dashboards keep summary tiles together.
- Kept Projects migration and Accounts operation output visible after page refreshes so status/errors do not disappear.
- Updated the generated `~/projects/WELCOME.md` with shared workspace, migration, work identity, and managed GitHub key instructions.
- Fixed CCC self-update so it re-runs the provisioner's updateable section from the latest GitHub checkout, updating helper commands and service files along with the web UI.
- Documented the one-time helper refresh command for older installs whose previous updater cannot rewrite itself.
- Rebranded the project as Container Code Companion with Parallax Group branding.
- Added a Debian/Ubuntu Linux-host installer path alongside the Proxmox LXC bootstrap.
- Added Proxmox LXC OS choices for Ubuntu 24.04 LTS, Ubuntu 26.04 LTS, and Debian 13, with Ubuntu 24.04 as the compatibility default.
- Fixed Node provisioning to install `npm` explicitly with Node.js.
- Added Ubuntu 26.04 Playwright/Chromium warnings and documented Debian 13 as the safer browser automation path.
- Added Projects Git clone/import and fast-forward pull actions for SSH and HTTPS remotes.
- Improved Projects clone layout and added a visible header-message Edit button.
- Rebuilt the native Go web UI around workstation workflows instead of Cockpit-style remnants.
- Added a real login page, mobile drawer navigation, footer branding, theme controls, and optional CRT effects.
- Suppressed CRT display effects while Terminal is active so full-screen TUIs like Gemini, Claude, tmux, and editors can render cleanly.
- Split App and OS updates into clear tabs with streamed app self-update output.
- Added App Catalog install/update status for common dev and AI-provider tools.
- Added Files, Notes, Projects, Terminal tabs, tmux quick actions, GitHub SSH key workflow, Provider Configs, and Preferences.
- Added Map Drives UI with LXC/Proxmox guidance for CIFS mount permission failures.
- Improved live dashboard gauges, network activity graph, and time/location settings.

## Validation

Current verification set:
- `go test ./...`
- `node --check container-code-companion/web/app.js`
- `bash tests/container-code-companion-static.sh`
- `bash -n ccc-bootstrap.sh`
- `bash -n install/ccc-provision-workstation.sh`
- `go build -buildvcs=false -o /tmp/container-code-companion-test ./cmd/server`
- `git diff --check`

## Known Notes

- CIFS mounts from inside an unprivileged LXC often fail unless Proxmox/container settings allow it. Prefer host-side mount plus bind mount for fewer user issues.
- Ubuntu 26.04 remains available, but Ubuntu 24.04 is the LXC default for package compatibility and Debian 13 is preferred when Playwright/headless Chromium matters.
- Ollama was removed from App Catalog because local model serving inside this LXC is likely to create support problems on Proxmox hosts.
- Existing `HANDOFF.md` files are local/ignored and should not be committed unless project policy changes.

## Next Work

Shared work identities is complete:
- Complete: shared project root at `/srv/ccc/projects`
- Complete: CLI migration for existing installs via `ccc-migrate-shared-workspace`
- Complete: managed machine GitHub SSH key under `/etc/ccc/ssh`
- Complete: Accounts actions to setup/sync per-user CCC agent profiles without copying provider auth
- Complete: project permission health and repair action
- Complete: linked legacy project directories are included in permission repair
- Complete: per-account config/skills and provider binary validation
- Complete: Projects GUI migration/status actions
- Complete: legacy `~/projects` and `~/repos` visibility before migration
- Complete: additional work identity shell login defaults to `~/projects`
- Complete: visible CCC update check state and persistent operation output for migration/account actions
- Complete: per-user agent config/skills sync visibility for Claude, Codex, Gemini, and templates
- Complete: per-user Claude settings/statusline baseline sync

Blueprints:
- `docs/specs/2026-05-23-shared-work-identities-design.md`
- `docs/plans/2026-05-23-shared-work-identities.md`
