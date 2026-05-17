package system

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type ManagementSnapshot struct {
	Overview      Overview          `json:"overview"`
	Services      []ServiceStatus   `json:"services"`
	Logs          []LogBlock        `json:"logs"`
	Network       NetworkStatus     `json:"network"`
	Accounts      []AccountStatus   `json:"accounts"`
	Files         []FileEntry       `json:"files"`
	Updates       UpdateStatus      `json:"updates"`
	Projects      []ProjectStatus   `json:"projects"`
	AgentConfigs  []AgentConfigFile `json:"agentConfigs"`
	OculusConfigs RepoStatus        `json:"oculusConfigs"`
}

type ServiceStatus struct {
	Name        string `json:"name"`
	Active      string `json:"active"`
	Sub         string `json:"sub"`
	Description string `json:"description"`
}

type LogBlock struct {
	Name  string `json:"name"`
	Lines string `json:"lines"`
}

type NetworkStatus struct {
	Addresses string `json:"addresses"`
	Routes    string `json:"routes"`
}

type AccountStatus struct {
	Username string `json:"username"`
	UID      string `json:"uid"`
	Groups   string `json:"groups"`
	Home     string `json:"home"`
	Shell    string `json:"shell"`
}

type FileEntry struct {
	Name  string `json:"name"`
	Path  string `json:"path"`
	Type  string `json:"type"`
	Size  int64  `json:"size"`
	MTime string `json:"mtime"`
}

type FileListing struct {
	Path    string      `json:"path"`
	Parent  string      `json:"parent"`
	Entries []FileEntry `json:"entries"`
}

type FileContent struct {
	Path    string `json:"path"`
	Content string `json:"content"`
	Size    int64  `json:"size"`
}

type UpdateStatus struct {
	AgentWorkstation string `json:"agentWorkstation"`
	OS               string `json:"os"`
	SelfUpdateLog    string `json:"selfUpdateLog"`
}

type ProjectStatus struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	GitBranch string `json:"gitBranch"`
	GitStatus string `json:"gitStatus"`
}

type AgentConfigFile struct {
	Name   string `json:"name"`
	Path   string `json:"path"`
	Exists bool   `json:"exists"`
	Size   int64  `json:"size"`
}

type RepoStatus struct {
	Path       string `json:"path"`
	Exists     bool   `json:"exists"`
	Branch     string `json:"branch"`
	Head       string `json:"head"`
	Status     string `json:"status"`
	Pending    string `json:"pending"`
	LastCommit string `json:"lastCommit"`
}

type CommandResult struct {
	Command  string `json:"command"`
	Cwd      string `json:"cwd"`
	Output   string `json:"output"`
	ExitCode int    `json:"exitCode"`
}

type FileOperation struct {
	Operation string `json:"operation"`
	Path      string `json:"path"`
	Target    string `json:"target"`
	Kind      string `json:"kind"`
}

type ProjectOperation struct {
	Operation string `json:"operation"`
	Name      string `json:"name"`
	NewName   string `json:"newName"`
	Template  string `json:"template"`
	Remote    string `json:"remote"`
}

func CollectManagementSnapshot() (ManagementSnapshot, error) {
	home := workstationHome()
	overview, _ := CollectOverview()
	snapshot := ManagementSnapshot{
		Overview:      overview,
		Services:      collectServices(),
		Logs:          collectLogs(),
		Network:       collectNetwork(),
		Accounts:      collectAccounts(),
		Files:         listFiles(filepath.Join(home, "projects"), 80),
		Updates:       collectUpdates(),
		Projects:      collectProjects(filepath.Join(home, "projects")),
		AgentConfigs:  collectAgentConfigs(home),
		OculusConfigs: collectRepoStatus("/opt/oculus-configs"),
	}
	return snapshot, nil
}

func RunShellCommand(command string, cwd string) (CommandResult, error) {
	command = strings.TrimSpace(command)
	if command == "" {
		return CommandResult{}, errors.New("command is required")
	}
	if cwd == "" {
		cwd = filepath.Join(workstationHome(), "projects")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", "-lc", command)
	cmd.Dir = cwd
	output, err := cmd.CombinedOutput()
	result := CommandResult{Command: command, Cwd: cwd, Output: string(output)}
	if cmd.ProcessState != nil {
		result.ExitCode = cmd.ProcessState.ExitCode()
	}
	if ctx.Err() == context.DeadlineExceeded {
		result.ExitCode = 124
		return result, errors.New("command timed out after 45 seconds")
	}
	if err != nil {
		return result, nil
	}
	return result, nil
}

func RunWorkstationAction(action string) (CommandResult, error) {
	switch action {
	case "sync-oculus-configs":
		return RunShellCommand("sudo ccc-sync-agent-configs", workstationHome())
	case "update-status":
		return RunShellCommand("ccc-update-status", workstationHome())
	case "self-update":
		return RunShellCommand("sudo nohup ccc-self-update > /var/log/ccc-self-update.log 2>&1 & echo 'Agent Workstation self-update started in background. Watch /var/log/ccc-self-update.log for progress.'", workstationHome())
	case "os-update":
		return RunShellCommand("sudo ccc-os-update", workstationHome())
	case "restart-code-server":
		return RunShellCommand("sudo systemctl restart code-server@$(id -un).service", workstationHome())
	case "restart-agent-workstation":
		return RunShellCommand("sudo systemctl restart agent-workstation.service", workstationHome())
	default:
		return CommandResult{}, fmt.Errorf("action %q is not allowed", action)
	}
}

func ControlService(service string, operation string) (CommandResult, error) {
	service = strings.TrimSpace(service)
	operation = strings.TrimSpace(operation)
	if service == "" {
		return CommandResult{}, errors.New("service is required")
	}
	switch operation {
	case "start", "stop", "restart", "enable", "disable":
	default:
		return CommandResult{}, fmt.Errorf("operation %q is not allowed", operation)
	}
	return RunShellCommand("sudo systemctl "+operation+" "+shellQuote(service), workstationHome())
}

func BrowseFiles(path string) (FileListing, error) {
	if strings.TrimSpace(path) == "" {
		path = filepath.Join(workstationHome(), "projects")
	}
	cleaned, err := filepath.Abs(path)
	if err != nil {
		return FileListing{}, err
	}
	return FileListing{
		Path:    cleaned,
		Parent:  filepath.Dir(cleaned),
		Entries: listFiles(cleaned, 500),
	}, nil
}

func ReadTextFile(path string) (FileContent, error) {
	cleaned, err := filepath.Abs(path)
	if err != nil {
		return FileContent{}, err
	}
	info, err := os.Stat(cleaned)
	if err != nil {
		return FileContent{}, err
	}
	if info.IsDir() {
		return FileContent{}, errors.New("cannot open a directory as a file")
	}
	if info.Size() > 2*1024*1024 {
		return FileContent{}, errors.New("file is larger than 2 MiB")
	}
	content, err := os.ReadFile(cleaned)
	if err != nil {
		return FileContent{}, err
	}
	if strings.ContainsRune(string(content), '\x00') {
		return FileContent{}, errors.New("binary files cannot be edited")
	}
	return FileContent{Path: cleaned, Content: string(content), Size: info.Size()}, nil
}

func WriteTextFile(path string, content string) error {
	cleaned, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	if len(content) > 2*1024*1024 {
		return errors.New("file content is larger than 2 MiB")
	}
	info, err := os.Stat(cleaned)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return errors.New("cannot save content to a directory")
	}
	return os.WriteFile(cleaned, []byte(content), info.Mode().Perm())
}

func RunFileOperation(operation FileOperation) (CommandResult, error) {
	if strings.TrimSpace(operation.Path) == "" || operation.Path == "/" {
		return CommandResult{}, errors.New("valid path is required")
	}
	switch operation.Operation {
	case "create":
		if operation.Kind == "dir" {
			if err := os.MkdirAll(operation.Path, 0o755); err != nil {
				return CommandResult{}, err
			}
			return CommandResult{Command: "create " + operation.Path, Output: "created directory"}, nil
		}
		file, err := os.OpenFile(operation.Path, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o644)
		if err != nil {
			return CommandResult{}, err
		}
		_ = file.Close()
		return CommandResult{Command: "create " + operation.Path, Output: "created file"}, nil
	case "rename":
		if strings.TrimSpace(operation.Target) == "" || operation.Target == "/" {
			return CommandResult{}, errors.New("valid target path is required")
		}
		if err := os.Rename(operation.Path, operation.Target); err != nil {
			return CommandResult{}, err
		}
		return CommandResult{Command: "rename " + operation.Path, Output: "renamed"}, nil
	case "delete":
		if err := os.RemoveAll(operation.Path); err != nil {
			return CommandResult{}, err
		}
		return CommandResult{Command: "delete " + operation.Path, Output: "deleted"}, nil
	default:
		return CommandResult{}, fmt.Errorf("file operation %q is not allowed", operation.Operation)
	}
}

func RunProjectOperation(operation ProjectOperation) (CommandResult, error) {
	projectsRoot := filepath.Join(workstationHome(), "projects")
	if err := os.MkdirAll(projectsRoot, 0o755); err != nil {
		return CommandResult{}, err
	}
	switch operation.Operation {
	case "create":
		if !safeProjectName(operation.Name) {
			return CommandResult{}, errors.New("invalid project name")
		}
		path := filepath.Join(projectsRoot, operation.Name)
		if err := os.Mkdir(path, 0o755); err != nil {
			return CommandResult{}, err
		}
		if operation.Template != "" && operation.Template != "blank" {
			templatePath := filepath.Join(workstationHome(), "Templates", operation.Template)
			if err := copyDirectory(templatePath, path); err != nil {
				return CommandResult{}, err
			}
		}
		_, _ = RunShellCommand("git init", path)
		if operation.Remote != "" {
			return RunShellCommand("gh repo create "+shellQuote(operation.Remote)+" --private --source=. --push", path)
		}
		return CommandResult{Command: "create " + operation.Name, Output: "created " + operation.Name}, nil
	case "rename":
		if !safeProjectName(operation.Name) || !safeProjectName(operation.NewName) {
			return CommandResult{}, errors.New("invalid project name")
		}
		if err := os.Rename(filepath.Join(projectsRoot, operation.Name), filepath.Join(projectsRoot, operation.NewName)); err != nil {
			return CommandResult{}, err
		}
		return CommandResult{Command: "rename " + operation.Name, Output: "renamed " + operation.Name + " to " + operation.NewName}, nil
	case "delete":
		if !safeProjectName(operation.Name) {
			return CommandResult{}, errors.New("invalid project name")
		}
		if err := os.RemoveAll(filepath.Join(projectsRoot, operation.Name)); err != nil {
			return CommandResult{}, err
		}
		return CommandResult{Command: "delete " + operation.Name, Output: "deleted " + operation.Name}, nil
	default:
		return CommandResult{}, fmt.Errorf("project operation %q is not allowed", operation.Operation)
	}
}

func collectServices() []ServiceStatus {
	names := []string{"agent-workstation.service", "code-server@" + currentUsername() + ".service", "ssh.service", "redis-server.service"}
	services := make([]ServiceStatus, 0, len(names))
	for _, name := range names {
		services = append(services, ServiceStatus{
			Name:        name,
			Active:      strings.TrimSpace(runText("systemctl", "is-active", name)),
			Sub:         strings.TrimSpace(runText("systemctl", "is-enabled", name)),
			Description: strings.TrimSpace(runText("systemctl", "show", "-p", "Description", "--value", name)),
		})
	}
	return services
}

func safeProjectName(name string) bool {
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 80 || strings.Contains(name, "..") {
		return false
	}
	for _, char := range name {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9') || char == '_' || char == '-' || char == '.' {
			continue
		}
		return false
	}
	first := name[0]
	return (first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z') || (first >= '0' && first <= '9')
}

func copyDirectory(src string, dst string) error {
	return filepath.WalkDir(src, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if entry.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		return os.WriteFile(target, content, info.Mode().Perm())
	})
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func collectLogs() []LogBlock {
	units := []string{"agent-workstation.service", "code-server@" + currentUsername() + ".service"}
	logs := make([]LogBlock, 0, len(units))
	for _, unit := range units {
		logs = append(logs, LogBlock{
			Name:  unit,
			Lines: runText("journalctl", "-u", unit, "-n", "80", "--no-pager", "--output", "short-iso"),
		})
	}
	return logs
}

func collectNetwork() NetworkStatus {
	return NetworkStatus{
		Addresses: runText("ip", "-brief", "addr"),
		Routes:    runText("ip", "route"),
	}
}

func collectAccounts() []AccountStatus {
	raw, err := os.ReadFile("/etc/passwd")
	if err != nil {
		return nil
	}
	var accounts []AccountStatus
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Split(line, ":")
		if len(fields) < 7 {
			continue
		}
		uid, _ := strconv.Atoi(fields[2])
		if uid < 1000 || strings.Contains(fields[6], "nologin") || strings.Contains(fields[6], "false") {
			continue
		}
		accounts = append(accounts, AccountStatus{
			Username: fields[0],
			UID:      fields[2],
			Groups:   strings.TrimSpace(runText("id", "-nG", fields[0])),
			Home:     fields[5],
			Shell:    fields[6],
		})
	}
	return accounts
}

func collectUpdates() UpdateStatus {
	return UpdateStatus{
		AgentWorkstation: runText("ccc-update-status"),
		OS:               runText("bash", "-lc", "apt list --upgradable 2>/dev/null | sed -n '1,60p'"),
		SelfUpdateLog:    runText("bash", "-lc", "tail -120 /var/log/ccc-self-update.log 2>/dev/null || true"),
	}
}

func collectProjects(root string) []ProjectStatus {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	var projects []ProjectStatus
	for _, entry := range entries {
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		path := filepath.Join(root, entry.Name())
		projects = append(projects, ProjectStatus{
			Name:      entry.Name(),
			Path:      path,
			GitBranch: gitText(path, "branch", "--show-current"),
			GitStatus: gitText(path, "status", "--short", "--branch"),
		})
	}
	sort.Slice(projects, func(i, j int) bool { return projects[i].Name < projects[j].Name })
	return projects
}

func collectAgentConfigs(home string) []AgentConfigFile {
	paths := []struct {
		name string
		path string
	}{
		{"Claude CLAUDE.md", filepath.Join(home, ".claude", "CLAUDE.md")},
		{"Codex AGENTS.md", filepath.Join(home, ".codex", "AGENTS.md")},
		{"Gemini GEMINI.md", filepath.Join(home, ".gemini", "GEMINI.md")},
		{"Claude MCP", filepath.Join(home, ".claude", "mcp.json")},
	}
	configs := make([]AgentConfigFile, 0, len(paths))
	for _, item := range paths {
		info, err := os.Stat(item.path)
		configs = append(configs, AgentConfigFile{
			Name:   item.name,
			Path:   item.path,
			Exists: err == nil,
			Size:   fileSize(info, err),
		})
	}
	return configs
}

func collectRepoStatus(path string) RepoStatus {
	status := RepoStatus{Path: path}
	if _, err := os.Stat(path); err != nil {
		return status
	}
	status.Exists = true
	status.Branch = gitText(path, "branch", "--show-current")
	status.Head = gitText(path, "rev-parse", "--short", "HEAD")
	status.Status = gitText(path, "status", "--short", "--branch")
	status.Pending = gitText(path, "diff", "--stat")
	status.LastCommit = gitText(path, "log", "-1", "--pretty=%h %s")
	return status
}

func listFiles(root string, limit int) []FileEntry {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	files := make([]FileEntry, 0, len(entries))
	for index, entry := range entries {
		if index >= limit {
			break
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		fileType := "file"
		if entry.IsDir() {
			fileType = "dir"
		}
		files = append(files, FileEntry{
			Name:  entry.Name(),
			Path:  filepath.Join(root, entry.Name()),
			Type:  fileType,
			Size:  info.Size(),
			MTime: info.ModTime().Format(time.RFC3339),
		})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })
	return files
}

func workstationHome() string {
	if home := os.Getenv("HOME"); home != "" {
		return home
	}
	if u, err := user.Current(); err == nil && u.HomeDir != "" {
		return u.HomeDir
	}
	return "/home/" + currentUsername()
}

func currentUsername() string {
	if name := os.Getenv("USER"); name != "" {
		return name
	}
	if u, err := user.Current(); err == nil && u.Username != "" {
		return filepath.Base(u.Username)
	}
	return "claude-code"
}

func runText(name string, args ...string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	text := strings.TrimSpace(string(output))
	if err != nil && text == "" {
		return err.Error()
	}
	return text
}

func gitText(dir string, args ...string) string {
	gitArgs := append([]string{"-C", dir}, args...)
	return runText("git", gitArgs...)
}

func fileSize(info os.FileInfo, err error) int64 {
	if err != nil || info == nil {
		return 0
	}
	return info.Size()
}
