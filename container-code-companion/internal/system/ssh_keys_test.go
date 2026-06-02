package system

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestProjectKeysRootDefaultsToEtcCCC(t *testing.T) {
	t.Setenv("CCC_PROJECT_KEYS_ROOT", "")
	if got := projectKeysRoot(); got != "/etc/ccc/project-keys" {
		t.Fatalf("projectKeysRoot() = %q, want /etc/ccc/project-keys", got)
	}
}

func TestProjectKeysRootReadsEnvVar(t *testing.T) {
	t.Setenv("CCC_PROJECT_KEYS_ROOT", "/tmp/test-keys")
	if got := projectKeysRoot(); got != "/tmp/test-keys" {
		t.Fatalf("projectKeysRoot() = %q, want /tmp/test-keys", got)
	}
}

func TestIsAllowedKeyPath_AcceptsHomeSSH(t *testing.T) {
	paths := []string{
		"/home/prime/.ssh/id_ed25519",
		"/home/work-id/.ssh/main",
		"/root/.ssh/id_rsa",
	}
	for _, p := range paths {
		if !isAllowedKeyPath(p) {
			t.Errorf("isAllowedKeyPath(%q) = false, want true", p)
		}
	}
}

func TestIsAllowedKeyPath_RejectsTraversalAndSystemPaths(t *testing.T) {
	paths := []string{
		"/home/prime/.ssh/../../../etc/passwd",
		"/etc/ssh/ssh_host_rsa_key",
		"/tmp/id_ed25519",
		"/home/prime/.ssh/../../root/.ssh/id_ed25519",
	}
	for _, p := range paths {
		if isAllowedKeyPath(p) {
			t.Errorf("isAllowedKeyPath(%q) = true, want false", p)
		}
	}
}

func TestIsAllowedKeyPath_AcceptsProjectKeysDir(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CCC_PROJECT_KEYS_ROOT", root)
	path := filepath.Join(root, "my-project", "id_ed25519")
	if !isAllowedKeyPath(path) {
		t.Fatalf("isAllowedKeyPath(%q) = false, want true", path)
	}
}

func TestGetProjectSSHConfig_ReturnsEmptyWhenNoKey(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CCC_PROJECT_KEYS_ROOT", root)

	cfg, err := GetProjectSSHConfig("nonexistent")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.KeyExists {
		t.Fatal("expected KeyExists=false for missing project")
	}
	if cfg.TestHost != "" {
		t.Fatalf("expected empty TestHost, got %q", cfg.TestHost)
	}
}

func TestSaveProjectTestHost_PersistsAndReads(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CCC_PROJECT_KEYS_ROOT", root)

	if err := SaveProjectTestHost("myproject", "192.168.1.50"); err != nil {
		t.Fatalf("SaveProjectTestHost: %v", err)
	}

	cfg, err := GetProjectSSHConfig("myproject")
	if err != nil {
		t.Fatalf("GetProjectSSHConfig: %v", err)
	}
	if cfg.TestHost != "192.168.1.50" {
		t.Fatalf("TestHost = %q, want 192.168.1.50", cfg.TestHost)
	}
}

func TestSaveProjectTestHost_RejectsEmptyName(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CCC_PROJECT_KEYS_ROOT", root)

	if err := SaveProjectTestHost("", "192.168.1.50"); err == nil {
		t.Fatal("expected error for empty project name")
	}
}

func TestGenerateProjectKey_CreatesKeyPair(t *testing.T) {
	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		t.Skip("ssh-keygen not available")
	}
	root := t.TempDir()
	t.Setenv("CCC_PROJECT_KEYS_ROOT", root)

	cfg, err := GenerateProjectKey("testproject")
	if err != nil {
		t.Fatalf("GenerateProjectKey: %v", err)
	}
	if !cfg.KeyExists {
		t.Fatal("expected KeyExists=true after generation")
	}
	privPath := filepath.Join(root, "testproject", "id_ed25519")
	pubPath := privPath + ".pub"
	if _, err := os.Stat(privPath); err != nil {
		t.Fatalf("private key not created: %v", err)
	}
	if _, err := os.Stat(pubPath); err != nil {
		t.Fatalf("public key not created: %v", err)
	}
	info, _ := os.Stat(privPath)
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("private key perm = %o, want 0600", info.Mode().Perm())
	}
	if cfg.PublicKey == "" {
		t.Fatal("expected non-empty PublicKey")
	}
}

func TestGenerateProjectKey_ErrorsIfKeyAlreadyExists(t *testing.T) {
	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		t.Skip("ssh-keygen not available")
	}
	root := t.TempDir()
	t.Setenv("CCC_PROJECT_KEYS_ROOT", root)

	if _, err := GenerateProjectKey("dup"); err != nil {
		t.Fatalf("first generate: %v", err)
	}
	if _, err := GenerateProjectKey("dup"); err == nil {
		t.Fatal("expected error when key already exists")
	}
}

func TestDeleteSSHKey_ValidPath_DeletesBothFiles(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CCC_PROJECT_KEYS_ROOT", root)

	// Create a fake key pair
	dir := filepath.Join(root, "someproject")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		t.Fatal(err)
	}
	privPath := filepath.Join(dir, "id_ed25519")
	pubPath := privPath + ".pub"
	if err := os.WriteFile(privPath, []byte("fake private"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pubPath, []byte("fake public"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := DeleteSSHKey(privPath); err != nil {
		t.Fatalf("DeleteSSHKey: %v", err)
	}
	if _, err := os.Stat(privPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("private key still exists after delete")
	}
	if _, err := os.Stat(pubPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("public key still exists after delete")
	}
}

func TestDeleteSSHKey_InvalidPath_Rejected(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CCC_PROJECT_KEYS_ROOT", root)

	if err := DeleteSSHKey("/etc/passwd"); err == nil {
		t.Fatal("expected error for disallowed path")
	}
	if err := DeleteSSHKey("/tmp/id_ed25519"); err == nil {
		t.Fatal("expected error for /tmp path")
	}
}

func TestListAllSSHKeys_ReturnsFilesFromConfiguredDirs(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CCC_PROJECT_KEYS_ROOT", root)

	// Create a fake project key
	dir := filepath.Join(root, "proj1")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		t.Fatal(err)
	}
	pubPath := filepath.Join(dir, "id_ed25519.pub")
	if err := os.WriteFile(pubPath, []byte("fake pub"), 0o644); err != nil {
		t.Fatal(err)
	}

	keys := ListAllSSHKeys()
	var found bool
	for _, k := range keys {
		if k.Path == pubPath {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected %q in ListAllSSHKeys result, got: %v", pubPath, keys)
	}
}

func TestCollectProjectsIncludesSSHFields(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CCC_PROJECT_KEYS_ROOT", root)

	// Save a test host for a project named "CCC" (matches the test project dir)
	if err := SaveProjectTestHost("CCC", "10.0.0.1"); err != nil {
		t.Fatalf("SaveProjectTestHost: %v", err)
	}

	cfg, err := GetProjectSSHConfig("CCC")
	if err != nil {
		t.Fatalf("GetProjectSSHConfig: %v", err)
	}
	if cfg.TestHost != "10.0.0.1" {
		t.Fatalf("TestHost = %q, want 10.0.0.1", cfg.TestHost)
	}
}

func TestWriteProjectDeploymentConfigs_CreatesBlock(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CCC_PROJECT_KEYS_ROOT", root)

	// Create a minimal CLAUDE.md
	claudeMD := filepath.Join(root, "CLAUDE.md")
	if err := os.WriteFile(claudeMD, []byte("# My Project\n\nExisting content.\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err := WriteProjectDeploymentConfigs("myproject", "192.168.1.10", []string{claudeMD})
	if err != nil {
		t.Fatalf("WriteProjectDeploymentConfigs: %v", err)
	}

	data, _ := os.ReadFile(claudeMD)
	content := string(data)
	if !strings.Contains(content, "<!-- CCC:DEPLOYMENT:START -->") {
		t.Fatal("expected deployment start marker in output")
	}
	if !strings.Contains(content, "192.168.1.10") {
		t.Fatal("expected test host in output")
	}
	if !strings.Contains(content, "Existing content.") {
		t.Fatal("existing content was erased")
	}
}

func TestWriteProjectDeploymentConfigs_ReplacesExistingBlock(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CCC_PROJECT_KEYS_ROOT", root)

	claudeMD := filepath.Join(root, "CLAUDE.md")
	initial := "# Project\n\n<!-- CCC:DEPLOYMENT:START -->\nold block\n<!-- CCC:DEPLOYMENT:END -->\n"
	if err := os.WriteFile(claudeMD, []byte(initial), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := WriteProjectDeploymentConfigs("myproject", "10.0.0.5", []string{claudeMD}); err != nil {
		t.Fatalf("WriteProjectDeploymentConfigs: %v", err)
	}

	data, _ := os.ReadFile(claudeMD)
	content := string(data)
	if strings.Contains(content, "old block") {
		t.Fatal("old block was not replaced")
	}
	if !strings.Contains(content, "10.0.0.5") {
		t.Fatal("new host not in output")
	}
	// Should only have one deployment block
	if strings.Count(content, "<!-- CCC:DEPLOYMENT:START -->") != 1 {
		t.Fatal("expected exactly one deployment block")
	}
}
