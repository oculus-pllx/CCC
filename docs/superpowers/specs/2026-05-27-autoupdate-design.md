# Auto-Update Feature Design

**Date:** 2026-05-27  
**Status:** Approved

## Overview

Add an opt-in auto-update toggle to the CCC web UI. When enabled, a daily cron fires a smart check: if GitHub has a newer commit than the installed binary, `ccc-self-update` runs automatically. If already current, it logs a skip and exits. The CCC service restarts briefly (~5 seconds) when an update deploys; no other processes, SSH sessions, or user work is affected.

## Background

A weekly cron already exists (`/etc/cron.d/ccc-app-update`) that unconditionally runs `ccc-update` every Sunday at 3 AM. There is no UI visibility or opt-in control. This design replaces that with a smarter, UI-controlled daily cron that is disabled by default.

## Components

### 1. Flag File: `/etc/ccc/autoupdate-enabled`

- Presence = enabled, absence = disabled.
- Default: absent (off). Existing installs are not auto-enrolled.
- Created/removed by backend actions via `sudo`.

### 2. New Script: `ccc-auto-update` (`/usr/local/bin/ccc-auto-update`)

Installed by the provisioner. Logic:

```
1. Check /etc/ccc/autoupdate-enabled exists — if not, exit 0 silently.
2. Log "Auto-update check: $(date)" to /var/log/ccc-app-update.log.
3. Run ccc-update-status; parse output for "up to date" vs newer commit.
4. If up to date: log "Already at <commit>. No update needed." and exit 0.
5. If update available: run ccc-self-update (logs to /var/log/ccc-self-update.log).
6. Log result (success or failure with exit code).
```

Logs to `/var/log/ccc-app-update.log` (existing log, existing logrotate config).

### 3. Cron: `/etc/cron.d/ccc-app-update`

Changed from:
```
0 3 * * 0  root  /usr/local/bin/ccc-update >> /var/log/ccc-app-update.log 2>&1
```
To:
```
0 3 * * *  root  /usr/local/bin/ccc-auto-update >> /var/log/ccc-app-update.log 2>&1
```

Daily at 3 AM instead of weekly Sunday. Safe because the smart check means no restart fires unless a real update is available.

### 4. Go Backend

**New fields on `UpdateStatus`** (`internal/system/management.go`):
```go
AutoUpdateEnabled bool   `json:"autoUpdateEnabled"`
AutoUpdateLastRun string `json:"autoUpdateLastRun"`
```

`AutoUpdateEnabled`: check if `/etc/ccc/autoupdate-enabled` exists (no sudo needed — readable by service user).  
`AutoUpdateLastRun`: last non-empty line of `/var/log/ccc-app-update.log` (read with `tail -1`, no sudo).

**New actions** in `RunWorkstationAction`:
- `enable-autoupdate` → `sudo touch /etc/ccc/autoupdate-enabled`
- `disable-autoupdate` → `sudo rm -f /etc/ccc/autoupdate-enabled`

Both require sudo (file lives in `/etc/ccc/` which is root-owned). Both are already covered by the existing `ALL=(ALL) NOPASSWD: ALL` sudoers rule for the service account.

### 5. UI (`web/app.js`)

In the Updates → App tab render function, add below the version comparison lines:

```
Auto-Update  [ ON ● ] / [ OFF ○ ]   Daily @ 3 AM
Last run: 2026-05-25 03:00 — already up to date
```

- Toggle is a pill button (matches existing plugin toggle pattern in Configs tab).
- Clicking toggle calls the appropriate action and re-renders the section.
- "Last run" line is hidden when log is empty (fresh install, never run).
- Label shows "Daily @ 3 AM" as static text (no schedule picker needed).

## Data Flow

```
User clicks toggle ON
  → POST /api/action { action: "enable-autoupdate" }
  → sudo touch /etc/ccc/autoupdate-enabled
  → GET /api/workstation → snapshot.updates.autoUpdateEnabled = true
  → UI re-renders toggle as ON

3 AM cron fires
  → /usr/local/bin/ccc-auto-update
  → checks flag file (exists → continue)
  → runs ccc-update-status → parses "GitHub: abc1234" vs "Installed: abc1234"
  → if newer: runs ccc-self-update → service restarts (~5s)
  → logs result to /var/log/ccc-app-update.log

User views Updates tab
  → snapshot.updates.autoUpdateLastRun = last line of /var/log/ccc-app-update.log
  → displayed below toggle
```

## Error Handling

- If `ccc-update-status` fails: log the error and exit without updating. No restart.
- If `ccc-self-update` fails: log the exit code. Service continues running current version. Next cron fire will retry.
- Toggle action failures (sudo fails, disk full): backend returns exitCode 1, UI shows error in existing action-output panel.

## Files Changed

| File | Change |
|---|---|
| `install/ccc-provision-workstation.sh` | Add `ccc-auto-update` heredoc, update cron entry |
| `internal/system/management.go` | Add 2 fields to UpdateStatus, add 2 actions, read flag+log in collectUpdates |
| `web/app.js` | Add toggle pill + last-run line to Updates > App render |

No new Go files. No new routes. No schema changes.

## Out of Scope

- Schedule picker (daily @ 3 AM is fixed)
- Auto-updating Claude/Codex CLIs on the auto-update timer (user can run `ccc-update` manually)
- Notification when auto-update fires (log is visible in the UI after next page load)
- Machine reboot (never happens — only the CCC service restarts)
