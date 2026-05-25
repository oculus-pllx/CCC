# Node npm And Playwright Ubuntu Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure CCC verifies npm bundled with NodeSource Node.js and warns users about Ubuntu 26.04 Playwright/Chromium limitations.

**Architecture:** Add static regression checks first, then patch the shared provisioner and README. Keep the change in existing installer scripts and docs; do not add new package sources or change the OS default.

**Tech Stack:** Bash provisioner, Markdown docs, existing shell static checks.

---

## File Map

- Modify `tests/container-code-companion-static.sh`: add static checks for `nodejs`, npm verification, no combined `nodejs npm` install, Ubuntu 26.04 Playwright warning markers, and README guidance.
- Modify `install/ccc-provision-workstation.sh`: install NodeSource `nodejs`, verify bundled `npm`, and warn in `ccc-install-playwright` on Ubuntu 26.04.
- Modify `README.md`: document npm verification and Debian 13 being safer for browser automation.

### Task 1: Add Failing Static Checks

**Files:**
- Modify: `tests/container-code-companion-static.sh`

- [x] **Step 1: Add static assertions**

Add:

```bash
require_file_contains install/ccc-provision-workstation.sh "apt-get install -y -qq nodejs"
require_file_contains install/ccc-provision-workstation.sh 'command -v npm'
require_file_not_contains install/ccc-provision-workstation.sh "apt-get install -y -qq nodejs npm"
require_file_contains install/ccc-provision-workstation.sh "Ubuntu 26.04 Chromium support may lag Playwright releases"
require_file_contains install/ccc-provision-workstation.sh 'VERSION_ID:-}" == "26.04"'
require_file_contains README.md "Debian 13 is the safer CCC path when browser automation matters"
```

- [x] **Step 2: Run static checks and verify red**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: FAIL because these markers are not present.

- [x] **Step 3: Commit red test checkpoint**

Run:

```bash
git add tests/container-code-companion-static.sh
git commit -m "test(installer): cover npm and chromium guidance"
```

### Task 2: Patch Installer And Docs

**Files:**
- Modify: `install/ccc-provision-workstation.sh`
- Modify: `README.md`

- [x] **Step 1: Install NodeSource Node.js and verify npm**

Use NodeSource `nodejs` only and verify bundled npm:

```bash
apt-get install -y -qq nodejs
command -v npm >/dev/null 2>&1
```

- [x] **Step 2: Warn in `ccc-install-playwright` on Ubuntu 26.04**

Add an `/etc/os-release` check in the generated script before `npx --yes playwright install --with-deps chromium`.

- [x] **Step 3: Update README guidance**

Add clear notes that npm is verified from the NodeSource package and that Debian
13 is the safer CCC path when browser automation matters.

- [x] **Step 4: Run focused verification**

Run:

```bash
bash tests/container-code-companion-static.sh
bash -n install/ccc-provision-workstation.sh
git diff --check
```

Expected: all commands exit 0.

- [x] **Step 5: Commit implementation**

Run:

```bash
git add install/ccc-provision-workstation.sh README.md docs/plans/2026-05-23-node-npm-playwright-ubuntu.md
git commit -m "fix(installer): install npm and warn on chromium support"
```

### Task 3: Final Verification

**Files:**
- Verify: `install/ccc-provision-workstation.sh`
- Verify: `README.md`
- Verify: `tests/container-code-companion-static.sh`

- [x] **Step 1: Run full relevant verification**

Run:

```bash
bash tests/container-code-companion-static.sh
bash -n install/ccc-provision-workstation.sh
(cd container-code-companion && go test ./...)
git diff --check
```

Expected: all commands exit 0.

- [x] **Step 2: Inspect repo state**

Run:

```bash
git status --short --branch
```

Expected: only intentional plan checkbox updates remain if any.
