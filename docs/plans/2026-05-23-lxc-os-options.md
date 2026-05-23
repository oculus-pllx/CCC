# LXC OS Options Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Ubuntu 24.04 LTS as the default LXC option while preserving Ubuntu 26.04 LTS and Debian 13 choices.

**Architecture:** Update the existing OS selection `case` in `ccc-bootstrap.sh` and keep template resolution through the current `_tmpl_pattern` path. Update README and static checks to cover the three options.

**Tech Stack:** Bash bootstrapper, Markdown docs, existing static shell checks.

---

## File Map

- Modify `tests/container-code-companion-static.sh`: add static coverage for Ubuntu 24.04 option, Ubuntu 26.04 option, Debian 13 option, and template patterns.
- Modify `ccc-bootstrap.sh`: change the OS menu, defaults, case branches, comments, and Canonical outage hint.
- Modify `README.md`: update OS choice docs and troubleshooting.

### Task 1: Add Failing Static Checks

**Files:**
- Modify: `tests/container-code-companion-static.sh`

- [ ] **Step 1: Add static assertions**

Add checks for:

```bash
require_file_contains ccc-bootstrap.sh "1) Ubuntu 24.04 LTS  (default)"
require_file_contains ccc-bootstrap.sh "2) Ubuntu 26.04 LTS"
require_file_contains ccc-bootstrap.sh "3) Debian 13 (Trixie)"
require_file_contains ccc-bootstrap.sh 'ubuntu-24\.04-standard_24\.04-[0-9]+_amd64\.tar\.zst'
require_file_contains ccc-bootstrap.sh 'ubuntu-26\.04-standard_26\.04-[0-9]+_amd64\.tar\.zst'
require_file_contains ccc-bootstrap.sh 'debian-13-standard_13\.[0-9]+-[0-9]+_amd64\.tar\.zst'
require_file_contains README.md "Ubuntu 24.04 LTS (default), Ubuntu 26.04 LTS, or Debian 13"
```

- [ ] **Step 2: Run static checks and verify red**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: FAIL because Ubuntu 24.04 is not yet present.

- [ ] **Step 3: Commit red test checkpoint**

Run:

```bash
git add tests/container-code-companion-static.sh
git commit -m "test(bootstrap): cover lxc os choices"
```

### Task 2: Update Bootstrap OS Selection

**Files:**
- Modify: `ccc-bootstrap.sh`

- [ ] **Step 1: Change OS menu and case branches**

Make option 1 Ubuntu 24.04 default, option 2 Ubuntu 26.04, and option 3 Debian 13.

- [ ] **Step 2: Update related labels/comments**

Change hardcoded Ubuntu 26.04 template comments and Debian fallback hint text so they match the new option numbers.

- [ ] **Step 3: Run focused shell validation**

Run:

```bash
bash -n ccc-bootstrap.sh
bash tests/container-code-companion-static.sh
```

Expected: static checks may still fail on README until docs are updated; shell syntax exits 0.

### Task 3: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update OS-choice text**

Document Ubuntu 24.04 LTS default, Ubuntu 26.04 LTS, and Debian 13.

- [ ] **Step 2: Update template troubleshooting**

Replace Ubuntu 26.04-only template troubleshooting with selected-template guidance and example filters for all three OS choices.

- [ ] **Step 3: Run focused verification**

Run:

```bash
bash tests/container-code-companion-static.sh
bash -n ccc-bootstrap.sh
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 4: Commit implementation**

Run:

```bash
git add ccc-bootstrap.sh README.md docs/plans/2026-05-23-lxc-os-options.md
git commit -m "feat(bootstrap): add ubuntu 24 lxc option"
```

### Task 4: Final Verification

**Files:**
- Verify: `ccc-bootstrap.sh`
- Verify: `README.md`
- Verify: `tests/container-code-companion-static.sh`

- [ ] **Step 1: Run full relevant verification**

Run:

```bash
bash tests/container-code-companion-static.sh
bash -n ccc-bootstrap.sh
bash -n install/ccc-provision-workstation.sh
(cd container-code-companion && go test ./...)
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 2: Inspect repo state**

Run:

```bash
git status --short --branch
```

Expected: only intentional plan checkbox updates remain if any.

