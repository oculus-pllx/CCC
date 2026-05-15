# CCC Handoff / Status

**Repo:** https://github.com/oculus-pllx/CCC  
**Date:** 2026-05-15  
**Status:** Active development — pending first clean end-to-end provision with latest script.

---

## What This Is

Single-file Proxmox LXC provisioner. Run on a Proxmox host as root. Interactively collects config, creates an Ubuntu 26.04 (or Debian 13) container, and provisions it end-to-end in ~10–15 minutes. No Docker. No Ansible. No external state.

Target audience: homelab operators running Proxmox who want a clean Claude Code environment without manual setup.

---

## Current State

| Area | Status |
|---|---|
| Script structure | Complete |
| README | ✅ Synced |
| Repo | ✅ `main` at `oculus-pllx/CCC` |
| Live provision test | ⚠️ Pending first clean end-to-end pass with latest script |
| Static IP / gateway / DNS validation | ✅ Re-prompt on bad format |
| Storage auto-detection | ✅ `pvesm status --content rootdir`, defaults to `local-lvm` |
| Network ping target | ✅ Uses `CT_GW` (static) or `CT_DNS` (DHCP) |
| Progress indicators | ✅ `[N/28]` step labels + 30s elapsed ticker |
| IPv6 disabled | ✅ sysctl + apt ForceIPv4 |
| Ubuntu status pre-check | ✅ status.canonical.com + archive.ubuntu.com |
| Debian 13 (Trixie) option | ✅ OS choice at provision start |
| Proxmox HA support | ✅ Cluster-only, optional group, non-fatal |
| Claude binary find | ✅ Searches all of `/home/claude-code`, matches symlinks, fatal on miss |
| pip PATH warnings | ✅ `--no-warn-script-location` |
| False "Ready!" on failure | ✅ Fatal on Claude miss — summary never prints |
| npx install prompts | ✅ `npx --yes` everywhere |
| Playwright | ✅ Skipped at provision — `ccc-install-playwright` on demand |
| statusLine in settings.json | ✅ Wired to `~/.claude/bin/statusline-command.sh` |
| Cockpit title | ✅ "Claude Code Commander" via `cockpit.conf` |
| udisks2 noise | ✅ Purged after Cockpit install |
| Cockpit "offline" update error | ✅ NM managed dummy connection + PackageKit `UseNetworkManager=false` |
| code-server start failure | ✅ Removed invalid `socket-timeout` option from config.yaml |
| code-server password special chars | ✅ `printf` + `tee` — no heredoc expansion |
| chpasswd special chars | ✅ `printf '%s:%s'` piped via stdin |
| ccc-self-update | ✅ Downloads latest script, re-runs tools/MOTD/plugin steps only |
| ccc-update-status | ✅ Shows installed commit, latest GitHub commit, behind count |
| ccc-onboarding / ccc-setup | ✅ First-login wizard: git identity, SSH keygen, GitHub known_hosts |
| oculus-configs (step 18) | ✅ Clones repo, copies CLAUDE.md, rules/, templates/, AGENTS.md, GEMINI.md |
| Cockpit CCC plugin (step 27) | ✅ Prism-dark 6-tab plugin: Overview, Projects, CLAUDE.md, MCP, Plugins, Updates |
| MOTD | ✅ Shows :8080/:9090, all ccc-* commands |

---

## Known Risks / Assumptions

### Ubuntu 26.04 template
Regex: `ubuntu-26\.04-standard_26\.04-[0-9]+_amd64\.tar\.zst`. Update if Proxmox changes naming scheme.

### Storage detection
Queries `pvesm status --content rootdir`. Defaults to `local-lvm`. Falls back to string `local-lvm` if query returns nothing.

### Rust installed twice
Root install (unused) + claude-code user install. Root install wastes ~2 min. Future cleanup candidate.

### oculus-configs clone (step 18)
Cloned to `/opt/oculus-configs`. Expects the following paths in that repo:
- `claude/CLAUDE.md`
- `claude/rules/` (directory)
- `templates/` (directory)
- `codex/skills/AGENTS.md`
- `gemini/skills/GEMINI.md`

Missing paths emit `warn` (yellow) and continue — not fatal.

### Cockpit plugin (step 27)
Written to `/usr/share/cockpit/ccc/`. Inside `CCC_UPDATEABLE_START/END` so `ccc-self-update` can push new plugin versions without reprovisioning. Dev scaffold in `docs/cockpit-plugin/` (uses `mock-cockpit.js` for local browser testing; production build uses `/cockpit/base1/cockpit.js`).

---

## TODOs / Future Work

- [ ] Complete first clean end-to-end provision with latest script
- [ ] Test oculus-configs paths in live container
- [ ] Test Cockpit plugin in live Cockpit session (all 6 tabs)
- [ ] Remove redundant root Rust install (~2 min savings)
- [ ] Add `--non-interactive` / config-file mode for automated provisioning
- [ ] Test storage auto-detection on standard `local-lvm` Proxmox install
- [ ] Test SSH key install with both RSA and ed25519

---

## File Map

```
claude-code-commander.sh     Main provisioner (~2400 lines, bash)
README.md                    User-facing docs
HANDOFF.md                   This file — project status and context
docs/cockpit-plugin/
  manifest.json              Cockpit plugin manifest
  mock-cockpit.js            Mock cockpit API for local browser dev
  index.html                 Full Prism-dark CCC plugin (production: /cockpit/base1/cockpit.js)
docs/superpowers/
  specs/                     Design specs
  plans/                     Implementation plans
```

---

## Key Script Sections (approximate — line numbers shift with edits)

| Section | Notes |
|---|---|
| Colors / helpers | Top of file |
| `preflight()` | root + pct/pveam/pvesh check |
| `check_apt_connectivity()` | Canonical status API + mirror reachability |
| `get_config()` | All interactive prompts incl. OS choice, HA detection |
| `get_template()` | pveam download if needed |
| `create_container()` | pct create |
| `configure_ha()` | ha-manager add (cluster only) |
| `start_container()` | pct start + gateway ping |
| `provision_container()` | Heredoc push + pct exec, elapsed timer |
| `print_summary()` | Final ready box (only prints on full success) |
| `main()` | Wires all above in order |

### Inside the provision heredoc (28 steps)

| Step | Block |
|---|---|
| 1 | Locale / timezone |
| 2 | System update |
| 3 | Core apt packages |
| 4 | Build tools & dev libraries |
| 5 | Search & productivity tools |
| 6 | Database clients |
| 7 | yq (mikefarah Go binary) |
| 8 | Node.js 22 LTS |
| 9 | Global npm packages (typescript, ts-node, tsx only) |
| 10 | Go |
| 11 | Rust (system) |
| 12 | Create claude-code user |
| 13 | Rust (claude-code user) |
| 14 | Python ecosystem (pip available, no pre-installs) |
| 15 | Claude Code install + symlink (fatal on miss) |
| 16 | Playwright (skipped — ccc-install-playwright) |
| 17 | settings.json (all perms, statusLine, agent teams, 64k) |
| 18 | oculus-configs clone → CLAUDE.md, rules/, templates/, AGENTS.md, GEMINI.md |
| 19 | Statusline script |
| 20 | code-server + WELCOME.md + .vscode workspace |
| 21 | SSH hardening |
| 22 | Shell environment + aliases + ccc function |
| 23 | ccc-install-playwright / ccc-install-codex / ccc-install-jcodemunch |
| 24 | MOTD (live IPs, all ccc-* commands) |
| 25 | Git defaults |
| 26 | Auto-update cron (Sundays 3 AM ET) |
| 27 | Cockpit + NM dummy connection + PackageKit offline fix + cockpit.conf + CCC plugin |
| 28 | Cleanup |
