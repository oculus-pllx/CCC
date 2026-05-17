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

type UpdateStatus struct {
	AgentWorkstation string `json:"agentWorkstation"`
	OS               string `json:"os"`
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
