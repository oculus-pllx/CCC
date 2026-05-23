# LXC OS Options Design

Date: 2026-05-23
Status: Approved design

## Goal

Give the Proxmox LXC bootstrapper explicit choices for Ubuntu 24.04 LTS,
Ubuntu 26.04 LTS, and Debian 13 so users can pick the right compatibility level
for their workstation.

## Scope

The change covers the Proxmox LXC path only:

- `ccc-bootstrap.sh` OS prompt.
- Template pattern resolution for Ubuntu 24.04, Ubuntu 26.04, and Debian 13.
- README install/troubleshooting wording.
- Static regression checks for the three options.

The Linux host installer is unchanged because it runs on the host OS the user
already has.

## Behavior

The bootstrap prompt should show:

1. Ubuntu 24.04 LTS as the default.
2. Ubuntu 26.04 LTS.
3. Debian 13 (Trixie).

Ubuntu 24.04 and Ubuntu 26.04 both use `CT_OS=ubuntu` and `CT_OSTYPE=ubuntu`.
Debian 13 uses `CT_OS=debian` and `CT_OSTYPE=debian`.

The template resolver should use these patterns:

- Ubuntu 24.04: `^ubuntu-24\.04-standard_24\.04-[0-9]+_amd64\.tar\.zst$`
- Ubuntu 26.04: `^ubuntu-26\.04-standard_26\.04-[0-9]+_amd64\.tar\.zst$`
- Debian 13: `^debian-13-standard_13\.[0-9]+-[0-9]+_amd64\.tar\.zst$`

All summaries and errors should use the selected OS label, not a hardcoded
Ubuntu 26.04 label.

## Documentation

README should describe all three LXC OS options and explain:

- Ubuntu 24.04 is the default compatibility choice.
- Ubuntu 26.04 is available for newer LTS testing.
- Debian 13 remains the safer option when browser automation matters.

Troubleshooting should use generic selected-template guidance and include
example `pveam` filters for Ubuntu 24.04, Ubuntu 26.04, and Debian 13.

## Testing

Static checks should prove the bootstrapper and README mention all three options
and the expected template patterns.

