# Project Status

Last updated: 2026-05-23
Branch: `main`

## Current State

Container Code Companion is functional for Proxmox LXC workstation provisioning, Debian/Ubuntu host installation, and day-to-day use.

Recent work completed:
- Added shared work identity foundation: fresh installs now create the `ccc` group, `/srv/ccc/projects` as `root:ccc` with `2775`, and link the primary user's `~/projects` there.
- Moved backend Projects and default file browsing operations to the shared `/srv/ccc/projects` root.
- Added `ccc-migrate-shared-workspace --status|--apply` for existing installs, with rsync migration, retained timestamped backups, compatibility symlink creation, and permission repair.
- Moved GitHub SSH management to the managed machine key at `/etc/ccc/ssh/github_ed25519`, with GUI actions to copy, generate, test, configure work identities, and explicitly promote an existing user key.
- Added Accounts actions to setup CCC profiles and sync agent configs per work identity without copying provider auth/session state.
- Added Projects shared-root permission health and a repair action for group-write/setgid permissions.
- Added Projects GUI actions for shared workspace migration status and apply.
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
- Complete: Projects GUI migration/status actions

Blueprints:
- `docs/specs/2026-05-23-shared-work-identities-design.md`
- `docs/plans/2026-05-23-shared-work-identities.md`
