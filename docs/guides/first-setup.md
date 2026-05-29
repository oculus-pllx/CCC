# First Setup

Complete walkthrough from a fresh install to a fully working AI dev workstation.

---

## 1. Install

**New Proxmox LXC** — run this on your Proxmox host as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/ccc-bootstrap.sh)
```

You'll be prompted for OS (Ubuntu 24.04 default), hostname, username, password, CPU/RAM/disk, and network. Provisioning takes 10–15 minutes and prints `[N/29]` step progress.

**Existing Debian/Ubuntu machine** — run this on the target machine:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/oculus-pllx/CCC/main/ccc-install-linux.sh)
```

---

## 2. SSH In

```bash
ssh claude-code@<container-ip>
```

Replace `claude-code` with the username you chose during install. The container IP is printed at the end of provisioning. Root login is disabled.

---

## 3. Run First-Login Onboarding

The onboarding wizard runs automatically on your first interactive login. If it didn't, or to re-run it:

```bash
ccc-onboarding
```

This sets your git identity (`user.name`, `user.email`), generates an SSH key if you don't have one, and walks you through GitHub setup.

---

## 4. Open the Web UI

Go to `http://<container-ip>:9090` in your browser. Sign in with the same username and password you use for SSH.

The dashboard shows system overview, services, projects, and SSH connections. All management tasks — accounts, projects, GitHub keys, configs, updates — are accessible from the sidebar.

---

## 5. Authenticate Your AI Providers

**Claude Code:**
```bash
claude
```
Follow the browser OAuth flow. Claude Code is pre-configured with all permissions approved and extended thinking enabled.

**Codex (optional):**
```bash
ccc-install-codex   # installs the CLI if not present
codex               # then authenticate
```

**Gemini (optional):**
```bash
gemini              # authenticate on first run
```

---

## 6. Set Up GitHub SSH Access

CCC uses a single machine SSH key shared across all work identities so every user on the workstation can push to GitHub without managing separate deploy keys.

In the web UI, go to **GitHub**:
1. Click **Generate Key** (or **Promote Existing Key** if you already have one in `~/.ssh`)
2. Click **Copy Public Key** and add it to GitHub at [github.com/settings/keys](https://github.com/settings/keys)
3. Click **Test GitHub SSH** to verify

From the CLI:
```bash
# Copy the public key
cat /etc/ccc/ssh/github_ed25519.pub

# Test access
ssh -T -i /etc/ccc/ssh/github_ed25519 git@github.com
```

See [Work Identities](work-identities.md) for configuring this key across multiple accounts.

---

## 7. Sync Shared Agent Configs

Pull the latest Claude/Codex/Gemini rules, skills, and templates from `oculus-configs`:

```bash
sudo ccc-sync-agent-configs
```

Or use **Accounts > Sync All Account Configs** in the web UI.

---

## 8. Optional: Install Extra Tools

```bash
ccc-install-playwright  # headless Chromium for browser automation (5–15 min)
ccc-install-codex       # OpenAI Codex CLI
ccc-install-jcodemunch  # jCodeMunch MCP — 95% token reduction
```

These are also available from **App Catalog** in the web UI.

---

## 9. Health Check

```bash
ccc-doctor
```

Checks network, runtimes, services, and disk. Run this if anything seems off.

---

## What's Next

- [Work Identities](work-identities.md) — add a second developer account with its own Claude/Codex/Gemini auth
- [Projects](projects.md) — create or clone your first project
- [Updates](updates.md) — set up auto-update so you stay current automatically
