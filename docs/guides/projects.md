# Projects

Working with the shared project workspace — create projects, clone repos, manage permissions, and migrate from older layouts.

---

## The Shared Workspace

All projects live at `/srv/ccc/projects`. Every user in the `ccc` group can read and write there. The `~/projects` symlink in each user's home points to `/srv/ccc/projects` for compatibility with tools that expect a local path.

```
/srv/ccc/projects/
  my-app/
  client-work/
  experiments/
```

The **Projects** page in the web UI shows everything in this root, plus any linked legacy directories.

---

## Create a New Project

In the web UI, go to **Projects**:
1. Click **New Project**
2. Enter a project name
3. Choose a template (empty, Node, Python, Go, or Rust)
4. Click **Create**

The project is created at `/srv/ccc/projects/<name>`, git-initialized, and opened in the file browser.

To open in VS Code Web (code-server):
- Click the project's **code-server** button — opens directly in a browser editor tab

---

## Clone a Git Repo

**Via the web UI (Projects > Clone)**:
1. Click **Clone Repository**
2. Paste the SSH or HTTPS URL
3. Click **Clone**

The repo lands in `/srv/ccc/projects/<repo-name>`.

**Via CLI:**
```bash
cd ~/projects
git clone git@github.com:you/repo.git
# or
git clone https://github.com/you/repo.git
```

For private repos using the managed machine key:
```bash
git clone git@github.com:you/private-repo.git
```
This works for any user in the `ccc` group once the machine key is configured — see [Work Identities — GitHub SSH](work-identities.md#step-4-configure-github-ssh-for-all-identities).

---

## Pull Updates on an Existing Project

**Via the web UI:**
Click the **Pull** button on any project card. This runs a fast-forward pull — it will refuse to overwrite uncommitted changes.

**Via CLI:**
```bash
cd ~/projects/my-app
git pull
```

---

## Migrate an Existing `~/projects`

If you installed CCC before the shared workspace was added, your projects are still in the old location (`~/projects` as a real directory, not a symlink). Migrate them:

**Check first:**
```bash
ccc-migrate-shared-workspace --status
```

This shows what exists, what `~/projects` currently points to, and what will happen.

**Apply migration:**
```bash
sudo ccc-migrate-shared-workspace --apply
```

Before applying:
- Commit or stash any in-progress work
- Close terminal sessions whose current directory is inside the old project root

What the migration does:
1. Creates `/srv/ccc/projects` with `ccc` group ownership and the setgid bit
2. Adds your user to the `ccc` group
3. rsyncs `~/projects/` into `/srv/ccc/projects/`
4. Renames the old `~/projects` to a timestamped backup (kept, not deleted)
5. Creates the `~/projects` → `/srv/ccc/projects` symlink
6. Links any entries from `~/repos` into the shared root
7. Repairs group-write permissions on all repos

You can also do this from **Projects > Shared Workspace > Migrate Existing Projects** in the web UI.

---

## Repair Permissions

If a project shows "permission denied" for a user in the `ccc` group, the repo was likely created before the setgid bit was set, or `git` reset the group-write permissions.

**Web UI:** Projects > Shared Workspace > **Repair Permissions**

**CLI:**
```bash
# Run from any user in the ccc group, or as root
sudo ccc-migrate-shared-workspace --apply
```

Permission repair:
- Sets `ccc` group ownership and `g+w` on all files in `/srv/ccc/projects`
- Sets `core.sharedRepository = group` on every git repo so git doesn't fight group-write over time
- Follows top-level symlinks to catch linked legacy repos

---

## Browsing and Editing Files

The **Files** tab in the web UI browses `/srv/ccc/projects` (and any accessible home directories). Click a file to open an inline editor. You can create, rename, and delete files and folders from the browser.

For heavier editing, use **code-server** at `http://<container-ip>:8080` — full VS Code Web with extensions for Python, Go, Rust, TypeScript, and more.

---

## Troubleshooting

**"Permission denied" when writing to a project**

Check that your user is in the `ccc` group:
```bash
groups
```

If `ccc` is missing, run **Setup CCC Profile** from Accounts in the web UI, then open a fresh SSH session (group membership requires a new login).

If `ccc` is present but writes still fail, repair permissions:
```bash
ls -la /srv/ccc/projects/my-app | head -5  # check ownership
```
Group should be `ccc`, mode should include `g+w`. If not, run the repair action.

**Project doesn't appear in the Projects page**

Check that it's inside `/srv/ccc/projects`:
```bash
ls /srv/ccc/projects
```

If it's in a legacy location, either move it manually or run the migration to link it.

**Clone fails with "Host key verification failed"**

The machine SSH key isn't configured for GitHub yet. Go to **GitHub** in the web UI and click **Test GitHub SSH**. If it fails, generate or promote a key and add the public key to GitHub. See [Work Identities — GitHub SSH](work-identities.md#step-4-configure-github-ssh-for-all-identities).
