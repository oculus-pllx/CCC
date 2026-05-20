# Parallax Group — Brand & Project Reference

> This document lives in every project repository under the Parallax Group ecosystem.  
> It is the canonical reference for brand identity, hierarchy, naming conventions, and design system.  
> **Last updated:** 2026 · Rev 8

---

## Ecosystem Overview

Parallax Group is the umbrella brand for a suite of open-source infrastructure and tooling projects. Each project is independent but shares a unified visual identity, naming philosophy, and brand mark.

```
PARALLAX GROUP (pllx.group)
│
├── Aperture      Network observability & operations platform     pllx.dev
├── Array         Distributed firewall management system          pllx.dev
├── Prism         AI inference server install & configuration     pllx.dev
├── Refract       Duplicate file finder & manager                 pllx.dev
├── Lens          Proxmox datacenter manager                      pllx.dev
└── Flux          NUT UPS management — single pane of glass       pllx.dev
```

---

## Domains

| Domain | Purpose |
|--------|---------|
| `pllx.group` | Parent brand hub — public site + protected ops panel |
| `pllx.dev` | Redirects to GitHub org — all project repositories live here |
| `pllx.app` | Future licensed product destination — TBD |

---

## Projects

### Aperture
**Tagline:** Network Observability & Operations  
**Status:** Active · v6.4.0  
**Accent:** Amber `#f59e0b`  
**Attribution:** `Aperture by Parallax Group`  
**Repository:** `github.com/pllx/parallax`  
**Parent platform:** Parallax

Professional network observability and operations platform for network engineers and sysadmins. Real-time monitoring, device interactions, performance metrics, and diagnostic tools in a single unified interface. Free single-node home edition; licensed multi-tenant edition planned.

**Named Components (internal taxonomy):**

| Name | Role |
|------|------|
| Aperture | React/Vite frontend SPA |
| Baseline | Node.js/Express backend |
| Cadence | Polling orchestrator |
| Relay | Socket.io WebSocket layer |
| Flare | Alert & threshold engine |
| Spectrum | Theming system |
| Facet | Dashboard widget unit |
| Helm | Navigation bar |
| Vault | `.env` / secrets file |
| Chamber | Docker image |
| Manifest | `docker-compose.yml` |
| Scope | Proxmox integration |
| Grid | Docker integration |
| Gate | OPNsense integration |
| Mesh | Tailscale integration |
| Sieve | Pi-hole integration |
| Pulse | System metrics |

> **Note on Spectrum:** The theming system inside Aperture is named **Spectrum**, using CSS custom properties `--spectrum-primary`, `--spectrum-glow`, and `--spectrum-dim`. It was previously named Prism — that name was freed for the standalone AI inference project below.

---

### Array
**Tagline:** Distributed Firewall Management System  
**Status:** Active · v3.0.0-alpha  
**Accent:** Rose `#f43f5e`  
**Attribution:** `Array by Parallax Group`  
**Repository:** `github.com/oculus-pllx/Array`

Distributed firewall management platform for Proxmox VMs. Onboards firewalls through a token-authenticated handshake with a central dashboard, then manages nftables rules, WireGuard tunnels, DHCP/DNS, metrics, alerting, and logging across the topology. Commit/confirm ruleset safety, desired-state snapshot reconciliation, drift detection, and built-in debug and chaos tools (network probe, path simulation, WAN down / latency / loss injection).

**Stack:**

| Layer | Technology |
|-------|------------|
| Agent | Python 3.12 (asyncio, HTTPS :5001) |
| Dashboard API | FastAPI + SQLite (WAL) |
| Frontend | Vue 3 + Tailwind CSS |
| Topology | vis-network |
| Rule engine | nftables (dual-stack `inet`) |
| DHCP/DNS | dnsmasq (SIGHUP reload) |
| VPN | WireGuard |
| Platform | Proxmox VE + Ubuntu 24.04 |

**Named Components (internal taxonomy):**

| Name | Role |
|------|------|
| Array | Vue 3 frontend SPA |
| Origin | FastAPI dashboard backend |
| Vertex | Firewall agent daemon |
| Carrier | WebSocket real-time layer |
| Beacon | UDP discovery broadcaster |
| Lattice | nftables rule engine |
| Ground | Baseline infrastructure rules |
| Tether | Commit/confirm transaction protocol |
| Frame | Desired-state snapshot |
| Phase | State reconciler |
| Plumb | Drift detector |
| Ledger | Change log / audit trail |
| Reservoir | Local traffic log spool |
| Beam | WireGuard tunnel manager |
| Atlas | dnsmasq (DHCP + DNS) |
| Tempo | Metrics collector |
| Distill | Metrics tier downsampler |
| Sigil | Onboarding token |
| Imprint | Cert pinning validator |
| Keystone | Master encryption key |
| Charter | Agent `config.json` |
| Sonar | Network reachability probe |
| Static | Chaos injector |
| Vector | Path simulator |
| Constellation | Topology map |
| Antechamber | Staging drawer |
| Pinhole | Command palette (Cmd-K) |
| Cluster | Firewall group |

> **Name rationale:** A phased array coordinates many independent elements into a single directed response — fitting for a system that turns a scatter of firewalls into one coherent policy surface. Also an ordered, structured collection: rules, peers, interfaces, tunnels.

---

### Prism
**Tagline:** AI Inference Server — Install & Configuration  
**Status:** Active  
**Accent:** Violet `#8b5cf6`  
**Attribution:** `Prism by Parallax Group`  
**Repository:** `github.com/oculus-pllx/Prism`

Automated installer for a local tool-calling AI agent. The wizard provisions a **Hermes or OpenClaw agent** — the reason the stack exists — along with the full inference infrastructure it requires: GPU driver, container runtime, Ollama, a tool-capable LLM, and a chat interface. Two-phase install: a curl-piped bootstrap script stands up the PRISM Control dashboard, then an 11-step browser-based wizard handles the rest.

**Stack (PRISM Control itself):**

| Layer | Technology |
|-------|------------|
| Bootstrap | Bash (`bootstrap.sh` via `curl \| bash`) |
| Backend | Node.js 20 + Express |
| Frontend | React + Vite |
| Process manager | PM2 (zero-downtime reloads) |
| Persistence | JSON file store |
| Auth | JWT (30-day cookie); 2FA planned |
| Wizard engine | Numbered Bash scripts orchestrated from Node |
| Admin fallback | Webmin (port 10000) |
| Target platform | Ubuntu 24.04 LTS bare metal, headless |

**Stack provisioned (what the wizard installs on the target):**

| Component | Role |
|-----------|------|
| NVIDIA driver | GPU runtime (reboot-aware, exit code 99) |
| Docker Engine | Container runtime |
| Dockhand / Portainer | Docker management UI (operator choice) |
| Ollama | Local LLM runtime |
| Qwen 2.5 14B Q8 | Tool-calling LLM (default; Qwen 3 32B Q4 alternative) |
| Open-WebUI | Chat interface for local models |
| Hermes / OpenClaw | Tool-calling agent (operator choice; systemd service) |
| Tailscale | Secure remote access mesh |
| n8n | Workflow automation (optional) |
| UFW | Host firewall |

**Named Components (internal taxonomy):**

| Name | Role |
|------|------|
| Prism | Express + React installer application |
| Apex | Express backend — the prism's sharp edge where refraction begins |
| Dispersion | 11-step setup wizard orchestrator |
| Medium | Target machine being provisioned (bare Ubuntu 24.04) |
| Focus | Tool-calling agent slot (Hermes or OpenClaw) — where the stack converges |
| Index | JSON state persistence |
| Filter | JWT auth middleware |
| Plate | Four-target backup system (local / iSCSI / PBS / SMB) |
| Shift | Update module — git pull + rebuild + PM2 reload |
| Palette | Model management (Ollama models UI) |
| Shutter | Service control — start/stop/status/logs |
| Gauge | System metrics collection (CPU / RAM / GPU / disk) |
| Spectrogram | Log viewer |

> **Name rationale:** Light enters a prism and gets transformed into something structured and new — fitting for a system that takes raw compute and produces a fully-configured AI inference environment.

---

### Refract
**Tagline:** Duplicate File Finder & Manager  
**Status:** Active  
**Accent:** Cyan `#06b6d4`  
**Attribution:** `Refract by Parallax Group`  
**Repository:** `github.com/pllx/refract`

Duplicate file detection and management application. Scans storage, identifies redundant files across directories, and provides a clean interface for reviewing, comparing, and resolving duplicates — without the risk of accidental mass deletion.

> **Name rationale:** Refraction bends and splits light as it passes through a medium — fitting for a tool that takes a single file fingerprint and finds every place it appears across storage.

---

### Lens
**Tagline:** Proxmox Datacenter Manager  
**Status:** Active  
**Accent:** Emerald `#10b981`  
**Attribution:** `Lens by Parallax Group`  
**Repository:** `github.com/pllx/lens`

Unified configuration, monitoring, and management interface for a full Proxmox stack. Covers the complete datacenter picture in one place.

**Scope:**

| Area | Coverage |
|------|----------|
| Nodes | Proxmox VE hypervisor management |
| PBS | Proxmox Backup Server oversight |
| UPS | Power device monitoring |
| Switching | Dedicated network switch management |

> **Name rationale:** A lens brings distant or complex things into sharp focus — collapsing four separate admin surfaces into one clear view.

---

### Flux
**Tagline:** NUT UPS Management — Single Pane of Glass  
**Status:** Active  
**Accent:** Orange `#f97316`  
**Attribution:** `Flux by Parallax Group`  
**Repository:** `github.com/pllx/flux`

Centralized management, monitoring, and control interface for Network UPS Tools (NUT) based servers. Manages multiple NUT instances from a single dashboard — status, load, runtime estimates, event history, and configuration — without touching config files directly.

> **Name rationale:** Flux is power in motion, constant and measurable. Also flux as in state of change — exactly what a UPS monitors: the transition between utility power and battery.

---

## Brand Mark — Parallax Shift

The **Parallax Shift** mark appears on every project. It consists of two offset chevron planes suggesting depth and displacement — the same object seen from two viewpoints.

### Construction

The mark is built from three layers drawn in SVG at a `64×64` base viewBox (scalable to any size):

```
Layer 1 — Depth connector lines
  Stroke opacity: 15%
  Stroke width:   1.44 (at 64px base)
  Stroke dash:    2.8 2.8
  Color:          project accent

  Top connector:    (11.2, 16.8) → (20.8, 13.6)
  Bottom connector: (11.2, 47.2) → (20.8, 50.4)
  Right connector:  (32,   32  ) → (44.8, 32  )

Layer 2 — Back chevron
  Points:         11.2,16.8 → 32,32 → 11.2,47.2
  Stroke opacity: 30%
  Stroke width:   3.2 (at 64px base)
  Linecap:        round
  Linejoin:       round

Layer 3 — Front chevron
  Points:         20.8,13.6 → 44.8,32 → 20.8,50.4
  Stroke opacity: 90%
  Stroke width:   4.0 (at 64px base)
  Linecap:        round
  Linejoin:       round
```

**Canonical SVG snippet (64px, amber — scale all coordinates proportionally for other sizes):**

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"
     viewBox="0 0 64 64" fill="none">
  <!-- Depth connectors -->
  <line x1="11.2" y1="16.8" x2="20.8" y2="13.6"
        stroke="#f59e0b" stroke-opacity="0.15" stroke-width="1.44"
        stroke-dasharray="2.8 2.8"/>
  <line x1="11.2" y1="47.2" x2="20.8" y2="50.4"
        stroke="#f59e0b" stroke-opacity="0.15" stroke-width="1.44"
        stroke-dasharray="2.8 2.8"/>
  <line x1="32"   y1="32"   x2="44.8" y2="32"
        stroke="#f59e0b" stroke-opacity="0.15" stroke-width="1.44"
        stroke-dasharray="2.8 2.8"/>
  <!-- Back chevron -->
  <polyline points="20.8,13.6 44.8,32 20.8,50.4"
            stroke="#f59e0b" stroke-opacity="0.30" stroke-width="3.2"
            stroke-linecap="round" stroke-linejoin="round" fill="none"/>
  <!-- Front chevron -->
  <polyline points="11.2,16.8 32,32 11.2,47.2"
            stroke="#f59e0b" stroke-opacity="0.90" stroke-width="4.0"
            stroke-linecap="round" stroke-linejoin="round" fill="none"/>
</svg>
```

### Scale Rules

| Size | Variant | Connectors | Stroke widths |
|------|---------|------------|---------------|
| ≥ 32px | Full — with depth connectors | Shown, dashed | As specified |
| < 32px | Compact — connectors omitted | Hidden | Scale proportionally |

**Stroke width scaling formula:** `strokeWidth = baseWidth × (targetSize / 64)`

### Color Rules

| Background | Mark color |
|------------|------------|
| Dark (default) | Project accent at specified opacities |
| Light | `#0f172a` (near-black) at specified opacities |

**Minimum clearance:** 1× the chevron arm width on all sides.

### Accent Color by Project

| Project | Accent | Hex |
|---------|--------|-----|
| Parallax Group | Amber | `#f59e0b` |
| Aperture | Amber | `#f59e0b` |
| Array | Rose | `#f43f5e` |
| Prism | Violet | `#8b5cf6` |
| Refract | Cyan | `#06b6d4` |
| Lens | Emerald | `#10b981` |
| Flux | Orange | `#f97316` |

---

## Logo Files

Logo assets live in `brand/logos/` at the root of the `pllx.group` repository. All files are SVG — scalable to any size without quality loss.

### File Structure

```
brand/logos/
├── marks/
│   ├── aperture-mark.svg       Amber   #f59e0b  — 64×64
│   ├── array-mark.svg          Rose    #f43f5e  — 64×64
│   ├── prism-mark.svg          Violet  #8b5cf6  — 64×64
│   ├── refract-mark.svg        Cyan    #06b6d4  — 64×64
│   ├── lens-mark.svg           Emerald #10b981  — 64×64
│   └── flux-mark.svg           Orange  #f97316  — 64×64
│
└── lockups/
    ├── parallax-group-lockup.svg   Parent brand — 340×64
    ├── aperture-lockup.svg         — 340×64
    ├── array-lockup.svg            — 340×64
    ├── prism-lockup.svg            — 340×64
    ├── refract-lockup.svg          — 340×64
    ├── lens-lockup.svg             — 340×64
    └── flux-lockup.svg             — 340×64
```

### Mark Files (`marks/`)

Square mark only — no wordmark. Use in favicons, app icons, avatars, and any context where only the symbol is needed.

- **Viewbox:** `0 0 64 64`
- **Background:** transparent
- **Font dependency:** none

### Lockup Files (`lockups/`)

Horizontal lockup — mark + wordmark + domain/tagline. Use in navigation bars, README headers, documentation, and anywhere the full brand identity is needed.

- **Viewbox:** `0 0 340 64`
- **Background:** transparent
- **Font dependency:** Syne 800 (wordmark), IBM Plex Mono 400 (sub-label)
- **Font fallbacks:** `'Helvetica Neue', Arial, sans-serif` / `'Courier New', monospace`
- **Font loading:** SVG includes `@import` from Google Fonts — requires network access to render correctly in browser. For offline/print use, ensure Syne and IBM Plex Mono are installed locally.

### Lockup Layout Spec

```
[  64×64 Mark  ] [  Wordmark (Syne 800, #e2e8f0)     ]
                 [  Sub-label (IBM Plex Mono, #3e4555) ]

Mark:     x=0,  y=0,  w=64, h=64
Wordmark: x=80, y=25, font-size=17 (group) / 16 (projects)
Sub:      x=80, y=44, font-size=10.5 (group) / 10 (projects)
```

### React / JSX Usage

For use in code (nav bars, etc.), render the mark inline as an SVG component rather than using an `<img>` tag — this preserves sharpness at all DPIs and allows accent color to be passed as a prop:

```jsx
const ParallaxMark = ({ size = 40, color = "#f59e0b" }) => {
  // Scale factor relative to 64px base
  const s = size / 64;
  const sw = (base) => base * s;

  return (
    <svg width={size} height={size} viewBox="0 0 64 64" fill="none">
      {/* Depth connector lines */}
      <line x1="11.2" y1="16.8" x2="20.8" y2="13.6"
            stroke={color} strokeOpacity="0.15"
            strokeWidth={sw(1.44)} strokeDasharray={`${sw(2.8)} ${sw(2.8)}`}/>
      <line x1="11.2" y1="47.2" x2="20.8" y2="50.4"
            stroke={color} strokeOpacity="0.15"
            strokeWidth={sw(1.44)} strokeDasharray={`${sw(2.8)} ${sw(2.8)}`}/>
      <line x1="32"   y1="32"   x2="44.8" y2="32"
            stroke={color} strokeOpacity="0.15"
            strokeWidth={sw(1.44)} strokeDasharray={`${sw(2.8)} ${sw(2.8)}`}/>
      {/* Back chevron */}
      <polyline points="11.2,16.8 32,32 11.2,47.2"
                stroke={color} strokeOpacity="0.30" strokeWidth={sw(3.2)}
                strokeLinecap="round" strokeLinejoin="round"/>
      {/* Front chevron */}
      <polyline points="20.8,13.6 44.8,32 20.8,50.4"
                stroke={color} strokeOpacity="0.90" strokeWidth={sw(4.0)}
                strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  );
};
```

---

## Brand Conventions

### Attribution Pattern

```
[Project] by Parallax Group     ← all standalone projects
Aperture by Parallax Group      ← Aperture (the Parallax platform)
```

### Developer / Technical Contexts

```
npm packages    @pllx/parallax, @pllx/array, @pllx/prism, etc.
Docker images   pllx/parallax, pllx/array, pllx/flux, etc.
GitHub org      github.com/pllx  (canonical)
                github.com/oculus-pllx  (current home for Array and Prism; username availability)
Domain prefix   pllx.dev, pllx.group, pllx.app
```

### Spectrum ≠ Prism

Inside Aperture (the Parallax frontend), the theming system is **Spectrum**.  
CSS custom properties: `--spectrum-primary`, `--spectrum-glow`, `--spectrum-dim`.  
**Prism** refers exclusively to the standalone AI inference project.

---

## Design System

### Typography

| Font | Weight | Use |
|------|--------|-----|
| Syne | 600–800 | Display, headings, wordmark, labels |
| IBM Plex Mono | 400–600 | Metrics, data, values, code, domains |
| IBM Plex Sans | 400–500 | Body copy, descriptions, prose |

### Color Palette

| Role | Hex | Name |
|------|-----|------|
| Background | `#08090b` | Near-black |
| Panel | `#101216` | Dark panel |
| Border | `rgba(255,255,255,0.05)` | Subtle border |
| Text | `#e2e8f0` | Primary text |
| Muted | `#64748b` | Secondary text |
| Dim | `#3e4555` | Tertiary / labels |
| Healthy | `#10b981` | OK / active state |
| Warning | `#f59e0b` | Warning state |
| Critical | `#f43f5e` | Critical / error state |

> Array's accent (`#f43f5e`) is shared with the system-wide Critical color. This is intentional — Array is a firewall tool; its identity lives in the same register as "stop," "block," and "deny." In Array's own UI, Critical is instead rendered in a deeper red (`#dc2626`) to maintain signal contrast against the brand accent.

### Aesthetic

60s mission control / cosmic — dark backgrounds, amber accents, monospaced data, restrained use of color. Every accent is purposeful. No gradients on text. Borders are barely-there. Glow effects only on interactive or highlighted elements.

---

## Naming Philosophy

Every component, integration, and system in the Parallax ecosystem has a canonical name. These names are used consistently across code, UI, documentation, and conversation — this consistency is **load-bearing**, not stylistic.

Names are single words, drawn from the optical / astronomical / signal vocabulary. They are evocative of their function without being literal.

---

*Parallax Group · pllx.group · All rights reserved*
