package system

import (
	"os"
	"path/filepath"
	"strings"
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

func TestBuildPublishArgs(t *testing.T) {
	cases := []struct {
		name      string
		op        ChroniclePublishOperation
		itemCount int
		want      []string
		wantErr   bool
	}{
		{"all", ChroniclePublishOperation{Mode: "all"}, 0, []string{"publish", "--all"}, false},
		{"discard", ChroniclePublishOperation{Mode: "discard"}, 0, []string{"publish", "--discard"}, false},
		{"items", ChroniclePublishOperation{Mode: "items", Items: []int{1, 3}}, 3, []string{"publish", "--items", "1,3"}, false},
		{"items empty", ChroniclePublishOperation{Mode: "items"}, 3, nil, true},
		{"items zero index", ChroniclePublishOperation{Mode: "items", Items: []int{0}}, 3, nil, true},
		{"items negative", ChroniclePublishOperation{Mode: "items", Items: []int{-2}}, 3, nil, true},
		{"items above count", ChroniclePublishOperation{Mode: "items", Items: []int{4}}, 3, nil, true},
		{"items with no pending", ChroniclePublishOperation{Mode: "items", Items: []int{1}}, 0, nil, true},
		{"bad mode", ChroniclePublishOperation{Mode: "nuke"}, 0, nil, true},
		{"empty mode", ChroniclePublishOperation{}, 0, nil, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := buildPublishArgs(tc.op, tc.itemCount)
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

func TestChronicleRunArgs(t *testing.T) {
	cases := []struct {
		name           string
		extract, synth string
		want           []string
		wantErr        bool
	}{
		{"both default", "", "", []string{"run"}, false},
		{"extract only", "claude-opus-4-8", "",
			[]string{"run", "--extract-model", "claude-opus-4-8"}, false},
		{"synth only", "", "claude-sonnet-5",
			[]string{"run", "--synthesize-model", "claude-sonnet-5"}, false},
		{"both set", "claude-haiku-4-5", "claude-sonnet-5",
			[]string{"run", "--extract-model", "claude-haiku-4-5",
				"--synthesize-model", "claude-sonnet-5"}, false},
		{"off-list extract", "gpt-4", "", nil, true},
		{"off-list synth", "", "sonnet", nil, true},
		{"metacharacter injection", "claude-sonnet-5; rm -rf /", "", nil, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := chronicleRunArgs(tc.extract, tc.synth)
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

// writePendingItems plants a pending file with n minimal items so publish
// index bounds can be exercised.
func writePendingItems(t *testing.T, dataDir string, n int) {
	t.Helper()
	items := make([]string, n)
	for i := range items {
		items[i] = `{"rule":"r","why":"w","citations":[],"target_file":"claude/CLAUDE.md","placement":"append"}`
	}
	json := `{"synthesized_at":"2026-07-06T12:00:00+00:00","session_count":1,"items":[` +
		strings.Join(items, ",") + `]}`
	if err := os.WriteFile(filepath.Join(dataDir, "pending-items.json"), []byte(json), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestPublishChronicleRunsFakeBinary(t *testing.T) {
	dataDir := withChronicleRoot(t)
	writePendingItems(t, dataDir, 4)
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

func TestPublishChronicleOutOfRangeRejectedBeforeExec(t *testing.T) {
	// Only two items pending, but the request asks for index 3.
	dataDir := withChronicleRoot(t)
	writePendingItems(t, dataDir, 2)
	binDir := filepath.Join(filepath.Dir(dataDir), ".venv", "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Binary would fail loudly if the out-of-range index ever reached it.
	script := "#!/bin/sh\necho SHOULD_NOT_RUN >&2\nexit 1\n"
	if err := os.WriteFile(filepath.Join(binDir, "chronicle"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	res, err := PublishChronicle(ChroniclePublishOperation{Mode: "items", Items: []int{3}})
	if err == nil {
		t.Fatal("expected out-of-range validation error before exec")
	}
	if strings.Contains(res.Output, "SHOULD_NOT_RUN") {
		t.Fatalf("binary ran despite out-of-range index: %q", res.Output)
	}
}

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
