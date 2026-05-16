# Design: Agent Workstation Rename and oculus-configs Sync

Date: 2026-05-16

## Goal

Rename Claude Code Commander into Agent Workstation and make the product accurately describe what the repo builds: a headless Proxmox LXC dev workstation for Claude Code, OpenAI Codex, and Gemini CLI.

The container remains headless. It must not install a desktop GUI, and it must not import the separate `oculus-configs` web UI/service. Browser-accessible tools are still allowed:

- Port 8080: code-server / VS Code Web for editing and terminals.
- Port 9090: Cockpit with the Agent Workstation management plugin.

## Non-Goals

- Do not add another web GUI.
- Do not run `oculus-configs/install.sh`.
- Do not install `configure.py` or the `oculus-configure` service from `oculus-configs`.
- Do not break existing containers only because they still have `ccc-*` commands.

## Naming

User-facing names should become Agent Workstation:

- README title and descriptions.
- Provisioning prompts and final summary text.
- MOTD labels.
- Cockpit plugin title and menu label.
- code-server welcome text.
- Script comments where they describe the product.

The old CCC abbreviation can remain as a compatibility layer in command names and config keys during this change. Commands such as `ccc-update`, `ccc-os-update`, and `ccc-self-update` continue to work. Optional `aw-*` aliases may be added later, but this design does not require them.

## Update Model

Agent Workstation exposes three separate update paths:

1. OS updates
   - Command: `ccc-os-update`
   - Scope: apt package metadata, package upgrades, package cleanup.
   - Does not update the provisioner or agent config.

2. Agent Workstation tooling updates
   - Command: `ccc-self-update`
   - Scope: this repo's updateable installer sections, MOTD, helper commands, Cockpit plugin, docs copied into the container.
   - Does not automatically change shared agent config unless explicitly wired through the third command.

3. Agent config updates
   - New command: `ccc-sync-agent-configs`
   - Scope: pull or clone `/opt/oculus-configs`, then sync selected Claude/Codex/Gemini files into the working user's home.
   - This command is also run during first provisioning.

## oculus-configs Role

`oculus-configs` is the single upstream source of truth for shared agent behavior across normal installs and Agent Workstation containers.

Agent Workstation consumes only data/config from that repo:

- `claude/CLAUDE.md`
- `claude/rules/*.md`
- `claude/mcp.json`
- `codex/AGENTS.md`
- `codex/skills/*` when present
- `gemini/GEMINI.md`
- `gemini/skills/*` when present
- `templates/*`

The upstream repo checkout lives at `/opt/oculus-configs` and is owned by the working user so Cockpit and CLI tools can inspect/update it without git dubious-ownership failures.

## Sync Behavior

`ccc-sync-agent-configs` should be idempotent and safe to re-run.

Behavior:

- Clone `oculus-configs` if `/opt/oculus-configs/.git` is missing.
- Otherwise fetch and fast-forward/pull the configured branch.
- Copy files into the working user's home.
- Create parent directories as needed.
- Warn and continue for optional paths that do not exist, such as `codex/skills` or `gemini/skills`.
- Preserve ownership as the working user.
- Do not overwrite live Claude MCP secrets blindly:
  - Install `claude/mcp.json` as `~/.claude/mcp.template.json`.
  - If `~/.claude/mcp.json` does not exist, copy the template there.
  - If `~/.claude/mcp.json` exists, leave it untouched.
- Top-level instruction files (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`) are managed files. Sync may replace them after writing timestamped `.bak` files when they already exist.

## Provisioning Flow

Current step 18 becomes an invocation of the same sync logic used by `ccc-sync-agent-configs`. This avoids having two slightly different implementations.

The provisioner should:

- Create the working user's `projects`, `.claude`, `.codex`, `.gemini`, and `Templates` directories.
- Install or update `/usr/local/bin/ccc-sync-agent-configs` inside the updateable section.
- Run `ccc-sync-agent-configs --no-pull` or equivalent during provisioning after the initial clone, so first install and later manual sync use the same file-copy rules.

## Cockpit Plugin

Cockpit remains the management UI on port 9090.

Required text updates:

- Menu/title: Agent Workstation.
- Overview should mention Claude, Codex, and Gemini readiness rather than only Claude.
- Updates tab should show three categories: OS, Agent Workstation, and oculus-configs.

The plugin may call the existing commands:

- OS: `ccc-os-update`
- Agent Workstation: `ccc-update-status` and `ccc-self-update`
- oculus-configs: `ccc-sync-agent-configs`

No terminal emulator or separate Node dashboard is introduced.

## Documentation

README and HANDOFF should describe:

- Agent Workstation as a headless Proxmox LXC dev workstation.
- Port 8080 as VS Code Web / code-server.
- Port 9090 as Cockpit plus Agent Workstation controls.
- The three update paths.
- `oculus-configs` as shared upstream agent config, not an additional UI.
- Claude Code, Codex, and Gemini CLI support.

## Compatibility

Existing `ccc-*` commands stay in place. The product can be renamed without forcing users to learn new command names immediately.

The repository name and primary script filename can remain unchanged for now unless a later migration decides to rename them. This avoids breaking the current curl install URL.

## Verification

Minimum verification before committing implementation:

- `bash -n claude-code-commander.sh`
- Extract embedded Cockpit plugin JavaScript and run `node --check`.
- `git diff --check`
- Grep checks:
  - No references to the removed standalone dashboard remain.
  - No `oculus-configure`, `configure.py`, or `localhost:4827` service setup is added.
  - Agent Workstation appears in user-facing product text.
  - `ccc-sync-agent-configs` is present in script, README, and MOTD/help text.

