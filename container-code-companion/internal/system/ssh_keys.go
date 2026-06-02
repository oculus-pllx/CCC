package system

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type SSHKeyEntry struct {
	Path        string `json:"path"`
	Owner       string `json:"owner"`
	KeyType     string `json:"keyType"`
	Fingerprint string `json:"fingerprint"`
	MTime       string `json:"mtime"`
	IsPublic    bool   `json:"isPublic"`
}

type ProjectSSHConfig struct {
	KeyExists   bool   `json:"keyExists"`
	PublicKey   string `json:"publicKey"`
	Fingerprint string `json:"fingerprint"`
	TestHost    string `json:"testHost"`
}

type SSHKeyOperation struct {
	Action      string `json:"action"`
	ProjectName string `json:"projectName,omitempty"`
	KeyPath     string `json:"keyPath,omitempty"`
	TestHost    string `json:"testHost,omitempty"`
	Password    string `json:"password,omitempty"`
}

func projectKeysRoot() string {
	if v := strings.TrimSpace(os.Getenv("CCC_PROJECT_KEYS_ROOT")); v != "" {
		return filepath.Clean(v)
	}
	return "/etc/ccc/project-keys"
}

// isAllowedKeyPath returns true only if path is within a user ~/.ssh dir,
// /root/.ssh, or the CCC project keys root. Prevents deletion of arbitrary files.
func isAllowedKeyPath(path string) bool {
	// Reject any path that contains traversal components before cleaning.
	if strings.Contains(path, "..") {
		return false
	}
	clean := filepath.Clean(path)
	keysRoot := projectKeysRoot()

	allowed := []string{"/home", "/root/.ssh", keysRoot}
	var inAllowed bool
	for _, root := range allowed {
		if strings.HasPrefix(clean, root+"/") || clean == root {
			inAllowed = true
			break
		}
	}
	if !inAllowed {
		return false
	}

	// For /home paths, structure must be /home/<user>/.ssh/<file>
	if strings.HasPrefix(clean, "/home/") {
		parts := strings.SplitN(strings.TrimPrefix(clean, "/home/"), "/", 4)
		if len(parts) < 3 || parts[1] != ".ssh" {
			return false
		}
		if strings.Contains(parts[2], "..") {
			return false
		}
	}

	return true
}

func projectKeyDir(projectName string) (string, error) {
	if projectName == "" {
		return "", errors.New("project name is required")
	}
	if strings.ContainsAny(projectName, "/\\.") {
		return "", fmt.Errorf("invalid project name: %q", projectName)
	}
	return filepath.Join(projectKeysRoot(), projectName), nil
}

// GetProjectSSHConfig returns the SSH key status and configured test host for a project.
func GetProjectSSHConfig(projectName string) (ProjectSSHConfig, error) {
	dir, err := projectKeyDir(projectName)
	if err != nil {
		return ProjectSSHConfig{}, err
	}

	cfg := ProjectSSHConfig{}

	hostFile := filepath.Join(dir, "host")
	if data, err := os.ReadFile(hostFile); err == nil {
		cfg.TestHost = strings.TrimSpace(string(data))
	}

	pubPath := filepath.Join(dir, "id_ed25519.pub")
	pubData, err := os.ReadFile(pubPath)
	if err != nil {
		return cfg, nil
	}
	cfg.KeyExists = true
	cfg.PublicKey = strings.TrimSpace(string(pubData))

	out, err := exec.Command("ssh-keygen", "-l", "-f", pubPath).Output()
	if err == nil {
		cfg.Fingerprint = strings.TrimSpace(string(out))
	}
	return cfg, nil
}

// SaveProjectTestHost persists the test machine hostname for a project.
func SaveProjectTestHost(projectName, host string) error {
	dir, err := projectKeyDir(projectName)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return fmt.Errorf("create project key dir: %w", err)
	}
	return os.WriteFile(filepath.Join(dir, "host"), []byte(host+"\n"), 0o644)
}

// GenerateProjectKey creates an ed25519 key pair for a project.
// Returns an error if the key already exists — delete first.
func GenerateProjectKey(projectName string) (ProjectSSHConfig, error) {
	dir, err := projectKeyDir(projectName)
	if err != nil {
		return ProjectSSHConfig{}, err
	}
	privPath := filepath.Join(dir, "id_ed25519")
	if _, err := os.Stat(privPath); err == nil {
		return ProjectSSHConfig{}, fmt.Errorf("key already exists at %s; delete it first", privPath)
	}
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return ProjectSSHConfig{}, fmt.Errorf("create project key dir: %w", err)
	}
	comment := "ccc-project-" + projectName
	if out, err := exec.Command("ssh-keygen", "-t", "ed25519", "-f", privPath, "-N", "", "-C", comment).CombinedOutput(); err != nil {
		return ProjectSSHConfig{}, fmt.Errorf("ssh-keygen: %w: %s", err, out)
	}
	return GetProjectSSHConfig(projectName)
}
