package system

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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

func TestProjectNameFromGitRemoteSupportsSSHAndHTTPS(t *testing.T) {
	for _, tc := range []struct {
		remote string
		want   string
	}{
		{remote: "https://github.com/oculus-pllx/CCC.git", want: "CCC"},
		{remote: "ssh://git@git.example.test/team/app.git", want: "app"},
		{remote: "git@github.com:oculus-pllx/ccc-ui.git", want: "ccc-ui"},
	} {
		if got, err := projectNameFromGitRemote(tc.remote); err != nil || got != tc.want {
			t.Fatalf("projectNameFromGitRemote(%q) = %q, %v; want %q", tc.remote, got, err, tc.want)
		}
	}
}

func TestValidateGitRemoteRejectsCredentialedAndShellRemotes(t *testing.T) {
	for _, remote := range []string{
		"https://token@github.com/owner/repo.git",
		"https://user:secret@git.example.test/owner/repo.git",
		"git@github.com:owner/repo.git && rm -rf /",
		"file:///tmp/repo",
	} {
		if _, err := validateGitRemote(remote); err == nil {
			t.Fatalf("expected remote %q to be rejected", remote)
		}
	}
}

func TestRunProjectOperationRejectsCloneTargetCollision(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	target := filepath.Join(home, "projects", "CCC")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create existing target: %v", err)
	}
	_, err := RunProjectOperation(ProjectOperation{
		Operation: "clone",
		Remote:    "https://github.com/oculus-pllx/CCC.git",
	})
	if err == nil || !strings.Contains(err.Error(), "project already exists") {
		t.Fatalf("expected clone target collision, got %v", err)
	}
}

func TestRunProjectOperationRejectsPullForNonGitProject(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.MkdirAll(filepath.Join(home, "projects", "plain"), 0o755); err != nil {
		t.Fatalf("create plain project: %v", err)
	}
	if _, err := RunProjectOperation(ProjectOperation{Operation: "pull", Name: "plain"}); err == nil {
		t.Fatal("expected non-Git project pull to fail")
	}
}

func TestRunProjectOperationPullsFastForwardGitProject(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	project := filepath.Join(home, "projects", "demo")
	if err := os.MkdirAll(project, 0o755); err != nil {
		t.Fatalf("create project: %v", err)
	}
	runGitTestCommand(t, project, "init")
	result, _ := RunProjectOperation(ProjectOperation{Operation: "pull", Name: "demo"})
	if !strings.Contains(result.Command, "git pull --ff-only") {
		t.Fatalf("expected fast-forward pull command, got %#v", result)
	}
}

func TestCollectProjectsMarksGitProjects(t *testing.T) {
	home := t.TempDir()
	project := filepath.Join(home, "projects", "demo")
	if err := os.MkdirAll(project, 0o755); err != nil {
		t.Fatalf("create project: %v", err)
	}
	runGitTestCommand(t, project, "init")
	projects := collectProjects(filepath.Join(home, "projects"))
	if len(projects) != 1 || !projects[0].GitRepo {
		t.Fatalf("expected Git project metadata, got %#v", projects)
	}
}

func runGitTestCommand(t *testing.T, cwd string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = cwd
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, output)
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
	for _, tool := range []string{"nodejs", "go", "python", "uv", "playwright", "codex", "claude", "gemini", "gh", "bubblewrap", "ripgrep", "jq", "fzf", "build-essential", "aider"} {
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

func TestProviderNPMToolsInstallToUserPrefix(t *testing.T) {
	for _, tool := range []string{"claude", "gemini"} {
		command, err := toolInstallCommand(tool)
		if err != nil {
			t.Fatalf("expected %s install command: %v", tool, err)
		}
		if !strings.Contains(command, `--prefix "$HOME/.local"`) {
			t.Fatalf("expected %s to install under user npm prefix, got %q", tool, command)
		}
	}
}

func TestToolUpdateAvailableIgnoresNeutralStatuses(t *testing.T) {
	for _, status := range []string{"", "No update detected.", "No automatic update check.", "Manual check: compare with latest release."} {
		if toolUpdateAvailable(status) {
			t.Fatalf("expected neutral status %q to not mark an update available", status)
		}
	}
	if !toolUpdateAvailable("jq/stable 1.7.1 amd64 [upgradable from: 1.6]") {
		t.Fatal("expected package-manager output to mark an update available")
	}
}

func TestAptUpdateCheckTargetsPackage(t *testing.T) {
	command := aptUpdateCheck("jq")
	if !strings.Contains(command, "apt list --upgradable 'jq'") {
		t.Fatalf("expected apt update check to target package, got %q", command)
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

func TestExplainDriveMountFailureAddsLXCContext(t *testing.T) {
	output := explainDriveMountFailure("mount: /mnt/share: permission denied.", "proxmox-lxc")
	if !strings.Contains(output, "LXC mount note") || !strings.Contains(output, "Proxmox host") {
		t.Fatalf("expected LXC guidance, got %q", output)
	}
}

func TestExplainDriveMountFailureAddsLinuxHostContext(t *testing.T) {
	output := explainDriveMountFailure("mount: /mnt/share: permission denied.", "linux-host")
	if strings.Contains(output, "Proxmox host") {
		t.Fatalf("did not expect Proxmox guidance, got %q", output)
	}
	if !strings.Contains(output, "Linux host mount note") {
		t.Fatalf("expected Linux host guidance, got %q", output)
	}
}
