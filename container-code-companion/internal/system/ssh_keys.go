package system

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
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

func cccProjectsRoot() string {
	if v := strings.TrimSpace(os.Getenv("CCC_PROJECTS_ROOT")); v != "" {
		return filepath.Clean(v)
	}
	return "/srv/ccc/projects"
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

// cccGroupGID returns the GID of the shared ccc group, or -1 if not found.
func cccGroupGID() int {
	groupName := strings.TrimSpace(os.Getenv("CCC_SHARED_GROUP"))
	if groupName == "" {
		groupName = "ccc"
	}
	g, err := user.LookupGroup(groupName)
	if err != nil {
		return -1
	}
	gid, _ := strconv.Atoi(g.Gid)
	return gid
}

// fixProjectKeyPerms ensures a project key directory and its files are
// accessible to any member of the ccc group. Called after creation and
// at startup for existing dirs.
//
// Group-read (0640) is what lets every ccc member use the shared per-project
// key; modern OpenSSH accepts a 0640 key (verified on this platform). But a
// group-read mode an agent owns is one the agent can revert: a long-running
// session repeatedly chmod'd a project key back to 0600, breaking shared
// access. hardenProjectKeyOwnership makes the key root-owned so a non-root
// agent physically cannot revert it (chmod by a non-owner fails with EPERM).
func fixProjectKeyPerms(dir string) {
	gid := cccGroupGID()
	_ = os.Chmod(dir, 0o750)
	if gid >= 0 {
		_ = os.Lchown(dir, -1, gid)
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		p := filepath.Join(dir, e.Name())
		mode := os.FileMode(0o644)
		if e.Name() == "id_ed25519" {
			mode = 0o640
		}
		_ = os.Chmod(p, mode)
		if gid >= 0 {
			_ = os.Lchown(p, -1, gid)
		}
	}
	hardenProjectKeyOwnership(dir)
}

// hardenProjectKeyOwnership makes a project's private key root-owned so that a
// non-root agent cannot chmod it back to owner-only (which breaks shared ccc
// access). The CCC app user has passwordless sudo (granted by the provisioner),
// so the single privileged step is delegated to a small path-validating root
// helper installed by the provisioner. Best-effort: if the helper or sudo is
// unavailable (e.g. in tests, or a non-CCC host), the key stays group-readable
// at 0640 — still usable, just revertible.
func hardenProjectKeyOwnership(dir string) {
	// Only act against the real key root; tests override CCC_PROJECT_KEYS_ROOT.
	if projectKeysRoot() != "/etc/ccc/project-keys" {
		return
	}
	const helper = "/usr/local/bin/ccc-fix-key-perms"
	if _, err := os.Stat(helper); err != nil {
		return
	}
	_ = exec.Command("sudo", "-n", helper, filepath.Base(dir)).Run()
}

// FixAllProjectKeyPerms repairs permissions on every existing project key dir.
// Called at server startup so keys created before this fix are corrected.
func FixAllProjectKeyPerms() {
	root := projectKeysRoot()
	dirs, _ := os.ReadDir(root)
	for _, d := range dirs {
		if d.IsDir() {
			fixProjectKeyPerms(filepath.Join(root, d.Name()))
		}
	}
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
	fixProjectKeyPerms(dir)
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
	fixProjectKeyPerms(dir)
	return GetProjectSSHConfig(projectName)
}

const (
	deploymentStartMarker = "<!-- CCC:DEPLOYMENT:START -->"
	deploymentEndMarker   = "<!-- CCC:DEPLOYMENT:END -->"
)

// DeleteSSHKey deletes the key file at path. If the path ends without ".pub"
// and a matching ".pub" file exists, it is deleted too.
// Rejects paths outside the allowed dirs.
func DeleteSSHKey(path string) error {
	if !isAllowedKeyPath(path) {
		return fmt.Errorf("path not in an allowed directory: %s", path)
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("delete key: %w", err)
	}
	// Also delete the paired .pub file if this is a private key
	if !strings.HasSuffix(path, ".pub") {
		pubPath := path + ".pub"
		if err := os.Remove(pubPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("delete public key: %w", err)
		}
	}
	return nil
}

// ListAllSSHKeys scans all user ~/.ssh dirs and the CCC project keys root,
// returning one entry per key file found.
func ListAllSSHKeys() []SSHKeyEntry {
	var entries []SSHKeyEntry

	// Scan user home dirs
	homeEntries, _ := os.ReadDir("/home")
	for _, u := range homeEntries {
		if !u.IsDir() {
			continue
		}
		sshDir := filepath.Join("/home", u.Name(), ".ssh")
		entries = append(entries, scanSSHDir(sshDir, u.Name())...)
	}

	// Scan root's .ssh
	entries = append(entries, scanSSHDir("/root/.ssh", "root")...)

	// Scan project keys root
	keysRoot := projectKeysRoot()
	projDirs, _ := os.ReadDir(keysRoot)
	for _, p := range projDirs {
		if !p.IsDir() {
			continue
		}
		entries = append(entries, scanSSHDir(filepath.Join(keysRoot, p.Name()), p.Name())...)
	}

	return entries
}

func scanSSHDir(dir, owner string) []SSHKeyEntry {
	files, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var entries []SSHKeyEntry
	for _, f := range files {
		if f.IsDir() {
			continue
		}
		path := filepath.Join(dir, f.Name())
		entry := buildSSHKeyEntry(path, owner)
		if entry != nil {
			entries = append(entries, *entry)
		}
	}
	return entries
}

func buildSSHKeyEntry(path, owner string) *SSHKeyEntry {
	info, err := os.Stat(path)
	if err != nil {
		return nil
	}
	isPublic := strings.HasSuffix(path, ".pub")
	entry := SSHKeyEntry{
		Path:     path,
		Owner:    owner,
		IsPublic: isPublic,
		MTime:    info.ModTime().Format("2006-01-02"),
	}
	// Get fingerprint from public key (or try if it might be a private key without .pub)
	fingerprintFile := path
	if !isPublic {
		if _, err := os.Stat(path + ".pub"); err == nil {
			fingerprintFile = path + ".pub"
		}
	}
	out, err := exec.Command("ssh-keygen", "-l", "-f", fingerprintFile).Output()
	if err == nil {
		parts := strings.Fields(string(out))
		if len(parts) >= 2 {
			entry.Fingerprint = parts[1]
		}
		if len(parts) >= 4 {
			entry.KeyType = parts[len(parts)-1]
			entry.KeyType = strings.Trim(entry.KeyType, "()")
		}
	}
	return &entry
}

// WriteProjectDeploymentConfigs writes (or replaces) the CCC deployment block
// in the given config files. configPaths is a list of absolute paths to
// CLAUDE.md, AGENTS.md, GEMINI.md, etc.
func WriteProjectDeploymentConfigs(projectName, testHost string, configPaths []string) error {
	keyPath := filepath.Join(projectKeysRoot(), projectName, "id_ed25519")
	block := fmt.Sprintf(`%s
## CCC Deployment Target (machine-local, not in repo)

- **Test machine:** root@%s
- **SSH key:** %s
- **To deploy:** `+"`"+`ssh -i %s root@%s "<command>"`+"`"+`
- Development and GitHub pushes happen on **this machine only**.
- Do **not** push to GitHub from the test machine.
- Do **not** create new SSH keys.
- Do **not** `+"`chmod`"+` or `+"`chown`"+` this key. It is intentionally root-owned and
  group-readable (0640, group `+"`ccc`"+`) so every team member shares one key;
  "tightening" it to 0600 breaks access for others and will be reverted.
%s`, deploymentStartMarker, testHost, keyPath, keyPath, testHost, deploymentEndMarker)

	var errs []string
	for _, p := range configPaths {
		if err := replaceDeploymentBlock(p, block); err != nil {
			errs = append(errs, fmt.Sprintf("%s: %v", p, err))
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("deployment config errors: %s", strings.Join(errs, "; "))
	}
	return nil
}

func replaceDeploymentBlock(filePath, newBlock string) error {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("read: %w", err)
	}
	content := string(data)

	startIdx := strings.Index(content, deploymentStartMarker)
	endIdx := strings.Index(content, deploymentEndMarker)

	var newContent string
	if startIdx >= 0 && endIdx >= 0 && endIdx > startIdx {
		// Replace the existing block
		newContent = content[:startIdx] + newBlock + content[endIdx+len(deploymentEndMarker):]
	} else {
		// Append the block
		if !strings.HasSuffix(content, "\n") {
			content += "\n"
		}
		newContent = content + "\n" + newBlock + "\n"
	}

	return os.WriteFile(filePath, []byte(newContent), 0o644)
}

// DeployProjectKey uses sshpass + ssh-copy-id to push the project's public key
// to its configured test machine.
func DeployProjectKey(projectName, password string) (string, error) {
	cfg, err := GetProjectSSHConfig(projectName)
	if err != nil {
		return "", fmt.Errorf("get project config: %w", err)
	}
	if !cfg.KeyExists {
		return "", fmt.Errorf("no SSH key for project %q; generate one first", projectName)
	}
	if cfg.TestHost == "" {
		return "", fmt.Errorf("no test host configured for project %q", projectName)
	}

	if _, err := exec.LookPath("sshpass"); err != nil {
		return "", fmt.Errorf("sshpass required for key deployment; install with: apt install sshpass")
	}

	pubPath := filepath.Join(projectKeysRoot(), projectName, "id_ed25519.pub")
	out, err := exec.Command(
		"sshpass", "-p", password,
		"ssh-copy-id",
		"-i", pubPath,
		"-o", "StrictHostKeyChecking=accept-new",
		"root@"+cfg.TestHost,
	).CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("ssh-copy-id: %w: %s", err, out)
	}
	return string(out), nil
}

// RunSSHKeyOperation dispatches an SSHKeyOperation and returns the result.
func RunSSHKeyOperation(op SSHKeyOperation) (any, error) {
	switch op.Action {
	case "list-keys":
		return ListAllSSHKeys(), nil

	case "get-project-config":
		return GetProjectSSHConfig(op.ProjectName)

	case "save-test-host":
		if err := SaveProjectTestHost(op.ProjectName, op.TestHost); err != nil {
			return nil, err
		}
		warn := refreshDeploymentConfigs(op.ProjectName)
		result := map[string]any{"ok": true}
		if warn != nil {
			result["deploymentConfigWarning"] = warn.Error()
		}
		return result, nil

	case "generate-key":
		cfg, err := GenerateProjectKey(op.ProjectName)
		if err != nil {
			return nil, err
		}
		_ = refreshDeploymentConfigs(op.ProjectName) // best-effort; primary result is the key config
		return cfg, nil

	case "delete-key":
		if err := DeleteSSHKey(op.KeyPath); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true}, nil

	case "deploy-key":
		output, err := DeployProjectKey(op.ProjectName, op.Password)
		if err != nil {
			return map[string]any{"output": output, "error": err.Error()}, err
		}
		return map[string]any{"output": output}, nil

	default:
		return nil, fmt.Errorf("unknown action: %q", op.Action)
	}
}

// refreshDeploymentConfigs injects the deployment block into agent config files
// for a project. Called automatically after save-test-host and generate-key.
// Returns nil if the project has no test host configured or no config files found.
func refreshDeploymentConfigs(projectName string) error {
	cfg, err := GetProjectSSHConfig(projectName)
	if err != nil || cfg.TestHost == "" {
		return nil
	}

	projectDirCandidates := []string{
		filepath.Join(cccProjectsRoot(), projectName),
		filepath.Join("/home/prime/projects", projectName),
	}

	var configFiles []string
	for _, base := range projectDirCandidates {
		for _, name := range []string{"CLAUDE.md", "AGENTS.md", "GEMINI.md"} {
			p := filepath.Join(base, name)
			if _, err := os.Stat(p); err == nil {
				configFiles = append(configFiles, p)
			}
		}
	}

	// If no config files exist yet, create CLAUDE.md in the primary project dir.
	if len(configFiles) == 0 {
		primary := filepath.Join(cccProjectsRoot(), projectName)
		if info, err := os.Stat(primary); err == nil && info.IsDir() {
			claudeMD := filepath.Join(primary, "CLAUDE.md")
			if err := os.WriteFile(claudeMD, []byte(""), 0o644); err == nil {
				configFiles = append(configFiles, claudeMD)
			}
		}
	}

	if len(configFiles) == 0 {
		return nil
	}

	return WriteProjectDeploymentConfigs(projectName, cfg.TestHost, configFiles)
}
