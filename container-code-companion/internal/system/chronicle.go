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
