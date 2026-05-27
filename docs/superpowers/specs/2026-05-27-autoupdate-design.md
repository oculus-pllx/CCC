# Auto-Update Feature Design

**Date:** 2026-05-27  
**Status:** Approved

## Overview

Add an opt-in auto-update toggle with configurable schedule to the CCC web UI. When enabled, a cron fires at the user-selected frequency and time. It runs a smart check: if GitHub has a newer commit than the installed binary, `ccc-self-update` runs automatically. If already current, it logs a skip and exits. The CCC service restarts briefly (~5 seconds) when an update deploys; no other processes, SSH sessions, or user work is affected.

## Background

A weekly cron already exists (`/etc/cron.d/ccc-app-update`) that unconditionally runs `ccc-update` every Sunday at 3 AM. There is no UI visibility, opt-in control, or schedule configuration. This design replaces that with a UI-controlled smart cron that is disabled by default and fully configurable.

## Components

### 1. Flag File: `/etc/ccc/autoupdate-enabled`

- Presence = enabled, absence = disabled.
- Default: absent (off). Existing installs are not auto-enrolled.
- Created/removed by backend actions via `sudo`.

### 2. Schedule Config: `/etc/ccc/autoupdate-schedule`

Stores frequency and hour as shell variables:
```
AUTOUPDATE_FREQ=daily
AUTOUPDATE_HOUR=3
```

Valid `AUTOUPDATE_FREQ` values: `daily`, `every2days`, `every3days`, `weekly-0` through `weekly-6` (0=Sunday).  
Valid `AUTOUPDATE_HOUR`: 0–23.

Written by the `set-autoupdate-schedule` action, read back by the snapshot for display. Default when absent: `daily` @ hour `3`.

### 3. New Script: `ccc-auto-update` (`/usr/local/bin/ccc-auto-update`)

Installed by the provisioner. Logic:

```
1. Check /etc/ccc/autoupdate-enabled exists — if not, exit 0 silently.
2. Log "Auto-update check: $(date)" to /var/log/ccc-app-update.log.
3. Run ccc-update-status; parse output for newer commit vs up to date.
4. If up to date: log "Already at <commit>. No update needed." and exit 0.
5. If update available: run ccc-self-update (which logs to /var/log/ccc-self-update.log).
6. Log result (success or failure with exit code).
```

### 4. Cron: `/etc/cron.d/ccc-app-update`

Rewritten by the backend whenever the schedule changes. Generated from the schedule config. Examples:

| Frequency | Hour | Cron expression |
|---|---|---|
| Daily | 3 | `0 3 * * *` |
| Every 2 days | 3 | `0 3 */2 * *` |
| Every 3 days | 3 | `0 3 */3 * *` |
| Weekly (Sun) | 3 | `0 3 * * 0` |
| Weekly (Mon) | 3 | `0 3 * * 1` |

Full cron line: `<expr>  root  /usr/local/bin/ccc-auto-update >> /var/log/ccc-app-update.log 2>&1`

Logrotate config for `/var/log/ccc-app-update.log` already exists; no change needed.

### 5. Go Backend

**New fields on `UpdateStatus`** (`internal/system/management.go`):
```go
AutoUpdateEnabled  bool   `json:"autoUpdateEnabled"`
AutoUpdateLastRun  string `json:"autoUpdateLastRun"`
AutoUpdateSchedule string `json:"autoUpdateSchedule"` // human label e.g. "Daily @ 3 AM"
```

- `AutoUpdateEnabled`: `os.Stat("/etc/ccc/autoupdate-enabled")` — no sudo needed.
- `AutoUpdateLastRun`: last non-empty line of `/var/log/ccc-app-update.log` via `tail -1`.
- `AutoUpdateSchedule`: read `/etc/ccc/autoupdate-schedule`, parse freq+hour, format as human label.

**New actions** in `RunWorkstationAction` (all via sudo):
- `enable-autoupdate` → `sudo touch /etc/ccc/autoupdate-enabled`
- `disable-autoupdate` → `sudo rm -f /etc/ccc/autoupdate-enabled`
- `set-autoupdate-schedule` — accepts JSON body with `freq` and `hour` fields; writes schedule config and rewrites cron file. Action body passed via the existing action mechanism (or as a structured account-style operation if needed).

**Schedule rewrite helper** (`scheduleAutoupdateCron(freq string, hour int) error`):
- Validates freq and hour inputs.
- Writes `/etc/ccc/autoupdate-schedule` via sudo tee.
- Generates cron expression, writes `/etc/cron.d/ccc-app-update` via sudo tee.

### 6. UI (`web/app.js`)

In the Updates → App tab, below the version comparison:

```
  Auto-Update   [ ON ● ]
  Schedule:   [ Daily ▼ ]  at  [ 03:00 ▼ ]
  Last run: 2026-05-27 03:00 — already up to date
```

- Toggle is a pill button (matches existing plugin toggle pattern).
- Schedule dropdowns appear only when auto-update is enabled.
- **Frequency options:** Daily, Every 2 days, Every 3 days, Weekly (Mon) … Weekly (Sun)
- **Time options:** 00:00 through 23:00 in 1-hour steps
- Changes to either dropdown fire `set-autoupdate-schedule` immediately (no save button).
- Last run line hidden when log is empty.
- Schedule label (`"Daily @ 3 AM"`) comes from `snapshot.updates.autoUpdateSchedule`.

## Data Flow

```
User enables toggle
  → POST /api/action { action: "enable-autoupdate" }
  → sudo touch /etc/ccc/autoupdate-enabled
  → snapshot refresh → autoUpdateEnabled: true → dropdowns appear

User changes frequency to "Every 2 days"
  → POST /api/action { action: "set-autoupdate-schedule", freq: "every2days", hour: 3 }
  → writes /etc/ccc/autoupdate-schedule
  → rewrites /etc/cron.d/ccc-app-update with "0 3 */2 * *"
  → snapshot refresh → autoUpdateSchedule: "Every 2 days @ 3 AM"

Cron fires at scheduled time
  → /usr/local/bin/ccc-auto-update
  → checks flag file (present → continue)
  → runs ccc-update-status → parses output
  → if newer commit: runs ccc-self-update → service restarts (~5s)
  → logs result to /var/log/ccc-app-update.log

User opens Updates tab next time
  → autoUpdateLastRun: "2026-05-28 03:00 — updated to abc1234"
```

## Error Handling

- `ccc-update-status` fails: log error, exit without updating.
- `ccc-self-update` fails: log exit code, service keeps running current version, next cron retries.
- `set-autoupdate-schedule` with invalid freq/hour: backend returns exitCode 1, UI shows error.
- Cron file write fails (permissions, disk): action returns error, no partial state written.

## Files Changed

| File | Change |
|---|---|
| `install/ccc-provision-workstation.sh` | Add `ccc-auto-update` heredoc, update cron entry to use new script |
| `internal/system/management.go` | 3 new fields on UpdateStatus, 3 new actions, schedule config read/write helper |
| `web/app.js` | Toggle pill + frequency dropdown + time dropdown + last-run line in Updates > App render |

No new Go files. No new routes. No schema changes.

## Out of Scope

- Sub-hour granularity (hourly or every N minutes)
- Auto-updating Claude/Codex CLIs on the auto-update timer
- Push notifications when auto-update fires
- Machine reboot (never — only CCC service restarts)
