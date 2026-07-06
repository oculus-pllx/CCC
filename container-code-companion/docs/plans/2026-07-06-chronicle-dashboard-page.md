# Claude Chronicle Dashboard Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Claude Chronicle" page to Container Code Companion that runs Chronicle's harvester with a live log readout, reviews the synthesized config-delta items as a checklist, and publishes a chosen subset (or discards) to `oculus-configs`.

**Architecture:** A new `internal/system/chronicle.go` module locates the Chronicle CLI by deriving paths from the existing `sharedProjectsRoot()`, launches `chronicle run` as a detached background process (mirroring `StartSelfUpdate`), reads its `data/pending-items.json` staging file, and runs `chronicle publish` with a server-built argv. Four `/api/chronicle-*` endpoints wired through `server.go`'s `Config` dependency-injection funcs drive a vanilla-JS SPA section that polls the run log and renders the item checklist.

**Tech Stack:** Go 1.x (stdlib `os`, `os/exec`, `encoding/json`), CCC's `internal/system` + `internal/server` packages, vanilla JS SPA (`web/app.js`, `web/index.html`, `web/styles.css`) — no framework, no build step, no new dependency.

## Global Constraints

- **Path derivation:** all Chronicle paths derive from `sharedProjectsRoot()` (resolves `/srv/ccc/projects`, honors `CCC_SHARED_PROJECTS`). No hardcoded absolute path, no config UI, no new env var. Binary `<root>/Chronicle/.venv/bin/chronicle`; workdir `<root>/Chronicle`; pending `<root>/Chronicle/data/pending-items.json`; run log `<root>/Chronicle/data/chronicle-run.log`.
- **No shell interpolation of client input:** `PublishChronicle` builds argv (`[]string`) server-side from the validated `Mode`; client text is never concatenated into a shell string. Invalid mode or empty/out-of-range item indices are rejected before exec with an actionable error.
- **Detached run:** `chronicle run` makes LLM calls that exceed CCC's 45s synchronous-command timeout, so it launches detached (`setsid`, `NO_COLOR=1`, no inherited pipes) exactly like `StartSelfUpdate`, and the browser polls a status endpoint.
- **CCC only invokes the CLI** and reads the pending file; it never reimplements Chronicle's synthesis or publish logic in Go.
- **Endpoints behind `requireSession`,** wired through `Config` DI funcs so handler tests can stub them (like `listNotes` / `sshKeyOperation`).
- **On-disk pending JSON is snake_case:** `synthesized_at`, `session_count`, `items[]` with `rule`, `why`, `citations`, `target_file`, `placement` (verbatim from Chronicle's `DeltaItem`). Unknown keys are ignored.
- **Non-zero CLI exit is not a Go error:** like `RunShellCommand`, publish/run report failure through `CommandResult.ExitCode` + `Output`, not a returned `error`. Reserve returned errors for pre-exec conditions (missing binary, invalid selection, decode failure).
- **Code quality:** no `console.log`/`fmt.Print` debug in production code; no dead imports; descriptive names; `go test ./...` must pass; existing CCC tests must continue to pass.
- **Git:** commit per task with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Branch is `main`, default workflow pushes to `main`, no PRs.

---

### Task 1: Pending-file reader (`chronicle.go` types + path helpers + `ReadChroniclePending`)

**Files:**
- Create: `internal/system/chronicle.go`
- Test: `internal/system/chronicle_test.go`

**Interfaces:**
- Consumes: `sharedProjectsRoot() string` (existing, `internal/system/management.go`).
- Produces:
  - `type ChroniclePendingItem struct { Rule, Why string; Citations []string; TargetFile, Placement string }`
  - `type ChroniclePending struct { Available bool; SynthesizedAt string; SessionCount int; Items []ChroniclePendingItem }`
  - `func ReadChroniclePending() (ChroniclePending, error)`
  - unexported path helpers `chronicleDir()`, `chronicleBinary()`, `chroniclePendingPath()`, `chronicleRunLogPath() string` (relied on by Tasks 2 & 3).

- [ ] **Step 1: Write the failing test**

Create `internal/system/chronicle_test.go`. These tests set `CCC_SHARED_PROJECTS` to a temp dir so the derived paths resolve there.

```go
package system

import (
	"os"
	"path/filepath"
	"testing"
)

// withChronicleRoot points sharedProjectsRoot() at a temp dir and returns the
// Chronicle data dir (created) so tests can plant a pending file / run log.
func withChronicleRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Setenv("CCC_SHARED_PROJECTS", root)
	dataDir := filepath.Join(root, "Chronicle", "data")
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		t.Fatalf("mkdir data dir: %v", err)
	}
	return dataDir
}

func TestReadChroniclePendingValid(t *testing.T) {
	dataDir := withChronicleRoot(t)
	json := `{"synthesized_at":"2026-07-06T12:00:00+00:00","session_count":3,` +
		`"items":[{"rule":"Prefer X","why":"because","citations":["s1 turn 4"],` +
		`"target_file":"claude/CLAUDE.md","placement":"append"}]}`
	if err := os.WriteFile(filepath.Join(dataDir, "pending-items.json"), []byte(json), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ReadChroniclePending()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.Available {
		t.Fatal("expected Available=true")
	}
	if got.SynthesizedAt != "2026-07-06T12:00:00+00:00" || got.SessionCount != 3 {
		t.Fatalf("meta mismatch: %+v", got)
	}
	if len(got.Items) != 1 || got.Items[0].Rule != "Prefer X" || got.Items[0].TargetFile != "claude/CLAUDE.md" {
		t.Fatalf("items mismatch: %+v", got.Items)
	}
}

func TestReadChroniclePendingAbsent(t *testing.T) {
	withChronicleRoot(t) // no pending file written
	got, err := ReadChroniclePending()
	if err != nil {
		t.Fatalf("absent file must not error: %v", err)
	}
	if got.Available {
		t.Fatal("expected Available=false for absent file")
	}
	if got.Items == nil {
		t.Fatal("Items should be a non-nil empty slice")
	}
}

func TestReadChroniclePendingEmpty(t *testing.T) {
	dataDir := withChronicleRoot(t)
	if err := os.WriteFile(filepath.Join(dataDir, "pending-items.json"), []byte("   \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ReadChroniclePending()
	if err != nil {
		t.Fatalf("empty file must not error: %v", err)
	}
	if got.Available {
		t.Fatal("expected Available=false for empty file")
	}
}

func TestReadChroniclePendingCorrupt(t *testing.T) {
	dataDir := withChronicleRoot(t)
	if err := os.WriteFile(filepath.Join(dataDir, "pending-items.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := ReadChroniclePending()
	if err == nil {
		t.Fatal("corrupt JSON must return an error")
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/ -run TestReadChroniclePending -v`
Expected: FAIL — `undefined: ReadChroniclePending` (build error).

- [ ] **Step 3: Write the minimal implementation**

Create `internal/system/chronicle.go`:

```go
package system

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// Chronicle is the standalone Python CLI at <projects-root>/Chronicle. Its
// paths derive from sharedProjectsRoot() so they honor CCC_SHARED_PROJECTS;
// there is no hardcoded path and no separate config.

func chronicleDir() string {
	return filepath.Join(sharedProjectsRoot(), "Chronicle")
}

func chronicleBinary() string {
	return filepath.Join(chronicleDir(), ".venv", "bin", "chronicle")
}

func chroniclePendingPath() string {
	return filepath.Join(chronicleDir(), "data", "pending-items.json")
}

func chronicleRunLogPath() string {
	return filepath.Join(chronicleDir(), "data", "chronicle-run.log")
}

// ChroniclePendingItem mirrors Chronicle's DeltaItem verbatim; the json tags
// match the on-disk snake_case keys so this struct also unmarshals the file.
type ChroniclePendingItem struct {
	Rule       string   `json:"rule"`
	Why        string   `json:"why"`
	Citations  []string `json:"citations"`
	TargetFile string   `json:"target_file"`
	Placement  string   `json:"placement"`
}

// ChroniclePending is the API view of data/pending-items.json.
type ChroniclePending struct {
	Available     bool                   `json:"available"`
	SynthesizedAt string                 `json:"synthesizedAt"`
	SessionCount  int                    `json:"sessionCount"`
	Items         []ChroniclePendingItem `json:"items"`
}

// chroniclePendingFile is the on-disk shape (snake_case wrapper keys).
type chroniclePendingFile struct {
	SynthesizedAt string                 `json:"synthesized_at"`
	SessionCount  int                    `json:"session_count"`
	Items         []ChroniclePendingItem `json:"items"`
}

// ReadChroniclePending parses the pending file. An absent or empty file yields
// Available:false with an empty item slice (not an error); malformed JSON
// returns an error naming the file.
func ReadChroniclePending() (ChroniclePending, error) {
	empty := ChroniclePending{Available: false, Items: []ChroniclePendingItem{}}
	data, err := os.ReadFile(chroniclePendingPath())
	if errors.Is(err, os.ErrNotExist) {
		return empty, nil
	}
	if err != nil {
		return ChroniclePending{}, err
	}
	if len(bytes.TrimSpace(data)) == 0 {
		return empty, nil
	}
	var file chroniclePendingFile
	if err := json.Unmarshal(data, &file); err != nil {
		return ChroniclePending{}, fmt.Errorf("parse %s: %w", chroniclePendingPath(), err)
	}
	items := file.Items
	if items == nil {
		items = []ChroniclePendingItem{}
	}
	return ChroniclePending{
		Available:     true,
		SynthesizedAt: file.SynthesizedAt,
		SessionCount:  file.SessionCount,
		Items:         items,
	}, nil
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/ -run TestReadChroniclePending -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd /srv/ccc/projects/CCC/container-code-companion
git add internal/system/chronicle.go internal/system/chronicle_test.go
git commit -m "$(cat <<'EOF'
feat: add Chronicle pending-file reader

Derive Chronicle paths from sharedProjectsRoot(); parse
data/pending-items.json into typed structs (absent/empty => Available:false,
corrupt => error).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Publish invocation (`buildPublishArgs` + `PublishChronicle`)

**Files:**
- Modify: `internal/system/chronicle.go`
- Test: `internal/system/chronicle_test.go`

**Interfaces:**
- Consumes: `chronicleBinary()`, `chronicleDir()` (Task 1); `CommandResult` (existing struct in `internal/system`, fields `Command`, `Cwd`, `Output`, `ExitCode` — same one `RunShellCommand` returns).
- Produces:
  - `type ChroniclePublishOperation struct { Mode string; Items []int }`
  - `func buildPublishArgs(op ChroniclePublishOperation) ([]string, error)` (pure; unit-tested directly)
  - `func PublishChronicle(op ChroniclePublishOperation) (CommandResult, error)`

- [ ] **Step 1: Write the failing test**

Append to `internal/system/chronicle_test.go`:

```go
func TestBuildPublishArgs(t *testing.T) {
	cases := []struct {
		name    string
		op      ChroniclePublishOperation
		want    []string
		wantErr bool
	}{
		{"all", ChroniclePublishOperation{Mode: "all"}, []string{"publish", "--all"}, false},
		{"discard", ChroniclePublishOperation{Mode: "discard"}, []string{"publish", "--discard"}, false},
		{"items", ChroniclePublishOperation{Mode: "items", Items: []int{1, 3}}, []string{"publish", "--items", "1,3"}, false},
		{"items empty", ChroniclePublishOperation{Mode: "items"}, nil, true},
		{"items zero index", ChroniclePublishOperation{Mode: "items", Items: []int{0}}, nil, true},
		{"items negative", ChroniclePublishOperation{Mode: "items", Items: []int{-2}}, nil, true},
		{"bad mode", ChroniclePublishOperation{Mode: "nuke"}, nil, true},
		{"empty mode", ChroniclePublishOperation{}, nil, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := buildPublishArgs(tc.op)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got args %v", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("got %v want %v", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("got %v want %v", got, tc.want)
				}
			}
		})
	}
}

func TestPublishChronicleMissingBinary(t *testing.T) {
	withChronicleRoot(t) // no binary planted
	_, err := PublishChronicle(ChroniclePublishOperation{Mode: "all"})
	if err == nil {
		t.Fatal("expected error when binary is missing")
	}
}

func TestPublishChronicleInvalidRejectedBeforeExec(t *testing.T) {
	// Plant a binary that would fail loudly if ever executed.
	dataDir := withChronicleRoot(t)
	binDir := filepath.Join(filepath.Dir(dataDir), ".venv", "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\necho SHOULD_NOT_RUN >&2\nexit 1\n"
	if err := os.WriteFile(filepath.Join(binDir, "chronicle"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	_, err := PublishChronicle(ChroniclePublishOperation{Mode: "items"}) // empty items
	if err == nil {
		t.Fatal("expected validation error before exec")
	}
}

func TestPublishChronicleRunsFakeBinary(t *testing.T) {
	dataDir := withChronicleRoot(t)
	binDir := filepath.Join(filepath.Dir(dataDir), ".venv", "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Fake chronicle echoes its args so we can assert argv + cwd wiring.
	script := "#!/bin/sh\necho \"args: $*\"\necho \"cwd: $(pwd)\"\nexit 0\n"
	if err := os.WriteFile(filepath.Join(binDir, "chronicle"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	res, err := PublishChronicle(ChroniclePublishOperation{Mode: "items", Items: []int{2, 4}})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.ExitCode != 0 {
		t.Fatalf("expected exit 0, got %d (%s)", res.ExitCode, res.Output)
	}
	if !strings.Contains(res.Output, "args: publish --items 2,4") {
		t.Fatalf("argv not passed through: %q", res.Output)
	}
	if !strings.Contains(res.Output, "cwd: "+chronicleDir()) {
		t.Fatalf("cwd not set to chronicleDir: %q", res.Output)
	}
}
```

Add `"strings"` to the test file's import block (alongside `os`, `path/filepath`, `testing`).

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/ -run 'TestBuildPublishArgs|TestPublishChronicle' -v`
Expected: FAIL — `undefined: buildPublishArgs` / `undefined: PublishChronicle`.

- [ ] **Step 3: Write the minimal implementation**

Append to `internal/system/chronicle.go`. Add `"context"`, `"os/exec"`, `"strconv"`, `"strings"`, `"time"` to the import block:

```go
// ChroniclePublishOperation selects what chronicle publish acts on.
type ChroniclePublishOperation struct {
	Mode  string `json:"mode"`  // "items" | "all" | "discard"
	Items []int  `json:"items"` // 1-based indices, required when Mode=="items"
}

// buildPublishArgs turns a validated operation into a chronicle argv. It never
// embeds client text into a shell string; the CLI receives discrete args.
func buildPublishArgs(op ChroniclePublishOperation) ([]string, error) {
	switch op.Mode {
	case "all":
		return []string{"publish", "--all"}, nil
	case "discard":
		return []string{"publish", "--discard"}, nil
	case "items":
		if len(op.Items) == 0 {
			return nil, errors.New("no items selected; pick at least one item or use Publish All / Discard")
		}
		parts := make([]string, 0, len(op.Items))
		for _, n := range op.Items {
			if n < 1 {
				return nil, fmt.Errorf("invalid item index %d; indices are 1-based", n)
			}
			parts = append(parts, strconv.Itoa(n))
		}
		return []string{"publish", "--items", strings.Join(parts, ",")}, nil
	default:
		return nil, fmt.Errorf("invalid publish mode %q; expected items, all, or discard", op.Mode)
	}
}

// PublishChronicle validates the selection and runs the matching
// `chronicle publish` invocation synchronously (publish is render + git push,
// well under the 45s ceiling; a 60s guard covers a stalled push). A non-zero
// CLI exit is reported through the result, not as a returned error.
func PublishChronicle(op ChroniclePublishOperation) (CommandResult, error) {
	args, err := buildPublishArgs(op)
	if err != nil {
		return CommandResult{}, err
	}
	bin := chronicleBinary()
	if _, statErr := os.Stat(bin); statErr != nil {
		return CommandResult{}, fmt.Errorf("Chronicle not found at %s", bin)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Dir = chronicleDir()
	cmd.Env = append(os.Environ(), "NO_COLOR=1")
	output, _ := cmd.CombinedOutput()

	result := CommandResult{
		Command: "chronicle " + strings.Join(args, " "),
		Cwd:     chronicleDir(),
		Output:  string(output),
	}
	if cmd.ProcessState != nil {
		result.ExitCode = cmd.ProcessState.ExitCode()
	}
	if ctx.Err() == context.DeadlineExceeded {
		result.ExitCode = 124
		return result, errors.New("chronicle publish timed out after 60 seconds")
	}
	return result, nil
}
```

> **Note for implementer:** verify `CommandResult`'s exact field names by reading its definition in `internal/system/management.go` (search `type CommandResult`). This plan assumes `Command`, `Cwd`, `Output`, `ExitCode`; if a field differs, match the real struct.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/ -run 'TestBuildPublishArgs|TestPublishChronicle' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /srv/ccc/projects/CCC/container-code-companion
git add internal/system/chronicle.go internal/system/chronicle_test.go
git commit -m "$(cat <<'EOF'
feat: add Chronicle publish invocation

Build chronicle publish argv server-side from a validated
ChroniclePublishOperation (never interpolating client text into a shell
string); reject bad mode / empty / out-of-range indices before exec.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Detached run launcher + status (`StartChronicleRun` + `ChronicleRunStatus`)

**Files:**
- Modify: `internal/system/chronicle.go`
- Test: `internal/system/chronicle_test.go`

**Interfaces:**
- Consumes: `chronicleBinary()`, `chronicleDir()`, `chronicleRunLogPath()` (Task 1); `CommandResult`.
- Produces:
  - `func StartChronicleRun() (CommandResult, error)` — launches `chronicle run` detached, appending to the run log; preflights the binary.
  - `func ChronicleRunStatus() (log string, running bool)` — returns run-log contents and whether a chronicle process is alive.
  - unexported `chronicleRunActive() bool`, `shellQuote(string) string`.

- [ ] **Step 1: Write the failing test**

Append to `internal/system/chronicle_test.go`:

```go
func TestStartChronicleRunMissingBinary(t *testing.T) {
	withChronicleRoot(t) // no binary
	res, err := StartChronicleRun()
	if err == nil {
		t.Fatal("expected error when binary is missing")
	}
	if res.ExitCode == 0 {
		t.Fatal("expected non-zero exit code in result")
	}
}

func TestChronicleRunStatusReadsLog(t *testing.T) {
	dataDir := withChronicleRoot(t)
	if err := os.WriteFile(filepath.Join(dataDir, "chronicle-run.log"), []byte("line one\nline two\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	log, running := ChronicleRunStatus()
	if log != "line one\nline two\n" {
		t.Fatalf("log mismatch: %q", log)
	}
	// No chronicle process is running against this temp path.
	if running {
		t.Fatal("expected running=false with no chronicle process")
	}
}

func TestChronicleRunStatusNoLog(t *testing.T) {
	withChronicleRoot(t) // no log file
	log, running := ChronicleRunStatus()
	if log != "" {
		t.Fatalf("expected empty log, got %q", log)
	}
	if running {
		t.Fatal("expected running=false")
	}
}

func TestShellQuote(t *testing.T) {
	if got := shellQuote("/a/b c"); got != "'/a/b c'" {
		t.Fatalf("got %q", got)
	}
	if got := shellQuote("it's"); got != `'it'\''s'` {
		t.Fatalf("got %q", got)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/ -run 'TestStartChronicleRun|TestChronicleRunStatus|TestShellQuote' -v`
Expected: FAIL — `undefined: StartChronicleRun` / `ChronicleRunStatus` / `shellQuote`.

- [ ] **Step 3: Write the minimal implementation**

Append to `internal/system/chronicle.go` (imports `bytes`, `os/exec`, `strings`, `errors`, `fmt`, `os`, `path/filepath` are already present from Tasks 1–2):

```go
// shellQuote single-quotes a path for safe inclusion in the detached bash
// launch string. Derived paths are unlikely to contain metacharacters, but
// quoting keeps the launch robust.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// StartChronicleRun launches `chronicle run` as a detached background process
// that appends stdout+stderr to the run log and returns immediately. This
// mirrors StartSelfUpdate and is required because chronicle run makes LLM calls
// that exceed CCC's 45s synchronous-command timeout. The arg list is kept
// simple so a later provider/limit change can extend it.
func StartChronicleRun() (CommandResult, error) {
	bin := chronicleBinary()
	if _, err := os.Stat(bin); err != nil {
		return CommandResult{
			Command:  "chronicle run",
			Output:   fmt.Sprintf("Chronicle not found at %s", bin),
			ExitCode: 1,
		}, fmt.Errorf("Chronicle not found at %s", bin)
	}

	logPath := chronicleRunLogPath()
	dataDir := filepath.Dir(logPath)
	// setsid + no inherited pipes so the run survives the HTTP response; a
	// fresh log per run (truncate) starts each readout clean.
	command := "mkdir -p " + shellQuote(dataDir) +
		" && printf 'chronicle run started at %s\\n' \"$(date -Is)\" > " + shellQuote(logPath) +
		" && { setsid env NO_COLOR=1 " + shellQuote(bin) + " run >> " + shellQuote(logPath) +
		" 2>&1 < /dev/null & }"

	var launchErr bytes.Buffer
	cmd := exec.Command("bash", "-lc", command)
	cmd.Dir = chronicleDir()
	cmd.Stderr = &launchErr
	if err := cmd.Start(); err != nil {
		return CommandResult{Command: "chronicle run", Output: "Run launch failed: " + err.Error(), ExitCode: 1}, err
	}
	if err := cmd.Wait(); err != nil {
		msg := strings.TrimSpace(launchErr.String())
		if msg == "" {
			msg = err.Error()
		}
		return CommandResult{Command: "chronicle run", Output: "Run launch failed: " + msg, ExitCode: 1}, errors.New(msg)
	}
	return CommandResult{
		Command:  "chronicle run",
		Cwd:      chronicleDir(),
		Output:   "Chronicle run started.",
		ExitCode: 0,
	}, nil
}

// ChronicleRunStatus returns the run-log contents and whether a chronicle run
// process is still alive. A missing log reads as empty (the run may not have
// written yet); it is not an error.
func ChronicleRunStatus() (string, bool) {
	log, _ := os.ReadFile(chronicleRunLogPath())
	return string(log), chronicleRunActive()
}

// chronicleRunActive scans /proc for a process whose cmdline references the
// chronicle binary path. Matching the full derived path (not just "chronicle")
// avoids false positives from unrelated processes. No sudo required.
func chronicleRunActive() bool {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return false
	}
	needle := chronicleBinary()
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if name == "" || name[0] < '1' || name[0] > '9' {
			continue
		}
		data, err := os.ReadFile("/proc/" + name + "/cmdline")
		if err != nil {
			continue
		}
		if strings.Contains(string(data), needle) {
			return true
		}
	}
	return false
}
```

> **Note for implementer:** cross-check the launch template against `StartSelfUpdate` in `internal/system/management.go` (the `setsid env ... & }` braces, `cmd.Start()`+`cmd.Wait()` to avoid inheriting pipes). Match its exact bracing/redirection idiom if it differs from above.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/ -run 'TestStartChronicleRun|TestChronicleRunStatus|TestShellQuote' -v`
Expected: PASS.

- [ ] **Step 5: Run the whole system package to confirm nothing regressed**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/`
Expected: `ok`.

- [ ] **Step 6: Commit**

```bash
cd /srv/ccc/projects/CCC/container-code-companion
git add internal/system/chronicle.go internal/system/chronicle_test.go
git commit -m "$(cat <<'EOF'
feat: add detached Chronicle run launcher and status

Launch chronicle run detached (setsid, NO_COLOR=1, fresh log) mirroring
self-update; report run-log contents plus a /proc-scan liveness flag for
browser polling.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: HTTP endpoints (Config wiring + handlers + routes + handler tests)

**Files:**
- Modify: `internal/server/server.go` (Config struct, Server struct, `New()` assignments + nil-defaults, `routes()`, four new handler methods)
- Modify: `internal/server/server_test.go` (`newTestServer` stubs + handler tests)

**Interfaces:**
- Consumes: `system.StartChronicleRun`, `system.ChronicleRunStatus`, `system.ReadChroniclePending`, `system.PublishChronicle`, `system.ChroniclePending`, `system.ChroniclePublishOperation`, `system.CommandResult` (Tasks 1–3); existing `requireSession`, `writeJSON`, `SessionCookieName`.
- Produces: four routes — `POST /api/chronicle-run`, `GET /api/chronicle-run-log`, `GET /api/chronicle-pending`, `POST /api/chronicle-publish` — and four Config funcs `ChronicleRun`, `ChronicleRunStatus`, `ChroniclePending`, `ChroniclePublish`.

- [ ] **Step 1: Write the failing handler tests**

Append to `internal/server/server_test.go`. (These reuse the file's existing imports: `net/http`, `net/http/httptest`, `testing`, `strings`, `encoding/json`, and the `system` package. Add any not already imported.)

```go
func TestChroniclePendingRequiresSession(t *testing.T) {
	srv := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/api/chronicle-pending", nil)
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)
	if res.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without session, got %d", res.Code)
	}
}

func TestChroniclePendingReturnsItems(t *testing.T) {
	srv := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/api/chronicle-pending", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.Code)
	}
	var got system.ChroniclePending
	if err := json.Unmarshal(res.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !got.Available || len(got.Items) != 1 {
		t.Fatalf("unexpected pending payload: %+v", got)
	}
}

func TestChronicleRunLogReturnsStatus(t *testing.T) {
	srv := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/api/chronicle-run-log", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.Code)
	}
	var got struct {
		Log     string `json:"log"`
		Running bool   `json:"running"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Log == "" || got.Running {
		t.Fatalf("unexpected run-log payload: %+v", got)
	}
}

func TestChroniclePublishValidReturnsResult(t *testing.T) {
	srv := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/chronicle-publish", strings.NewReader(`{"mode":"all"}`))
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d (%s)", res.Code, res.Body.String())
	}
}

func TestChroniclePublishInvalidModeRejected(t *testing.T) {
	srv := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/chronicle-publish", strings.NewReader(`{"mode":""}`))
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)
	if res.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for invalid mode, got %d", res.Code)
	}
}

func TestChronicleRunRejectsGet(t *testing.T) {
	srv := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/api/chronicle-run", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)
	if res.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 for GET, got %d", res.Code)
	}
}
```

Then extend the `Config{...}` literal inside `newTestServer` (in the same test file) with the four stubs:

```go
		ChronicleRunStatus: func() (string, bool) {
			return "chronicle run started at 2026-07-06\n", false
		},
		ChroniclePending: func() (system.ChroniclePending, error) {
			return system.ChroniclePending{
				Available:     true,
				SynthesizedAt: "2026-07-06T12:00:00+00:00",
				SessionCount:  3,
				Items: []system.ChroniclePendingItem{
					{Rule: "rule one", TargetFile: "claude/CLAUDE.md"},
				},
			}, nil
		},
		ChroniclePublish: func(op system.ChroniclePublishOperation) (system.CommandResult, error) {
			if op.Mode == "" {
				return system.CommandResult{}, fmt.Errorf("invalid publish mode")
			}
			return system.CommandResult{Command: "chronicle publish", Output: "published " + op.Mode, ExitCode: 0}, nil
		},
		ChronicleRun: func() (system.CommandResult, error) {
			return system.CommandResult{Command: "chronicle run", Output: "Chronicle run started.", ExitCode: 0}, nil
		},
```

(If `fmt` is not yet imported in the test file, add it.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/server/ -run TestChronicle -v`
Expected: FAIL — unknown field `ChronicleRunStatus` in `Config` / no route (build error).

- [ ] **Step 3: Add the Config fields, Server fields, New() wiring, routes, and handlers**

In `internal/server/server.go`:

**(a)** Add to the `Config` struct (near the other func fields like `ListNotes` / `SSHKeyOperation`):

```go
	ChronicleRun       func() (system.CommandResult, error)
	ChronicleRunStatus func() (string, bool)
	ChroniclePending   func() (system.ChroniclePending, error)
	ChroniclePublish   func(op system.ChroniclePublishOperation) (system.CommandResult, error)
```

**(b)** Add matching lowercase fields to the `Server` struct:

```go
	chronicleRun       func() (system.CommandResult, error)
	chronicleRunStatus func() (string, bool)
	chroniclePending   func() (system.ChroniclePending, error)
	chroniclePublish   func(op system.ChroniclePublishOperation) (system.CommandResult, error)
```

**(c)** In `New(config Config)`, copy the config funcs into the server (with the other `s.x = config.X` lines):

```go
	s.chronicleRun = config.ChronicleRun
	s.chronicleRunStatus = config.ChronicleRunStatus
	s.chroniclePending = config.ChroniclePending
	s.chroniclePublish = config.ChroniclePublish
```

and add the nil-defaults (with the other `if s.x == nil` blocks):

```go
	if s.chronicleRun == nil {
		s.chronicleRun = system.StartChronicleRun
	}
	if s.chronicleRunStatus == nil {
		s.chronicleRunStatus = system.ChronicleRunStatus
	}
	if s.chroniclePending == nil {
		s.chroniclePending = system.ReadChroniclePending
	}
	if s.chroniclePublish == nil {
		s.chroniclePublish = system.PublishChronicle
	}
```

**(d)** In `routes()`, register the four endpoints (with the other `s.mux.Handle("/api/...", s.requireSession(...))` lines):

```go
	s.mux.Handle("/api/chronicle-run", s.requireSession(http.HandlerFunc(s.handleChronicleRun)))
	s.mux.Handle("/api/chronicle-run-log", s.requireSession(http.HandlerFunc(s.handleChronicleRunLog)))
	s.mux.Handle("/api/chronicle-pending", s.requireSession(http.HandlerFunc(s.handleChroniclePending)))
	s.mux.Handle("/api/chronicle-publish", s.requireSession(http.HandlerFunc(s.handleChroniclePublish)))
```

**(e)** Add the four handler methods (near `handleNotes` / `handleSelfUpdate`):

```go
func (s *Server) handleChronicleRun(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// A missing binary is reported through the result (ExitCode!=0 + Output);
	// the browser inspects exitCode, mirroring handleSelfUpdate.
	result, _ := s.chronicleRun()
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleChronicleRunLog(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	log, running := s.chronicleRunStatus()
	writeJSON(w, http.StatusOK, map[string]any{"log": log, "running": running})
}

func (s *Server) handleChroniclePending(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	pending, err := s.chroniclePending()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, pending)
}

func (s *Server) handleChroniclePublish(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var op system.ChroniclePublishOperation
	if err := json.NewDecoder(r.Body).Decode(&op); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	result, err := s.chroniclePublish(op)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, result)
}
```

> **Note for implementer:** confirm the exact helper names/signatures by reading `server.go` — `writeJSON(w, status, payload)`, `requireSession`, `SessionCookieName`, and how `New` copies+defaults funcs (`handleNotes`/`handleSelfUpdate` are the reference handlers). Use `any` only if the file already does; otherwise use `map[string]interface{}`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/server/ -run TestChronicle -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Run the full Go suite**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./...`
Expected: all packages `ok`.

- [ ] **Step 6: Commit**

```bash
cd /srv/ccc/projects/CCC/container-code-companion
git add internal/server/server.go internal/server/server_test.go
git commit -m "$(cat <<'EOF'
feat: wire Chronicle HTTP endpoints

Add /api/chronicle-run, -run-log, -pending, -publish behind requireSession,
injected through Config funcs so handler tests stub them; publish rejects an
invalid mode with 400.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Frontend section (nav + renderer + poll loop + publish actions)

**Files:**
- Modify: `web/index.html` (nav button in the Settings group)
- Modify: `web/app.js` (`titles` entry, `renderers` entry, `renderChronicle`, pending-list renderer, run/poll, publish/discard binding, `bindSectionActions` case)
- Modify: `web/styles.css` (checklist row styling)

**Interfaces:**
- Consumes: endpoints from Task 4 (`/api/chronicle-run`, `/api/chronicle-run-log`, `/api/chronicle-pending`, `/api/chronicle-publish`); existing JS helpers `postJSON(url, body, method='POST')`, `escapeHTML`, `stripANSI`, `loadSnapshot`, `startSnapshotPolling`, `stopSnapshotPolling`, and the `titles`/`renderers`/`bindSectionActions` structures.
- Produces: a `data-section="chronicle"` section rendered by `renderChronicle()`.

> **Note for implementer:** this repo has no JS test harness (per spec); verification is `go test ./...` still green (the web dir is embedded/served) plus a manual smoke test against a live Chronicle checkout. Before editing, read `web/app.js` to confirm the exact current shapes of `titles`, the `renderers` map, `renderSection`'s sign-in guard, `bindSectionActions`, and `postJSON`; match them. Confirm `startSnapshotPolling`/`stopSnapshotPolling` exist (used by `runSelfUpdateStream`); if the helper names differ, use the actual ones.

- [ ] **Step 1: Add the nav button**

In `web/index.html`, inside the **Settings** nav group (next to the `oculus`/`configs` buttons), add:

```html
        <button data-section="chronicle">Claude Chronicle</button>
```

- [ ] **Step 2: Add the title entry**

In `web/app.js`, add to the `titles` map (Settings-adjacent):

```js
  chronicle: 'Claude Chronicle',
```

- [ ] **Step 3: Register the renderer**

In `web/app.js`, add to the `renderers` map in `renderSection`:

```js
  chronicle: renderChronicle,
```

- [ ] **Step 4: Add the render + behavior functions**

Add these functions to `web/app.js` (near the other `renderX` functions):

```js
function renderChronicle() {
  return `
    <p class="section-description">Harvest Fable-5 transcript patterns into config-delta proposals, review them, and publish a selection to oculus-configs.</p>
    <div class="action-row">
      <button id="chronicle-run-btn" class="small-button">Run Chronicle</button>
      <span id="chronicle-run-state" class="muted"></span>
    </div>
    <pre id="chronicle-run-log" class="output" hidden></pre>
    <div id="chronicle-pending"><p class="muted">Loading pending items…</p></div>
    <pre id="chronicle-publish-output" class="output" hidden></pre>
  `;
}

function bindChronicle() {
  const runBtn = document.getElementById('chronicle-run-btn');
  if (runBtn) runBtn.addEventListener('click', runChronicle);
  loadChroniclePending();
}

async function loadChroniclePending() {
  const container = document.getElementById('chronicle-pending');
  if (!container) return;
  try {
    const resp = await fetch('/api/chronicle-pending', { credentials: 'include' });
    if (!resp.ok) throw new Error('HTTP ' + resp.status);
    const pending = await resp.json();
    renderChroniclePendingList(pending);
  } catch (err) {
    container.innerHTML = `<p class="error-text">${escapeHTML(err.message)}</p>`;
  }
}

function renderChroniclePendingList(pending) {
  const container = document.getElementById('chronicle-pending');
  if (!container) return;
  const items = (pending && pending.items) || [];
  if (!pending || !pending.available || items.length === 0) {
    container.innerHTML = '<p class="muted">No pending items — run Chronicle to synthesize.</p>';
    return;
  }
  const rows = items.map((item, i) => `
    <label class="chronicle-item">
      <input type="checkbox" class="chronicle-item-check" value="${i + 1}" checked>
      <span class="chronicle-item-rule">${escapeHTML(item.rule || '')}</span>
      <span class="chronicle-item-target">${escapeHTML(item.target_file || '')}</span>
    </label>
  `).join('');
  container.innerHTML = `
    <div class="chronicle-pending-header">
      <strong>${items.length} pending item${items.length === 1 ? '' : 's'}</strong>
      <span class="muted">synthesized ${escapeHTML(pending.synthesizedAt || 'unknown')} · ${pending.sessionCount || 0} session${pending.sessionCount === 1 ? '' : 's'}</span>
    </div>
    <div class="chronicle-item-list">${rows}</div>
    <div class="action-row">
      <button id="chronicle-publish-selected" class="small-button">Publish Selected</button>
      <button id="chronicle-publish-all" class="small-button">Publish All</button>
      <button id="chronicle-discard" class="small-button danger-button">Discard</button>
    </div>
  `;
  bindChroniclePublishButtons();
}

function bindChroniclePublishButtons() {
  const sel = document.getElementById('chronicle-publish-selected');
  const all = document.getElementById('chronicle-publish-all');
  const dis = document.getElementById('chronicle-discard');
  if (sel) sel.addEventListener('click', () => {
    const items = Array.from(document.querySelectorAll('.chronicle-item-check:checked'))
      .map((c) => parseInt(c.value, 10));
    if (items.length === 0) {
      showChroniclePublishOutput('Select at least one item, or use Publish All / Discard.');
      return;
    }
    publishChronicle({ mode: 'items', items });
  });
  if (all) all.addEventListener('click', () => publishChronicle({ mode: 'all' }));
  if (dis) dis.addEventListener('click', () => {
    if (confirm('Discard all pending items without publishing?')) {
      publishChronicle({ mode: 'discard' });
    }
  });
}

function showChroniclePublishOutput(text) {
  const out = document.getElementById('chronicle-publish-output');
  if (out) {
    out.hidden = false;
    out.textContent = stripANSI(text);
  }
}

async function publishChronicle(op) {
  showChroniclePublishOutput('Publishing…');
  try {
    const result = await postJSON('/api/chronicle-publish', op);
    showChroniclePublishOutput(result.output || ('Exit code ' + result.exitCode));
    await loadChroniclePending();
    await loadSnapshot(); // refresh oculus-configs data so the new proposal commit shows
  } catch (err) {
    showChroniclePublishOutput(err.message);
  }
}

async function runChronicle() {
  const runBtn = document.getElementById('chronicle-run-btn');
  const state = document.getElementById('chronicle-run-state');
  const log = document.getElementById('chronicle-run-log');
  if (!log) return;
  log.hidden = false;
  log.textContent = 'Starting run…\n';
  if (runBtn) runBtn.disabled = true;
  if (state) state.textContent = 'running…';
  // Pause the snapshot poll so it doesn't re-render the section mid-run.
  stopSnapshotPolling();

  let start;
  try {
    start = await postJSON('/api/chronicle-run', {});
  } catch (err) {
    log.textContent = 'Failed to start run: ' + err.message;
    finishChronicleRun(runBtn, state, false);
    return;
  }
  if (start.exitCode !== 0) {
    log.textContent = stripANSI(start.output || 'Failed to start run.');
    finishChronicleRun(runBtn, state, false);
    return;
  }

  let notRunningCount = 0;
  const poll = setInterval(async () => {
    try {
      const resp = await fetch('/api/chronicle-run-log', { credentials: 'include' });
      if (!resp.ok) throw new Error('HTTP ' + resp.status);
      const data = await resp.json();
      if (log.isConnected) log.textContent = stripANSI(data.log || '(no output yet)\n');
      if (data.running) {
        notRunningCount = 0;
        return;
      }
      // Two consecutive not-running polls == run finished (matches self-update).
      notRunningCount += 1;
      if (notRunningCount >= 2) {
        clearInterval(poll);
        finishChronicleRun(runBtn, state, true);
        loadChroniclePending();
      }
    } catch (err) {
      clearInterval(poll);
      if (log.isConnected) log.textContent += '\n[poll error: ' + err.message + ']';
      finishChronicleRun(runBtn, state, false);
    }
  }, 2000);
}

function finishChronicleRun(runBtn, state, ok) {
  if (runBtn) runBtn.disabled = false;
  if (state) state.textContent = ok ? 'done' : '';
  startSnapshotPolling();
}
```

- [ ] **Step 5: Wire the section into `bindSectionActions`**

In `web/app.js`, add a case inside `bindSectionActions(section)`:

```js
  if (section === 'chronicle') {
    bindChronicle();
  }
```

- [ ] **Step 6: Add checklist styling**

Append to `web/styles.css` (uses the existing theme tokens `--muted`, `--border`):

```css
.chronicle-item-list {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin: 10px 0;
}
.chronicle-item {
  display: grid;
  grid-template-columns: auto 1fr auto;
  gap: 10px;
  align-items: baseline;
  padding: 6px 8px;
  border: 1px solid var(--border);
  border-radius: 6px;
}
.chronicle-item-target {
  color: var(--muted);
  font-size: 0.85em;
}
.chronicle-pending-header {
  display: flex;
  gap: 10px;
  align-items: baseline;
  flex-wrap: wrap;
  margin-bottom: 8px;
}
```

- [ ] **Step 7: Build and run the Go suite (web is embedded/served by CCC)**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go build ./... && go test ./...`
Expected: build succeeds; all tests `ok`.

- [ ] **Step 8: Manual smoke test**

With a live Chronicle checkout under `<projects-root>/Chronicle`, load the CCC UI, open **Claude Chronicle** in the Settings nav, confirm: (a) pending list loads on entry; (b) **Run Chronicle** streams the log and, on completion, refreshes the checklist; (c) **Publish Selected/All** shows CLI output and **Discard** clears the list. If no Chronicle checkout is present, confirm the page shows the "Chronicle not found" run output rather than crashing.

- [ ] **Step 9: Commit**

```bash
cd /srv/ccc/projects/CCC/container-code-companion
git add web/index.html web/app.js web/styles.css
git commit -m "$(cat <<'EOF'
feat: add Claude Chronicle dashboard section

Nav button + section that runs chronicle with a live polled log, renders the
synthesized item checklist, and publishes a selection / all / discard,
refreshing the oculus-configs snapshot on success.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Deferred (documented, not built)

Per the spec's Scope: a **provider dropdown** and **`--limit` field** wired through to `chronicle run`. This is purely additive — two form controls in `renderChronicle`, read in `runChronicle`, passed to `POST /api/chronicle-run`, and appended to the run argv in `StartChronicleRun` (whose arg list Task 3 keeps deliberately simple). No Core code needs to anticipate it beyond that.

## Self-Review

**Spec coverage:**
- Goal / two-stage flow → Tasks 1–5. ✅
- Locating Chronicle (derive from `sharedProjectsRoot`, path table) → Task 1 path helpers + Global Constraints. ✅
- Flow: Run detached → Task 3; Poll → Task 5 poll loop + Task 4 run-log; Review checklist → Task 5; Publish/Discard → Tasks 2, 4, 5. ✅
- Backend signatures (`ChroniclePendingItem`, `ChroniclePending`, `StartChronicleRun`, `ChronicleRunStatus`, `ReadChroniclePending`, `PublishChronicle`, `ChroniclePublishOperation`) → verbatim in Tasks 1–3. ✅
- Argv built server-side, no shell interpolation of client text; validation before exec → Task 2 (`buildPublishArgs` + tests). ✅
- Four endpoints behind `requireSession`, wired via Config DI → Task 4. ✅
- Frontend: nav in Settings, `renderChronicle` in renderers + title, `bindSectionActions` case, poll loop, fetch pending on entry → Task 5. ✅
- Error handling: missing binary (run + publish), empty synthesis (`Available:false`), corrupt JSON (error), publish push failure (result surfaced) → Tasks 1–5 + tests. ✅
- Testing: `ReadChroniclePending` temp-file cases, `PublishChronicle` argv/validation, handler stubs, `go test ./...` green → Tasks 1, 2, 4. ✅
- Deferred provider/limit documented → "Deferred" section + Task 3 note. ✅

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"add validation" left as prose — every code step carries complete code. Three implementer notes point at existing code to cross-verify names (`CommandResult` fields, `StartSelfUpdate` idiom, `writeJSON`/`titles`/`bindSectionActions` shapes); these are verification instructions, not placeholders.

**Type consistency:** `ChroniclePending`/`ChroniclePendingItem`/`ChroniclePublishOperation`/`CommandResult` used identically across Tasks 1–4. Path helpers (`chronicleDir`, `chronicleBinary`, `chroniclePendingPath`, `chronicleRunLogPath`) defined in Task 1, reused in 2–3. Config funcs `ChronicleRun`/`ChronicleRunStatus`/`ChroniclePending`/`ChroniclePublish` match between `newTestServer` stubs (Task 4 Step 1) and the struct/wiring (Task 4 Step 3). Frontend `loadChroniclePending`/`renderChroniclePendingList`/`publishChronicle`/`runChronicle`/`finishChronicleRun`/`bindChronicle` names consistent across Task 5. ✅
