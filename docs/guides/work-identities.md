# Work Identities

Run multiple AI developer accounts on one workstation — each with its own Claude, Codex, and Gemini OAuth sessions — while sharing projects and a single GitHub machine key.

---

## How It Works

Each work identity is a separate Linux user. They get:
- Their own `~/.claude/`, `~/.codex/`, `~/.gemini/` — separate auth, separate history, separate billing
- Their own `~/.gitconfig` and `~/.ssh/config`
- Access to the same `/srv/ccc/projects` shared project workspace via `~/projects`
- The same baseline Claude/Codex/Gemini configs and skills from `oculus-configs`
- Their own Claude Code install in `~/.local/bin` (per-account, self-updating); Codex and Gemini CLIs are shared from `/usr/local/ccc-npm`

Provider credentials are **never copied** between users. What is shared: project files, the managed GitHub SSH key, and the baseline rules/skills config.

---

## Prerequisites

- You're logged in as the primary CCC user (the one created at install)
- The web UI is open at `http://<container-ip>:9090`

---

## Step 1: Create the Linux User

In the web UI, go to **Accounts**:
1. Click **Create User**
2. Enter the new username (e.g., `work`, `client-a`, `personal`)
3. Set a password
4. Click **Create**

Or from the CLI:
```bash
sudo useradd -m -s /bin/bash <username>
sudo passwd <username>
```

---

## Step 2: Setup CCC Profile

Still in **Accounts**, find the new user and click **Setup CCC Profile**. This:

- Adds the user to the `ccc` group (shared project access)
- Links `~/projects` → `/srv/ccc/projects`
- Syncs Claude/Codex/Gemini configs and skills from `oculus-configs` (via `ccc-sync-agent-configs`)
- Installs the user's own Claude Code CLI into `~/.local/bin` (Codex/Gemini are already shared system-wide)
- Writes the CCC-managed `settings.json` and statusline script
- Validates the provider CLIs are reachable

Shell environment (aliases, PATH, auto-cd to `~/projects` on login) is machine-wide via `/etc/profile.d/ccc-env.sh` and `/etc/ccc/ccc-shell.sh` — nothing is appended to the user's `.bashrc`.

Wait for the output panel to confirm everything was created. If it reports missing binaries or config files, run **Sync Account Configs** for that user and check again.

---

## Step 3: Authenticate as the New User

Sign in as the new work identity — either SSH or a new terminal tab:

```bash
ssh <username>@<container-ip>
```

Then authenticate each provider you'll use:

```bash
claude      # Claude Code OAuth — opens browser
codex       # Codex CLI auth
gemini      # Gemini CLI auth
```

Each auth session is stored in that user's home directory and is completely independent from other users.

**GitHub CLI** (if needed for `gh pr`, `gh repo`, etc.):
```bash
gh auth login
```
Git push/pull via SSH uses the shared machine key — `gh auth login` is only needed for GitHub API operations.

---

## Step 4: Configure GitHub SSH for All Identities

The managed machine key at `/etc/ccc/ssh/github_ed25519` is readable by all users in the `ccc` group. To make it the default for Git SSH:

In the web UI, go to **GitHub** and click **Configure For All Work Identities**. This writes the SSH config block into every `ccc` group member's `~/.ssh/config`:

```
Host github.com
  IdentityFile /etc/ccc/ssh/github_ed25519
  IdentitiesOnly yes
```

Or apply it manually for a specific user:
```bash
sudo -u <username> bash -c 'mkdir -p ~/.ssh && cat >> ~/.ssh/config' <<EOF

Host github.com
  IdentityFile /etc/ccc/ssh/github_ed25519
  IdentitiesOnly yes
EOF
```

After this, `git push` works as that user without any per-user key setup.

---

## Switching Between Identities

Open a new SSH session or terminal tab as the desired user:

```bash
ssh work@<container-ip>        # work identity
ssh claude-code@<container-ip> # primary identity
```

Inside the web UI Terminal, you can `su - <username>` to switch inline, or open a new terminal tab (each tab is a fresh PTY session).

---

## Keeping Configs in Sync

When you update agent configs, skills, or rules for the primary user, push them to all work identities:

**Web UI:** Accounts > **Sync All Account Configs**

**CLI:**
```bash
sudo ccc-sync-agent-configs --all-users
```

For a single user:
```bash
sudo ccc-sync-agent-configs --user <username>
```

This syncs baseline configs and skills but **does not touch** auth tokens, sessions, history, or billing state.

---

## Removing a Work Identity

In **Accounts**, click **Delete User** for the account. This removes the Linux user and their home directory. Projects in `/srv/ccc/projects` are not affected — they're shared and owned by the `ccc` group.

---

## Troubleshooting

**"Permission denied" writing to `/srv/ccc/projects`**
The user's `ccc` group membership needs a fresh login session to activate. Sign out and back in:
```bash
exit
ssh <username>@<container-ip>
```
Then verify: `groups` should include `ccc`.

**Setup CCC Profile output shows missing files**
Run **Sync Account Configs** for that user. If it still fails, check that `oculus-configs` is accessible:
```bash
ls /opt/oculus-configs
```
If the directory is empty or missing, run `sudo ccc-sync-agent-configs` as the primary user first.

**`claude` not found after profile setup**
The CLI is installed to `~/.local/bin`. Confirm the PATH is set:
```bash
echo $PATH | grep local
```
If missing, source the profile: `source ~/.profile` or open a fresh SSH session.
