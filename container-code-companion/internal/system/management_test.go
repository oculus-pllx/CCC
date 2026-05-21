package system

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRunProjectOperationAddsExistingDirectoryAsProjectLink(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	existing := filepath.Join(home, "work", "existing-project")
	if err := os.MkdirAll(existing, 0o755); err != nil {
		t.Fatalf("create existing project: %v", err)
	}
	if err := os.WriteFile(filepath.Join(existing, "README.md"), []byte("keep me"), 0o644); err != nil {
		t.Fatalf("write existing file: %v", err)
	}

	result, err := RunProjectOperation(ProjectOperation{
		Operation: "add-existing",
		Name:      "linked-project",
		Path:      existing,
	})
	if err != nil {
		t.Fatalf("add existing project: %v", err)
	}
	if result.Output != "added linked-project" {
		t.Fatalf("unexpected output: %#v", result)
	}

	link := filepath.Join(home, "projects", "linked-project")
	target, err := os.Readlink(link)
	if err != nil {
		t.Fatalf("expected project symlink: %v", err)
	}
	if target != existing {
		t.Fatalf("expected link to %q, got %q", existing, target)
	}

	projects := collectProjects(filepath.Join(home, "projects"))
	if len(projects) != 1 || projects[0].Name != "linked-project" || projects[0].Path != link {
		t.Fatalf("expected linked project to be listed, got %#v", projects)
	}

	if _, err := RunProjectOperation(ProjectOperation{Operation: "delete", Name: "linked-project"}); err != nil {
		t.Fatalf("delete linked project: %v", err)
	}
	if _, err := os.Stat(filepath.Join(existing, "README.md")); err != nil {
		t.Fatalf("expected original directory to remain after project link delete: %v", err)
	}
}

func TestRunProjectOperationRejectsExistingProjectFilePath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	existingFile := filepath.Join(home, "work", "not-a-dir.txt")
	if err := os.MkdirAll(filepath.Dir(existingFile), 0o755); err != nil {
		t.Fatalf("create work dir: %v", err)
	}
	if err := os.WriteFile(existingFile, []byte("nope"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}

	_, err := RunProjectOperation(ProjectOperation{
		Operation: "add-existing",
		Name:      "not-a-dir",
		Path:      existingFile,
	})
	if err == nil {
		t.Fatal("expected file path to be rejected")
	}
}

func TestRunFileOperationCopiesAndChangesMode(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source.txt")
	target := filepath.Join(root, "target.txt")
	if err := os.WriteFile(source, []byte("copy me"), 0o644); err != nil {
		t.Fatalf("write source: %v", err)
	}

	if _, err := RunFileOperation(FileOperation{Operation: "copy", Path: source, Target: target}); err != nil {
		t.Fatalf("copy file: %v", err)
	}
	content, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("read target: %v", err)
	}
	if string(content) != "copy me" {
		t.Fatalf("expected copied content, got %q", string(content))
	}

	if _, err := RunFileOperation(FileOperation{Operation: "chmod", Path: target, Mode: "600"}); err != nil {
		t.Fatalf("chmod file: %v", err)
	}
	info, err := os.Stat(target)
	if err != nil {
		t.Fatalf("stat target: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("expected mode 0600, got %v", info.Mode().Perm())
	}
}

func TestRunToolOperationBuildsAllowlistedInstallCommands(t *testing.T) {
	for _, tool := range []string{"nodejs", "go", "playwright", "codex", "gh", "bubblewrap"} {
		command, err := toolInstallCommand(tool)
		if err != nil {
			t.Fatalf("expected %s install operation to be allowed: %v", tool, err)
		}
		if command == "" {
			t.Fatalf("expected %s install command", tool)
		}
	}
	if _, err := toolInstallCommand("unknown"); err == nil {
		t.Fatal("expected unknown tool to be rejected")
	}
}

func TestRunDriveOperationRejectsUnsafeMountRequests(t *testing.T) {
	_, err := RunDriveOperation(DriveOperation{
		Operation:  "mount-cifs",
		Name:       "../bad",
		Remote:     "//server/share",
		MountPoint: "/mnt/bad",
	})
	if err == nil {
		t.Fatal("expected unsafe drive name to be rejected")
	}
}
