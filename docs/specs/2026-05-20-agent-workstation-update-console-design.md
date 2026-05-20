# Agent Workstation Update Console Design

## Goal

Replace the current Updates page with a single, understandable update console that separates Agent Workstation application updates from OS package updates. The flow must work from a fresh LXC container without Git dubious ownership failures for `/opt/agent-workstation-src`.

## Current Problems

- The Updates page presents app and OS update actions in one flat action row, then repeats status/output in separate blocks.
- App updates depend on `/opt/agent-workstation-src`, which is created by the root installer but inspected by non-root UI commands and build tooling. Fresh containers can fail with `fatal: detected dubious ownership in repository at '/opt/agent-workstation-src'`.
- The UI still feels like a leftover backend control panel instead of a purpose-built Agent Workstation maintenance screen.

## Architecture

The update system remains command-backed because the project already has the right maintenance boundaries:

- App update status: `ccc-update-status`
- App update execution: `ccc-self-update`
- OS package status: `apt list --upgradable`
- OS package execution: `ccc-os-update`

The GUI changes from one mixed update page to one tabbed update console:

- `App` tab: Agent Workstation source/version status, one update action, and one live output stream.
- `OS` tab: apt package status, one update action, and one command output area.

The backend keeps the existing `/api/self-update` streaming endpoint for app updates and `/api/action` for OS updates. No new background job system is introduced in this pass.

## UI Behavior

The Updates page contains a compact tab bar with two tabs: `App` and `OS`.

The App tab shows:

- A status badge derived from `ccc-update-status`.
- The latest app status output.
- The recent self-update log only when it is useful for diagnosis.
- A primary `Update App` action that streams `ccc-self-update` output.
- Reconnect status when `agent-workstation.service` restarts.

The OS tab shows:

- A badge indicating whether apt reports packages available.
- A concise package update list.
- A primary `Update OS` action that runs `ccc-os-update`.
- A single output area for command results.

The page must not show duplicate windows containing the same update information.

## Git Ownership Fix

The installer and self-update script must make `/opt/agent-workstation-src` safe for both root and the workstation user.

Required behavior:

- Configure `safe.directory` before any non-trivial Git command against `/opt/agent-workstation-src`.
- Keep inline `git -c safe.directory=...` usage for commands in helper scripts.
- Add system-level `safe.directory` after cloning the source checkout.
- Avoid Go VCS stamping failures caused by Git ownership checks during `go build` by building the Agent Workstation binary with `-buildvcs=false`.

## Error Handling

- App update preflight errors should remain visible in the App tab output.
- If the service restarts mid-stream, the UI should continue polling for reconnect and show the final reconnect result.
- OS update command output should stay in the OS tab and not overwrite App tab output.
- If status commands fail, the UI should show the command output instead of hiding the failure.

## Testing

Add focused static and unit coverage around the new behavior:

- Static test assertions for App/OS tab labels and action wiring.
- Static test assertions that old mixed update button text is gone.
- Static test assertions that installer/self-update builds use `-buildvcs=false`.
- Static test assertions that installer setup writes system-level safe-directory for `/opt/agent-workstation-src`.
- Existing Go tests must continue to pass.

## Out Of Scope

- Persistent update job history.
- A new backend update scheduler.
- Changing the existing CLI command names.
- Merging app and OS updates into one command.
