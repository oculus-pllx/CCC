package system

import (
	"os"
	"os/exec"
	"path/filepath"
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
