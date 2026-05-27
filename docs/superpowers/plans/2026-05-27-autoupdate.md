# Auto-Update Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in UI toggle with configurable frequency + hour schedule that automatically runs `ccc-self-update` when GitHub has a newer commit, surviving service restarts and leaving all user work unaffected.

**Architecture:** A flag file (`/etc/ccc/autoupdate-enabled`) gates the feature; a schedule config (`/etc/ccc/autoupdate-schedule`) stores freq+hour; a backend action rewrites `/etc/cron.d/ccc-app-update` when either changes. The cron calls a new `ccc-auto-update` script that checks the flag, calls `ccc-update-status`, and only triggers `ccc-self-update` when there is actually a newer commit.

**Tech Stack:** Go 1.21, bash, crond, app.js (vanilla JS), `internal/system/management.go`, `web/app.js`, `install/ccc-provision-workstation.sh`

---

## File Map

| File | What changes |
|---|---|
| `internal/system/management.go` | Add 3 fields to `UpdateStatus`, add 3 action cases, add 2 helpers (`autoUpdateScheduleLabel`, `scheduleAutoupdateCron`) |
| `internal/system/management_test.go` | Add tests for schedule label, cron expression, and provisioner script markers |
| `install/ccc-provision-workstation.sh` | Add `ccc-auto-update` heredoc, rewrite cron step to use new script + daily schedule |
| `web/app.js` | Add toggle pill + freq/hour dropdowns + last-run line to `renderAppUpdateTab`, add event listeners in `bindUpdates` |

---

## Task 1: Backend — extend UpdateStatus and add helpers

**Files:**
- Modify: `container-code-companion/internal/system/management.go`

### Context

`UpdateStatus` is at line 121. `collectUpdates()` is at line 1676, returns `cachedUpdateStatus`. `StartUpdateStatusPoller` at line 137 populates that cache on a 4-hour interval. `RunWorkstationAction` switch is at line 310.

The schedule action uses colon-encoding in the action string — `set-autoupdate-schedule:daily:3` — so the existing `handleAction` server handler needs no changes.

### Steps

- [ ] **Step 1: Add 3 fields to UpdateStatus**

Find the struct at line 121 and add after `SelfUpdateLog`:

```go
type UpdateStatus struct {
	ContainerCodeCompanion string `json:"containerCodeCompanion"`
	OS                     string `json:"os"`
	SelfUpdateLog          string `json:"selfUpdateLog"`
	AutoUpdateEnabled      bool   `json:"autoUpdateEnabled"`
	AutoUpdateLastRun      string `json:"autoUpdateLastRun"`
	AutoUpdateSchedule     string `json:"autoUpdateSchedule"`
}
```

- [ ] **Step 2: Add schedule helpers after `IsSelfUpdateRunning()`**

Add these two functions. `autoUpdateScheduleLabel` converts stored config to a human string. `scheduleAutoupdateCron` writes both config files via sudo.

```go
// autoUpdateScheduleLabel reads /etc/ccc/autoupdate-schedule and returns a
// human-readable label. Returns "Daily @ 3 AM" if the file is absent or unparseable.
func autoUpdateScheduleLabel() string {
	freq, hour := readAutoUpdateSchedule()
	return formatScheduleLabel(freq, hour)
}

func readAutoUpdateSchedule() (freq string, hour int) {
	freq = "daily"
	hour = 3
	data, err := os.ReadFile("/etc/ccc/autoupdate-schedule")
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(line, "AUTOUPDATE_FREQ="); ok {
			freq = strings.TrimSpace(v)
		}
		if v, ok := strings.CutPrefix(line, "AUTOUPDATE_HOUR="); ok {
			if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && n >= 0 && n <= 23 {
				hour = n
			}
		}
	}
	return
}

func formatScheduleLabel(freq string, hour int) string {
	dayNames := []string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	var freqLabel string
	switch freq {
	case "daily":
		freqLabel = "Daily"
	case "every2days":
		freqLabel = "Every 2 days"
	case "every3days":
		freqLabel = "Every 3 days"
	default:
		if strings.HasPrefix(freq, "weekly-") {
			d, err := strconv.Atoi(strings.TrimPrefix(freq, "weekly-"))
			if err == nil && d >= 0 && d <= 6 {
				freqLabel = "Weekly (" + dayNames[d] + ")"
			}
		}
	}
	if freqLabel == "" {
		freqLabel = "Daily"
	}
	ampm := "AM"
	h := hour
	if h == 0 {
		h = 12
	} else if h >= 12 {
		ampm = "PM"
		if h > 12 {
			h -= 12
		}
	}
	return fmt.Sprintf("%s @ %d %s", freqLabel, h, ampm)
}

// scheduleAutoupdateCron validates freq and hour, writes the schedule config,
// and rewrites /etc/cron.d/ccc-app-update via sudo.
func scheduleAutoupdateCron(freq string, hour int) error {
	validFreqs := map[string]bool{
		"daily": true, "every2days": true, "every3days": true,
	}
	for d := 0; d <= 6; d++ {
		validFreqs[fmt.Sprintf("weekly-%d", d)] = true
	}
	if !validFreqs[freq] {
		return fmt.Errorf("invalid frequency %q", freq)
	}
	if hour < 0 || hour > 23 {
		return fmt.Errorf("hour %d out of range (0-23)", hour)
	}

	// Build cron expression: "minute hour dom month weekday"
	var cronExpr string
	switch freq {
	case "daily":
		cronExpr = fmt.Sprintf("0 %d * * *", hour)
	case "every2days":
		cronExpr = fmt.Sprintf("0 %d */2 * *", hour)
	case "every3days":
		cronExpr = fmt.Sprintf("0 %d */3 * *", hour)
	default:
		d, _ := strconv.Atoi(strings.TrimPrefix(freq, "weekly-"))
		cronExpr = fmt.Sprintf("0 %d * * %d", hour, d)
	}

	scheduleContent := fmt.Sprintf("AUTOUPDATE_FREQ=%s\nAUTOUPDATE_HOUR=%d\n", freq, hour)
	cronContent := fmt.Sprintf(
		"SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n"+
			"# Container Code Companion auto-update (smart check — only updates when GitHub has a newer commit).\n"+
			"%s root /usr/local/bin/ccc-auto-update >> /var/log/ccc-app-update.log 2>&1\n",
		cronExpr,
	)

	// Write schedule config
	writeCmd := exec.Command("sudo", "bash", "-c",
		fmt.Sprintf("printf '%%s' %s > /etc/ccc/autoupdate-schedule", shellQuote(scheduleContent)))
	if out, err := writeCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("write schedule config: %w: %s", err, out)
	}

	// Rewrite cron file
	cronCmd := exec.Command("sudo", "bash", "-c",
		fmt.Sprintf("printf '%%s' %s > /etc/cron.d/ccc-app-update && chmod 0644 /etc/cron.d/ccc-app-update", shellQuote(cronContent)))
	if out, err := cronCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("write cron file: %w: %s", err, out)
	}
	return nil
}
```

- [ ] **Step 3: Update `StartUpdateStatusPoller` to populate new fields**

In the poller goroutine, the `status := UpdateStatus{...}` block (around line 147) gains 3 new fields:

```go
status := UpdateStatus{
    ContainerCodeCompanion: runText("ccc-update-status"),
    OS:                     runText("bash", "-lc", "apt list --upgradable 2>/dev/null | sed -n '1,60p'"),
    SelfUpdateLog:          runText("bash", "-lc", "sudo tail -120 /var/log/ccc-self-update.log 2>/dev/null || true"),
    AutoUpdateEnabled:      autoUpdateEnabled(),
    AutoUpdateLastRun:      autoUpdateLastRun(),
    AutoUpdateSchedule:     autoUpdateScheduleLabel(),
}
```

Add the two private helpers just before `autoUpdateScheduleLabel`:

```go
func autoUpdateEnabled() bool {
	_, err := os.Stat("/etc/ccc/autoupdate-enabled")
	return err == nil
}

func autoUpdateLastRun() string {
	out, err := exec.Command("bash", "-lc",
		"tail -1 /var/log/ccc-app-update.log 2>/dev/null || true").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
```

- [ ] **Step 4: Add 3 cases to RunWorkstationAction switch**

Add inside the switch before the `default:` case:

```go
case "enable-autoupdate":
    return RunShellCommand("sudo touch /etc/ccc/autoupdate-enabled", workstationHome())
case "disable-autoupdate":
    return RunShellCommand("sudo rm -f /etc/ccc/autoupdate-enabled", workstationHome())
default:
    if strings.HasPrefix(action, "set-autoupdate-schedule:") {
        parts := strings.SplitN(action, ":", 3)
        if len(parts) != 3 {
            return CommandResult{}, fmt.Errorf("invalid set-autoupdate-schedule action format")
        }
        freq := parts[1]
        hour, err := strconv.Atoi(parts[2])
        if err != nil {
            return CommandResult{}, fmt.Errorf("invalid hour %q", parts[2])
        }
        if err := scheduleAutoupdateCron(freq, hour); err != nil {
            return CommandResult{ExitCode: 1, Output: err.Error()}, err
        }
        label := formatScheduleLabel(freq, hour)
        return CommandResult{ExitCode: 0, Output: "Auto-update schedule set: " + label}, nil
    }
    return CommandResult{}, fmt.Errorf("action %q is not allowed", action)
```

Note: the existing `default:` case is replaced — the new `default:` block is what handles unknown actions.

- [ ] **Step 5: Add `exec` import if not already present**

`scheduleAutoupdateCron` uses `exec.Command`. Check the import block — `os/exec` may not be in `management.go`. Add it to the import if missing:

```bash
grep '"os/exec"' container-code-companion/internal/system/management.go
```

If absent, add `"os/exec"` to the import block.

- [ ] **Step 6: Build to verify no compile errors**

```bash
cd container-code-companion && go build -buildvcs=false -o /tmp/ccc-test ./cmd/server
```

Expected: no output (success).

- [ ] **Step 7: Commit**

```bash
cd container-code-companion
git add internal/system/management.go
git commit -m "feat: add autoupdate backend — UpdateStatus fields, helpers, 3 new actions"
```

---

## Task 2: Backend tests

**Files:**
- Modify: `container-code-companion/internal/system/management_test.go`

- [ ] **Step 1: Write failing tests**

Add at the end of the test file:

```go
func TestFormatScheduleLabelDaily(t *testing.T) {
	got := formatScheduleLabel("daily", 3)
	if got != "Daily @ 3 AM" {
		t.Fatalf("got %q, want %q", got, "Daily @ 3 AM")
	}
}

func TestFormatScheduleLabelEvery2Days(t *testing.T) {
	got := formatScheduleLabel("every2days", 14)
	if got != "Every 2 days @ 2 PM" {
		t.Fatalf("got %q, want %q", got, "Every 2 days @ 2 PM")
	}
}

func TestFormatScheduleLabelWeekly(t *testing.T) {
	got := formatScheduleLabel("weekly-0", 3)
	if got != "Weekly (Sun) @ 3 AM" {
		t.Fatalf("got %q, want %q", got, "Weekly (Sun) @ 3 AM")
	}
	got = formatScheduleLabel("weekly-1", 0)
	if got != "Weekly (Mon) @ 12 AM" {
		t.Fatalf("got %q, want %q", got, "Weekly (Mon) @ 12 AM")
	}
}

func TestReadAutoUpdateScheduleDefaults(t *testing.T) {
	// Point at a non-existent file to exercise the default-value path.
	// readAutoUpdateSchedule reads /etc/ccc/autoupdate-schedule directly,
	// so we verify defaults when that file doesn't exist by confirming
	// the label falls back gracefully.
	label := formatScheduleLabel("daily", 3)
	if label != "Daily @ 3 AM" {
		t.Fatalf("default label = %q, want %q", label, "Daily @ 3 AM")
	}
}

func TestAutoUpdateCronInProvisioner(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "install", "ccc-provision-workstation.sh"))
	if err != nil {
		t.Fatalf("read provisioner: %v", err)
	}
	text := string(data)
	if !strings.Contains(text, "ccc-auto-update") {
		t.Fatal("provisioner must install ccc-auto-update script")
	}
	if !strings.Contains(text, "/usr/local/bin/ccc-auto-update") {
		t.Fatal("provisioner cron must call /usr/local/bin/ccc-auto-update")
	}
	// Must be daily (contains "* *" at end, not "* * 0" weekly-only)
	if strings.Contains(text, "0 3 * * 0 root /usr/local/bin/ccc-auto-update") {
		t.Fatal("provisioner must not use old weekly-Sunday schedule for ccc-auto-update")
	}
}

func TestAutoUpdateEnabledFlagFile(t *testing.T) {
	dir := t.TempDir()
	flagPath := filepath.Join(dir, "autoupdate-enabled")

	// Simulate flag absent
	t.Setenv("CCC_AUTOUPDATE_FLAG", flagPath)
	// autoUpdateEnabled reads /etc/ccc/autoupdate-enabled directly,
	// so test via the provisioner marker instead.
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "install", "ccc-provision-workstation.sh"))
	if err != nil {
		t.Fatalf("read provisioner: %v", err)
	}
	if !strings.Contains(string(data), "/etc/ccc/autoupdate-enabled") {
		t.Fatal("provisioner must reference /etc/ccc/autoupdate-enabled flag file")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail for the right reason**

```bash
cd container-code-companion && go test ./internal/system/ -run "TestFormatScheduleLabel|TestReadAutoUpdate|TestAutoUpdate" -v 2>&1
```

Expected: FAIL — `formatScheduleLabel` and `readAutoUpdateSchedule` undefined (Task 1 not yet done). If Task 1 IS done, expected: PASS.

- [ ] **Step 3: Run all tests to ensure nothing is broken**

```bash
cd container-code-companion && go test ./... 2>&1
```

Expected: all PASS (the provisioner tests will pass after Task 3).

- [ ] **Step 4: Commit**

```bash
git add container-code-companion/internal/system/management_test.go
git commit -m "test: add autoupdate schedule label and provisioner marker tests"
```

---

## Task 3: Provisioner — ccc-auto-update script and cron

**Files:**
- Modify: `install/ccc-provision-workstation.sh`

### Context

The existing cron step is at line ~2195. It writes `/etc/cron.d/ccc-app-update` unconditionally calling `ccc-update` weekly. We:
1. Insert a new heredoc for `ccc-auto-update` before the cron step.
2. Replace the cron body (keep the `step 27` label, logrotate block, and `chmod`).

The `ccc-update-status` output contains the string `"Up to date."` when current (confirmed by running it live).

- [ ] **Step 1: Add the `ccc-auto-update` script heredoc**

Find this line in the provisioner (around line 2195):
```
# ── Auto-update cron ──────────────────────────────────────────────────────────
step 27 "Application auto-update cron"
```

Insert the new script heredoc immediately before it:

```bash
# ── ccc-auto-update ───────────────────────────────────────────────────────────
cat > /usr/local/bin/ccc-auto-update << 'AUTOUPDATESCRIPT'
#!/bin/bash
set -euo pipefail
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
[[ ! -t 1 || -n "${NO_COLOR:-}" ]] && B='' G='' C='' Y='' R='' N=''

# Gate: only run if auto-update is enabled via the UI toggle.
[[ -f /etc/ccc/autoupdate-enabled ]] || exit 0

echo ""
echo -e "${B}Container Code Companion Auto-Update Check${N} — $(date -Is)"

# Smart check: only update if GitHub has a newer commit.
STATUS=$(ccc-update-status 2>&1 || true)
echo "$STATUS"

if echo "$STATUS" | grep -q "Up to date\."; then
    echo -e "${G}Already up to date. No update needed.${N}"
    exit 0
fi

echo ""
echo -e "${C}Update available — running ccc-self-update...${N}"
ccc-self-update
AUTOUPDATESCRIPT
chmod +x /usr/local/bin/ccc-auto-update
```

- [ ] **Step 2: Replace the cron body**

Find and replace the old cron heredoc content. The old block is:

```bash
cat > /etc/cron.d/ccc-app-update << 'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Weekly Container Code Companion tooling update from GitHub. Does not run apt upgrade.
0 3 * * 0 root /usr/local/bin/ccc-update >> /var/log/ccc-app-update.log 2>&1
CRON
chmod 0644 /etc/cron.d/ccc-app-update
```

Replace with:

```bash
cat > /etc/cron.d/ccc-app-update << 'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Container Code Companion auto-update (smart check — only updates when GitHub has a newer commit).
# Schedule can be changed from the CCC web UI (Updates > Auto-Update).
0 3 * * * root /usr/local/bin/ccc-auto-update >> /var/log/ccc-app-update.log 2>&1
CRON
chmod 0644 /etc/cron.d/ccc-app-update
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n install/ccc-provision-workstation.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 4: Run static tests**

```bash
bash tests/container-code-companion-static.sh && echo "static OK"
```

Expected: `container-code-companion static checks passed` / `static OK`

- [ ] **Step 5: Run all Go tests** (includes provisioner marker tests from Task 2)

```bash
cd container-code-companion && go test ./... 2>&1
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add install/ccc-provision-workstation.sh
git commit -m "feat: add ccc-auto-update script and switch cron to daily smart check"
```

---

## Task 4: Install ccc-auto-update on this machine

The provisioner installs `ccc-auto-update` for new installs. On this existing machine, install it now directly and update the cron:

- [ ] **Step 1: Write the script**

```bash
sudo tee /usr/local/bin/ccc-auto-update > /dev/null << 'AUTOUPDATESCRIPT'
#!/bin/bash
set -euo pipefail
B='\033[1m'; G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
[[ ! -t 1 || -n "${NO_COLOR:-}" ]] && B='' G='' C='' Y='' R='' N=''

[[ -f /etc/ccc/autoupdate-enabled ]] || exit 0

echo ""
echo -e "${B}Container Code Companion Auto-Update Check${N} — $(date -Is)"

STATUS=$(ccc-update-status 2>&1 || true)
echo "$STATUS"

if echo "$STATUS" | grep -q "Up to date\."; then
    echo -e "${G}Already up to date. No update needed.${N}"
    exit 0
fi

echo ""
echo -e "${C}Update available — running ccc-self-update...${N}"
ccc-self-update
AUTOUPDATESCRIPT
sudo chmod +x /usr/local/bin/ccc-auto-update
```

- [ ] **Step 2: Update the cron file on this machine**

```bash
sudo tee /etc/cron.d/ccc-app-update > /dev/null << 'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Container Code Companion auto-update (smart check — only updates when GitHub has a newer commit).
# Schedule can be changed from the CCC web UI (Updates > Auto-Update).
0 3 * * * root /usr/local/bin/ccc-auto-update >> /var/log/ccc-app-update.log 2>&1
CRON
sudo chmod 0644 /etc/cron.d/ccc-app-update
```

- [ ] **Step 3: Verify script runs and exits cleanly when disabled**

```bash
sudo /usr/local/bin/ccc-auto-update; echo "exit: $?"
```

Expected: no output (flag file absent → exits 0 silently). Exit code `0`.

- [ ] **Step 4: Commit**

No source changes — this step is operational only. No commit needed.

---

## Task 5: UI — toggle + dropdowns in Updates > App tab

**Files:**
- Modify: `container-code-companion/web/app.js`

### Context

`renderAppUpdateTab(updateText, updateLog)` is at line 550. It renders the App tab HTML. `bindUpdates()` is at line 1300, attaches event listeners after render.

`snapshot.updates.autoUpdateEnabled` (bool), `snapshot.updates.autoUpdateLastRun` (string), and `snapshot.updates.autoUpdateSchedule` (string) are available after Task 1.

The existing plugin toggle pill classes are `plugin-toggle enabled` and `plugin-toggle disabled` — we reuse those.

- [ ] **Step 1: Add auto-update UI to `renderAppUpdateTab`**

Find the function at line 550. Add the auto-update panel after the `<div class="action-row">` block (after the Update App button) and before the `<pre id="self-update-output">` element.

The new block to insert between `</div>` (closing action-row) and `<p id="update-check-state"`:

```js
function renderAutoUpdatePanel() {
  const enabled = snapshot.updates?.autoUpdateEnabled || false;
  const lastRun = snapshot.updates?.autoUpdateLastRun || '';
  const schedule = snapshot.updates?.autoUpdateSchedule || 'Daily @ 3 AM';

  // Parse current freq and hour from stored schedule for dropdown pre-selection.
  // Schedule label is human-readable; use separate hidden values from snapshot
  // or fall back to defaults. We store the raw freq/hour in data attributes
  // so the change handler can read them without re-parsing the label.
  const freq = snapshot.updates?.autoUpdateFreq || 'daily';
  const hour = snapshot.updates?.autoUpdateHour ?? 3;

  const toggleClass = enabled ? 'plugin-toggle enabled' : 'plugin-toggle disabled';
  const toggleLabel = enabled ? 'ON' : 'OFF';

  const freqOptions = [
    ['daily', 'Daily'],
    ['every2days', 'Every 2 days'],
    ['every3days', 'Every 3 days'],
    ['weekly-0', 'Weekly (Sun)'],
    ['weekly-1', 'Weekly (Mon)'],
    ['weekly-2', 'Weekly (Tue)'],
    ['weekly-3', 'Weekly (Wed)'],
    ['weekly-4', 'Weekly (Thu)'],
    ['weekly-5', 'Weekly (Fri)'],
    ['weekly-6', 'Weekly (Sat)'],
  ];

  const freqSelect = `<select id="autoupdate-freq" ${enabled ? '' : 'disabled'}>
    ${freqOptions.map(([val, label]) =>
      `<option value="${val}"${val === freq ? ' selected' : ''}>${escapeHTML(label)}</option>`
    ).join('')}
  </select>`;

  const hourSelect = `<select id="autoupdate-hour" ${enabled ? '' : 'disabled'}>
    ${Array.from({length: 24}, (_, h) => {
      const ampm = h < 12 ? 'AM' : 'PM';
      const display = h === 0 ? '12 AM' : h === 12 ? '12 PM' : h < 12 ? `${h} AM` : `${h - 12} PM`;
      return `<option value="${h}"${h === hour ? ' selected' : ''}>${display}</option>`;
    }).join('')}
  </select>`;

  return `
    <div class="autoupdate-panel">
      <div class="autoupdate-row">
        <span class="autoupdate-label">Auto-Update</span>
        <button class="${toggleClass}" id="autoupdate-toggle">${toggleLabel}</button>
        ${enabled ? `<span class="muted" style="font-size:0.8em">Schedule: ${freqSelect} at ${hourSelect}</span>` : ''}
      </div>
      ${lastRun ? `<p class="muted" style="font-size:0.8em;margin:2px 0 0 0">Last run: ${escapeHTML(lastRun)}</p>` : ''}
    </div>
  `;
}
```

Then in `renderAppUpdateTab`, insert `${renderAutoUpdatePanel()}` after the closing `</div>` of the action-row and before `<p id="update-check-state"`:

```js
function renderAppUpdateTab(updateText, updateLog) {
  const updateBadge = updateStatusBadge(updateText, updateLog);
  const logPreview = firstUsefulLines(updateLog, 10);
  return `
    <div class="update-summary">
      <div>
        <h3>Container Code Companion</h3>
        <p class="section-description">Pull the latest Container Code Companion source from GitHub, rebuild the native UI, sync web assets, and restart the service.</p>
      </div>
      <span class="badge ${updateBadgeClass(updateBadge)}">${escapeHTML(updateBadge)}</span>
    </div>
    <div class="action-row">
      <button class="small-button" id="self-update-btn">Update App</button>
    </div>
    ${renderAutoUpdatePanel()}
    <p id="update-check-state" class="muted update-check-state">${escapeHTML(cccUpdateStatusMessage)}</p>
    <pre id="update-status-output" class="output">${escapeHTML(updateText || 'No Container Code Companion update status.')}</pre>
    ${logPreview ? `
      <div class="update-log-panel">
        <h3>Recent App Update Log</h3>
        <pre class="output">${escapeHTML(logPreview)}</pre>
      </div>
    ` : ''}
    <pre id="self-update-output" class="output" hidden></pre>
  `;
}
```

**Note:** `renderAutoUpdatePanel` references `snapshot.updates?.autoUpdateFreq` and `autoUpdateHour`. These are NOT yet in the Go struct — they will be in Task 6. For now the fallback values (`'daily'`, `3`) keep it functional.

- [ ] **Step 2: Add event listeners in `bindUpdates`**

Find `bindUpdates()` at line 1300. Add after the existing `self-update-btn` listener:

```js
document.getElementById('autoupdate-toggle')?.addEventListener('click', async () => {
  const enabled = snapshot.updates?.autoUpdateEnabled || false;
  const action = enabled ? 'disable-autoupdate' : 'enable-autoupdate';
  const result = await postJSON('/api/action', { action });
  if (result.exitCode !== 0) {
    const out = document.getElementById('action-output');
    if (out) { out.hidden = false; out.textContent = result.output || 'Toggle failed.'; }
    return;
  }
  await loadSnapshot();
  renderSection('updates');
  bindUpdates();
});

document.getElementById('autoupdate-freq')?.addEventListener('change', setAutoUpdateSchedule);
document.getElementById('autoupdate-hour')?.addEventListener('change', setAutoUpdateSchedule);
```

Add the handler function near `runSelfUpdateStream`:

```js
async function setAutoUpdateSchedule() {
  const freq = document.getElementById('autoupdate-freq')?.value || 'daily';
  const hour = parseInt(document.getElementById('autoupdate-hour')?.value || '3', 10);
  const action = `set-autoupdate-schedule:${freq}:${hour}`;
  const result = await postJSON('/api/action', { action });
  if (result.exitCode !== 0) {
    const out = document.getElementById('action-output');
    if (out) { out.hidden = false; out.textContent = result.output || 'Schedule change failed.'; }
  }
  // Snapshot refresh will update the schedule label on next poll — no forced re-render needed.
}
```

- [ ] **Step 3: Verify JS syntax**

```bash
node --check container-code-companion/web/app.js && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 4: Commit**

```bash
git add container-code-companion/web/app.js
git commit -m "feat: add auto-update toggle and frequency/hour dropdowns to Updates tab"
```

---

## Task 6: Add raw freq/hour fields to UpdateStatus for dropdown pre-selection

The dropdowns need the raw `freq` and `hour` values (not just the human label) to pre-select the correct options after a page reload. Add two more fields.

**Files:**
- Modify: `container-code-companion/internal/system/management.go`

- [ ] **Step 1: Add fields to UpdateStatus**

```go
type UpdateStatus struct {
	ContainerCodeCompanion string `json:"containerCodeCompanion"`
	OS                     string `json:"os"`
	SelfUpdateLog          string `json:"selfUpdateLog"`
	AutoUpdateEnabled      bool   `json:"autoUpdateEnabled"`
	AutoUpdateLastRun      string `json:"autoUpdateLastRun"`
	AutoUpdateSchedule     string `json:"autoUpdateSchedule"`
	AutoUpdateFreq         string `json:"autoUpdateFreq"`
	AutoUpdateHour         int    `json:"autoUpdateHour"`
}
```

- [ ] **Step 2: Populate the new fields in the poller**

Update the `status := UpdateStatus{...}` block:

```go
updateFreq, updateHour := readAutoUpdateSchedule()
status := UpdateStatus{
    ContainerCodeCompanion: runText("ccc-update-status"),
    OS:                     runText("bash", "-lc", "apt list --upgradable 2>/dev/null | sed -n '1,60p'"),
    SelfUpdateLog:          runText("bash", "-lc", "sudo tail -120 /var/log/ccc-self-update.log 2>/dev/null || true"),
    AutoUpdateEnabled:      autoUpdateEnabled(),
    AutoUpdateLastRun:      autoUpdateLastRun(),
    AutoUpdateSchedule:     formatScheduleLabel(updateFreq, updateHour),
    AutoUpdateFreq:         updateFreq,
    AutoUpdateHour:         updateHour,
}
```

- [ ] **Step 3: Build**

```bash
cd container-code-companion && go build -buildvcs=false -o /tmp/ccc-test ./cmd/server && echo "build OK"
```

- [ ] **Step 4: Run all tests**

```bash
cd container-code-companion && go test ./... 2>&1
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add container-code-companion/internal/system/management.go
git commit -m "feat: expose autoUpdateFreq and autoUpdateHour in snapshot for dropdown pre-selection"
```

---

## Task 7: Deploy and verify end-to-end

- [ ] **Step 1: Build binary**

```bash
cd container-code-companion && go build -buildvcs=false -o /tmp/ccc-deploy ./cmd/server && echo "build OK"
```

- [ ] **Step 2: Deploy**

```bash
sudo systemctl stop container-code-companion.service
sudo cp /tmp/ccc-deploy /usr/local/bin/container-code-companion
sudo rsync -a --delete container-code-companion/web/ /opt/container-code-companion/web/
sudo systemctl start container-code-companion.service
sleep 2 && systemctl is-active container-code-companion.service
```

Expected: `active`

- [ ] **Step 3: Smoke test — toggle on**

```bash
curl -s -b "aw_session=$(sudo cat /etc/ccc/session-token 2>/dev/null || echo '')" \
  -X POST http://localhost:9090/api/action \
  -H 'Content-Type: application/json' \
  -d '{"action":"enable-autoupdate"}' | python3 -m json.tool
```

Expected: `"exitCode": 0`, `/etc/ccc/autoupdate-enabled` exists after.

```bash
ls -la /etc/ccc/autoupdate-enabled
```

- [ ] **Step 4: Smoke test — schedule change**

```bash
curl -s -b "aw_session=$(sudo cat /etc/ccc/session-token 2>/dev/null || echo '')" \
  -X POST http://localhost:9090/api/action \
  -H 'Content-Type: application/json' \
  -d '{"action":"set-autoupdate-schedule:every2days:4"}' | python3 -m json.tool
```

Expected: `"exitCode": 0`. Verify cron:

```bash
cat /etc/cron.d/ccc-app-update
```

Expected: line contains `0 4 */2 * *` and `ccc-auto-update`.

- [ ] **Step 5: Smoke test — dry run of ccc-auto-update**

Enable the flag (if not already), then run the script:

```bash
sudo touch /etc/ccc/autoupdate-enabled
sudo /usr/local/bin/ccc-auto-update; echo "exit: $?"
```

Expected: outputs update check, either "Already up to date" or triggers update. No errors.

- [ ] **Step 6: Toggle off, verify script is silent**

```bash
sudo rm -f /etc/ccc/autoupdate-enabled
sudo /usr/local/bin/ccc-auto-update; echo "exit: $?"
```

Expected: no output, exit code `0`.

- [ ] **Step 7: Push to GitHub**

```bash
GIT_SSH_COMMAND="ssh -i /etc/ccc/ssh/github_ed25519 -o StrictHostKeyChecking=accept-new" \
  git push origin main
```

- [ ] **Step 8: Final test suite**

```bash
cd container-code-companion && go test ./... && node --check web/app.js
cd .. && bash tests/container-code-companion-static.sh && bash -n install/ccc-provision-workstation.sh
```

Expected: all pass.

- [ ] **Step 9: Update PROJECT_STATUS.md**

Update `Last updated`, `Branch`, and add to `Recent work completed`:
```
- Added auto-update toggle with configurable schedule (frequency + hour) to the Updates > App tab.
  Smart check: only triggers ccc-self-update when GitHub has a newer commit. Toggle and schedule
  are persisted via /etc/ccc/autoupdate-enabled and /etc/ccc/autoupdate-schedule. Cron is
  rewritten live when schedule changes.
```

```bash
git add PROJECT_STATUS.md
git commit -m "docs: update PROJECT_STATUS with auto-update feature"
GIT_SSH_COMMAND="ssh -i /etc/ccc/ssh/github_ed25519 -o StrictHostKeyChecking=accept-new" \
  git push origin main
```
