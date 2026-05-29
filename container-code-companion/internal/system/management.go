package system

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
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
	"sync"
	"time"
)

var scpGitRemotePattern = regexp.MustCompile(`^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+(?:\.git)?$`)
var sshdUserTTYPattern = regexp.MustCompile(`sshd(?:-session)?:\s+([A-Za-z0-9._-]+)@(?:(?:pts|tty)/[0-9]+|notty)`)

type ManagementSnapshot struct {
	Overview      Overview          `json:"overview"`
	Services      []ServiceStatus   `json:"services"`
	Logs          []LogBlock        `json:"logs"`
	Network       NetworkStatus     `json:"network"`
	SSHSessions   SSHSessionSummary `json:"sshSessions"`
	Accounts      []AccountStatus   `json:"accounts"`
	Files         []FileEntry       `json:"files"`
	Updates       UpdateStatus      `json:"updates"`
	Projects      []ProjectStatus   `json:"projects"`
	ProjectRoot   ProjectRootStatus `json:"projectRoot"`
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

type SSHSessionSummary struct {
	Total       int              `json:"total"`
	UniqueUsers int              `json:"uniqueUsers"`
	Users       []SSHUserSession `json:"users"`
}

type SSHUserSession struct {
	Username string `json:"username"`
	Count    int    `json:"count"`
}

type TmuxSession struct {
	Name            string `json:"name"`
	Windows         int    `json:"windows"`
	AttachedClients int    `json:"attachedClients"`
	IdleSeconds     int    `json:"idleSeconds"`
}

type AccountStatus struct {
	Username     string            `json:"username"`
	UID          string            `json:"uid"`
	Groups       string            `json:"groups"`
	Home         string            `json:"home"`
	Shell        string            `json:"shell"`
	AgentConfigs []AgentConfigFile `json:"agentConfigs"`
	Plugins      []PluginEntry     `json:"plugins"`
	TmuxSessions []TmuxSession     `json:"tmuxSessions"`
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
	AutoUpdateEnabled      bool   `json:"autoUpdateEnabled"`
	AutoUpdateLastRun      string `json:"autoUpdateLastRun"`
	AutoUpdateSchedule     string `json:"autoUpdateSchedule"`
	AutoUpdateFreq         string `json:"autoUpdateFreq"`
	AutoUpdateHour         int    `json:"autoUpdateHour"`
}

var (
	cachedUpdateStatus  UpdateStatus
	updateStatusMu      sync.RWMutex
	updatePollerStarted bool
	updatePollerMu      sync.Mutex
)

// StartUpdateStatusPoller starts a background goroutine that refreshes
// the update status cache on the given interval. Safe to call multiple
// times; only the first call starts the goroutine.
func StartUpdateStatusPoller(interval time.Duration) {
	updatePollerMu.Lock()
	defer updatePollerMu.Unlock()
	if updatePollerStarted {
		return
	}
	updatePollerStarted = true
	go func() {
		time.Sleep(30 * time.Second)
		for {
			updateFreq, updateHour := readAutoUpdateSchedule()
			status := UpdateStatus{
				ContainerCodeCompanion: runText("ccc-update-status"),
				OS:                     runText("bash", "-lc", "apt list --upgradable 2>/dev/null | sed -n '1,60p'"),
				SelfUpdateLog:          runText("bash", "-lc", "sudo tail -120 /var/log/ccc-self-update.log 2>/dev/null || true"),
				AutoUpdateEnabled:      autoUpdateEnabled(),
				AutoUpdateLastRun:      autoUpdateLastRun(),
				AutoUpdateSchedule:     formatScheduleLabel(updateFreq, updateHour),
				AutoUpdateFreq:         updateFreq,
				AutoUpdateHour:         updateHour,
			}
			updateStatusMu.Lock()
			cachedUpdateStatus = status
			updateStatusMu.Unlock()
			time.Sleep(interval)
		}
	}()
}

type ProjectStatus struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	GitRepo   bool   `json:"gitRepo"`
	GitBranch string `json:"gitBranch"`
	GitRemote string `json:"gitRemote"`
	GitStatus string `json:"gitStatus"`
}

type ProjectRootStatus struct {
	Root          string `json:"root"`
	Exists        bool   `json:"exists"`
	Mode          string `json:"mode"`
	GroupWritable bool   `json:"groupWritable"`
	Setgid        bool   `json:"setgid"`
	Summary       string `json:"summary"`
}

type AgentConfigFile struct {
	Name   string `json:"name"`
	Path   string `json:"path"`
	Exists bool   `json:"exists"`
	Size   int64  `json:"size"`
	IsDir  bool   `json:"isDir"`
}

type PluginEntry struct {
	Name      string `json:"name"`
	ShortName string `json:"shortName"`
	Enabled   bool   `json:"enabled"`
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
	Operation   string `json:"operation"`
	Username    string `json:"username"`
	Password    string `json:"password"`
	Shell       string `json:"shell"`
	Groups      string `json:"groups"`
	Plugin      string `json:"plugin"`
	Enabled     bool   `json:"enabled"`
	SessionName string `json:"sessionName"`
	NewName     string `json:"newName"`
	Keys        string `json:"keys"`
}

func CollectManagementSnapshot() (ManagementSnapshot, error) {
	home := workstationHome()
	projectsRoot := projectListingRoot()
	overview, _ := CollectOverview()
	snapshot := ManagementSnapshot{
		Overview:      overview,
		Services:      collectServices(),
		Logs:          collectLogs(),
		Network:       collectNetwork(),
		SSHSessions:   collectSSHSessions(),
		Accounts:      collectAccounts(),
		Files:         listFiles(projectsRoot, 80),
		Updates:       collectUpdates(),
		Projects:      collectProjects(projectsRoot),
		ProjectRoot:   collectProjectPermissionHealth(),
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
		cwd = sharedProjectsRoot()
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
	case "sync-all-agent-configs":
		return RunShellCommand(allAgentConfigSyncCommand(), workstationHome())
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
	case "shared-workspace-status":
		return RunShellCommand(sharedWorkspaceMigrationCommand("--status", false), workstationHome())
	case "shared-workspace-apply":
		return RunShellCommand(sharedWorkspaceMigrationCommand("--apply", true), workstationHome())
	case "enable-autoupdate":
		return RunShellCommand("sudo touch /etc/ccc/autoupdate-enabled", workstationHome())
	case "disable-autoupdate":
		return RunShellCommand("sudo rm -f /etc/ccc/autoupdate-enabled", workstationHome())
	default:
		// set-autoupdate-schedule carries a variable payload (freq:hour) so it
		// cannot be matched as a static case — check with HasPrefix instead.
		if strings.HasPrefix(action, "set-autoupdate-schedule:") {
			parts := strings.SplitN(action, ":", 3)
			if len(parts) != 3 {
				return CommandResult{}, fmt.Errorf("invalid set-autoupdate-schedule action format")
			}
			freq := parts[1]
			hour, err := strconv.Atoi(parts[2])
			if err != nil {
				return CommandResult{}, fmt.Errorf("invalid hour %q", parts[2])
			}
			if err := scheduleAutoupdateCron(freq, hour); err != nil {
				return CommandResult{ExitCode: 1, Output: err.Error()}, err
			}
			label := formatScheduleLabel(freq, hour)
			return CommandResult{ExitCode: 0, Output: "Auto-update schedule set: " + label}, nil
		}
		return CommandResult{}, fmt.Errorf("action %q is not allowed", action)
	}
}

func sharedWorkspaceMigrationCommand(flag string, sudo bool) string {
	missing := "printf '%s\\n' 'Migration command is not installed yet. Run sudo ccc-self-update, then try again.'; exit 127"
	run := "ccc-migrate-shared-workspace " + shellQuote(flag)
	if sudo {
		run = "sudo " + run
	}
	return "if command -v ccc-migrate-shared-workspace >/dev/null 2>&1; then " + run + "; else " + missing + "; fi"
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

// IsSelfUpdateRunning returns true if a ccc-self-update process is still running.
// It scans /proc without sudo so it works from the service account.
func IsSelfUpdateRunning() bool {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return false
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		n := e.Name()
		if len(n) == 0 || n[0] < '1' || n[0] > '9' {
			continue
		}
		data, err := os.ReadFile("/proc/" + n + "/cmdline")
		if err != nil {
			continue
		}
		if strings.Contains(string(data), "ccc-self-update") {
			return true
		}
	}
	return false
}

func autoUpdateEnabled() bool {
	_, err := os.Stat("/etc/ccc/autoupdate-enabled")
	return err == nil
}

func autoUpdateLastRun() string {
	out, err := exec.Command("bash", "-lc",
		"tail -1 /var/log/ccc-app-update.log 2>/dev/null || true").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func autoUpdateScheduleLabel() string {
	freq, hour := readAutoUpdateSchedule()
	return formatScheduleLabel(freq, hour)
}

func readAutoUpdateSchedule() (freq string, hour int) {
	freq = "daily"
	hour = 3
	data, err := os.ReadFile("/etc/ccc/autoupdate-schedule")
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(line, "AUTOUPDATE_FREQ="); ok {
			freq = strings.TrimSpace(v)
		}
		if v, ok := strings.CutPrefix(line, "AUTOUPDATE_HOUR="); ok {
			if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && n >= 0 && n <= 23 {
				hour = n
			}
		}
	}
	return
}

func formatScheduleLabel(freq string, hour int) string {
	dayNames := []string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	var freqLabel string
	switch freq {
	case "daily":
		freqLabel = "Daily"
	case "every2days":
		freqLabel = "Every 2 days"
	case "every3days":
		freqLabel = "Every 3 days"
	default:
		if strings.HasPrefix(freq, "weekly-") {
			d, err := strconv.Atoi(strings.TrimPrefix(freq, "weekly-"))
			if err == nil && d >= 0 && d <= 6 {
				freqLabel = "Weekly (" + dayNames[d] + ")"
			}
		}
	}
	if freqLabel == "" {
		freqLabel = "Daily"
	}
	ampm := "AM"
	h := hour
	if h == 0 {
		h = 12
	} else if h >= 12 {
		ampm = "PM"
		if h > 12 {
			h -= 12
		}
	}
	return fmt.Sprintf("%s @ %d %s", freqLabel, h, ampm)
}

func scheduleAutoupdateCron(freq string, hour int) error {
	validFreqs := map[string]bool{
		"daily": true, "every2days": true, "every3days": true,
	}
	for d := 0; d <= 6; d++ {
		validFreqs[fmt.Sprintf("weekly-%d", d)] = true
	}
	if !validFreqs[freq] {
		return fmt.Errorf("invalid frequency %q", freq)
	}
	if hour < 0 || hour > 23 {
		return fmt.Errorf("hour %d out of range (0-23)", hour)
	}

	var cronExpr string
	switch freq {
	case "daily":
		cronExpr = fmt.Sprintf("0 %d * * *", hour)
	case "every2days":
		cronExpr = fmt.Sprintf("0 %d */2 * *", hour)
	case "every3days":
		cronExpr = fmt.Sprintf("0 %d */3 * *", hour)
	default:
		d, _ := strconv.Atoi(strings.TrimPrefix(freq, "weekly-"))
		cronExpr = fmt.Sprintf("0 %d * * %d", hour, d)
	}

	scheduleContent := fmt.Sprintf("AUTOUPDATE_FREQ=%s\nAUTOUPDATE_HOUR=%d\n", freq, hour)
	cronContent := fmt.Sprintf(
		"SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n"+
			"# Container Code Companion auto-update (smart check — only updates when GitHub has a newer commit).\n"+
			"%s root /usr/local/bin/ccc-auto-update >> /var/log/ccc-app-update.log 2>&1\n",
		cronExpr,
	)

	script := fmt.Sprintf(
		"printf '%%s' %s > /etc/ccc/autoupdate-schedule && "+
			"printf '%%s' %s > /etc/cron.d/ccc-app-update && "+
			"chmod 0644 /etc/cron.d/ccc-app-update",
		shellQuote(scheduleContent), shellQuote(cronContent))
	var errOut bytes.Buffer
	cmd := exec.Command("sudo", "bash", "-c", script)
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("write autoupdate config: %w: %s", err, errOut.String())
	}
	return nil
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
	case "setup-ccc-profile":
		return RunShellCommand(setupCCCProfileCommand(operation.Username), workstationHome())
	case "sync-agent-configs":
		return RunShellCommand(agentConfigSyncCommand(operation.Username), workstationHome())
	case "toggle-plugin":
		if operation.Plugin == "" {
			return CommandResult{}, errors.New("plugin is required")
		}
		if !safePluginName(operation.Plugin) {
			return CommandResult{}, errors.New("invalid plugin name")
		}
		home := "/home/" + operation.Username
		enabledVal := "True"
		if !operation.Enabled {
			enabledVal = "False"
		}
		py := fmt.Sprintf("import json\npath=%q\ntry:\n data=json.load(open(path))\nexcept:\n data={}\nep=data.setdefault('enabledPlugins',{})\nep[%q]=%s\njson.dump(data,open(path,'w'),indent=2)\nprint('Plugin %s set to %s')\n",
			home+"/.claude/settings.json", operation.Plugin, enabledVal, operation.Plugin, enabledVal)
		return RunShellCommand("sudo python3 -c "+shellQuote(py), workstationHome())
	case "delete":
		return RunShellCommand("sudo userdel -r "+shellQuote(operation.Username), workstationHome())
	case "tmux-new":
		if !safeProjectName(operation.SessionName) {
			return CommandResult{}, errors.New("valid session name is required")
		}
		home := "/home/" + operation.Username
		return RunShellCommand("sudo -u "+shellQuote(operation.Username)+" env HOME="+shellQuote(home)+" tmux new-session -d -s "+shellQuote(operation.SessionName), workstationHome())
	case "tmux-kill":
		if !safeProjectName(operation.SessionName) {
			return CommandResult{}, errors.New("valid session name is required")
		}
		return RunShellCommand("sudo -u "+shellQuote(operation.Username)+" tmux kill-session -t "+shellQuote(operation.SessionName), workstationHome())
	case "tmux-kill-all":
		return RunShellCommand("sudo -u "+shellQuote(operation.Username)+" tmux kill-server", workstationHome())
	case "tmux-rename":
		if !safeProjectName(operation.SessionName) {
			return CommandResult{}, errors.New("valid session name is required")
		}
		if !safeProjectName(operation.NewName) {
			return CommandResult{}, errors.New("invalid new session name")
		}
		return RunShellCommand("sudo -u "+shellQuote(operation.Username)+" tmux rename-session -t "+shellQuote(operation.SessionName)+" "+shellQuote(operation.NewName), workstationHome())
	case "tmux-send-keys":
		if operation.SessionName == "" || operation.Keys == "" {
			return CommandResult{}, errors.New("session name and keys are required")
		}
		return RunShellCommand("sudo -u "+shellQuote(operation.Username)+" tmux send-keys -t "+shellQuote(operation.SessionName)+" "+shellQuote(operation.Keys)+" Enter", workstationHome())
	default:
		return CommandResult{}, fmt.Errorf("account operation %q is not allowed", operation.Operation)
	}
}

func setupCCCProfileCommand(username string) string {
	home := "/home/" + username
	group := os.Getenv("CCC_SHARED_GROUP")
	if strings.TrimSpace(group) == "" {
		group = "ccc"
	}
	projectsRoot := sharedProjectsRoot()
	githubKeyPath := githubMachineKeyPath()
	githubConfig := "Host github.com\n  HostName github.com\n  User git\n  IdentityFile " + githubKeyPath + "\n  IdentitiesOnly yes\n"
	shellEnvBlock := "\n# CCC shell environment\nexport EDITOR=nano\nexport LANG=en_US.UTF-8\nexport TZ=America/New_York\nexport PATH=\"$HOME/.local/bin:$HOME/.claude/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH\"\n"
	shellProjectsBlock := "\n# CCC shell projects login\n[[ \"$PWD\" == \"$HOME\" ]] && cd ~/projects 2>/dev/null || true\n"
	claudeInstallCommand := "sudo -u " + shellQuote(username) + " env HOME=" + shellQuote(home) + " PATH=" + shellQuote(home+"/.local/bin:/usr/local/bin:/usr/bin:/bin") + " bash -c 'curl -fsSL https://claude.ai/install.sh | bash'"
	otherProviderInstallCommand := "sudo -u " + shellQuote(username) + " env HOME=" + shellQuote(home) + " PATH=" + shellQuote(home+"/.local/bin:/usr/local/bin:/usr/bin:/bin") + ` npm install -g --prefix ` + shellQuote(home+"/.local") + " @openai/codex @google/gemini-cli"
	providerValidation := []string{
		"sudo test -x " + shellQuote(home+"/.local/bin/claude"),
		"sudo test -x " + shellQuote(home+"/.local/bin/codex"),
		"sudo test -x " + shellQuote(home+"/.local/bin/gemini"),
	}
	commands := []string{
		"sudo git config --system safe.directory \"*\" 2>/dev/null || true",
		"test $(id -u " + shellQuote(username) + ") -ge 1000",
		"sudo groupadd -f " + shellQuote(group),
		"sudo usermod -aG " + shellQuote(group) + " " + shellQuote(username),
		"sudo chgrp " + shellQuote(group) + " " + shellQuote(home),
		"sudo chmod g+rx " + shellQuote(home),
		"sudo mkdir -p " + shellQuote(projectsRoot),
		"sudo chown root:" + shellQuote(group) + " " + shellQuote(projectsRoot),
		"sudo chmod 2775 " + shellQuote(projectsRoot),
		"sudo rm -rf " + shellQuote(home+"/projects"),
		"sudo ln -sfn " + shellQuote(projectsRoot) + " " + shellQuote(home+"/projects"),
		"sudo mkdir -p " + shellQuote(home+"/.claude") + " " + shellQuote(home+"/.codex") + " " + shellQuote(home+"/.gemini") + " " + shellQuote(home+"/.ssh") + " " + shellQuote(home+"/.local"),
		"sudo chmod 700 " + shellQuote(home+"/.ssh"),
		agentConfigSyncCommand(username),
		"sudo touch " + shellQuote(home+"/.bashrc"),
		"sudo sed -i '/# CCC shell environment/,+4d' " + shellQuote(home+"/.bashrc"),
		"sudo sed -i '/# CCC shell projects login/,+1d' " + shellQuote(home+"/.bashrc"),
		"printf %s " + shellQuote(shellEnvBlock) + " | sudo tee -a " + shellQuote(home+"/.bashrc") + " >/dev/null",
		"printf %s " + shellQuote(shellProjectsBlock) + " | sudo tee -a " + shellQuote(home+"/.bashrc") + " >/dev/null",
		"sudo chown -R " + shellQuote(username+":"+username) + " " + shellQuote(home+"/.claude") + " " + shellQuote(home+"/.codex") + " " + shellQuote(home+"/.gemini") + " " + shellQuote(home+"/.ssh") + " " + shellQuote(home+"/.local"),
		"sudo chown " + shellQuote(username+":"+username) + " " + shellQuote(home+"/.bashrc"),
		claudeInstallCommand,
		otherProviderInstallCommand,
		strings.Join(providerValidation, " && "),
		sharedProjectPermissionRepairCommand(projectsRoot, group),
	}
	if fileExists(githubKeyPath) || fileExists(githubKeyPath+".pub") {
		commands = append(commands,
			"printf %s "+shellQuote(githubConfig)+" | sudo tee "+shellQuote(home+"/.ssh/config")+" >/dev/null",
			"sudo chmod 600 "+shellQuote(home+"/.ssh/config"),
		)
	} else {
		commands = append(commands, "true # IdentityFile "+githubKeyPath)
	}
	commands = append(commands,
		"sudo chown -R "+shellQuote(username+":"+username)+" "+shellQuote(home+"/.claude")+" "+shellQuote(home+"/.codex")+" "+shellQuote(home+"/.gemini")+" "+shellQuote(home+"/.ssh")+" "+shellQuote(home+"/.local"),
		"sudo chown "+shellQuote(username+":"+username)+" "+shellQuote(home+"/.bashrc"),
		"printf '%s\\n' 'Profile ready. Provider CLIs installed. First-login checklist: run claude, codex, gemini, and optionally gh auth login.'",
	)
	return strings.Join(commands, " && ")
}

func agentConfigSyncCommand(username string) string {
	return "sudo bash -lc " + shellQuote(directAgentConfigSyncScript("sync_one "+shellQuote(username)))
}

func allAgentConfigSyncCommand() string {
	runAll := "getent passwd | awk -F: '$3 >= 1000 && $7 !~ /(nologin|false)$/ {print $1}' | while read -r user; do sync_one \"$user\"; done"
	return "sudo bash -lc " + shellQuote(directAgentConfigSyncScript(runAll))
}

func directAgentConfigSyncScript(runLine string) string {
	return strings.Join([]string{
		"set -euo pipefail",
		`[ -r /etc/ccc/config ] && source /etc/ccc/config`,
		`repo="${OCULUS_CONFIGS_REPO:-https://github.com/oculus-pllx/oculus-configs.git}"`,
		`ref="${OCULUS_CONFIGS_REF:-main}"`,
		`src="${OCULUS_CONFIGS_DIR:-/opt/oculus-configs}"`,
		`shared_group="${CCC_SHARED_GROUP:-ccc}"`,
		`primary_user="${CCC_USER:-claude-code}"`,
		`source_home="${CCC_HOME:-/home/$primary_user}"`,
		"refresh_source() {",
		`  if [ ! -d "$src/.git" ]; then`,
		`    rm -rf "$src"`,
		`    git clone --depth 1 --branch "$ref" "$repo" "$src"`,
		"  else",
		`    git -c "safe.directory=$src" -C "$src" fetch --depth 1 origin "$ref"`,
		`    git -c "safe.directory=$src" -C "$src" checkout -q "$ref" 2>/dev/null || git -c "safe.directory=$src" -C "$src" checkout -q -B "$ref"`,
		`    git -c "safe.directory=$src" -C "$src" reset --hard "origin/$ref" >/dev/null`,
		"  fi",
		"  chown -R root:root \"$src\"",
		"  git config --system safe.directory \"*\" 2>/dev/null || true",
		"}",
		"copy_file() {",
		`  local from=$1 to=$2 label=$3`,
		`  if [ ! -f "$from" ]; then printf '  skipped missing %s\n' "$label"; return 0; fi`,
		`  install -D -m 0644 "$from" "$to"`,
		`  printf '  copied file %s\n' "$label"`,
		"}",
		"copy_dir() {",
		`  local from=$1 to=$2 label=$3`,
		`  if [ ! -d "$from" ]; then printf '  skipped missing %s\n' "$label"; return 0; fi`,
		`  rm -rf "$to"`,
		`  mkdir -p "$to"`,
		`  cp -a "$from"/. "$to"/`,
		`  printf '  copied dir  %s\n' "$label"`,
		"}",
		"copy_optional_dir() {",
		`  local from=$1 to=$2 label=$3`,
		`  if [ ! -d "$from" ]; then printf '  skipped missing %s\n' "$label"; return 0; fi`,
		`  mkdir -p "$to"`,
		`  cp -a "$from"/. "$to"/`,
		`  printf '  merged dir %s\n' "$label"`,
		"}",
		"mirror_provider_profile() {",
		`  local provider_dir=$1 label=$2`,
		`  local from="$source_home/$provider_dir"`,
		`  local to="$home/$provider_dir"`,
		`  if [ "$source_home" = "$home" ]; then return 0; fi`,
		`  if [ ! -d "$from" ]; then printf '  provider profile missing, skipped %s\n' "$label"; return 0; fi`,
		`  mkdir -p "$to"`,
		`  rsync -a --delete \`,
		`    --exclude=.git/ \`,
		`    --exclude=.credentials.json \`,
		`    --exclude=credentials.json \`,
		`    --exclude=auth.json \`,
		`    --exclude='auth*' \`,
		`    --exclude='oauth*' \`,
		`    --exclude='token*' \`,
		`    --exclude=sessions/ \`,
		`    --exclude=session-env/ \`,
		`    --exclude=projects/ \`,
		`    --exclude=/cache/ \`,
		`    --exclude=plugins/cache/ \`,
		`    --exclude=logs/ \`,
		`    --exclude=backups/ \`,
		`    --exclude=shell-snapshots/ \`,
		`    --exclude=file-history/ \`,
		`    --exclude='history*' \`,
		`    --exclude='*.log' \`,
		`    "$from"/ "$to"/`,
		`  printf '  mirrored provider profile %s\n' "$label"`,
		"}",
		"write_claude_baseline() {",
		`  local home=$1`,
		`  mkdir -p "$home/.claude/bin"`,
		`  if [ ! -f "$home/.claude/settings.json" ]; then`,
		`    cat > "$home/.claude/settings.json" <<'CLAUDESETTINGS'`,
		`{`,
		`  "$schema": "https://json.schemastore.org/claude-code-settings.json",`,
		`  "permissions": {`,
		`    "allow": ["Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "MultiEdit(*)", "WebFetch(*)", "WebSearch(*)", "TodoRead(*)", "TodoWrite(*)", "Grep(*)", "Glob(*)", "LS(*)", "Task(*)", "mcp__*"]`,
		`  },`,
		`  "env": {`,
		`    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",`,
		`    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",`,
		`    "MAX_THINKING_TOKENS": "31999"`,
		`  },`,
		`  "alwaysThinkingEnabled": true,`,
		`  "enableRemoteControl": true,`,
		`  "statusLine": {"type": "command", "command": "~/.claude/bin/statusline-command.sh"},`,
		`  "enabledPlugins": {`,
		`    "superpowers@claude-plugins-official": true,`,
		`    "frontend-design@claude-plugins-official": true,`,
		`    "skill-creator@claude-plugins-official": true`,
		`  }`,
		`}`,
		`CLAUDESETTINGS`,
		`    printf '  wrote Claude settings\n'`,
		`  elif command -v python3 >/dev/null 2>&1; then`,
		`    python3 - "$home/.claude/settings.json" <<'MERGESETTINGS'`,
		`import json, sys`,
		`path = sys.argv[1]`,
		`try:`,
		`    data = json.loads(open(path).read())`,
		`except Exception:`,
		`    data = {}`,
		`required = ["Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "MultiEdit(*)", "WebFetch(*)", "WebSearch(*)", "TodoRead(*)", "TodoWrite(*)", "Grep(*)", "Glob(*)", "LS(*)", "Task(*)", "mcp__*"]`,
		`perms = data.setdefault("permissions", {})`,
		`allows = list(perms.get("allow", []))`,
		`for a in required:`,
		`    if a not in allows:`,
		`        allows.append(a)`,
		`perms["allow"] = allows`,
		`env = data.setdefault("env", {})`,
		`for k, v in {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1", "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000", "MAX_THINKING_TOKENS": "31999"}.items():`,
		`    env.setdefault(k, v)`,
		`data.setdefault("alwaysThinkingEnabled", True)`,
		`data.setdefault("enableRemoteControl", True)`,
		`sl = data.get("statusLine", {})`,
		`if not isinstance(sl, dict): sl = {"command": str(sl)}`,
		`sl.setdefault("type", "command")`,
		`sl.setdefault("command", "~/.claude/bin/statusline-command.sh")`,
		`data["statusLine"] = sl`,
		`ep = data.setdefault("enabledPlugins", {})`,
		`for k in ["superpowers@claude-plugins-official", "frontend-design@claude-plugins-official", "skill-creator@claude-plugins-official"]:`,
		`    ep.setdefault(k, True)`,
		`data.setdefault("$schema", "https://json.schemastore.org/claude-code-settings.json")`,
		`open(path, "w").write(json.dumps(data, indent=2) + "\n")`,
		`MERGESETTINGS`,
		`    printf '  merged Claude settings\n'`,
		`  fi`,
		`  if [ ! -f "$home/.claude/bin/statusline-command.sh" ]; then`,
		`    cat > "$home/.claude/bin/statusline-command.sh" <<'CLAUDESTATUSLINE'`,
		`#!/bin/bash`,
		`set -euo pipefail`,
		`INPUT=$(cat 2>/dev/null || echo '{}')`,
		`if command -v jq &>/dev/null; then`,
		`  MODEL=$(echo "$INPUT" | jq -r '.model.id // ""' 2>/dev/null | sed 's/claude-//;s/-[0-9]\{8\}.*//')`,
		`  THINKING=$(echo "$INPUT" | jq -r '.thinking.enabled // false' 2>/dev/null)`,
		`  CTX_USED=$(echo "$INPUT" | jq -r '.context.used // 0' 2>/dev/null)`,
		`  CTX_MAX=$(echo "$INPUT" | jq -r '.context.max // 200000' 2>/dev/null)`,
		`else`,
		`  MODEL="claude"; THINKING="false"; CTX_USED=0; CTX_MAX=200000`,
		`fi`,
		`[ -z "$MODEL" ] && MODEL="claude"`,
		`CTX_PCT=0`,
		`[ "$CTX_MAX" -gt 0 ] && CTX_PCT=$(( CTX_USED * 100 / CTX_MAX ))`,
		`CTX_WARN=""`,
		`[ $CTX_PCT -ge 85 ] && CTX_WARN="!!"`,
		`[ $CTX_PCT -ge 60 ] && [ $CTX_PCT -lt 85 ] && CTX_WARN="!"`,
		`THINK=""`,
		`[ "$THINKING" = "true" ] && THINK=" | think"`,
		`GIT_BRANCH=""`,
		`git rev-parse --is-inside-work-tree &>/dev/null 2>&1 && GIT_BRANCH=" ($(git branch --show-current 2>/dev/null || echo detached))"`,
		`DIR=$(pwd | sed "s|^$HOME|~|")`,
		`TIME=$(date +"%I:%M%p" | sed 's/^0//' | tr '[:upper:]' '[:lower:]')`,
		`echo "${USER}@$(hostname -s):${DIR}${GIT_BRANCH} [${MODEL}${THINK}] [ctx:${CTX_PCT}%${CTX_WARN}] ${TIME}"`,
		`CLAUDESTATUSLINE`,
		`    chmod +x "$home/.claude/bin/statusline-command.sh"`,
		`    printf '  wrote statusline\n'`,
		`  fi`,
		"}",
		"install_claude_plugins() {",
		`  local home=$1`,
		`  local cache="$home/.claude/plugins/cache/claude-plugins-official"`,
		`  mkdir -p "$cache"`,
		`  if [ ! -d "$cache/superpowers" ] || [ -z "$(ls -A "$cache/superpowers/5.1.0" 2>/dev/null)" ]; then`,
		`    rm -rf "$cache/superpowers"`,
		`    git clone --quiet --depth 1 --branch v5.1.0 https://github.com/obra/superpowers "$cache/superpowers/5.1.0" 2>/dev/null \`,
		`      && printf '  installed superpowers plugin\n' \`,
		`      || printf '  superpowers plugin install failed (network?)\n'`,
		`  fi`,
		`  need_cpo=0`,
		`  [ ! -d "$cache/frontend-design" ] && need_cpo=1`,
		`  [ ! -d "$cache/skill-creator" ] && need_cpo=1`,
		`  if [ "$need_cpo" -eq 1 ]; then`,
		`    tmp=$(mktemp -d)`,
		`    if git clone --quiet --depth 1 --filter=blob:none --sparse https://github.com/anthropics/claude-plugins-official "$tmp" 2>/dev/null; then`,
		`      git -C "$tmp" sparse-checkout set plugins/frontend-design plugins/skill-creator 2>/dev/null`,
		`      if [ ! -d "$cache/frontend-design" ] && [ -d "$tmp/plugins/frontend-design" ]; then`,
		`        mkdir -p "$cache/frontend-design"`,
		`        cp -r "$tmp/plugins/frontend-design" "$cache/frontend-design/unknown"`,
		`        printf '  installed frontend-design plugin\n'`,
		`      fi`,
		`      if [ ! -d "$cache/skill-creator" ] && [ -d "$tmp/plugins/skill-creator" ]; then`,
		`        mkdir -p "$cache/skill-creator"`,
		`        cp -r "$tmp/plugins/skill-creator" "$cache/skill-creator/unknown"`,
		`        printf '  installed skill-creator plugin\n'`,
		`      fi`,
		`    else`,
		`      printf '  anthropics plugin clone failed (network?)\n'`,
		`    fi`,
		`    rm -rf "$tmp"`,
		`  fi`,
		`  command -v python3 >/dev/null 2>&1 || return 0`,
		`  python3 - "$home" <<'REGISTRYGEN'`,
		`import json, os, sys, glob`,
		`from datetime import datetime, timezone`,
		`home = sys.argv[1]`,
		`cache = home + "/.claude/plugins/cache"`,
		`plugins = {}`,
		`now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")`,
		`for mkt_path in sorted(glob.glob(cache + "/*")):`,
		`    if not os.path.isdir(mkt_path): continue`,
		`    mkt = os.path.basename(mkt_path)`,
		`    for plugin_path in sorted(glob.glob(mkt_path + "/*")):`,
		`        if not os.path.isdir(plugin_path): continue`,
		`        plugin = os.path.basename(plugin_path)`,
		`        try: vdirs = sorted(d for d in os.listdir(plugin_path) if os.path.isdir(os.path.join(plugin_path, d)))`,
		`        except OSError: continue`,
		`        version = vdirs[0] if vdirs else "unknown"`,
		`        install_path = os.path.join(plugin_path, version) if vdirs else plugin_path`,
		`        plugins[plugin + "@" + mkt] = [{"scope": "user", "installPath": install_path, "version": version, "installedAt": now, "lastUpdated": now}]`,
		`open(home + "/.claude/plugins/installed_plugins.json", "w").write(json.dumps({"version": 2, "plugins": plugins, "enabledPlugins": {k: True for k in plugins}}, indent=2) + "\n")`,
		`known_file = home + "/.claude/plugins/known_marketplaces.json"`,
		`try:`,
		`    with open(known_file) as f: known = json.load(f)`,
		`except Exception: known = {}`,
		`for k in list(known):`,
		`    loc = known[k].get("installLocation", "")`,
		`    if loc and not loc.startswith(home + "/"): known[k]["installLocation"] = home + "/.claude/plugins/marketplaces/" + k`,
		`if "claude-plugins-official" not in known:`,
		`    known["claude-plugins-official"] = {"source": {"source": "github", "repo": "anthropics/claude-plugins-official"}, "installLocation": home + "/.claude/plugins/marketplaces/claude-plugins-official", "lastUpdated": now}`,
		`for k in known: os.makedirs(known[k].get("installLocation", ""), exist_ok=True)`,
		`open(known_file, "w").write(json.dumps(known, indent=2) + "\n")`,
		`REGISTRYGEN`,
		`  printf '  updated plugin registry\n'`,
		"}",
		"check_file() { test -f \"$1\" && printf '  ok file %s\\n' \"$1\" || { printf '  missing file %s\\n' \"$1\"; return 1; }; }",
		"check_dir() { test -d \"$1\" && printf '  ok dir  %s\\n' \"$1\" || { printf '  missing dir  %s\\n' \"$1\"; return 1; }; }",
		"check_exec() { test -x \"$1\" && printf '  ok exec %s\\n' \"$1\" || { printf '  missing exec %s\\n' \"$1\"; return 1; }; }",
		"sync_one() {",
		`  local target_user=$1`,
		`  local home`,
		`  home=$(getent passwd "$target_user" | cut -d: -f6)`,
		`  [ -n "$home" ] || { printf 'Unknown user: %s\n' "$target_user"; return 1; }`,
		`  printf '\nDirect Agent Config Sync\n'`,
		`  printf '  Source: %s (%s)\n' "$repo" "$ref"`,
		`  printf '  Account: %s\n' "$target_user"`,
		`  printf '  Home: %s\n\n' "$home"`,
		`  refresh_source`,
		`  mkdir -p "$home/.claude" "$home/.codex" "$home/.gemini" "$home/Templates"`,
		`  chgrp "$shared_group" "$home"`,
		`  chmod g+rx "$home"`,
		`  mirror_provider_profile ".claude" "Claude"`,
		`  mirror_provider_profile ".codex" "Codex"`,
		`  mirror_provider_profile ".gemini" "Gemini"`,
		`  copy_file "$src/claude/CLAUDE.md" "$home/.claude/CLAUDE.md" "Claude CLAUDE.md"`,
		`  copy_dir "$src/claude/rules" "$home/.claude/rules" "Claude rules"`,
		`  copy_optional_dir "$src/claude/plugins" "$home/.claude/plugins" "Claude default plugins"`,
		`  copy_optional_dir "$src/claude/skills" "$home/.claude/skills" "Claude default skills"`,
		`  copy_optional_dir "$src/claude/commands" "$home/.claude/commands" "Claude default commands"`,
		`  if [ -f "$src/claude/mcp.json" ]; then`,
		`    install -D -m 0644 "$src/claude/mcp.json" "$home/.claude/mcp.template.json"`,
		`    [ -f "$home/.claude/mcp.json" ] || install -D -m 0644 "$src/claude/mcp.json" "$home/.claude/mcp.json"`,
		`    printf '  copied file Claude MCP template\n'`,
		`  fi`,
		`  copy_file "$src/codex/AGENTS.md" "$home/.codex/AGENTS.md" "Codex AGENTS.md"`,
		`  copy_optional_dir "$src/codex/plugins" "$home/.codex/plugins" "Codex default plugins"`,
		`  copy_dir "$src/codex/skills" "$home/.codex/skills" "Codex skills"`,
		`  copy_file "$src/gemini/GEMINI.md" "$home/.gemini/GEMINI.md" "Gemini GEMINI.md"`,
		`  copy_dir "$src/gemini/skills" "$home/.gemini/skills" "Gemini skills"`,
		`  copy_dir "$src/templates" "$home/Templates" "project templates"`,
		`  write_claude_baseline "$home"`,
		`  install_claude_plugins "$home"`,
		`  chown -R "$target_user:$target_user" "$home/.claude" "$home/.codex" "$home/.gemini" "$home/Templates"`,
		`  printf '\nValidation:\n'`,
		`  check_file "$home/.claude/CLAUDE.md"`,
		`  check_file "$home/.claude/settings.json"`,
		`  check_exec "$home/.claude/bin/statusline-command.sh"`,
		`  check_dir "$home/.claude/rules"`,
		`  check_file "$home/.codex/AGENTS.md"`,
		`  check_dir "$home/.codex/skills"`,
		`  check_file "$home/.gemini/GEMINI.md"`,
		`  check_dir "$home/.gemini/skills"`,
		`  printf '\nCreated config inventory:\n'`,
		`  find "$home/.claude" "$home/.codex" "$home/.gemini" -maxdepth 3 \( -type f -o -type d \) 2>/dev/null | sort | sed 's/^/  /'`,
		"}",
		runLine,
	}, "\n")
}

func sharedProjectPermissionRepairCommand(projectsRoot, group string) string {
	quotedRoot := shellQuote(projectsRoot)
	quotedGroup := shellQuote(group)
	return strings.Join([]string{
		"sudo chown root:" + quotedGroup + " " + quotedRoot,
		"sudo chmod 2775 " + quotedRoot,
		"sudo chgrp -R " + quotedGroup + " " + quotedRoot,
		"sudo chmod -R g+rwX " + quotedRoot,
		"sudo find " + quotedRoot + " -type d -exec chmod g+s {} +",
		"for entry in " + quotedRoot + "/*; do if [ -L \"$entry\" ] && [ -d \"$entry\" ]; then sudo chgrp -R " + quotedGroup + " \"$entry\"/ && sudo chmod -R g+rwX \"$entry\"/ && sudo find \"$entry\"/ -type d -exec chmod g+s {} +; fi; done",
		"for proj in " + quotedRoot + "/*/; do [ -d \"$proj/.git\" ] && git -C \"$proj\" config core.sharedRepository group 2>/dev/null || true; done",
	}, " && ")
}

func BrowseFiles(path string) (FileListing, error) {
	if strings.TrimSpace(path) == "" {
		path = projectListingRoot()
	}
	cleaned, err := filepath.Abs(path)
	if err != nil {
		return FileListing{}, err
	}
	entries, err := listFilesWithError(cleaned, 500)
	if err != nil {
		return FileListing{}, err
	}
	return FileListing{
		Path:    cleaned,
		Parent:  filepath.Dir(cleaned),
		Entries: entries,
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

type BatchUploadEntry struct {
	RelPath string
	Reader  io.Reader
}

func safeRelPath(relPath string) (string, error) {
	if strings.TrimSpace(relPath) == "" {
		return "", errors.New("relative path is required")
	}
	if strings.Contains(relPath, "\x00") {
		return "", errors.New("relative path contains invalid characters")
	}
	cleaned := filepath.Clean(relPath)
	if filepath.IsAbs(cleaned) {
		return "", errors.New("relative path must not be absolute")
	}
	for _, part := range strings.Split(cleaned, string(filepath.Separator)) {
		if part == ".." {
			return "", errors.New("relative path must not contain ..")
		}
	}
	return cleaned, nil
}

func SaveUploadedFiles(destDir string, entries []BatchUploadEntry) ([]string, error) {
	if strings.TrimSpace(destDir) == "" {
		return nil, errors.New("destination directory is required")
	}
	cleanedDir, err := filepath.Abs(destDir)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(cleanedDir)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, errors.New("destination must be a directory")
	}
	var written []string
	for _, entry := range entries {
		cleanRel, err := safeRelPath(entry.RelPath)
		if err != nil {
			return nil, fmt.Errorf("invalid path %q: %w", entry.RelPath, err)
		}
		target := filepath.Join(cleanedDir, cleanRel)
		if !strings.HasPrefix(target+string(filepath.Separator), cleanedDir+string(filepath.Separator)) {
			return nil, fmt.Errorf("path %q escapes destination directory", entry.RelPath)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			return nil, err
		}
		n, copyErr := io.Copy(f, io.LimitReader(entry.Reader, 64*1024*1024+1))
		_ = f.Close()
		if copyErr != nil {
			return nil, copyErr
		}
		if n > 64*1024*1024 {
			_ = os.Remove(target)
			return nil, fmt.Errorf("file %q is larger than 64 MiB", entry.RelPath)
		}
		written = append(written, target)
	}
	return written, nil
}

func StreamZipDownload(w io.Writer, paths []string) error {
	if len(paths) == 0 {
		return errors.New("at least one path is required")
	}
	zw := zip.NewWriter(w)
	// Plain files are stored by basename; callers must ensure no two paths share the same base name.
	for _, p := range paths {
		cleanP, err := filepath.Abs(p)
		if err != nil {
			return err
		}
		info, err := os.Stat(cleanP)
		if err != nil {
			return err
		}
		if info.IsDir() {
			if err := addDirToZip(zw, cleanP); err != nil {
				return err
			}
		} else {
			if err := addFileToZip(zw, cleanP, filepath.Base(cleanP)); err != nil {
				return err
			}
		}
	}
	return zw.Close()
}

func addFileToZip(zw *zip.Writer, path, name string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	w, err := zw.Create(name)
	if err != nil {
		return err
	}
	_, err = io.Copy(w, f)
	return err
}

func addDirToZip(zw *zip.Writer, dir string) error {
	base := filepath.Dir(dir)
	return filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(base, path)
		if err != nil {
			return err
		}
		return addFileToZip(zw, path, rel)
	})
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
	projectsRoot := sharedProjectsRoot()
	if err := os.MkdirAll(projectsRoot, 0o775); err != nil {
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
		_, _ = RunShellCommand("git init && git config core.sharedRepository group", path)
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
	case "clone":
		remote, err := validateGitRemote(operation.Remote)
		if err != nil {
			return CommandResult{}, err
		}
		name := strings.TrimSpace(operation.Name)
		if name == "" {
			name, err = projectNameFromGitRemote(remote)
			if err != nil {
				return CommandResult{}, err
			}
		}
		if !safeProjectName(name) {
			return CommandResult{}, errors.New("invalid project name")
		}
		target := filepath.Join(projectsRoot, name)
		if _, err := os.Lstat(target); err == nil {
			return CommandResult{}, errors.New("project already exists")
		} else if !os.IsNotExist(err) {
			return CommandResult{}, err
		}
		result, err := RunShellCommand("git clone "+shellQuote(remote)+" "+shellQuote(target), projectsRoot)
		result = explainProjectGitFailure(result, remote)
		if err != nil {
			return result, err
		}
		if result.ExitCode != 0 {
			return result, errors.New("Git clone failed")
		}
		_, _ = RunShellCommand("git config core.sharedRepository group", target)
		return result, nil
	case "pull":
		projectPath, err := managedProjectPath(projectsRoot, operation.Name)
		if err != nil {
			return CommandResult{}, err
		}
		if !isGitWorktree(projectPath) {
			return CommandResult{}, errors.New("project is not a Git repository")
		}
		result, err := RunShellCommand("git pull --ff-only", projectPath)
		result = explainProjectGitFailure(result, "")
		if err != nil {
			return result, err
		}
		if result.ExitCode != 0 {
			return result, errors.New("Git pull failed")
		}
		return result, nil
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
	case "repair-permissions":
		group := os.Getenv("CCC_SHARED_GROUP")
		if strings.TrimSpace(group) == "" {
			group = "ccc"
		}
		return RunShellCommand(sharedProjectPermissionRepairCommand(projectsRoot, group), workstationHome())
	default:
		return CommandResult{}, fmt.Errorf("project operation %q is not allowed", operation.Operation)
	}
}

func collectProjectPermissionHealth() ProjectRootStatus {
	root := sharedProjectsRoot()
	status := ProjectRootStatus{Root: root, Summary: "missing"}
	info, err := os.Stat(root)
	if err != nil {
		return status
	}
	status.Exists = true
	status.Mode = info.Mode().String()
	status.GroupWritable = info.Mode().Perm()&0o020 != 0
	status.Setgid = info.Mode()&os.ModeSetgid != 0
	if status.GroupWritable && status.Setgid {
		status.Summary = "healthy"
	} else {
		status.Summary = "repair recommended"
	}
	return status
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

func managedProjectPath(projectsRoot, name string) (string, error) {
	if !safeProjectName(name) {
		return "", errors.New("invalid project name")
	}
	path := filepath.Join(projectsRoot, name)
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", errors.New("project path must be a directory")
	}
	return path, nil
}

func isGitWorktree(path string) bool {
	return strings.TrimSpace(gitText(path, "rev-parse", "--is-inside-work-tree")) == "true"
}

func explainProjectGitFailure(result CommandResult, remote string) CommandResult {
	result.Output = sanitizeGitOutput(result.Output)
	lower := strings.ToLower(result.Output)
	githubRemote := strings.Contains(remote, "github.com") || strings.Contains(lower, "github.com")
	if strings.Contains(lower, "permission denied (publickey)") && githubRemote {
		result.Output += "\n\nSSH auth note: authorize this workstation public key in Settings > GitHub before cloning GitHub SSH repositories."
	}
	if strings.Contains(lower, "authentication failed") || strings.Contains(lower, "could not read username") {
		result.Output += "\n\nHTTPS auth note: configure Git HTTPS credentials on this host or use an SSH remote."
	}
	return result
}

func sanitizeGitRemote(remote string) string {
	parsed, err := url.Parse(strings.TrimSpace(remote))
	if err == nil && parsed.Scheme != "" && parsed.User != nil {
		parsed.User = nil
		return parsed.String()
	}
	return strings.TrimSpace(remote)
}

func sanitizeGitOutput(output string) string {
	fields := strings.Fields(output)
	for _, field := range fields {
		clean := strings.Trim(field, "'\"")
		sanitized := sanitizeGitRemote(clean)
		if sanitized != clean {
			output = strings.ReplaceAll(output, clean, sanitized)
		}
	}
	return output
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
		{Name: "claude", Label: "Claude Code", Command: "claude", Version: "claude --version", Install: "curl -fsSL https://claude.ai/install.sh | bash", UpdateCheck: "claude update --check 2>/dev/null || echo 'No update detected.'", Description: "Anthropic Claude Code CLI"},
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

func collectSSHSessions() SSHSessionSummary {
	summary := parseWhoSSHSessions(runText("who"))
	if summary.Total > 0 {
		return summary
	}
	return parseSSHDSessionProcesses(runText("ps", "-eo", "args"))
}

func parseWhoSSHSessions(output string) SSHSessionSummary {
	counts := map[string]int{}
	total := 0
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		username := fields[0]
		tty := fields[1]
		if username == "" || !strings.HasPrefix(tty, "pts/") {
			continue
		}
		counts[username]++
		total++
	}
	return sshSessionSummaryFromCounts(counts, total)
}

func parseSSHDSessionProcesses(output string) SSHSessionSummary {
	counts := map[string]int{}
	total := 0
	for _, line := range strings.Split(output, "\n") {
		match := sshdUserTTYPattern.FindStringSubmatch(line)
		if len(match) != 2 {
			continue
		}
		username := match[1]
		counts[username]++
		total++
	}
	return sshSessionSummaryFromCounts(counts, total)
}

func sshSessionSummaryFromCounts(counts map[string]int, total int) SSHSessionSummary {
	users := make([]SSHUserSession, 0, len(counts))
	for username, count := range counts {
		users = append(users, SSHUserSession{Username: username, Count: count})
	}
	sort.Slice(users, func(i, j int) bool {
		if users[i].Count == users[j].Count {
			return users[i].Username < users[j].Username
		}
		return users[i].Count > users[j].Count
	})
	return SSHSessionSummary{
		Total:       total,
		UniqueUsers: len(users),
		Users:       users,
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
		home := fields[5]
		accounts = append(accounts, AccountStatus{
			Username:     fields[0],
			UID:          fields[2],
			Groups:       strings.TrimSpace(runText("id", "-nG", fields[0])),
			Home:         home,
			Shell:        fields[6],
			AgentConfigs: collectAgentConfigs(home),
			Plugins:      collectPluginStatus(home),
			TmuxSessions: ListTmuxSessions(fields[0]),
		})
	}
	return accounts
}

// parseTmuxOutput parses the output of:
//
//	tmux list-sessions -F "#{session_name}|#{session_windows}|#{session_attached}|#{session_activity}"
//
// nowUnix is used to compute IdleSeconds; pass time.Now().Unix() in production.
func parseTmuxOutput(output string, nowUnix int64) []TmuxSession {
	var sessions []TmuxSession
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		if line == "" {
			continue
		}
		parts := strings.Split(line, "|")
		if len(parts) != 4 {
			continue
		}
		windows, _ := strconv.Atoi(parts[1])
		attached, _ := strconv.Atoi(parts[2])
		activity, _ := strconv.ParseInt(parts[3], 10, 64)
		idle := 0
		if activity > 0 && nowUnix > activity {
			idle = int(nowUnix - activity)
		}
		sessions = append(sessions, TmuxSession{
			Name:            parts[0],
			Windows:         windows,
			AttachedClients: attached,
			IdleSeconds:     idle,
		})
	}
	return sessions
}

// ListTmuxSessions returns active tmux sessions for username.
// Returns an empty slice (never an error) if tmux has no server running.
func ListTmuxSessions(username string) []TmuxSession {
	cmd := exec.Command("sudo", "-u", username,
		"tmux", "list-sessions", "-F",
		"#{session_name}|#{session_windows}|#{session_attached}|#{session_activity}")
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			log.Printf("ListTmuxSessions(%s): unexpected error: %v", username, err)
		}
		return []TmuxSession{}
	}
	return parseTmuxOutput(string(out), time.Now().Unix())
}

var knownPlugins = []struct{ name, shortName string }{
	{"superpowers@claude-plugins-official", "Superpowers"},
	{"frontend-design@claude-plugins-official", "Frontend Design"},
	{"skill-creator@claude-plugins-official", "Skill Creator"},
}

func collectPluginStatus(home string) []PluginEntry {
	data, err := os.ReadFile(filepath.Join(home, ".claude", "settings.json"))
	var enabledPlugins map[string]bool
	if err == nil {
		var settings struct {
			EnabledPlugins map[string]bool `json:"enabledPlugins"`
		}
		if json.Unmarshal(data, &settings) == nil {
			enabledPlugins = settings.EnabledPlugins
		}
	}
	entries := make([]PluginEntry, len(knownPlugins))
	for i, p := range knownPlugins {
		entries[i] = PluginEntry{
			Name:      p.name,
			ShortName: p.shortName,
			Enabled:   enabledPlugins[p.name],
		}
	}
	return entries
}

func safePluginName(s string) bool {
	for _, c := range s {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '@' || c == '.') {
			return false
		}
	}
	return len(s) > 0 && len(s) <= 128
}


func collectUpdates() UpdateStatus {
	updateStatusMu.RLock()
	defer updateStatusMu.RUnlock()
	return cachedUpdateStatus
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
		gitRepo := isGitWorktree(path)
		projects = append(projects, ProjectStatus{
			Name:      entry.Name(),
			Path:      path,
			GitRepo:   gitRepo,
			GitBranch: gitText(path, "branch", "--show-current"),
			GitRemote: sanitizeGitRemote(gitText(path, "remote", "get-url", "origin")),
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
		{"Claude settings.json", filepath.Join(home, ".claude", "settings.json")},
		{"Claude statusline", filepath.Join(home, ".claude", "bin", "statusline-command.sh")},
		{"Claude rules", filepath.Join(home, ".claude", "rules")},
		{"Claude MCP", filepath.Join(home, ".claude", "mcp.json")},
		{"Claude MCP template", filepath.Join(home, ".claude", "mcp.template.json")},
		{"Codex AGENTS.md", filepath.Join(home, ".codex", "AGENTS.md")},
		{"Codex skills", filepath.Join(home, ".codex", "skills")},
		{"Gemini GEMINI.md", filepath.Join(home, ".gemini", "GEMINI.md")},
		{"Gemini skills", filepath.Join(home, ".gemini", "skills")},
		{"Project templates", filepath.Join(home, "Templates")},
	}
	configs := make([]AgentConfigFile, 0, len(paths))
	for _, item := range paths {
		info, err := os.Stat(item.path)
		configs = append(configs, AgentConfigFile{
			Name:   item.name,
			Path:   item.path,
			Exists: err == nil,
			Size:   fileSize(info, err),
			IsDir:  err == nil && info.IsDir(),
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
	files, err := listFilesWithError(root, limit)
	if err != nil {
		return nil
	}
	return files
}

func listFilesWithError(root string, limit int) ([]FileEntry, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
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
	return files, nil
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

func sharedProjectsRoot() string {
	if root := strings.TrimSpace(os.Getenv("CCC_SHARED_PROJECTS")); root != "" {
		return filepath.Clean(root)
	}
	return "/srv/ccc/projects"
}

func projectListingRoot() string {
	sharedRoot := sharedProjectsRoot()
	if directoryHasEntries(sharedRoot) {
		return sharedRoot
	}
	for _, root := range legacyProjectRoots() {
		if directoryHasEntries(root) {
			return root
		}
	}
	return sharedRoot
}

func legacyProjectRoots() []string {
	home := workstationHome()
	return []string{
		filepath.Join(home, "projects"),
		filepath.Join(home, "repos"),
	}
}

func directoryHasEntries(path string) bool {
	entries, err := os.ReadDir(path)
	return err == nil && len(entries) > 0
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
	return runText("git", gitCommandArgs(dir, args...)...)
}

func gitCommandArgs(dir string, args ...string) []string {
	gitArgs := []string{"-c", "safe.directory=" + dir, "-C", dir}
	gitArgs = append(gitArgs, args...)
	return gitArgs
}

func fileSize(info os.FileInfo, err error) int64 {
	if err != nil || info == nil {
		return 0
	}
	return info.Size()
}

type GitHubStatus struct {
	PublicKey         string   `json:"publicKey"`
	KeyExists         bool     `json:"keyExists"`
	KeyPath           string   `json:"keyPath"`
	TestOutput        string   `json:"testOutput,omitempty"`
	ConfiguredUsers   []string `json:"configuredUsers"`
	CurrentUserKey    string   `json:"currentUserKey,omitempty"`
	CurrentUserKeySet bool     `json:"currentUserKeyExists"`
}

func CollectGitHubStatus() (GitHubStatus, error) {
	keyPath := githubMachineKeyPath()
	pub, err := os.ReadFile(keyPath + ".pub")
	status := GitHubStatus{
		KeyPath:           keyPath,
		ConfiguredUsers:   githubConfiguredUsers(keyPath),
		CurrentUserKey:    filepath.Join(workstationHome(), ".ssh", "id_ed25519"),
		CurrentUserKeySet: fileExists(filepath.Join(workstationHome(), ".ssh", "id_ed25519.pub")),
	}
	if err != nil {
		return status, nil
	}
	status.KeyExists = true
	status.PublicKey = strings.TrimSpace(string(pub))
	return status, nil
}

func RunGitHubOperation(action string, usernames ...string) (CommandResult, error) {
	keyPath := githubMachineKeyPath()
	sshDir := filepath.Dir(keyPath)

	switch action {
	case "generate-key":
		if os.Getenv("CCC_GITHUB_KEY_PATH") == "" {
			group := os.Getenv("CCC_SHARED_GROUP")
			if strings.TrimSpace(group) == "" {
				group = "ccc"
			}
			command := strings.Join([]string{
				"sudo mkdir -p " + shellQuote(sshDir),
				"sudo chown root:" + shellQuote(group) + " " + shellQuote(sshDir),
				"sudo chmod 0750 " + shellQuote(sshDir),
				"sudo rm -f " + shellQuote(keyPath) + " " + shellQuote(keyPath+".pub"),
				"sudo ssh-keygen -t ed25519 -f " + shellQuote(keyPath) + " -N '' -C container-code-companion",
				"sudo chown root:" + shellQuote(group) + " " + shellQuote(keyPath) + " " + shellQuote(keyPath+".pub"),
				"sudo chmod 0640 " + shellQuote(keyPath),
				"sudo chmod 0644 " + shellQuote(keyPath+".pub"),
				"cat " + shellQuote(keyPath+".pub"),
			}, " && ")
			return RunShellCommand(command, workstationHome())
		}
		if err := prepareGitHubMachineKeyDir(sshDir); err != nil {
			return CommandResult{}, err
		}
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
		_ = os.Chmod(keyPath, 0o640)
		_ = os.Chmod(keyPath+".pub", 0o644)
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
	case "configure-users":
		if os.Getenv("CCC_GITHUB_KEY_PATH") == "" {
			return configureGitHubMachineKeyForUsersWithSudo(keyPath, usernames)
		}
		configured, err := configureGitHubMachineKeyForUsers(keyPath, usernames)
		if err != nil {
			return CommandResult{Command: "configure-users", Output: err.Error(), ExitCode: 1}, err
		}
		return CommandResult{Command: "configure-users", Output: "Configured GitHub SSH key for: " + strings.Join(configured, ", "), ExitCode: 0}, nil
	case "promote-current-user-key":
		source := filepath.Join(workstationHome(), ".ssh", "id_ed25519")
		if os.Getenv("CCC_GITHUB_KEY_PATH") == "" {
			group := os.Getenv("CCC_SHARED_GROUP")
			if strings.TrimSpace(group) == "" {
				group = "ccc"
			}
			command := strings.Join([]string{
				"test -f " + shellQuote(source),
				"test -f " + shellQuote(source+".pub"),
				"test ! -e " + shellQuote(keyPath),
				"test ! -e " + shellQuote(keyPath+".pub"),
				"sudo mkdir -p " + shellQuote(filepath.Dir(keyPath)),
				"sudo cp " + shellQuote(source) + " " + shellQuote(keyPath),
				"sudo cp " + shellQuote(source+".pub") + " " + shellQuote(keyPath+".pub"),
				"sudo chown root:" + shellQuote(group) + " " + shellQuote(keyPath) + " " + shellQuote(keyPath+".pub"),
				"sudo chmod 0640 " + shellQuote(keyPath),
				"sudo chmod 0644 " + shellQuote(keyPath+".pub"),
				"cat " + shellQuote(keyPath+".pub"),
			}, " && ")
			return RunShellCommand(command, workstationHome())
		}
		if err := promoteCurrentUserGitHubKey(source, keyPath); err != nil {
			return CommandResult{Command: "promote-current-user-key", Output: err.Error(), ExitCode: 1}, err
		}
		pub, _ := os.ReadFile(keyPath + ".pub")
		return CommandResult{Command: "promote-current-user-key", Output: strings.TrimSpace(string(pub)), ExitCode: 0}, nil

	default:
		return CommandResult{}, fmt.Errorf("action %q is not allowed", action)
	}
}

func githubMachineKeyPath() string {
	if path := strings.TrimSpace(os.Getenv("CCC_GITHUB_KEY_PATH")); path != "" {
		return filepath.Clean(path)
	}
	return "/etc/ccc/ssh/github_ed25519"
}

func prepareGitHubMachineKeyDir(path string) error {
	if err := os.MkdirAll(path, 0o750); err != nil {
		return err
	}
	return os.Chmod(path, 0o750)
}

func githubConfiguredUsers(keyPath string) []string {
	entries, err := os.ReadDir("/home")
	if err != nil {
		return nil
	}
	var users []string
	needle := "IdentityFile " + keyPath
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		configPath := filepath.Join("/home", entry.Name(), ".ssh", "config")
		content, err := os.ReadFile(configPath)
		if err == nil && strings.Contains(string(content), needle) {
			users = append(users, entry.Name())
		}
	}
	sort.Strings(users)
	return users
}

func configureGitHubMachineKeyForUsers(keyPath string, usernames []string) ([]string, error) {
	if len(usernames) == 0 {
		for _, account := range collectAccounts() {
			if account.Username != "" && account.Home != "" {
				usernames = append(usernames, account.Username)
			}
		}
	}
	var configured []string
	for _, username := range usernames {
		username = strings.TrimSpace(username)
		if username == "" {
			continue
		}
		u, err := user.Lookup(username)
		if err != nil {
			return configured, err
		}
		sshDir := filepath.Join(u.HomeDir, ".ssh")
		if err := os.MkdirAll(sshDir, 0o700); err != nil {
			return configured, err
		}
		config := "Host github.com\n  HostName github.com\n  User git\n  IdentityFile " + keyPath + "\n  IdentitiesOnly yes\n"
		if err := os.WriteFile(filepath.Join(sshDir, "config"), []byte(config), 0o600); err != nil {
			return configured, err
		}
		configured = append(configured, username)
	}
	return configured, nil
}

func configureGitHubMachineKeyForUsersWithSudo(keyPath string, usernames []string) (CommandResult, error) {
	if len(usernames) == 0 {
		for _, account := range collectAccounts() {
			if account.Username != "" {
				usernames = append(usernames, account.Username)
			}
		}
	}
	var commands []string
	var configured []string
	config := "Host github.com\n  HostName github.com\n  User git\n  IdentityFile " + keyPath + "\n  IdentitiesOnly yes\n"
	for _, username := range usernames {
		username = strings.TrimSpace(username)
		if !safeProjectName(username) {
			continue
		}
		u, err := user.Lookup(username)
		if err != nil {
			return CommandResult{Command: "configure-users", Output: err.Error(), ExitCode: 1}, err
		}
		sshDir := filepath.Join(u.HomeDir, ".ssh")
		configPath := filepath.Join(sshDir, "config")
		commands = append(commands,
			"sudo mkdir -p "+shellQuote(sshDir),
			"printf %s "+shellQuote(config)+" | sudo tee "+shellQuote(configPath)+" >/dev/null",
			"sudo chown -R "+shellQuote(username+":"+username)+" "+shellQuote(sshDir),
			"sudo chmod 0700 "+shellQuote(sshDir),
			"sudo chmod 0600 "+shellQuote(configPath),
		)
		configured = append(configured, username)
	}
	if len(commands) == 0 {
		return CommandResult{Command: "configure-users", Output: "No valid work identities selected.", ExitCode: 1}, errors.New("no valid work identities selected")
	}
	result, err := RunShellCommand(strings.Join(commands, " && "), workstationHome())
	if err != nil {
		return result, err
	}
	result.Command = "configure-users"
	result.Output = strings.TrimSpace(result.Output)
	if result.ExitCode == 0 {
		result.Output = "Configured GitHub SSH key for: " + strings.Join(configured, ", ")
	}
	return result, nil
}

func promoteCurrentUserGitHubKey(source, target string) error {
	if !fileExists(source) || !fileExists(source+".pub") {
		return errors.New("current user key pair not found")
	}
	if fileExists(target) || fileExists(target+".pub") {
		return errors.New("managed machine key already exists")
	}
	if err := prepareGitHubMachineKeyDir(filepath.Dir(target)); err != nil {
		return err
	}
	privateKey, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	publicKey, err := os.ReadFile(source + ".pub")
	if err != nil {
		return err
	}
	if err := os.WriteFile(target, privateKey, 0o640); err != nil {
		return err
	}
	return os.WriteFile(target+".pub", publicKey, 0o644)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
