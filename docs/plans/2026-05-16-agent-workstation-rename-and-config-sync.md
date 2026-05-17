# Agent Workstation Rename and Config Sync Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename user-facing CCC branding to Agent Workstation and split updates into OS, Agent Workstation tooling, and oculus-configs agent config sync.

**Architecture:** Keep the existing single bash provisioner and Cockpit plugin. Add one reusable `ccc-sync-agent-configs` command in the updateable section, call it during provisioning, and update Cockpit/docs text without adding another web service.

**Tech Stack:** Bash, Cockpit plugin HTML/JavaScript using `cockpit.js`, Markdown docs, shell-based static verification.

---

### Task 1: Static Regression Test

**Files:**
- Create: `tests/agent-workstation-static.sh`

- [x] **Step 1: Add a failing static test**

Create a shell test that asserts the rename, update separation, Cockpit retention, and absence of the removed standalone dashboard.

- [x] **Step 2: Run test to verify it fails**

Run: `bash tests/agent-workstation-static.sh`
Expected: FAIL because the starting code still used old product branding and did not include `ccc-sync-agent-configs`.

### Task 2: Provisioner Config Sync

**Files:**
- Modify: `claude-code-commander.sh`

- [x] **Step 1: Add `ccc-sync-agent-configs` to the updateable section**

Implement a root-safe command that clones or pulls `/opt/oculus-configs`, copies Claude/Codex/Gemini files, protects live MCP config, backs up managed top-level instruction files, and preserves working-user ownership.

- [x] **Step 2: Replace the inline step 18 copy logic**

Use the same command during provisioning so first install and later sync use one implementation.

- [x] **Step 3: Update command help, MOTD, doctor, and update labels**

Keep `ccc-*` commands but rename user-facing product text to Agent Workstation and list the three update paths.

### Task 3: Cockpit Plugin

**Files:**
- Modify: `docs/cockpit-plugin/index.html`
- Modify embedded plugin block in `claude-code-commander.sh`

- [x] **Step 1: Rename plugin title/menu text**

Use Agent Workstation while preserving Cockpit/PatternFly theme loading.

- [x] **Step 2: Update Overview and Updates**

Show Claude/Codex/Gemini readiness and provide separate OS, Agent Workstation, and oculus-configs update actions.

### Task 4: Documentation

**Files:**
- Modify: `README.md`
- Modify: `HANDOFF.md`

- [x] **Step 1: Rewrite product description**

Describe Agent Workstation as a headless Proxmox LXC CLI dev workstation.

- [x] **Step 2: Document update paths and oculus-configs role**

Explain `ccc-os-update`, `ccc-self-update`, and `ccc-sync-agent-configs`.

### Task 5: Verification and Commit

**Files:**
- All changed files

- [x] **Step 1: Run verification**

Run:

```bash
bash tests/agent-workstation-static.sh
bash -n claude-code-commander.sh
awk 'BEGIN{capture=0} /<script>/{capture=1; next} /<\/script>/{capture=0} capture{print}' docs/cockpit-plugin/index.html > /tmp/cockpit-plugin.js
node --check /tmp/cockpit-plugin.js
git diff --check
```

- [x] **Step 2: Commit**

Commit the implementation with message: `Rename to Agent Workstation and sync agent configs`.
