package system

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
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

// ChroniclePublishOperation selects what chronicle publish acts on.
type ChroniclePublishOperation struct {
	Mode  string `json:"mode"`  // "items" | "all" | "discard"
	Items []int  `json:"items"` // 1-based indices, required when Mode=="items"
}

// chronicleModelAllowlist is the exact set of model values the dashboard may
// pass to `chronicle run`. It is the primary guard on the one piece of
// browser-supplied input that reaches a shell command (shellQuote is the
// backstop). Empty string is not in the set: it means "Default" (flag omitted).
var chronicleModelAllowlist = map[string]bool{
	"claude-sonnet-5":  true,
	"claude-fable-5":   true,
	"claude-opus-4-8":  true,
	"claude-haiku-4-5": true,
}

// chronicleRunArgs builds the `chronicle run` argument list, appending
// --extract-model/--synthesize-model only for a non-empty, allowlisted model.
// An empty model means Default: Chronicle applies its own per-provider default.
func chronicleRunArgs(extractModel, synthesizeModel string) ([]string, error) {
	args := []string{"run"}
	for _, m := range []struct{ flag, value string }{
		{"--extract-model", extractModel},
		{"--synthesize-model", synthesizeModel},
	} {
		if m.value == "" {
			continue
		}
		if !chronicleModelAllowlist[m.value] {
			return nil, fmt.Errorf("model %q is not an allowed Chronicle model", m.value)
		}
		args = append(args, m.flag, m.value)
	}
	return args, nil
}

// buildPublishArgs turns a validated operation into a chronicle argv. It never
// embeds client text into a shell string; the CLI receives discrete args.
// itemCount is the number of pending items and bounds "items" indices; every
// index must satisfy 1 <= n <= itemCount, so an out-of-range selection is
// rejected here rather than reaching the CLI.
func buildPublishArgs(op ChroniclePublishOperation, itemCount int) ([]string, error) {
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
			if n > itemCount {
				return nil, fmt.Errorf("invalid item index %d; only %d item(s) pending", n, itemCount)
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
	// "items" indices are bounded by the current pending set, so read it to
	// reject an out-of-range selection before exec. Other modes don't need it.
	itemCount := 0
	if op.Mode == "items" {
		pending, perr := ReadChroniclePending()
		if perr != nil {
			return CommandResult{}, perr
		}
		itemCount = len(pending.Items)
	}
	args, err := buildPublishArgs(op, itemCount)
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

// StartChronicleRun launches `chronicle run` as a detached background process
// that appends stdout+stderr to the run log and returns immediately. This
// mirrors StartSelfUpdate and is required because chronicle run makes LLM calls
// that exceed CCC's 45s synchronous-command timeout. The arg list is kept
// simple so a later provider/limit change can extend it.
func StartChronicleRun(extractModel, synthesizeModel string) (CommandResult, error) {
	bin := chronicleBinary()
	if _, err := os.Stat(bin); err != nil {
		return CommandResult{
			Command:  "chronicle run",
			Output:   fmt.Sprintf("Chronicle not found at %s", bin),
			ExitCode: 1,
		}, fmt.Errorf("Chronicle not found at %s", bin)
	}

	runArgs, err := chronicleRunArgs(extractModel, synthesizeModel)
	if err != nil {
		return CommandResult{
			Command:  "chronicle run",
			Output:   err.Error(),
			ExitCode: 1,
		}, err
	}
	quoted := make([]string, len(runArgs))
	for i, a := range runArgs {
		quoted[i] = shellQuote(a)
	}
	runInvocation := shellQuote(bin) + " " + strings.Join(quoted, " ")

	logPath := chronicleRunLogPath()
	dataDir := filepath.Dir(logPath)
	// setsid + no inherited pipes so the run survives the HTTP response; a
	// fresh log per run (truncate) starts each readout clean. Braces matter
	// here for the same reason as StartSelfUpdate: a bare trailing "&" would
	// background the entire && chain in a subshell that still holds this
	// process's stderr pipe, blocking cmd.Wait() until the run itself exits.
	command := "mkdir -p " + shellQuote(dataDir) +
		" && printf 'chronicle run started at %s\\n' \"$(date -Is)\" > " + shellQuote(logPath) +
		" && { setsid env NO_COLOR=1 " + runInvocation + " >> " + shellQuote(logPath) +
		" 2>&1 < /dev/null & }"

	// Use Start+Wait instead of Output/Run so that no stdout/stderr pipe is
	// inherited by the setsid child process. If Output() is used, the child
	// inherits bash's stderr pipe and cmd.Output() blocks until chronicle run
	// exits (minutes), causing the HTTP response to never be sent.
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
