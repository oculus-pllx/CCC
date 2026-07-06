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
