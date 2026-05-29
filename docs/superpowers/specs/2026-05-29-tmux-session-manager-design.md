# Tmux Session Manager — Design Spec
**Date:** 2026-05-29

## Overview

Add a tmux session manager to the CCC management GUI. Each account row in the Accounts panel gains an inline `TMUX SESSIONS` block showing all active sessions for that user with full controls.

## Layout

Sessions appear **inside each account row** in the Accounts panel (not a separate top-level panel). This keeps everything about a user in one place.

## Session Row

Each session displays:
- Status dot: green `●` = has attached client, grey `○` = detached
- Session name
- Attached/idle status (e.g. `attached` or `idle 4m`)
- Window count (e.g. `2 windows`)
- Four action buttons: **Attach · Rename · Send Keys · Kill**

Below all sessions for a user: **+ New Session** and **Kill All** buttons.

If a user has no tmux sessions, the block shows "No tmux sessions" quietly.

## Actions

| Action | Behavior |
|--------|----------|
| **Attach** | Opens the tmux session in the CCC web terminal via the existing PTY endpoint, running `tmux attach-session -t <name>` as the account user |
| **Rename** | Prompts for a new name, runs `tmux rename-session -t <old> <new>` as the account user |
| **Send Keys** | Prompts for a command string, runs `tmux send-keys -t <name> "<cmd>" Enter` as the account user. Injects the command into the session without attaching. |
| **Kill** | Runs `tmux kill-session -t <name>` as the account user. Confirms before killing. |
| **+ New Session** | Prompts for a session name (default: `work`), runs `tmux new-session -d -s <name>` as the account user |
| **Kill All** | Kills all sessions for the user. Confirms before killing. |

## Data Model

Add to `AccountStatus` in `management.go`:
```go
TmuxSessions []TmuxSession `json:"tmuxSessions"`
```

New type:
```go
type TmuxSession struct {
    Name            string `json:"name"`
    Windows         int    `json:"windows"`
    AttachedClients int    `json:"attachedClients"`
    IdleSeconds     int    `json:"idleSeconds"`
}
```

New operation fields on `AccountOperation`:
- `SessionName` string — target session name
- `NewName` string — for rename
- `Keys` string — for send-keys

## Backend

**`ListTmuxSessions(username, home string) []TmuxSession`** — runs:
```
sudo -u <user> tmux list-sessions -F "#{session_name}|#{session_windows}|#{session_attached}|#{session_activity}"
```
Parses output into `[]TmuxSession`. Returns empty slice (not error) if tmux isn't running for that user.

**`collectAccounts()`** — calls `ListTmuxSessions` for each account and populates `TmuxSessions`.

**New cases in `RunAccountOperation`:**
- `tmux-new` — `sudo -u <user> env HOME=<home> tmux new-session -d -s <SessionName>`
- `tmux-kill` — `sudo -u <user> tmux kill-session -t <SessionName>`
- `tmux-kill-all` — `sudo -u <user> tmux kill-server`
- `tmux-rename` — `sudo -u <user> tmux rename-session -t <SessionName> <NewName>`
- `tmux-send-keys` — `sudo -u <user> tmux send-keys -t <SessionName> <Keys> Enter`

**Attach** is handled entirely in the frontend — it opens the PTY terminal pre-populated with the attach command rather than going through `/api/account`.

## Frontend

In `renderAccounts()`, each account section gains a tmux block below the existing action buttons:

```
TMUX SESSIONS
● work    attached   2 windows   [Attach] [Rename] [Send Keys] [Kill]
○ scratch idle 4m    1 window    [Attach] [Rename] [Send Keys] [Kill]
                                 [+ New Session]  [Kill All]
```

Rename and Send Keys show an inline `<input>` + confirm button in place of the prompt (no modal needed — consistent with how Password and Shell work elsewhere in the UI).

Kill and Kill All show a confirm button before executing.

## Refresh

Sessions update with the existing 5-second snapshot poll. No special interval needed.

## Error Handling

- `ListTmuxSessions` failure (tmux not installed, no server): returns empty slice, UI shows "No tmux sessions"
- Operation failures: shown in the existing `account-output` pre element

## Files Changed

- `container-code-companion/internal/system/management.go` — new type, `ListTmuxSessions`, updated `collectAccounts`, new operation cases
- `container-code-companion/web/app.js` — tmux block in `renderAccounts`, event handlers
