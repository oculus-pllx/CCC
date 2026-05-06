# CCC Handoff / Status

**Repo:** https://github.com/oculus-pllx/CCC  
**Date:** 2026-05-05  
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
| Progress indicators | ✅ `[N/31]` step labels + 30s elapsed ticker |
| IPv6 disabled | ✅ sysctl + apt ForceIPv4 |
| Ubuntu status pre-check | ✅ status.canonical.com + archive.ubuntu.com |
| Debian 13 (Trixie) option | ✅ OS choice at provision start |
| Proxmox HA support | ✅ Cluster-only, optional group, non-fatal |
| Claude binary find | ✅ Searches all of `/home/claude-code`, matches symlinks, fatal on miss |
| pip PATH warnings | ✅ `--no-warn-script-location` |
| False "Ready!" on failure | ✅ Fatal on Claude miss — summary never prints |
| npx install prompts | ✅ `npx --yes` everywhere |
| Playwright | ✅ Skipped at provision — `ccc-install-playwright` on demand |
| Skill discovery | ✅ Repos cloned to `skill-repos/`, `.md` files copied to `skills/` |
| statusLine in settings.json | ✅ Wired to `~/.claude/bin/statusline-command.sh` |
| Cockpit title | ✅ "Claude Code Commander" via `cockpit.conf` |
| udisks2 noise | ✅ Purged after Cockpit install |
| Cockpit "offline" update error | ✅ `network-manager` installed, unmanaged-devices config keeps it off LXC interfaces |
| code-server start failure | ✅ Removed invalid `socket-timeout` option from config.yaml |
| Debian 13 step 3 failure | ✅ Removed `software-properties-common` (unused, Ubuntu-specific); `bat` alias handles both binary names |
| ccc-self-update | ✅ Downloads latest script, re-runs steps 25–27 (tools only, no reprovision) |
| ccc-setup-plugins | ✅ Interactive menu — plugins + pre-installed skills |
| ccc-setup | ✅ Post-install wizard: git identity, SSH keygen, GitHub |
| ccc-update | ✅ apt + claude update + skill repo sync |
| ccc-doctor | ✅ Network, runtimes, services, disk/RAM health check |
| ccc-install-playwright | ✅ On-demand with live output |
| ccc-install-codex | ✅ OpenAI Codex CLI on demand |
| code-server WELCOME.md | ✅ Opens in projects/ — first steps, multi-terminal tip |
| MOTD | ✅ Shows live IPs for :8080/:9090, all ccc-* commands |
| Skill repo URLs | Unverified — see Risks |
| Plugin names | Unverified — see Risks |

---

## Known Risks / Assumptions

### Skill repos (cloned to `~/.claude/skill-repos/` — `--depth 1`)
URLs assumed correct, not verified against live GitHub:
- `github.com/anthropics/skills` → `anthropic-skills`
- `github.com/forrestchang/andrej-karpathy-skills` → `karpathy-skills`
- `github.com/mattpocock/skills` → `mattpocock-skills`
- `github.com/juliusbrussee/caveman` → `caveman`

Each clone uses `|| echo "[SKIP]"` — provision won't fail on 404 but skill won't be available.

### Plugin names
Pasted into live Claude Code session — not validated at provision time:
```
/plugin install skill-creator@claude-plugins-official
/plugin install superpowers@claude-plugins-official
/plugin install frontend-design@claude-plugins-official
/plugin marketplace add mksglu/context-mode
/plugin marketplace add thedotmack/claude-mem
```
Update `ccc-setup-plugins` block in script if registry format changes.

### Ubuntu 26.04 template
Regex: `ubuntu-26\.04-standard_26\.04-[0-9]+_amd64\.tar\.zst`. Update if Proxmox changes naming scheme.

### `get-shit-done-cc` npm package
Installed via `npx --yes get-shit-done-cc --claude --global`. Non-fatal if missing.

### Storage detection
Queries `pvesm status --content rootdir`. Defaults to `local-lvm`. Falls back to string `local-lvm` if query returns nothing.

### Rust installed twice
Root install (unused) + claude-code user install. Root install wastes ~2 min. Future cleanup candidate.

---

## TODOs / Future Work

- [ ] Complete first clean end-to-end provision with latest script
- [ ] Verify all 4 skill repo URLs are live
- [ ] Verify plugin names against current Claude Code registry
- [ ] Remove redundant root Rust install (~2 min savings)
- [ ] Add `--non-interactive` / config-file mode for automated provisioning
- [ ] Consider `CHANGELOG.md` once version bumps start
- [ ] Test storage auto-detection on standard `local-lvm` Proxmox install
- [ ] Test SSH key install with both RSA and ed25519
- [x] Playwright — moved to on-demand `ccc-install-playwright`
- [x] Proxmox VE attribution in README
- [x] Skill discovery fix (copy .md files to skills/)
- [x] statusLine wired into settings.json
- [x] Interactive plugin/skill menu
- [x] Post-install wizard (ccc-setup)
- [x] Update command (ccc-update)
- [x] Health check (ccc-doctor)
- [x] code-server welcome file
- [x] Codex CLI install (ccc-install-codex)

---

## File Map

```
claude-code-commander.sh   Main provisioner (~1200 lines, bash)
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

### Inside the provision heredoc (31 steps)

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
| 9 | Global npm packages |
| 10 | get-shit-done-cc |
| 11 | Go |
| 12 | Rust (system) |
| 13 | Create claude-code user |
| 14 | Rust (claude-code user) |
| 15 | Python ecosystem |
| 16 | Claude Code install + symlink (fatal on miss) |
| 17 | Playwright (skipped — ccc-install-playwright) |
| 18 | settings.json (all perms, statusLine, agent teams, 64k) |
| 19 | CLAUDE.md |
| 20 | Skill repos → skill-repos/ + copy .md to skills/ |
| 21 | Statusline script |
| 22 | code-server + WELCOME.md + .vscode workspace |
| 23 | SSH hardening |
| 24 | Shell environment + aliases + ccc function |
| 25 | ccc-setup-plugins (interactive menu) |
| 26 | ccc-install-playwright |
| 27 | MOTD (live IPs, all ccc-* commands) |
| 28 | Git defaults |
| 29 | Auto-update cron (Sundays 3 AM ET) |
| 30 | Cockpit + cockpit.conf + purge udisks2 |
| 31 | Cleanup |
