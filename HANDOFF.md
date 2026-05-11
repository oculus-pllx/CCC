# CCC Handoff / Status

**Repo:** https://github.com/oculus-pllx/CCC  
**Date:** 2026-05-09  
**Status:** Active development — iterative live provisions, most bugs fixed. Pending clean end-to-end pass with latest script.

---

## What This Is

Single-file Proxmox LXC provisioner. Run on a Proxmox host as root. Interactively collects config, creates an Ubuntu 26.04 (or Debian 13) container, and provisions it end-to-end in ~10–15 minutes. No Docker. No Ansible. No external state.

Target audience: homelab operators running Proxmox (especially TrueNAS-backed) who want a clean Claude Code environment without manual setup.

---

## Current State

| Area | Status |
|---|---|
| Script structure | Complete |
| README | ✅ Synced |
| Repo | ✅ `main` at `oculus-pllx/CCC` |
| Live provision test | ⚠️ Multiple runs — bugs fixed iteratively. Pending first clean end-to-end pass. |
| Static IP / gateway / DNS validation | ✅ Re-prompt on bad format |
| Storage auto-detection | ✅ `pvesm status --content rootdir`, defaults to `local-lvm` |
| Network ping target | ✅ Uses `CT_GW` (static) or `CT_DNS` (DHCP) |
| Progress indicators | ✅ `[N/29]` step labels + 30s elapsed ticker |
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
| Cockpit "offline" update error | ✅ NetworkManager managed dummy connection + PackageKit `UseNetworkManager=false`; repair command `ccc-fix-cockpit-updates`; verifier `ccc-verify-cockpit-updates` |
| code-server start failure | ✅ Removed invalid `socket-timeout` option from config.yaml |
| code-server password special chars | ✅ `printf` + `tee` — no heredoc expansion, handles any char |
| chpasswd special chars | ✅ `printf '%s:%s'` piped via stdin — no shell expansion truncation |
| Debian 13 step 3 failure | ✅ Removed `software-properties-common` (unused, Ubuntu-specific); `bat` alias handles both binary names |
| ccc-self-update | ✅ Downloads latest script, re-runs tools/MOTD steps only (no reprovision), reads `/etc/ccc/config` |
| ccc-onboarding / ccc-setup | ✅ First-login wizard: git identity, SSH keygen, GitHub known_hosts |
| ccc-kit | ✅ Prints Cockpit Command Center URL, public/private GitHub URL examples, and where to paste plugin commands |
| ccc-update | ✅ apt + Claude update as provisioned user; plugin mgmt delegated to CCC Command Center |
| ccc-doctor | ✅ Network, runtimes, services, disk/RAM health check, custom-user aware |
| ccc-install-playwright | ✅ On-demand with live output |
| ccc-install-codex | ✅ OpenAI Codex CLI on demand |
| ccc-install-jcodemunch | ✅ jCodeMunch MCP — pip install + claude mcp add |
| CCC Command Center (Cockpit) | ✅ Cockpit page — connect GitHub kit repo, browse plugins, copy commands, run tools/updates; local Node helper supports SSH private repos |
| code-server WELCOME.md | ✅ Opens in projects/ — first steps, multi-terminal tip |
| MOTD | ✅ Shows live IPs for :8080/:9090, all ccc-* commands |
| Hardcoded skill repos | ✅ Removed — CCC Command Center owns plugin/skill install |
| ccc-setup-plugins | ✅ Removed — CCC Command Center replaces entirely |
| Caveman in kit repo | ✅ Added as git submodule to oculus-pllx/oculus-claude-kit |

---

## Known Risks / Assumptions

### Ubuntu 26.04 template
Regex: `ubuntu-26\.04-standard_26\.04-[0-9]+_amd64\.tar\.zst`. Update if Proxmox changes naming scheme.

### Storage detection
Queries `pvesm status --content rootdir`. Defaults to `local-lvm`. Falls back to string `local-lvm` if query returns nothing.

### Rust installed twice
Root install (unused) + claude-code user install. Root install wastes ~2 min. Future cleanup candidate.

---

## TODOs / Future Work

- [ ] Complete first clean end-to-end provision with latest script
- [ ] Verify CCC Command Center loads and connects to a GitHub repo on fresh provision
- [ ] Verify Cockpit GUI updates work (NM dummy connection fix)
- [ ] Remove redundant root Rust install (~2 min savings)
- [ ] Add `--non-interactive` / config-file mode for automated provisioning
- [ ] Consider `CHANGELOG.md` once version bumps start
- [ ] Test storage auto-detection on standard `local-lvm` Proxmox install
- [ ] Test SSH key install with both RSA and ed25519
- [x] CCC Command Center: add support for private repos via SSH key (post-ccc-onboarding)
- [x] Playwright — moved to on-demand `ccc-install-playwright`
- [x] Proxmox VE attribution in README
- [x] statusLine wired into settings.json
- [x] Post-install wizard (ccc-setup)
- [x] Update command (ccc-update)
- [x] Health check (ccc-doctor)
- [x] code-server welcome file
- [x] Codex CLI install (ccc-install-codex)
- [x] Strip hardcoded skill repos + ccc-setup-plugins — CCC Command Center owns plugin install
- [x] Password special char truncation fix (chpasswd + code-server config.yaml)
- [x] Caveman added to oculus-claude-kit as git submodule

---

## File Map

```
claude-code-commander.sh   Main provisioner (~900 lines, bash)
README.md                  User-facing docs
HANDOFF.md                 This file — project status and context
.gitignore                 Excludes Windows Zone.Identifier files
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

### Inside the provision heredoc (29 steps)

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
| 18 | CLAUDE.md |
| 19 | Statusline script |
| 20 | code-server + WELCOME.md + .vscode workspace |
| 21 | SSH hardening |
| 22 | Shell environment + aliases + ccc function |
| 23 | ccc-install-playwright |
| 24 | MOTD (live IPs, all ccc-* commands) |
| 25 | Git defaults |
| 26 | Auto-update cron (Sundays 3 AM ET) |
| 27 | Cockpit + NM dummy connection + PackageKit offline fix + cockpit.conf |
| 28 | CCC Command Center Cockpit package + local kit API helper |
| 29 | Cleanup |
