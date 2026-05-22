# Project Status

Last updated: 2026-05-21
Branch: `main`

## Current State

Container Code Companion is functional for Proxmox LXC workstation provisioning, Debian/Ubuntu host installation, and day-to-day use.

Recent work completed:
- Rebranded the project as Container Code Companion with Parallax Group branding.
- Added a Debian/Ubuntu Linux-host installer path alongside the Proxmox LXC bootstrap.
- Rebuilt the native Go web UI around workstation workflows instead of Cockpit-style remnants.
- Added a real login page, mobile drawer navigation, footer branding, theme controls, and optional CRT effects.
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
- `go build -buildvcs=false -o /tmp/container-code-companion-test ./cmd/server`
- `git diff --check`

## Known Notes

- CIFS mounts from inside an unprivileged LXC often fail unless Proxmox/container settings allow it. Prefer host-side mount plus bind mount for fewer user issues.
- Ollama was removed from App Catalog because local model serving inside this LXC is likely to create support problems on Proxmox hosts.
- Existing `HANDOFF.md` files are local/ignored and should not be committed unless project policy changes.

## Next Work

The original GUI punchlist is complete. New work should come from fresh field testing, user issues, or explicit feature requests.
