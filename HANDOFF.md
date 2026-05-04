# CCC Handoff / Status

**Repo:** https://github.com/oculus-pllx/CCC  
**Date:** 2026-05-04  
**Status:** First live provision failed (CT 119 — IPv6/apt issue, fixed). Re-provisioning.

---

## What This Is

Single-file Proxmox LXC provisioner. Run on a Proxmox host as root. Interactively collects config, creates an Ubuntu 26.04 container, and provisions it end-to-end in ~10–15 minutes. No Docker. No Ansible. No external state.

Target audience: homelab operators running Proxmox (especially TrueNAS-backed) who want a clean Claude Code environment without manual setup.

---

## Current State

| Area | Status |
|---|---|
| Script structure | Complete |
| README | ✅ Synced to all fixes |
| Repo pushed | ✅ `main` branch at `oculus-pllx/CCC` |
| Live provision test | ❌ CT 119 failed (IPv6/apt), destroyed. Re-running with fixes. |
| Static IP / gateway / DNS validation | ✅ All three re-prompt on bad format |
| Storage auto-detection | ✅ `pvesm status --content rootdir`, defaults to `local-lvm` |
| Network ping target | ✅ Uses `CT_GW` (static) or `CT_DNS` (DHCP) — no hardcoded IPs |
| Progress indicators | ✅ `[N/29]` step labels + 30s elapsed ticker on host |
| IPv6 disabled in container | ✅ sysctl + apt ForceIPv4 at provision start |
| Ubuntu status pre-check | ✅ Checks status.canonical.com + archive.ubuntu.com before config |
| Proxmox HA support | ✅ Cluster-only, optional group, non-fatal on failure |
| Skill repo URLs | Unverified — see Risks below |
| Plugin names | Unverified — see Risks below |

---

## Known Risks / Assumptions

### Skill repos (cloned during provision — `--depth 1`)
These GitHub URLs are assumed correct but not verified:
- `github.com/anthropics/skills` → cloned as `anthropic-skills`
- `github.com/forrestchang/andrej-karpathy-skills` → cloned as `karpathy-skills`
- `github.com/mattpocock/skills` → cloned as `mattpocock-skills`
- `github.com/juliusbrussee/caveman` → cloned as `caveman`

Script uses `|| echo "[SKIP] ..."` on each clone — provision won't fail if a repo 404s, but the skill won't be available. Verify URLs before promoting to others.

### Plugin names
These are pasted into a live Claude Code session — not validated at provision time:
```
/plugin install skill-creator@claude-plugins-official
/plugin install superpowers@claude-plugins-official
/plugin install frontend-design@claude-plugins-official
/plugin marketplace add mksglu/context-mode
/plugin marketplace add thedotmack/claude-mem
```
Plugin registry format may change. Update `claude-code-commander.sh` lines 694–714 and README Plugin Setup section if names break.

### Ubuntu 26.04 template
Script uses `pveam available` regex: `ubuntu-26\.04-standard_26\.04-[0-9]+_amd64\.tar\.zst`. If Proxmox changes the naming scheme for 26.04 releases, this regex needs updating (line 57–67 of the script).

### `get-shit-done-cc` npm package
Installed globally via `npx get-shit-done-cc --claude --global`. If package doesn't exist or changes API, it logs a warning and continues — not a blocking failure.

### Storage detection
Script queries `pvesm status --content rootdir` at config time and lists active pools. Defaults to `local-lvm` if present, else first found. Falls back to `local-lvm` string if query returns nothing. User can override at the prompt.

### Rust installed twice
Rust is installed once as root (line 321) and again for the `claude-code` user (line 332). Root install is unused — only the user install matters. The root install is harmless but wasted time (~2 min). Consider removing it in a future cleanup.

---

## TODOs / Future Work

- [ ] Complete first successful end-to-end provision and document results
- [ ] Verify all 4 skill repo URLs are live and correct
- [ ] Verify plugin names against current Claude Code plugin registry
- [ ] Remove redundant root Rust install (save ~2 min provision time)
- [ ] Add `--non-interactive` / config-file mode for automated provisioning
- [ ] Consider adding `CHANGELOG.md` once version bumps start
- [ ] Test storage auto-detection on a standard `local-lvm` Proxmox install
- [ ] Test SSH key install path with both RSA and ed25519 key files
- [ ] Validate Playwright headless Chromium works inside unprivileged LXC (known issue area)

---

## File Map

```
claude-code-commander.sh   Main provisioner script (~900 lines, bash)
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
| `check_ubuntu_connectivity()` | Canonical status API + archive.ubuntu.com curl |
| `get_config()` | All interactive prompts incl. HA detection |
| `get_template()` | pveam download if needed |
| `create_container()` | pct create |
| `configure_ha()` | ha-manager add (cluster only, skipped on single node) |
| `start_container()` | pct start + gateway ping + internet check |
| `provision_container()` | Heredoc push + pct exec, elapsed timer |
| `print_summary()` | Final ready box |
| `main()` | Wires all above in order |

### Inside the provision heredoc (notable blocks)
| Block | Approx lines |
|---|---|
| Locale / timezone | 218–230 |
| Core apt packages | 236–251 |
| Node.js 22 LTS + global npm | 288–307 |
| Go install | 310–317 |
| Rust (user) | 330–335 |
| Python pip ecosystem | 337–344 |
| Claude Code install + symlink | 346–360 |
| Playwright | 362–368 |
| `settings.json` (all perms, agent teams, 64k) | 370–403 |
| `CLAUDE.md` | 405–475 |
| Skill repo clones | 477–498 |
| Statusline script | 500–561 |
| code-server install + enable | 564–572 |
| SSH hardening | 574–583 |
| `.bashrc` (aliases, `ccc` function) | 585–689 |
| `ccc-setup-plugins` script | 694–714 |
| MOTD | 716–729 |
| Git defaults | 731–736 |
| Auto-update cron (Sundays 3 AM ET) | 738–755 |
| Cleanup | 757–766 |
