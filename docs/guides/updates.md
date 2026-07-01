# Updates

CCC separates updates into three independent paths so they can move at different cadences.

| Path | What it updates | How |
|---|---|---|
| **CCC tooling** | The web UI, helper commands, cron, service files | `sudo ccc-self-update` or Updates > App |
| **OS packages** | Debian/Ubuntu apt packages | `sudo ccc-os-update` |
| **Agent configs** | Claude/Codex/Gemini rules, skills, templates | `sudo ccc-sync-agent-configs` |

---

## Checking Update Status

```bash
ccc-update-status
```

Shows the installed provisioner commit, the latest commit on GitHub, how many commits behind you are, and recent commit messages. The Overview page and Updates page also show live status — a top-bar alert appears when an update is available.

---

## Manual CCC Update

**From the CLI:**
```bash
sudo ccc-self-update
```

**From the web UI:**
Go to **Updates > App** and click **Update Now**. The UI launches the update in the background, streams the live log, and automatically reconnects after the brief service restart (~5 seconds). You don't need to refresh the page — it picks up where it left off.

What `ccc-self-update` does:
1. Pulls the latest CCC source from GitHub
2. Builds the new `container-code-companion` binary
3. Re-runs the updateable provisioner section — keeps `/usr/local/bin` helper commands, cron, MOTD, tmux configs, and system scripts current without a full reprovisioning
4. Syncs web assets
5. Updates every account's Claude Code CLI to the latest native version — migrating any older npm-style install to the native installer — so per-user versions never drift
6. Writes the new version to `/etc/ccc/version` and restarts the service
7. Runs `ccc-sync-agent-configs` for your user so new default configs are applied immediately

If the build fails, the service keeps running the old version and the error is in `/var/log/ccc-self-update.log`.

---

## Auto-Update

Enable auto-update from **Updates > App** — no cron editing required.

**Toggle:** Click the ON/OFF pill to enable. When enabled, a scheduled job fires at your chosen time and checks GitHub first — if you're already up to date, it logs a skip and exits. Only if a newer commit exists does it run `ccc-self-update`.

**Schedule:** Two dropdowns appear when auto-update is on:
- **Frequency:** Daily, Every 2 days, Every 3 days, or any day of the week
- **Time:** Any hour (00:00 through 23:00)

Changes to either dropdown take effect immediately. The **Last run** line shows when the cron last fired and what it did (skipped or updated).

The smart-check script (`ccc-auto-update`) is what the cron calls. It:
1. Checks `/etc/ccc/autoupdate-enabled` — if absent, exits silently
2. Runs `ccc-update-status` and parses the output
3. If already up to date: logs "No update needed" and exits
4. If update available: runs `ccc-self-update` and logs the result

---

## OS Package Updates

```bash
sudo ccc-os-update
```

Runs `apt update`, `apt upgrade`, `apt autoremove`, and `apt clean`. This only touches OS packages — CCC tooling and agent configs are unaffected.

Run this when you want security patches or system package updates. It's intentionally not automated.

---

## Agent Config Sync

```bash
sudo ccc-sync-agent-configs              # primary CCC user
sudo ccc-sync-agent-configs --user bob   # specific work identity
sudo ccc-sync-agent-configs --all-users  # every normal login user
```

Pulls the latest Claude/Codex/Gemini rules, skills, and templates from `oculus-configs` and writes them to the target user's home. Does not touch auth tokens, sessions, or history.

**Web UI:** Accounts > **Sync All Account Configs** does the same as `--all-users`.

---

## App Catalog

Go to **App Catalog** in the web UI to see installed vs. available versions for common tools: Node.js, Go, Python, uv, Playwright, Claude Code, Codex, Gemini CLI, GitHub CLI, and more. Click **Update** on any tool to upgrade it independently.

---

## Troubleshooting

**Update hangs at "Fetching latest source"**

The git fetch timed out (120s limit). The script will attempt a re-clone automatically. If it fails:
```bash
sudo tail -80 /var/log/ccc-self-update.log
sudo ccc-self-update  # retry
```

**"Failed to start update" in the web UI**

Try a hard refresh (Ctrl+Shift+R / Cmd+Shift+R) — the browser may have cached an old version of the UI. If the error persists:
```bash
sudo systemctl status container-code-companion.service
sudo ccc-self-update  # fall back to CLI
```

**Auto-update fired but nothing happened**

Check the log:
```bash
tail -20 /var/log/ccc-app-update.log
```

Common causes: already up to date (expected), `ccc-update-status` couldn't reach GitHub (network issue), or the flag file was removed.

**Build fails during self-update**

The compile error is in the log:
```bash
sudo tail -160 /var/log/ccc-self-update.log
```

Usually a Go version mismatch or a network error during module download. After fixing, retry:
```bash
sudo ccc-self-update
```

**Older install: self-update can't rewrite itself**

If `ccc-self-update` predates the updateable-section runner, do a one-time manual helper refresh:
```bash
curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/install/ccc-provision-workstation.sh \
  -o /tmp/ccc-provision-workstation.sh
sudo bash -lc 'set -a; . /etc/ccc/config; set +a; CCC_UPDATEABLE_ONLY=1 bash /tmp/ccc-provision-workstation.sh'
```

After this, `sudo ccc-self-update` works normally.
