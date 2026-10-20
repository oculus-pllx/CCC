package system

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const testGitHubKey = "/etc/ccc/ssh/github_ed25519"

// An account's ssh config with its own hosts and a stale GitHub block in the middle.
const existingSSHConfig = `Host eyeris-prism
  HostName 192.168.0.55
  User root
  IdentityFile /etc/ccc/project-keys/Eyeris/id_ed25519

Host github.com
  HostName github.com
  User git
  IdentityFile /home/prime/.ssh/old_key

Host nas
  HostName 192.168.0.80
`

func assertGitHubConfigMerged(t *testing.T, got string) {
	t.Helper()
	for _, want := range []string{
		"Host eyeris-prism\n  HostName 192.168.0.55\n  User root\n  IdentityFile /etc/ccc/project-keys/Eyeris/id_ed25519\n",
		"Host nas\n  HostName 192.168.0.80\n",
		"IdentityFile " + testGitHubKey,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("merged config missing %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "old_key") {
		t.Fatalf("stale GitHub block was kept:\n%s", got)
	}
	if n := strings.Count(got, "Host github.com"); n != 1 {
		t.Fatalf("want exactly one GitHub block, got %d:\n%s", n, got)
	}
	// ssh uses the first value it sees for each option, so the GitHub block goes first.
	if !strings.HasPrefix(got, "Host github.com\n") {
		t.Fatalf("GitHub block should lead the file:\n%s", got)
	}
}

func TestMergeGitHubSSHConfigKeepsOtherHosts(t *testing.T) {
	assertGitHubConfigMerged(t, mergeGitHubSSHConfig(existingSSHConfig, testGitHubKey))
}

func TestMergeGitHubSSHConfigOnEmptyFileIsJustTheGitHubBlock(t *testing.T) {
	if got := mergeGitHubSSHConfig("", testGitHubKey); got != githubSSHConfigBlock(testGitHubKey) {
		t.Fatalf("got %q", got)
	}
}

func TestMergeGitHubSSHConfigIsIdempotent(t *testing.T) {
	once := mergeGitHubSSHConfig(existingSSHConfig, testGitHubKey)
	if twice := mergeGitHubSSHConfig(once, testGitHubKey); twice != once {
		t.Fatalf("second merge changed the file:\n--- once\n%s\n--- twice\n%s", once, twice)
	}
}

// runWithFakeSudo runs a generated shell command with `sudo` replaced by a pass-through,
// so the command's real file handling is exercised without privileges.
func runWithFakeSudo(t *testing.T, command string) {
	t.Helper()
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "sudo"), []byte("#!/bin/sh\nexec \"$@\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("bash", "-c", command)
	cmd.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"))
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("command failed: %v\n%s", err, out)
	}
}

func TestGitHubSSHConfigWriteCommandKeepsOtherHosts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config")
	if err := os.WriteFile(path, []byte(existingSSHConfig), 0o600); err != nil {
		t.Fatal(err)
	}

	runWithFakeSudo(t, githubSSHConfigWriteCommand(path, testGitHubKey))
	runWithFakeSudo(t, githubSSHConfigWriteCommand(path, testGitHubKey))

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	assertGitHubConfigMerged(t, string(got))
	if string(got) != mergeGitHubSSHConfig(existingSSHConfig, testGitHubKey) {
		t.Fatalf("shell and Go merges disagree:\n%s", got)
	}
}

func TestGitHubSSHConfigWriteCommandCreatesMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config")

	runWithFakeSudo(t, githubSSHConfigWriteCommand(path, testGitHubKey))

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != githubSSHConfigBlock(testGitHubKey) {
		t.Fatalf("got %q", got)
	}
}

func TestSetupCCCProfileCommandMergesSSHConfigInsteadOfOverwriting(t *testing.T) {
	command := setupCCCProfileCommand("work-id")
	if !strings.Contains(command, githubSSHConfigWriteCommand("/home/work-id/.ssh/config", githubMachineKeyPath())) {
		t.Fatalf("setup command does not merge ~/.ssh/config:\n%s", command)
	}
}
