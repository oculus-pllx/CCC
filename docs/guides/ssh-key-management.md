# SSH Key Management

Manage SSH keys on the workstation — per-project key pairs, test machine deployment, and a system-wide audit panel to find and clean up unmanaged keys.

---

## Overview

CCC keeps project SSH keys isolated from user home directories:

```
/etc/ccc/project-keys/
  my-project/
    id_ed25519        (private key, ccc group readable)
    id_ed25519.pub    (public key)
    host              (target machine IP or hostname)
```

Keys are owned by the `ccc` group (`0640`) so **any user in the `ccc` group can use them directly** — no sudo, no copies, no agent required. The directory tree is `root:ccc 0750`.

The shared GitHub machine key stays at `/etc/ccc/ssh/github_ed25519` as before — this feature is separate and does not affect it.

---

## SSH Key Inventory (audit panel)

Open **Projects** in the web UI. At the top, above the project list, is the **SSH Key Inventory** panel.

It scans:
- All user `~/.ssh/` directories
- `/root/.ssh/`
- `/etc/ccc/project-keys/`

Each key is shown with its path, owner, type, and last modified date.

**Flagged keys** — any key outside `/etc/ccc/project-keys/` that isn't the known GitHub machine key (`/etc/ccc/ssh/github_ed25519`) is marked ⚠ **unmanaged**. This surfaces keys that AI agents may have created without being asked.

**Delete a key:**
- Click **Delete** next to any key
- Confirm the dialog
- Deleting a private key also removes its `.pub` pair

---

## Per-Project SSH Keys

Click **SSH ▾** on any project card to expand its SSH panel.

### 1. Configure the test host

Enter the IP or hostname of the test machine and click **Save**.

- This writes the target to `/etc/ccc/project-keys/<name>/host`
- CCC also injects a deployment block into the project's agent config files (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`) so AI agents running in that project automatically know:
  - The target machine (`root@<host>`)
  - The SSH key path
  - The correct `ssh` command to use for deployment
  - That development and GitHub pushes happen on **this machine only** — not the test machine

The block looks like this (and is replaced automatically if the host changes):

```markdown
<!-- CCC:DEPLOYMENT:START -->
## CCC Deployment Target (machine-local, not in repo)

- **Test machine:** root@192.168.1.10
- **SSH key:** /etc/ccc/project-keys/my-project/id_ed25519
- **To deploy:** `ssh -i /etc/ccc/project-keys/my-project/id_ed25519 root@192.168.1.10 "<command>"`
- Development and GitHub pushes happen on **this machine only**.
- Do **not** push to GitHub from the test machine.
- Do **not** create new SSH keys.
<!-- CCC:DEPLOYMENT:END -->
```

The shared `oculus-configs` repo is never modified — this block is written locally after each sync.

### 2. Generate a key

Click **Generate Key**. CCC runs:

```bash
ssh-keygen -t ed25519 -f /etc/ccc/project-keys/<name>/id_ed25519 -N "" -C "ccc-project-<name>"
```

Returns an error if a key already exists — delete the existing key first.

### 3. Deploy to the test machine (one-time)

Click **Deploy to Test Machine**, enter the root password for the test machine, and click **Deploy Key**.

CCC runs:

```bash
sshpass -p <password> ssh-copy-id \
  -i /etc/ccc/project-keys/<name>/id_ed25519.pub \
  -o StrictHostKeyChecking=accept-new \
  root@<host>
```

After a successful deploy, the test machine's `authorized_keys` includes the project public key. All future SSH connections are passwordless.

> `sshpass` must be installed: `apt install sshpass`

### 4. SSH Connect

Click **SSH Connect** — the terminal switches to the Terminal tab and sends:

```
ssh -i /etc/ccc/project-keys/<name>/id_ed25519 root@<host>
```

Both the test host and an existing key are required for this button to be active.

### 5. Other actions

- **Copy Public Key** — copies the public key to the clipboard (for manual `authorized_keys` setup)
- **Delete Key** — removes the key pair (prompts for confirmation); generate a new one at any time

---

## Key Status Indicators

The SSH toggle button turns green (`SSH ▾` with a green border) when a key exists for the project.

Inside the panel, the status dot shows:
- **●** green — key exists
- **●** red — no key generated yet

Buttons are disabled until the prerequisites are met:
- **Delete Key**, **Copy Public Key** — requires a key to exist
- **Deploy to Test Machine**, **SSH Connect** — requires both a key and a configured test host

---

## Troubleshooting

**Deploy fails: "sshpass required"**
```bash
apt install sshpass
```

**Deploy fails: "Permission denied"**
- Wrong root password — try again
- The test machine may not allow root password login. Check `/etc/ssh/sshd_config` on the test machine: `PermitRootLogin` must be `yes` or `prohibit-password` for key-based auth to work

**SSH Connect opens the terminal but connection is refused**
- Confirm the key was deployed successfully (Deploy to Test Machine succeeded)
- Check the test machine is reachable: `ping <host>`
- Verify the public key landed in the test machine's `/root/.ssh/authorized_keys`

**"Key already exists" error on Generate**
- Delete the existing key from the SSH panel first, then generate a new one

**Agent configs not updated after saving test host**
- The deployment block is written to `CLAUDE.md`, `AGENTS.md`, `GEMINI.md` inside the project directory at `/srv/ccc/projects/<name>/`
- If none of those files exist, CCC creates `CLAUDE.md` automatically on the next Save

**"Permission denied" using a key as a non-oculus user**
- All keys are created with `ccc` group read access (`0640`) — any user in the `ccc` group can use them
- If a key was generated before this was fixed, do a CCC self-update — permissions are repaired automatically at service startup
- Verify with: `ls -la /etc/ccc/project-keys/<name>/` — group should be `ccc`

**`/etc/ccc/project-keys` does not exist**
- Run a CCC self-update — the directory is created automatically during every update
