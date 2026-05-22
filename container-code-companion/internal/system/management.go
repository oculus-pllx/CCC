package system

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

var scpGitRemotePattern = regexp.MustCompile(`^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+(?:\.git)?$`)

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

type NetworkActivity struct {
	Interfaces []NetworkInterfaceActivity `json:"interfaces"`
}

type NetworkInterfaceActivity struct {
	Name    string `json:"name"`
	RXBytes uint64 `json:"rxBytes"`
	TXBytes uint64 `json:"txBytes"`
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
	Mode  string `json:"mode"`
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

type UploadedFile struct {
	Path string `json:"path"`
	Size int64  `json:"size"`
}

type DownloadFile struct {
	Path string
	Name string
	Size int64
}

type UpdateStatus struct {
	ContainerCodeCompanion string `json:"containerCodeCompanion"`
	OS                     string `json:"os"`
	SelfUpdateLog          string `json:"selfUpdateLog"`
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
	Mode      string `json:"mode"`
}

type ToolStatus struct {
	Name            string `json:"name"`
	Label           string `json:"label"`
	Command         string `json:"command"`
	Installed       bool   `json:"installed"`
	Version         string `json:"version"`
	UpdateAvailable bool   `json:"updateAvailable"`
	UpdateStatus    string `json:"updateStatus"`
	Description     string `json:"description"`
}

type ToolOperation struct {
	Operation string `json:"operation"`
	Tool      string `json:"tool"`
}

type DriveOperation struct {
	Operation  string `json:"operation"`
	Name       string `json:"name"`
	Remote     string `json:"remote"`
	MountPoint string `json:"mountPoint"`
	Username   string `json:"username"`
	Password   string `json:"password"`
}

type ProjectOperation struct {
	Operation string `json:"operation"`
	Name      string `json:"name"`
	NewName   string `json:"newName"`
	Path      string `json:"path"`
	Template  string `json:"template"`
	Remote    string `json:"remote"`
}

type AccountOperation struct {
	Operation string `json:"operation"`
	Username  string `json:"username"`
	Password  string `json:"password"`
	Shell     string `json:"shell"`
	Groups    string `json:"groups"`
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
		return StartSelfUpdate()
	case "os-update":
		return RunShellCommand("sudo ccc-os-update", workstationHome())
	case "restart-code-server":
		return RunShellCommand("sudo systemctl restart code-server@$(id -un).service", workstationHome())
	case "restart-container-code-companion":
		return RunShellCommand("sudo systemctl restart container-code-companion.service", workstationHome())
	default:
		return CommandResult{}, fmt.Errorf("action %q is not allowed", action)
	}
}

func StartSelfUpdate() (CommandResult, error) {
	logPath := "/var/log/ccc-self-update.log"

	// Preflight: verify ccc-self-update is accessible via sudo
	check := exec.Command("sudo", "-n", "bash", "-lc", "command -v ccc-self-update >/dev/null 2>&1 || { echo 'ccc-self-update not found in PATH'; exit 1; }")
	if out, err := check.CombinedOutput(); err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return CommandResult{Command: "ccc-self-update", Output: "Cannot start update: " + msg, ExitCode: 1}, errors.New(msg)
	}

	command := "umask 022" +
		" && mkdir -p /var/log" +
		" && touch " + logPath +
		" && chmod 0644 " + logPath +
		" && printf 'Container Code Companion self-update started at %s\\n' \"$(date -Is)\" > " + logPath +
		" && setsid env NO_COLOR=1 ccc-self-update >> " + logPath + " 2>&1 < /dev/null &"
	// Use Start+Wait instead of Output/Run so that no stdout/stderr pipe is
	// inherited by the setsid child process. If Output() is used, the child
	// inherits bash's stderr pipe and cmd.Output() blocks until ccc-self-update
	// exits (minutes), causing the HTTP response to never be sent.
	var launchErr bytes.Buffer
	cmd := exec.Command("sudo", "bash", "-lc", command)
	cmd.Dir = workstationHome()
	cmd.Stderr = &launchErr
	if err := cmd.Start(); err != nil {
		return CommandResult{Command: "ccc-self-update", Output: "Update launch failed: " + err.Error(), ExitCode: 1}, err
	}
	if err := cmd.Wait(); err != nil {
		msg := strings.TrimSpace(launchErr.String())
		if msg == "" {
			msg = err.Error()
		}
		return CommandResult{Command: "ccc-self-update", Output: "Update launch failed: " + msg, ExitCode: 1}, errors.New(msg)
	}
	return CommandResult{
		Command:  "ccc-self-update",
		Cwd:      workstationHome(),
		Output:   "Container Code Companion self-update started.",
		ExitCode: 0,
	}, nil
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

func RunAccountOperation(operation AccountOperation) (CommandResult, error) {
	operation.Operation = strings.TrimSpace(operation.Operation)
	operation.Username = strings.TrimSpace(operation.Username)
	operation.Shell = strings.TrimSpace(operation.Shell)
	operation.Groups = strings.TrimSpace(operation.Groups)
	if !safeProjectName(operation.Username) {
		return CommandResult{}, errors.New("valid username is required")
	}
	switch operation.Operation {
	case "create":
		shell := operation.Shell
		if shell == "" {
			shell = "/bin/bash"
		}
		command := "sudo useradd -m -s " + shellQuote(shell)
		if operation.Groups != "" {
			command += " -G " + shellQuote(operation.Groups)
		}
		command += " " + shellQuote(operation.Username)
		if operation.Password != "" {
			command += " && printf '%s:%s\\n' " + shellQuote(operation.Username) + " " + shellQuote(operation.Password) + " | sudo chpasswd"
		}
		return RunShellCommand(command, workstationHome())
	case "set-password":
		if operation.Password == "" {
			return CommandResult{}, errors.New("password is required")
		}
		return RunShellCommand("printf '%s:%s\\n' "+shellQuote(operation.Username)+" "+shellQuote(operation.Password)+" | sudo chpasswd", workstationHome())
	case "set-shell":
		if operation.Shell == "" {
			return CommandResult{}, errors.New("shell is required")
		}
		return RunShellCommand("sudo chsh -s "+shellQuote(operation.Shell)+" "+shellQuote(operation.Username), workstationHome())
	case "set-groups":
		return RunShellCommand("sudo usermod -G "+shellQuote(operation.Groups)+" "+shellQuote(operation.Username), workstationHome())
	case "delete":
		return RunShellCommand("sudo userdel -r "+shellQuote(operation.Username), workstationHome())
	default:
		return CommandResult{}, fmt.Errorf("account operation %q is not allowed", operation.Operation)
	}
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

func SaveUploadedFile(dir string, filename string, source io.Reader) (UploadedFile, error) {
	if strings.TrimSpace(dir) == "" {
		return UploadedFile{}, errors.New("upload directory is required")
	}
	if strings.TrimSpace(filename) == "" || filename != filepath.Base(filename) {
		return UploadedFile{}, errors.New("valid upload filename is required")
	}
	cleanedDir, err := filepath.Abs(dir)
	if err != nil {
		return UploadedFile{}, err
	}
	info, err := os.Stat(cleanedDir)
	if err != nil {
		return UploadedFile{}, err
	}
	if !info.IsDir() {
		return UploadedFile{}, errors.New("upload path must be a directory")
	}
	target := filepath.Join(cleanedDir, filename)
	file, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return UploadedFile{}, err
	}
	defer file.Close()
	written, err := io.Copy(file, io.LimitReader(source, 64*1024*1024+1))
	if err != nil {
		return UploadedFile{}, err
	}
	if written > 64*1024*1024 {
		_ = os.Remove(target)
		return UploadedFile{}, errors.New("uploaded file is larger than 64 MiB")
	}
	return UploadedFile{Path: target, Size: written}, nil
}

func PrepareFileDownload(path string) (DownloadFile, error) {
	if strings.TrimSpace(path) == "" {
		return DownloadFile{}, errors.New("download path is required")
	}
	cleaned, err := filepath.Abs(path)
	if err != nil {
		return DownloadFile{}, err
	}
	info, err := os.Stat(cleaned)
	if err != nil {
		return DownloadFile{}, err
	}
	if info.IsDir() {
		return DownloadFile{}, errors.New("directory downloads are not supported yet")
	}
	return DownloadFile{Path: cleaned, Name: filepath.Base(cleaned), Size: info.Size()}, nil
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
	case "copy":
		if strings.TrimSpace(operation.Target) == "" || operation.Target == "/" {
			return CommandResult{}, errors.New("valid target path is required")
		}
		if err := copyPath(operation.Path, operation.Target); err != nil {
			return CommandResult{}, err
		}
		return CommandResult{Command: "copy " + operation.Path, Output: "copied"}, nil
	case "chmod":
		mode, err := strconv.ParseUint(operation.Mode, 8, 32)
		if err != nil || mode > 0o777 {
			return CommandResult{}, errors.New("valid mode is required")
		}
		if err := os.Chmod(operation.Path, os.FileMode(mode)); err != nil {
			return CommandResult{}, err
		}
		return CommandResult{Command: "chmod " + operation.Path, Output: "permissions updated"}, nil
	case "delete":
		if err := os.RemoveAll(operation.Path); err != nil {
			return CommandResult{}, err
		}
		return CommandResult{Command: "delete " + operation.Path, Output: "deleted"}, nil
	default:
		return CommandResult{}, fmt.Errorf("file operation %q is not allowed", operation.Operation)
	}
}

func CollectToolStatuses() []ToolStatus {
	specs := toolSpecs()
	statuses := make([]ToolStatus, 0, len(specs))
	for _, spec := range specs {
		version := strings.TrimSpace(runText("bash", "-lc", "command -v "+shellQuote(spec.Command)+" >/dev/null 2>&1 && "+spec.Version+" || true"))
		updateStatus := "not installed"
		updateAvailable := false
		if version != "" {
			updateStatus = strings.TrimSpace(runText("bash", "-lc", spec.UpdateCheck+" || true"))
			if updateStatus == "" {
				updateStatus = "No update detected."
			}
			updateAvailable = toolUpdateAvailable(updateStatus)
		}
		statuses = append(statuses, ToolStatus{
			Name:            spec.Name,
			Label:           spec.Label,
			Command:         spec.Command,
			Installed:       version != "",
			Version:         version,
			UpdateAvailable: updateAvailable,
			UpdateStatus:    updateStatus,
			Description:     spec.Description,
		})
	}
	return statuses
}

func RunToolOperation(operation ToolOperation) (CommandResult, error) {
	if operation.Operation != "install" {
		return CommandResult{}, fmt.Errorf("tool operation %q is not allowed", operation.Operation)
	}
	command, err := toolInstallCommand(operation.Tool)
	if err != nil {
		return CommandResult{}, err
	}
	return RunShellCommand(command, workstationHome())
}

func toolInstallCommand(tool string) (string, error) {
	for _, spec := range toolSpecs() {
		if spec.Name == tool {
			return spec.Install, nil
		}
	}
	return "", fmt.Errorf("tool %q is not allowed", tool)
}

func RunDriveOperation(operation DriveOperation) (CommandResult, error) {
	switch operation.Operation {
	case "mount-cifs":
		if !safeProjectName(operation.Name) {
			return CommandResult{}, errors.New("valid drive name is required")
		}
		if !strings.HasPrefix(operation.Remote, "//") || strings.ContainsAny(operation.Remote, "`$;&|") {
			return CommandResult{}, errors.New("valid CIFS remote is required")
		}
		mountPoint := strings.TrimSpace(operation.MountPoint)
		if mountPoint == "" {
			mountPoint = filepath.Join("/mnt", operation.Name)
		}
		if !strings.HasPrefix(mountPoint, "/mnt/") || strings.Contains(mountPoint, "..") {
			return CommandResult{}, errors.New("mount point must be under /mnt")
		}
		options := "rw"
		if operation.Username != "" {
			options += ",username=" + operation.Username
		}
		if operation.Password != "" {
			options += ",password=" + operation.Password
		}
		command := "sudo mkdir -p " + shellQuote(mountPoint) + " && sudo mount -t cifs " + shellQuote(operation.Remote) + " " + shellQuote(mountPoint) + " -o " + shellQuote(options)
		result, err := RunShellCommand(command, workstationHome())
		if err != nil {
			return result, err
		}
		if result.ExitCode != 0 {
			result.Output = explainDriveMountFailure(result.Output, cccInstallMode())
			return result, errors.New("drive mount failed")
		}
		return result, nil
	default:
		return CommandResult{}, fmt.Errorf("drive operation %q is not allowed", operation.Operation)
	}
}

func cccInstallMode() string {
	data, err := os.ReadFile("/etc/ccc/config")
	if err != nil {
		return "proxmox-lxc"
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "CCC_INSTALL_MODE=") {
			return strings.Trim(strings.TrimPrefix(line, "CCC_INSTALL_MODE="), "\"")
		}
	}
	return "proxmox-lxc"
}

func explainDriveMountFailure(output, installMode string) string {
	text := strings.TrimSpace(output)
	lower := strings.ToLower(text)
	if strings.Contains(lower, "permission denied") {
		if installMode == "linux-host" {
			text += "\n\nLinux host mount note: confirm the share credentials, mount path permissions, CIFS support, and sudo/mount policy on this machine."
		} else {
			text += "\n\nLXC mount note: CIFS mounts require mount capability from the Proxmox host/container configuration. If this is an unprivileged LXC, update the container options on the Proxmox side or mount the share on the host and bind-mount it into the container. The GUI cannot grant kernel mount permission from inside the container."
		}
	}
	if strings.Contains(lower, "unknown filesystem type") || strings.Contains(lower, "bad option") {
		if installMode == "linux-host" {
			text += "\n\nCIFS note: make sure cifs-utils is installed on this host and the kernel supports CIFS mounts."
		} else {
			text += "\n\nCIFS note: make sure cifs-utils is installed in the container and the Proxmox host supports the CIFS mount."
		}
	}
	return text
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
	case "add-existing":
		if !safeProjectName(operation.Name) {
			return CommandResult{}, errors.New("invalid project name")
		}
		target, err := filepath.Abs(strings.TrimSpace(operation.Path))
		if err != nil {
			return CommandResult{}, err
		}
		info, err := os.Stat(target)
		if err != nil {
			return CommandResult{}, err
		}
		if !info.IsDir() {
			return CommandResult{}, errors.New("existing project path must be a directory")
		}
		linkPath := filepath.Join(projectsRoot, operation.Name)
		if _, err := os.Lstat(linkPath); err == nil {
			return CommandResult{}, errors.New("project already exists")
		} else if !os.IsNotExist(err) {
			return CommandResult{}, err
		}
		if err := os.Symlink(target, linkPath); err != nil {
			return CommandResult{}, err
		}
		return CommandResult{Command: "add-existing " + operation.Name, Output: "added " + operation.Name}, nil
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
	names := []string{"container-code-companion.service", "code-server@" + currentUsername() + ".service", "ssh.service", "redis-server.service"}
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

func validateGitRemote(remote string) (string, error) {
	remote = strings.TrimSpace(remote)
	if remote == "" || strings.ContainsAny(remote, " \t\r\n`$;&|") {
		return "", errors.New("valid Git SSH or HTTPS remote is required")
	}
	if strings.HasPrefix(remote, "https://") || strings.HasPrefix(remote, "ssh://") {
		parsed, err := url.Parse(remote)
		if err != nil || parsed.Host == "" || strings.Trim(parsed.Path, "/") == "" {
			return "", errors.New("valid Git SSH or HTTPS remote is required")
		}
		if parsed.Scheme == "https" && parsed.User != nil {
			return "", errors.New("Git HTTPS remotes must not include credentials")
		}
		if parsed.Scheme == "ssh" && parsed.User != nil {
			if _, hasPassword := parsed.User.Password(); hasPassword {
				return "", errors.New("Git SSH remotes must not include passwords")
			}
		}
		return remote, nil
	}
	if scpGitRemotePattern.MatchString(remote) {
		return remote, nil
	}
	return "", errors.New("valid Git SSH or HTTPS remote is required")
}

func projectNameFromGitRemote(remote string) (string, error) {
	remote, err := validateGitRemote(remote)
	if err != nil {
		return "", err
	}
	path := remote
	if parsed, err := url.Parse(remote); err == nil && parsed.Scheme != "" {
		path = parsed.Path
	} else if colon := strings.Index(remote, ":"); colon >= 0 {
		path = remote[colon+1:]
	}
	name := strings.TrimSuffix(filepath.Base(strings.TrimSuffix(path, "/")), ".git")
	if !safeProjectName(name) {
		return "", errors.New("Git remote does not contain a safe project name")
	}
	return name, nil
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

func copyPath(src string, dst string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return copyDirectory(src, dst)
	}
	content, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, content, info.Mode().Perm())
}

type toolSpec struct {
	Name        string
	Label       string
	Command     string
	Version     string
	Install     string
	UpdateCheck string
	Description string
}

func toolSpecs() []toolSpec {
	return []toolSpec{
		{Name: "nodejs", Label: "Node.js", Command: "node", Version: "node --version", Install: "sudo apt-get update && sudo apt-get install -y nodejs npm", UpdateCheck: aptUpdateCheck("nodejs"), Description: "JavaScript runtime and npm"},
		{Name: "go", Label: "Go", Command: "go", Version: "go version", Install: "sudo ccc-update-go || sudo apt-get install -y golang-go", UpdateCheck: "ccc-update-go --check 2>/dev/null || echo 'No update detected.'", Description: "Go toolchain for native builds"},
		{Name: "python", Label: "Python", Command: "python3", Version: "python3 --version", Install: "sudo apt-get update && sudo apt-get install -y python3 python3-pip python3-venv pipx", UpdateCheck: aptUpdateCheck("python3"), Description: "Python runtime, venv, pip, and pipx"},
		{Name: "uv", Label: "uv", Command: "uv", Version: "uv --version", Install: "curl -LsSf https://astral.sh/uv/install.sh | sh", UpdateCheck: "uv self update --dry-run 2>/dev/null || echo 'No update detected.'", Description: "Fast Python package and project manager"},
		{Name: "playwright", Label: "Playwright", Command: "npx", Version: "npx --yes playwright --version", Install: "ccc-install-playwright", UpdateCheck: "npm outdated -g playwright --depth=0 2>/dev/null || echo 'No update detected.'", Description: "Browser automation/test dependencies"},
		{Name: "codex", Label: "OpenAI Codex", Command: "codex", Version: "codex --version", Install: "ccc-install-codex", UpdateCheck: "npm outdated -g --prefix \"$HOME/.local\" @openai/codex --depth=0 2>/dev/null || echo 'No update detected.'", Description: "OpenAI Codex CLI"},
		{Name: "claude", Label: "Claude Code", Command: "claude", Version: "claude --version", Install: "npm install -g --prefix \"$HOME/.local\" @anthropic-ai/claude-code", UpdateCheck: "npm outdated -g --prefix \"$HOME/.local\" @anthropic-ai/claude-code --depth=0 2>/dev/null || echo 'No update detected.'", Description: "Anthropic Claude Code CLI"},
		{Name: "gemini", Label: "Gemini CLI", Command: "gemini", Version: "gemini --version", Install: "npm install -g --prefix \"$HOME/.local\" @google/gemini-cli", UpdateCheck: "npm outdated -g --prefix \"$HOME/.local\" @google/gemini-cli --depth=0 2>/dev/null || echo 'No update detected.'", Description: "Google Gemini command-line agent"},
		{Name: "gh", Label: "GitHub CLI", Command: "gh", Version: "gh --version | head -1", Install: "sudo apt-get update && sudo apt-get install -y gh", UpdateCheck: aptUpdateCheck("gh"), Description: "GitHub auth and repo operations"},
		{Name: "bubblewrap", Label: "Bubblewrap", Command: "bwrap", Version: "bwrap --version", Install: "sudo apt-get update && sudo apt-get install -y bubblewrap", UpdateCheck: aptUpdateCheck("bubblewrap"), Description: "Codex sandbox prerequisite"},
		{Name: "ripgrep", Label: "ripgrep", Command: "rg", Version: "rg --version | head -1", Install: "sudo apt-get update && sudo apt-get install -y ripgrep", UpdateCheck: aptUpdateCheck("ripgrep"), Description: "Fast code search"},
		{Name: "jq", Label: "jq", Command: "jq", Version: "jq --version", Install: "sudo apt-get update && sudo apt-get install -y jq", UpdateCheck: aptUpdateCheck("jq"), Description: "JSON processing for scripts and API work"},
		{Name: "fzf", Label: "fzf", Command: "fzf", Version: "fzf --version", Install: "sudo apt-get update && sudo apt-get install -y fzf", UpdateCheck: aptUpdateCheck("fzf"), Description: "Interactive fuzzy finder for terminal workflows"},
		{Name: "build-essential", Label: "Build Essential", Command: "gcc", Version: "gcc --version | head -1", Install: "sudo apt-get update && sudo apt-get install -y build-essential pkg-config", UpdateCheck: aptUpdateCheck("build-essential"), Description: "Compiler and native build prerequisites"},
		{Name: "aider", Label: "Aider", Command: "aider", Version: "aider --version", Install: "python3 -m pip install --user -U aider-chat", UpdateCheck: "python3 -m pip list --outdated --user 2>/dev/null | grep -E '^aider-chat\\s' || echo 'No update detected.'", Description: "Provider-agnostic AI coding assistant"},
	}
}

func aptUpdateCheck(pkg string) string {
	return "apt list --upgradable " + shellQuote(pkg) + " 2>/dev/null | sed -n '2,4p' | grep . || echo 'No update detected.'"
}

func toolUpdateAvailable(status string) bool {
	normalized := strings.ToLower(strings.TrimSpace(status))
	if normalized == "" ||
		strings.Contains(normalized, "no update") ||
		strings.Contains(normalized, "no automatic update") ||
		strings.Contains(normalized, "manual check") {
		return false
	}
	return true
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func collectLogs() []LogBlock {
	units := []string{"container-code-companion.service", "code-server@" + currentUsername() + ".service"}
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

func CollectNetworkActivity() (NetworkActivity, error) {
	raw, err := os.ReadFile("/proc/net/dev")
	if err != nil {
		return NetworkActivity{}, err
	}
	activity := NetworkActivity{}
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || !strings.Contains(line, ":") {
			continue
		}
		parts := strings.SplitN(line, ":", 2)
		name := strings.TrimSpace(parts[0])
		fields := strings.Fields(parts[1])
		if name == "lo" || len(fields) < 16 {
			continue
		}
		rxBytes, rxErr := strconv.ParseUint(fields[0], 10, 64)
		txBytes, txErr := strconv.ParseUint(fields[8], 10, 64)
		if rxErr != nil || txErr != nil {
			continue
		}
		activity.Interfaces = append(activity.Interfaces, NetworkInterfaceActivity{
			Name:    name,
			RXBytes: rxBytes,
			TXBytes: txBytes,
		})
	}
	return activity, nil
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
		ContainerCodeCompanion: runText("ccc-update-status"),
		OS:                     runText("bash", "-lc", "apt list --upgradable 2>/dev/null | sed -n '1,60p'"),
		SelfUpdateLog:          runText("bash", "-lc", "sudo tail -120 /var/log/ccc-self-update.log 2>/dev/null || true"),
	}
}

func collectProjects(root string) []ProjectStatus {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	var projects []ProjectStatus
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		path := filepath.Join(root, entry.Name())
		info, err := os.Stat(path)
		if err != nil || !info.IsDir() {
			continue
		}
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
			Mode:  info.Mode().Perm().String(),
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

type GitHubStatus struct {
	PublicKey  string `json:"publicKey"`
	KeyExists  bool   `json:"keyExists"`
	KeyPath    string `json:"keyPath"`
	TestOutput string `json:"testOutput,omitempty"`
}

func CollectGitHubStatus() (GitHubStatus, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return GitHubStatus{}, err
	}
	keyPath := filepath.Join(home, ".ssh", "id_ed25519.pub")
	pub, err := os.ReadFile(keyPath)
	if err != nil {
		return GitHubStatus{KeyExists: false, KeyPath: filepath.Join(home, ".ssh", "id_ed25519")}, nil
	}
	return GitHubStatus{
		KeyExists: true,
		KeyPath:   filepath.Join(home, ".ssh", "id_ed25519"),
		PublicKey: strings.TrimSpace(string(pub)),
	}, nil
}

func RunGitHubOperation(action string) (CommandResult, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return CommandResult{}, err
	}
	sshDir := filepath.Join(home, ".ssh")
	keyPath := filepath.Join(sshDir, "id_ed25519")

	switch action {
	case "generate-key":
		if err := os.MkdirAll(sshDir, 0700); err != nil {
			return CommandResult{}, err
		}
		// Remove existing key pair so ssh-keygen doesn't prompt
		os.Remove(keyPath)
		os.Remove(keyPath + ".pub")
		cmd := exec.Command("ssh-keygen", "-t", "ed25519", "-f", keyPath, "-N", "", "-C", "container-code-companion")
		out, err := cmd.CombinedOutput()
		if err != nil {
			return CommandResult{Command: "ssh-keygen", Output: strings.TrimSpace(string(out)), ExitCode: 1}, err
		}
		pub, err := os.ReadFile(keyPath + ".pub")
		if err != nil {
			return CommandResult{Command: "ssh-keygen", Output: "Key generated but cannot read public key: " + err.Error(), ExitCode: 1}, err
		}
		return CommandResult{Command: "ssh-keygen", Output: strings.TrimSpace(string(pub)), ExitCode: 0}, nil

	case "test-connection":
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "ssh", "-T", "-o", "StrictHostKeyChecking=accept-new",
			"-o", "BatchMode=yes", "-i", keyPath, "git@github.com")
		out, _ := cmd.CombinedOutput()
		text := strings.TrimSpace(string(out))
		exitCode := 0
		if cmd.ProcessState != nil && cmd.ProcessState.ExitCode() == 1 {
			// GitHub returns exit 1 even on successful auth ("Hi username! You've authenticated...")
			exitCode = 0
		} else if cmd.ProcessState != nil && cmd.ProcessState.ExitCode() > 1 {
			exitCode = cmd.ProcessState.ExitCode()
		}
		return CommandResult{Command: "ssh -T git@github.com", Output: text, ExitCode: exitCode}, nil

	default:
		return CommandResult{}, fmt.Errorf("action %q is not allowed", action)
	}
}
