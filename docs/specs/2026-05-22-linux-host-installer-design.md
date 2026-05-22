# Linux Host Installer Design

Date: 2026-05-22
Status: Approved design sections, pending implementation plan

## Goal

Add an installation path for Container Code Companion that installs the CCC
workstation experience onto an existing Debian or Ubuntu system without creating
a Proxmox LXC container.

The Linux host installer exists for the integrated CCC workflow: CCC web UI,
code-server, provider tools, and the Parallax `oculus-configs` integration. It
is not a generic developer-machine bootstrapper.

## Scope

The first version supports:

- Existing Debian and Ubuntu systems with `sudo` access.
- LAN-reachable authenticated CCC and code-server web services.
- Current-user installation by default.
- Optional dedicated CCC user creation during install.
- The same required `oculus-configs` sync used by the LXC workstation.
- A README install choice that makes Proxmox LXC and existing-Linux paths clear.

The first version does not promise:

- Fedora, RHEL, Arch, macOS, or Windows support.
- A noninteractive automation interface.
- A reinstall/repair wizard for existing Linux-host installations.
- Host network, hostname, firewall, or SSH security policy management.

## Install Paths

CCC remains one project with two install entrypoints.

| Use case | Entrypoint | Run location |
| --- | --- | --- |
| Create a new CCC Proxmox LXC | `ccc-bootstrap.sh` | Proxmox host as root |
| Install CCC on existing Linux | `ccc-install-linux.sh` | Debian or Ubuntu host with `sudo` |

`ccc-bootstrap.sh` keeps ownership of Proxmox orchestration: LXC template
selection, container resources, networking, optional HA, and invoking
workstation provisioning inside the new container.

`ccc-install-linux.sh` owns existing-host concerns: distro preflight, target
user selection, a host-safe install summary, and reporting LAN service URLs
after install.

## Architecture

Both entrypoints should call a shared workstation provisioning layer instead of
maintaining copied provisioning bodies. The current LXC bootstrap already has a
large workstation provisioner inside its in-container heredoc; implementation
should extract that behavior carefully while preserving the existing LXC flow.

The shared layer should receive explicit install inputs instead of prompting for
Proxmox or host decisions:

- install mode
- target user
- target home directory
- CCC repo/ref/update script settings
- service exposure/auth settings
- whether machine-owner policy changes are allowed

`/etc/ccc/config` should persist the install mode so CCC update tooling and UI
guidance can distinguish an LXC workstation from a Linux host workstation. The
mode values should be explicit, for example:

```bash
CCC_INSTALL_MODE="proxmox-lxc"
CCC_INSTALL_MODE="linux-host"
```

## Linux Installer Flow

1. Preflight the host.
   - Confirm Debian or Ubuntu package tooling.
   - Confirm `sudo` access.
   - Check download reachability needed for GitHub and provider/tool installers.
   - Detect an existing CCC installation before changing the system.
2. Select the target user.
   - Default to the user who launched the installer.
   - Offer a dedicated CCC user option for fresh VMs or shared servers.
   - If a dedicated user is selected, prompt for username and password and set
     up only the access CCC needs.
3. Show an install summary.
   - Show target user/home, install mode, services/ports, and broad system
     changes before the user proceeds.
4. Provision the workstation.
   - Install the baseline dev stack and system packages required by CCC.
   - Install CCC UI/service, code-server, CCC commands, and update support.
   - Install the provider-integration baseline: Node/npm, Go, Rust, Python
     basics, GitHub CLI, Claude Code prerequisites, and Codex sandbox
     prerequisite packages.
   - Sync `oculus-configs` as a required step.
   - Install managed provider config templates and statusline assets for the
     target user.
5. Report completion.
   - Print CCC UI and code-server URLs, target username, credential guidance,
     retry commands, and optional tools available through CCC afterward.

## Provisioning Boundaries

### Shared CCC-Owned Setup

Both install paths may own:

- `/etc/ccc` configuration and installed-version state
- `/usr/local/bin/ccc-*` commands
- CCC binary, web assets, and `container-code-companion.service`
- code-server install/config/service for the target user
- baseline dev tools needed for provider integrations
- `oculus-configs` clone/sync and managed provider templates
- target-user shell helpers, statusline, projects, and templates
- CCC tooling update behavior

### Proxmox LXC Only

The Proxmox path owns:

- Proxmox API and `pct` work
- LXC creation, templates, resources, and configured network
- container bootstrap passwords and optional HA registration
- container-specific SSH hardening decisions
- LXC-specific workarounds only when still justified for that path

### Existing Linux Host Only

The Linux-host path must:

- respect existing host identity and networking
- avoid disabling IPv6 globally
- avoid rewriting SSH hardening or root-login policy
- avoid assuming the host is a blank OS
- warn before installing broad packages and services
- configure authenticated LAN-reachable CCC and code-server services

CCC UI guidance should use install mode or environment detection where host type
matters. For example, map-drive guidance should mention Proxmox mount capability
for LXC workstations without presenting that as the rule for every Linux host.

## Required And Optional Components

The installer should install an integrated baseline by default:

- CCC web UI and service
- code-server
- CCC command/update tooling
- `oculus-configs` sync and managed templates
- Claude Code baseline setup and statusline
- Codex sandbox prerequisites such as bubblewrap
- GitHub CLI, Git, Node/npm, Go, Rust, Python basics, build tools, and search
  tools used by CCC workflows

Larger or secondary tools may remain post-install options through CCC commands
or App Catalog, including Playwright browser payloads, Gemini CLI, Aider, and
future non-baseline tools.

## Failure Handling

- Unsupported distributions stop before system changes.
- Missing `sudo` access stops before provisioning.
- Required download/network preflight failures stop with a clear reason.
- Failed `oculus-configs` sync means the installer does not call the workstation
  ready; it prints `ccc-sync-agent-configs` retry guidance.
- Optional provider-tool failures must be reported separately from CCC core
  install status.
- Failed CCC or code-server service startup must report status/log commands.
- Existing CCC detection should stop and direct the user to an update path in
  the first version rather than overwriting state implicitly.

## README Contract

The README should present the install choice before the long feature list:

- "I want a new Proxmox LXC" with the `ccc-bootstrap.sh` command.
- "I already have Debian or Ubuntu Linux" with the
  `ccc-install-linux.sh` command.

It should state what each path changes. The existing-Linux path should be
described as Debian/Ubuntu-only until other distros are explicitly designed and
tested.

## Verification

Automated checks should cover:

- shell syntax/static checks for both entrypoints and shared provisioning
  scripts
- assertions that Proxmox/LXC-only commands stay out of the Linux-host path
- assertions that persisted config records install mode and target-user inputs
- existing Go and UI test suites for CCC behavior

Manual verification should cover:

- fresh Proxmox LXC install
- fresh Ubuntu host or VM install using the current user
- fresh Debian host or VM install using a dedicated CCC user
- LAN browser access to CCC and code-server after Linux-host installation

## Implementation Risk

The riskiest work is extracting the workstation provisioner from the current
single-file Proxmox bootstrap without regressing a working LXC install. The
implementation plan should stage that extraction, preserve the current LXC
behavior first, and then add the Linux-host entrypoint against the shared layer.
