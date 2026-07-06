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
