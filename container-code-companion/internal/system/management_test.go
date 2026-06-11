package system

import (
	"archive/zip"
	"bytes"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSharedProjectsRootDefaultsToSrvCCCProjects(t *testing.T) {
	t.Setenv("CCC_SHARED_PROJECTS", "")
	if got := sharedProjectsRoot(); got != "/srv/ccc/projects" {
		t.Fatalf("sharedProjectsRoot() = %q, want /srv/ccc/projects", got)
	}
}

func TestGitHubMachineKeyPathDefaultsToEtcCCCSSH(t *testing.T) {
	t.Setenv("CCC_GITHUB_KEY_PATH", "")
	if got := githubMachineKeyPath(); got != "/etc/ccc/ssh/github_ed25519" {
		t.Fatalf("githubMachineKeyPath() = %q, want /etc/ccc/ssh/github_ed25519", got)
	}
}

func TestCollectGitHubStatusUsesManagedMachineKey(t *testing.T) {
	keyPath := filepath.Join(t.TempDir(), "github_ed25519")
	t.Setenv("CCC_GITHUB_KEY_PATH", keyPath)
	if err := os.WriteFile(keyPath+".pub", []byte("ssh-ed25519 AAAATEST managed-key\n"), 0o644); err != nil {
		t.Fatalf("write public key: %v", err)
	}

	status, err := CollectGitHubStatus()
	if err != nil {
		t.Fatalf("collect github status: %v", err)
	}
	if !status.KeyExists {
		t.Fatal("expected managed key to exist")
	}
	if status.KeyPath != keyPath {
		t.Fatalf("KeyPath = %q, want %q", status.KeyPath, keyPath)
	}
	if status.PublicKey != "ssh-ed25519 AAAATEST managed-key" {
		t.Fatalf("unexpected public key: %q", status.PublicKey)
	}
}

func TestSetupCCCProfileCommandIncludesSharedWorkspaceAndAgentSync(t *testing.T) {
	command := setupCCCProfileCommand("work-id")
	for _, want := range []string{
		"id -u 'work-id'",
		"sudo usermod -aG 'ccc' 'work-id'",
		// The web UI service user reads other accounts' settings.json without
		// sudo (server-side Claude options page), so homes stay group-readable.
		"sudo chgrp 'ccc' '/home/work-id'",
		"sudo chmod g+rx '/home/work-id'",
		"sudo ln -sfn '/srv/ccc/projects' '/home/work-id/projects'",
		"sudo mkdir -p '/home/work-id/.claude' '/home/work-id/.codex' '/home/work-id/.gemini'",
		"/usr/local/bin/ccc-sync-agent-configs --user 'work-id'",
		"curl -fsSL https://claude.ai/install.sh | bash",
		"sudo test -x '/home/work-id/.local/bin/claude'",
		"test -x /usr/local/ccc-npm/bin/codex",
		"test -x /usr/local/ccc-npm/bin/gemini",
		"sudo chgrp -R 'ccc' '/srv/ccc/projects'",
		"if [ -L \"$entry\" ] && [ -d \"$entry\" ]; then sudo chgrp -R 'ccc' \"$entry\"/",
		"IdentityFile /etc/ccc/ssh/github_ed25519",
	} {
		if !strings.Contains(command, want) {
			t.Fatalf("setup command missing %q:\n%s", want, command)
		}
	}
	// Codex/Gemini are shared from /usr/local/ccc-npm; shell env is machine-wide
	// (/etc/profile.d + /etc/ccc/ccc-shell.sh). No per-user installs or .bashrc
	// appends.
	for _, reject := range []string{
		"npm install -g --prefix '/home/work-id/.local'",
		"tee -a '/home/work-id/.bashrc'",
	} {
		if strings.Contains(command, reject) {
			t.Fatalf("setup command must not contain %q:\n%s", reject, command)
		}
	}
}

// provisionerText reads the workstation provisioner — the single source of
// truth for the agent config sync logic the web UI delegates to.
func provisionerText(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "install", "ccc-provision-workstation.sh"))
	if err != nil {
		t.Fatalf("read provisioner: %v", err)
	}
	return string(data)
}

// provisionerSyncScript extracts the ccc-sync-agent-configs heredoc body from
// the provisioner's updateable section.
func provisionerSyncScript(t *testing.T) string {
	t.Helper()
	text := provisionerText(t)
	start := strings.Index(text, "<< 'AGENTCONFIGSYNCSCRIPT'")
	end := strings.Index(text, "\nAGENTCONFIGSYNCSCRIPT\n")
	if start < 0 || end < 0 || end < start {
		t.Fatal("AGENTCONFIGSYNCSCRIPT heredoc not found in provisioner")
	}
	return text[start:end]
}

func TestAgentConfigSyncCommandDelegatesToInstalledScript(t *testing.T) {
	command := agentConfigSyncCommand("work-id")
	for _, want := range []string{
		"sudo",
		"/usr/local/bin/ccc-sync-agent-configs",
		"--user 'work-id'",
	} {
		if !strings.Contains(command, want) {
			t.Fatalf("agent sync command missing %q:\n%s", want, command)
		}
	}
}

func TestProvisionerSyncScriptCoversExpectedFilesAndSkills(t *testing.T) {
	script := provisionerSyncScript(t)
	for _, want := range []string{
		`copy_managed_file "$OCULUS_CONFIGS_DIR/claude/CLAUDE.md" "$CCC_HOME/.claude/CLAUDE.md"`,
		`copy_optional_dir "$OCULUS_CONFIGS_DIR/claude/plugins" "$CCC_HOME/.claude/plugins"`,
		`copy_optional_dir "$OCULUS_CONFIGS_DIR/claude/skills" "$CCC_HOME/.claude/skills"`,
		`copy_optional_dir "$OCULUS_CONFIGS_DIR/claude/commands" "$CCC_HOME/.claude/commands"`,
		`copy_managed_file "$OCULUS_CONFIGS_DIR/codex/AGENTS.md" "$CCC_HOME/.codex/AGENTS.md"`,
		`copy_optional_dir "$OCULUS_CONFIGS_DIR/codex/skills" "$CCC_HOME/.codex/skills"`,
		`copy_managed_file "$OCULUS_CONFIGS_DIR/gemini/GEMINI.md" "$CCC_HOME/.gemini/GEMINI.md"`,
		`copy_optional_dir "$OCULUS_CONFIGS_DIR/gemini/skills" "$CCC_HOME/.gemini/skills"`,
		"write_claude_baseline",
		"install_claude_plugins",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("provisioner sync script missing %q", want)
		}
	}
}

func TestSelfUpdateRunsAgentConfigSyncForCurrentUser(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "install", "ccc-provision-workstation.sh"))
	if err != nil {
		t.Fatalf("read provisioner: %v", err)
	}
	text := string(data)
	// The 4-step self-update syncs web assets (step 3), then runs agent config
	// sync, then records the version and restarts (step 4).
	assetsIndex := strings.Index(text, `Syncing web assets`)
	syncIndex := -1
	if assetsIndex >= 0 {
		nextSync := strings.Index(text[assetsIndex:], `ccc-sync-agent-configs`)
		if nextSync >= 0 {
			syncIndex = assetsIndex + nextSync
		}
	}
	finalIndex := strings.Index(text, `Recording version and restarting service`)
	if assetsIndex < 0 || syncIndex < 0 || finalIndex < 0 {
		t.Fatalf("expected self-update asset sync, agent config sync, and version/restart markers")
	}
	if !(assetsIndex < syncIndex && syncIndex < finalIndex) {
		t.Fatalf("expected ccc-sync-agent-configs to run after web asset sync and before version/restart")
	}
}

func TestAgentConfigSyncNeverMirrorsProviderProfiles(t *testing.T) {
	// One person, many provider accounts: each account owns its ~/.claude,
	// ~/.codex, ~/.gemini state (auth, history, UI prefs). Shared baseline
	// flows from oculus-configs only — never by mirroring another account.
	if strings.Contains(provisionerSyncScript(t), "mirror_provider_profile") {
		t.Fatal("sync script must not mirror provider profiles between accounts")
	}
	if strings.Contains(agentConfigSyncCommand("work-id"), "rsync") {
		t.Fatal("agent sync command must not rsync provider profiles")
	}
}

func TestGitCommandArgsMarksRepositorySafe(t *testing.T) {
	args := gitCommandArgs("/opt/oculus-configs", "status", "--short")
	got := strings.Join(args, " ")
	for _, want := range []string{
		"-c safe.directory=/opt/oculus-configs",
		"-C /opt/oculus-configs",
		"status --short",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("git args missing %q: %q", want, got)
		}
	}
}

func TestAllAgentConfigSyncCommandSyncsAllUsers(t *testing.T) {
	command := allAgentConfigSyncCommand()
	for _, want := range []string{
		"sudo",
		"/usr/local/bin/ccc-sync-agent-configs",
		"--all-users",
	} {
		if !strings.Contains(command, want) {
			t.Fatalf("allAgentConfigSyncCommand() missing %q:\n%s", want, command)
		}
	}
	script := provisionerSyncScript(t)
	if !strings.Contains(script, "--all-users") || !strings.Contains(script, "getent passwd") {
		t.Fatal("installed sync script must implement --all-users via a getent user loop")
	}
}

func TestBrowseFilesReturnsUnreadableDirectoryError(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatalf("mkdir private dir: %v", err)
	}
	if err := os.Chmod(dir, 0); err != nil {
		t.Fatalf("chmod private dir: %v", err)
	}
	defer os.Chmod(dir, 0o700)

	_, err := BrowseFiles(dir)
	if err == nil {
		t.Fatal("expected unreadable directory error")
	}
	if !strings.Contains(err.Error(), "permission denied") {
		t.Fatalf("expected permission denied error, got %v", err)
	}
}

func TestSharedProjectPermissionRepairCommandFollowsTopLevelSymlinkedProjects(t *testing.T) {
	command := sharedProjectPermissionRepairCommand("/srv/ccc/projects", "ccc")
	for _, want := range []string{
		"sudo chown root:'ccc' '/srv/ccc/projects'",
		"sudo chgrp -R 'ccc' '/srv/ccc/projects'",
		"sudo chmod -R g+rwX '/srv/ccc/projects'",
		"for entry in '/srv/ccc/projects'/*;",
		"if [ -L \"$entry\" ] && [ -d \"$entry\" ]; then sudo chgrp -R 'ccc' \"$entry\"/",
		"sudo chmod -R g+rwX \"$entry\"/",
		"sudo find \"$entry\"/ -type d -exec chmod g+s {} +",
		"core.sharedRepository group",
	} {
		if !strings.Contains(command, want) {
			t.Fatalf("repair command missing %q:\n%s", want, command)
		}
	}
}

func TestCollectAgentConfigsIncludesSyncedSkillDirectories(t *testing.T) {
	home := t.TempDir()
	for _, path := range []string{
		filepath.Join(home, ".claude", "CLAUDE.md"),
		filepath.Join(home, ".claude", "settings.json"),
		filepath.Join(home, ".claude", "bin", "statusline-command.sh"),
		filepath.Join(home, ".claude", "rules"),
		filepath.Join(home, ".codex", "AGENTS.md"),
		filepath.Join(home, ".codex", "skills"),
		filepath.Join(home, ".gemini", "GEMINI.md"),
		filepath.Join(home, ".gemini", "skills"),
	} {
		if strings.HasSuffix(path, ".md") || strings.HasSuffix(path, ".json") || strings.HasSuffix(path, "statusline-command.sh") {
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
			}
			if err := os.WriteFile(path, []byte("managed config\n"), 0o644); err != nil {
				t.Fatalf("write %s: %v", path, err)
			}
			continue
		}
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", path, err)
		}
	}

	configs := collectAgentConfigs(home)
	names := map[string]bool{}
	for _, config := range configs {
		if config.Exists {
			names[config.Name] = true
		}
	}
	for _, want := range []string{"Claude settings.json", "Claude statusline", "Claude rules", "Codex skills", "Gemini skills"} {
		if !names[want] {
			t.Fatalf("expected existing config %q in %#v", want, configs)
		}
	}
}

func TestParseWhoSSHSessionsGroupsDuplicateUsers(t *testing.T) {
	input := strings.Join([]string{
		"oculus   pts/0        2026-05-24 09:15 (192.0.2.10)",
		"claude   pts/1        2026-05-24 09:20 (198.51.100.7)",
		"oculus   pts/2        2026-05-24 09:25 (192.0.2.10)",
		"reboot   system boot  2026-05-24 09:00",
	}, "\n")

	summary := parseWhoSSHSessions(input)

	if summary.Total != 3 {
		t.Fatalf("Total = %d, want 3", summary.Total)
	}
	if summary.UniqueUsers != 2 {
		t.Fatalf("UniqueUsers = %d, want 2", summary.UniqueUsers)
	}
	if len(summary.Users) != 2 {
		t.Fatalf("Users length = %d, want 2: %#v", len(summary.Users), summary.Users)
	}
	if summary.Users[0].Username != "oculus" || summary.Users[0].Count != 2 {
		t.Fatalf("first user = %#v, want oculus x2", summary.Users[0])
	}
	if summary.Users[1].Username != "claude" || summary.Users[1].Count != 1 {
		t.Fatalf("second user = %#v, want claude x1", summary.Users[1])
	}
}

func TestParseSSHDSessionProcessesGroupsDuplicateUsers(t *testing.T) {
	input := strings.Join([]string{
		"root        100       1 Ss   sshd: oculus [priv]",
		"oculus      101     100 S    sshd: oculus@pts/0",
		"root        102       1 Ss   sshd: claude [priv]",
		"claude      103     102 S    sshd: claude@pts/1",
		"root        104       1 Ss   sshd: oculus [priv]",
		"oculus      105     104 S    sshd: oculus@pts/2",
	}, "\n")

	summary := parseSSHDSessionProcesses(input)

	if summary.Total != 3 {
		t.Fatalf("Total = %d, want 3", summary.Total)
	}
	if summary.UniqueUsers != 2 {
		t.Fatalf("UniqueUsers = %d, want 2", summary.UniqueUsers)
	}
	if summary.Users[0].Username != "oculus" || summary.Users[0].Count != 2 {
		t.Fatalf("first user = %#v, want oculus x2", summary.Users[0])
	}
	if summary.Users[1].Username != "claude" || summary.Users[1].Count != 1 {
		t.Fatalf("second user = %#v, want claude x1", summary.Users[1])
	}
}

func TestParseSSHDSessionProcessesSupportsOpenSSHSessionProcessName(t *testing.T) {
	input := strings.Join([]string{
		"root        200       1 Ss   sshd-session: oculus [priv]",
		"oculus      201     200 S    sshd-session: oculus@pts/0",
		"oculus      202     201 S    sshd-session: oculus@notty",
	}, "\n")

	summary := parseSSHDSessionProcesses(input)

	if summary.Total != 2 {
		t.Fatalf("Total = %d, want 2", summary.Total)
	}
	if summary.UniqueUsers != 1 {
		t.Fatalf("UniqueUsers = %d, want 1", summary.UniqueUsers)
	}
	if summary.Users[0].Username != "oculus" || summary.Users[0].Count != 2 {
		t.Fatalf("user = %#v, want oculus x2", summary.Users[0])
	}
}

func TestRunProjectOperationCreatesProjectUnderSharedRoot(t *testing.T) {
	home := t.TempDir()
	sharedRoot := filepath.Join(t.TempDir(), "shared-projects")
	t.Setenv("HOME", home)
	t.Setenv("CCC_SHARED_PROJECTS", sharedRoot)

	result, err := RunProjectOperation(ProjectOperation{Operation: "create", Name: "demo"})
	if err != nil {
		t.Fatalf("create project: %v", err)
	}
	if result.Output != "created demo" {
		t.Fatalf("unexpected output: %#v", result)
	}
	if _, err := os.Stat(filepath.Join(sharedRoot, "demo", ".git")); err != nil {
		t.Fatalf("expected project git repo under shared root: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, "projects", "demo")); !os.IsNotExist(err) {
		t.Fatalf("expected home projects path to remain unused, got err %v", err)
	}
}

func TestRunProjectOperationCloneTargetsSharedRoot(t *testing.T) {
	home := t.TempDir()
	sharedRoot := filepath.Join(t.TempDir(), "shared-projects")
	t.Setenv("HOME", home)
	t.Setenv("CCC_SHARED_PROJECTS", sharedRoot)

	target := filepath.Join(sharedRoot, "CCC")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create existing target: %v", err)
	}
	_, err := RunProjectOperation(ProjectOperation{
		Operation: "clone",
		Remote:    "https://github.com/oculus-pllx/CCC.git",
	})
	if err == nil || !strings.Contains(err.Error(), "project already exists") {
		t.Fatalf("expected clone target collision in shared root, got %v", err)
	}
}

func TestProjectPermissionHealthReportsSharedRoot(t *testing.T) {
	sharedRoot := filepath.Join(t.TempDir(), "shared-projects")
	t.Setenv("CCC_SHARED_PROJECTS", sharedRoot)
	if err := os.MkdirAll(sharedRoot, 0o775); err != nil {
		t.Fatalf("create shared root: %v", err)
	}

	health := collectProjectPermissionHealth()
	if health.Root != sharedRoot {
		t.Fatalf("Root = %q, want %q", health.Root, sharedRoot)
	}
	if !health.Exists {
		t.Fatal("expected shared root to exist")
	}
}

func TestProjectListingRootFallsBackToLegacyReposWhenSharedRootEmpty(t *testing.T) {
	home := t.TempDir()
	sharedRoot := filepath.Join(t.TempDir(), "shared-projects")
	legacyRoot := filepath.Join(home, "repos")
	t.Setenv("HOME", home)
	t.Setenv("CCC_SHARED_PROJECTS", sharedRoot)
	if err := os.MkdirAll(sharedRoot, 0o775); err != nil {
		t.Fatalf("create shared root: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(legacyRoot, "demo"), 0o755); err != nil {
		t.Fatalf("create legacy repo: %v", err)
	}

	if got := projectListingRoot(); got != legacyRoot {
		t.Fatalf("projectListingRoot() = %q, want %q", got, legacyRoot)
	}
}

func TestRunProjectOperationAddsExistingDirectoryAsProjectLink(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CCC_SHARED_PROJECTS", filepath.Join(home, "projects"))
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
	t.Setenv("CCC_SHARED_PROJECTS", filepath.Join(home, "projects"))
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
	t.Setenv("CCC_SHARED_PROJECTS", filepath.Join(home, "projects"))
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
	t.Setenv("CCC_SHARED_PROJECTS", filepath.Join(home, "projects"))
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
	t.Setenv("CCC_SHARED_PROJECTS", filepath.Join(home, "projects"))
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

func TestExplainProjectGitFailureUsesGitHubOutputForPullGuidance(t *testing.T) {
	result := explainProjectGitFailure(CommandResult{
		Output: "git@github.com: Permission denied (publickey).",
	}, "")
	if !strings.Contains(result.Output, "Settings > GitHub") {
		t.Fatalf("expected GitHub SSH guidance, got %q", result.Output)
	}
}

func TestAgentConfigSyncCopyFileSkipsMissingSource(t *testing.T) {
	if !strings.Contains(provisionerSyncScript(t), `if [[ ! -f "$src" ]]`) {
		t.Fatal("copy_managed_file must skip gracefully when the source file is missing")
	}
}

func TestAgentConfigSyncCopyDirSkipsMissingSource(t *testing.T) {
	if !strings.Contains(provisionerSyncScript(t), `if [[ ! -d "$src" ]]`) {
		t.Fatal("copy_optional_dir must skip gracefully when the source dir is missing")
	}
}

func TestExplainProjectGitFailureSanitizesCredentialedHTTPSOutput(t *testing.T) {
	result := explainProjectGitFailure(CommandResult{
		Output: "fatal: https://user:secret@git.example.test/owner/repo.git authentication failed",
	}, "")
	if strings.Contains(result.Output, "user:secret") {
		t.Fatalf("expected credentialed remote to be sanitized, got %q", result.Output)
	}
}

func TestStartUpdateStatusPollerDoesNotBlock(t *testing.T) {
	// Poller must return immediately (it starts a goroutine)
	done := make(chan struct{})
	go func() {
		StartUpdateStatusPoller(24 * time.Hour) // long interval — won't fire in test
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("StartUpdateStatusPoller blocked for >500ms; it must start a goroutine and return")
	}
}

func TestCollectUpdatesReturnsImmediately(t *testing.T) {
	start := time.Now()
	_ = collectUpdates()
	if time.Since(start) > 100*time.Millisecond {
		t.Fatalf("collectUpdates took %v; must return cached data immediately without blocking", time.Since(start))
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

func TestNodeInstallDoesNotPullDebianNPM(t *testing.T) {
	command, err := toolInstallCommand("nodejs")
	if err != nil {
		t.Fatalf("expected nodejs install command: %v", err)
	}
	// NodeSource's nodejs package bundles npm and declares Conflicts: npm,
	// so installing Debian's separate npm package alongside it always fails.
	if strings.Contains(command, "npm") {
		t.Fatalf("nodejs install must not reference the npm apt package, got %q", command)
	}
}

func TestProviderNPMToolsInstallToUserPrefix(t *testing.T) {
	for _, tool := range []string{"gemini"} {
		command, err := toolInstallCommand(tool)
		if err != nil {
			t.Fatalf("expected %s install command: %v", tool, err)
		}
		if !strings.Contains(command, `--prefix "$HOME/.local"`) {
			t.Fatalf("expected %s to install under user npm prefix, got %q", tool, command)
		}
	}
	// Claude uses the official binary installer, not npm
	claudeCmd, err := toolInstallCommand("claude")
	if err != nil {
		t.Fatalf("expected claude install command: %v", err)
	}
	if !strings.Contains(claudeCmd, "claude.ai/install.sh") {
		t.Fatalf("expected claude to use binary installer, got %q", claudeCmd)
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

func TestAgentConfigSyncBaselinePreservesExistingSettings(t *testing.T) {
	script := provisionerSyncScript(t)
	if !strings.Contains(script, `if [[ ! -f "$CCC_HOME/.claude/settings.json" ]]`) {
		t.Fatal("write_claude_baseline must check if settings.json exists before writing")
	}
}

func TestAgentConfigSyncBaselineMergesSettingsWithPython(t *testing.T) {
	script := provisionerSyncScript(t)
	if !strings.Contains(script, "python3") {
		t.Fatal("write_claude_baseline must use python3 to merge settings.json when file exists")
	}
	if !strings.Contains(script, `perms.get("allow"`) {
		t.Fatal("write_claude_baseline python merge must scrub the legacy allow list, not blind-overwrite")
	}
	if !strings.Contains(script, `"defaultMode": "bypassPermissions"`) {
		t.Fatal("baseline settings must use permissions.defaultMode (tool-glob allowlists were never valid)")
	}
	if !strings.Contains(script, `Bash(*)`) {
		t.Fatal("python merge must strip the legacy invalid Bash(*)-style allow entries")
	}
}

func TestAgentConfigSyncBaselineStatuslineShowsModel(t *testing.T) {
	script := provisionerSyncScript(t)
	if strings.Contains(script, `echo "${USER}@$(hostname -s):$(pwd`) {
		t.Fatal("write_claude_baseline statusline is the minimal one-liner; must use full statusline with model/context")
	}
	if !strings.Contains(script, "jq") {
		t.Fatal("write_claude_baseline statusline must use jq for model/thinking/context extraction")
	}
	if !strings.Contains(script, "CTX_PCT") {
		t.Fatal("write_claude_baseline statusline must show context percentage")
	}
}

func TestAgentConfigSyncOptionalDirMergesNotReplaces(t *testing.T) {
	script := provisionerSyncScript(t)
	start := strings.Index(script, "copy_optional_dir() {")
	if start < 0 {
		t.Fatal("copy_optional_dir function not found in sync script")
	}
	end := strings.Index(script[start:], "\n}")
	if end < 0 {
		t.Fatal("copy_optional_dir function body not terminated")
	}
	funcBody := script[start : start+end]
	if strings.Contains(funcBody, "rm -rf") {
		t.Fatal("copy_optional_dir must not rm -rf destination (use merge, not replace)")
	}
}

func TestAgentConfigSyncPluginsWritesKnownMarketplaces(t *testing.T) {
	script := provisionerSyncScript(t)
	if !strings.Contains(script, "known_marketplaces.json") {
		t.Fatal("install_claude_plugins must write known_marketplaces.json")
	}
	if !strings.Contains(script, "claude-plugins-official") {
		t.Fatal("install_claude_plugins must register claude-plugins-official marketplace")
	}
}

func TestAgentConfigSyncPluginsFixesWrongHomePaths(t *testing.T) {
	script := provisionerSyncScript(t)
	if !strings.Contains(script, `not loc.startswith(home + "/")`) {
		t.Fatal("install_claude_plugins must detect and fix marketplace paths from a different user's home")
	}
}

func TestAgentConfigSyncPluginsReclonesEmptySuperpowers(t *testing.T) {
	script := provisionerSyncScript(t)
	// Guard must also re-clone when the 5.1.0 dir exists but is empty
	if !strings.Contains(script, `ls -A "$cache/superpowers/5.1.0"`) {
		t.Fatal("install_claude_plugins must re-clone superpowers when the 5.1.0 directory is empty")
	}
	if !strings.Contains(script, `rm -rf "$cache/superpowers"`) {
		t.Fatal("install_claude_plugins must remove stale superpowers dir before re-cloning")
	}
}

func TestFormatScheduleLabelDaily(t *testing.T) {
	got := formatScheduleLabel("daily", 3)
	if got != "Daily @ 3 AM" {
		t.Fatalf("got %q, want %q", got, "Daily @ 3 AM")
	}
}

func TestFormatScheduleLabelEvery2Days(t *testing.T) {
	got := formatScheduleLabel("every2days", 14)
	if got != "Every 2 days @ 2 PM" {
		t.Fatalf("got %q, want %q", got, "Every 2 days @ 2 PM")
	}
}

func TestFormatScheduleLabelWeekly(t *testing.T) {
	got := formatScheduleLabel("weekly-0", 3)
	if got != "Weekly (Sun) @ 3 AM" {
		t.Fatalf("got %q, want %q", got, "Weekly (Sun) @ 3 AM")
	}
	got = formatScheduleLabel("weekly-1", 0)
	if got != "Weekly (Mon) @ 12 AM" {
		t.Fatalf("got %q, want %q", got, "Weekly (Mon) @ 12 AM")
	}
}

func TestReadAutoUpdateScheduleDefaults(t *testing.T) {
	label := formatScheduleLabel("daily", 3)
	if label != "Daily @ 3 AM" {
		t.Fatalf("default label = %q, want %q", label, "Daily @ 3 AM")
	}
}

func TestAutoUpdateCronInProvisioner(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "install", "ccc-provision-workstation.sh"))
	if err != nil {
		t.Fatalf("read provisioner: %v", err)
	}
	text := string(data)
	if !strings.Contains(text, "ccc-auto-update") {
		t.Fatal("provisioner must install ccc-auto-update script")
	}
	if !strings.Contains(text, "/usr/local/bin/ccc-auto-update") {
		t.Fatal("provisioner cron must call /usr/local/bin/ccc-auto-update")
	}
	if strings.Contains(text, "0 3 * * 0 root /usr/local/bin/ccc-auto-update") {
		t.Fatal("provisioner must not use old weekly-Sunday schedule for ccc-auto-update")
	}
}

func TestAutoUpdateEnabledFlagFile(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "install", "ccc-provision-workstation.sh"))
	if err != nil {
		t.Fatalf("read provisioner: %v", err)
	}
	if !strings.Contains(string(data), "/etc/ccc/autoupdate-enabled") {
		t.Fatal("provisioner must reference /etc/ccc/autoupdate-enabled flag file")
	}
}

func TestSafeRelPathRejectsTraversal(t *testing.T) {
	cases := []struct {
		input string
		valid bool
	}{
		{"file.txt", true},
		{"src/utils/helpers.js", true},
		{"a/b/c.go", true},
		{"../escape.txt", false},
		{"src/../../etc/passwd", false},
		{"/absolute/path", false},
		{"", false},
		{"with\x00null", false},
	}
	for _, tc := range cases {
		_, err := safeRelPath(tc.input)
		if tc.valid && err != nil {
			t.Errorf("safeRelPath(%q): expected valid, got error %v", tc.input, err)
		}
		if !tc.valid && err == nil {
			t.Errorf("safeRelPath(%q): expected error, got nil", tc.input)
		}
	}
}

func TestSaveUploadedFilesWritesFlatFiles(t *testing.T) {
	root := t.TempDir()
	entries := []BatchUploadEntry{
		{RelPath: "a.txt", Reader: strings.NewReader("content a")},
		{RelPath: "b.txt", Reader: strings.NewReader("content b")},
	}
	written, err := SaveUploadedFiles(root, entries)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(written) != 2 {
		t.Fatalf("expected 2 written files, got %d", len(written))
	}
	got, _ := os.ReadFile(filepath.Join(root, "a.txt"))
	if string(got) != "content a" {
		t.Fatalf("expected 'content a', got %q", got)
	}
}

func TestSaveUploadedFilesPreservesDirectoryStructure(t *testing.T) {
	root := t.TempDir()
	entries := []BatchUploadEntry{
		{RelPath: "src/utils/helpers.js", Reader: strings.NewReader("// helpers")},
		{RelPath: "src/index.js", Reader: strings.NewReader("// index")},
	}
	_, err := SaveUploadedFiles(root, entries)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(root, "src/utils/helpers.js"))
	if string(got) != "// helpers" {
		t.Fatalf("expected helpers content, got %q", got)
	}
}

func TestSaveUploadedFilesRejectsTraversalPath(t *testing.T) {
	root := t.TempDir()
	entries := []BatchUploadEntry{
		{RelPath: "../escape.txt", Reader: strings.NewReader("nope")},
	}
	_, err := SaveUploadedFiles(root, entries)
	if err == nil {
		t.Fatal("expected error for traversal path, got nil")
	}
	if _, statErr := os.Stat(filepath.Join(filepath.Dir(root), "escape.txt")); !os.IsNotExist(statErr) {
		t.Fatal("traversal file must not be created")
	}
}

func TestStreamZipDownloadCreatesZipFromDirectory(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "hello.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	sub := filepath.Join(root, "sub")
	if err := os.Mkdir(sub, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(sub, "world.txt"), []byte("world"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	var buf bytes.Buffer
	err := StreamZipDownload(&buf, []string{root})
	if err != nil {
		t.Fatalf("StreamZipDownload error: %v", err)
	}

	zr, err := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatalf("zip.NewReader error: %v", err)
	}
	names := make(map[string]bool)
	for _, f := range zr.File {
		names[f.Name] = true
	}
	dirBase := filepath.Base(root)
	if !names[dirBase+"/hello.txt"] {
		t.Fatalf("expected %s/hello.txt in zip, got %v", dirBase, names)
	}
	if !names[dirBase+"/sub/world.txt"] {
		t.Fatalf("expected %s/sub/world.txt in zip, got %v", dirBase, names)
	}
}

func TestStreamZipDownloadCreatesZipFromMultiplePaths(t *testing.T) {
	root := t.TempDir()
	fileA := filepath.Join(root, "a.txt")
	fileB := filepath.Join(root, "b.txt")
	_ = os.WriteFile(fileA, []byte("aaa"), 0o644)
	_ = os.WriteFile(fileB, []byte("bbb"), 0o644)

	var buf bytes.Buffer
	err := StreamZipDownload(&buf, []string{fileA, fileB})
	if err != nil {
		t.Fatalf("StreamZipDownload error: %v", err)
	}
	zr, err := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatalf("zip.NewReader: %v", err)
	}
	names := make(map[string]bool)
	for _, f := range zr.File {
		names[f.Name] = true
	}
	if !names["a.txt"] || !names["b.txt"] {
		t.Fatalf("expected a.txt and b.txt in zip, got %v", names)
	}
}

func TestSaveUploadedFilesRejectsOversizedFile(t *testing.T) {
	root := t.TempDir()
	entries := []BatchUploadEntry{
		{RelPath: "big.bin", Reader: io.LimitReader(infiniteReader{}, 64*1024*1024+1)},
	}
	_, err := SaveUploadedFiles(root, entries)
	if err == nil {
		t.Fatal("expected error for oversized file, got nil")
	}
	if _, statErr := os.Stat(filepath.Join(root, "big.bin")); !os.IsNotExist(statErr) {
		t.Fatal("oversized file partial write must be removed")
	}
}

type infiniteReader struct{}

func (infiniteReader) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 0
	}
	return len(p), nil
}

func TestEnsureSharedProjectsRootSetgid(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "projects")
	t.Setenv("CCC_SHARED_PROJECTS", tmp)

	EnsureSharedProjectsRoot()

	info, err := os.Stat(tmp)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode()&os.ModeSetgid == 0 || info.Mode().Perm()&0o070 != 0o070 {
		t.Errorf("projects root not setgid+group-rwx: mode=%v", info.Mode())
	}
}

func TestRunProjectOperationCreateIsGroupWritable(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("CCC_SHARED_PROJECTS", tmp)

	_, err := RunProjectOperation(ProjectOperation{Operation: "create", Name: "demo"})
	if err != nil {
		t.Fatalf("create failed: %v", err)
	}

	info, err := os.Stat(filepath.Join(tmp, "demo"))
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm()&0o070 != 0o070 {
		t.Errorf("project dir not group-rwx: mode=%v", info.Mode())
	}
	if info.Mode()&os.ModeSetgid == 0 {
		t.Errorf("project dir missing setgid bit: mode=%v", info.Mode())
	}
}

func TestParseTmuxOutput(t *testing.T) {
	input := "work|2|1|1748000000\nscratch|1|0|1747999500\n"
	now := int64(1748000300)
	got := parseTmuxOutput(input, now)
	if len(got) != 2 {
		t.Fatalf("expected 2 sessions, got %d", len(got))
	}
	if got[0].Name != "work" {
		t.Errorf("got[0].Name = %q, want %q", got[0].Name, "work")
	}
	if got[0].Windows != 2 {
		t.Errorf("got[0].Windows = %d, want 2", got[0].Windows)
	}
	if got[0].AttachedClients != 1 {
		t.Errorf("got[0].AttachedClients = %d, want 1", got[0].AttachedClients)
	}
	if got[0].IdleSeconds != 300 {
		t.Errorf("got[0].IdleSeconds = %d, want 300", got[0].IdleSeconds)
	}
	if got[1].Name != "scratch" {
		t.Errorf("got[1].Name = %q, want %q", got[1].Name, "scratch")
	}
	if got[1].AttachedClients != 0 {
		t.Errorf("got[1].AttachedClients = %d, want 0", got[1].AttachedClients)
	}
	if got[1].IdleSeconds != 800 {
		t.Errorf("got[1].IdleSeconds = %d, want 800", got[1].IdleSeconds)
	}
}

func TestParseTmuxOutputEmpty(t *testing.T) {
	got := parseTmuxOutput("", time.Now().Unix())
	if len(got) != 0 {
		t.Fatalf("expected 0 sessions, got %d", len(got))
	}
}

func TestParseTmuxOutputMalformedLineSkipped(t *testing.T) {
	input := "work|2|1|1748000000\nbadline\nscratch|1|0|1747999500\n"
	got := parseTmuxOutput(input, time.Now().Unix())
	if len(got) != 2 {
		t.Fatalf("expected 2 sessions (bad line skipped), got %d", len(got))
	}
}

func TestListTmuxSessionsNoServer(t *testing.T) {
	// A nonexistent user causes tmux/sudo to exit non-zero.
	// ListTmuxSessions must return a non-nil empty slice, never panic.
	got := ListTmuxSessions("nonexistent-user-xyz-ccc-test")
	if got == nil {
		t.Fatal("expected non-nil slice, got nil")
	}
	if len(got) != 0 {
		t.Fatalf("expected 0 sessions, got %d", len(got))
	}
}

func TestReadClaudeSettingsMissingFileReturnsEmptyMap(t *testing.T) {
	settings, err := ReadClaudeSettings(t.TempDir())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(settings) != 0 {
		t.Fatalf("expected empty map, got %v", settings)
	}
}

func TestReadClaudeSettingsValidFile(t *testing.T) {
	dir := t.TempDir()
	claudeDir := filepath.Join(dir, ".claude")
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	content := `{"autoCompactEnabled":true,"theme":"dark"}`
	if err := os.WriteFile(filepath.Join(claudeDir, "settings.json"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	settings, err := ReadClaudeSettings(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if settings["autoCompactEnabled"] != true {
		t.Errorf("autoCompactEnabled = %v, want true", settings["autoCompactEnabled"])
	}
	if settings["theme"] != "dark" {
		t.Errorf("theme = %v, want dark", settings["theme"])
	}
}

func TestReadClaudeSettingsCorruptFileReturnsEmptyMap(t *testing.T) {
	dir := t.TempDir()
	claudeDir := filepath.Join(dir, ".claude")
	os.MkdirAll(claudeDir, 0o755)
	os.WriteFile(filepath.Join(claudeDir, "settings.json"), []byte("not json {{{"), 0o644)
	settings, err := ReadClaudeSettings(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(settings) != 0 {
		t.Fatalf("expected empty map for corrupt file, got %v", settings)
	}
}

func TestWriteClaudeSettingsPythonScriptMergesWithoutWipingOtherKeys(t *testing.T) {
	dir := t.TempDir()
	claudeDir := filepath.Join(dir, ".claude")
	os.MkdirAll(claudeDir, 0o755)
	settingsPath := filepath.Join(claudeDir, "settings.json")

	initial := `{"autoCompactEnabled":true,"theme":"dark","alwaysThinkingEnabled":true}`
	os.WriteFile(settingsPath, []byte(initial), 0o644)

	patch := `{"autoCompactEnabled":false,"autoCompactWindow":150000}`
	py := "import json,sys\npath=sys.argv[1]\npatch=json.loads(sys.argv[2])\ntry:\n data=json.load(open(path))\nexcept (FileNotFoundError,ValueError):\n data={}\ndata.update(patch)\nopen(path,'w').write(json.dumps(data,indent=2)+'\\n')"
	cmd := exec.Command("python3", "-c", py, settingsPath, patch)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("python3: %v: %s", err, out)
	}

	result, err := ReadClaudeSettings(dir)
	if err != nil {
		t.Fatalf("read after write: %v", err)
	}
	if result["autoCompactEnabled"] != false {
		t.Errorf("autoCompactEnabled = %v, want false", result["autoCompactEnabled"])
	}
	if result["autoCompactWindow"] != float64(150000) {
		t.Errorf("autoCompactWindow = %v, want 150000", result["autoCompactWindow"])
	}
	if result["theme"] != "dark" {
		t.Errorf("theme = %v, want dark (must not be wiped)", result["theme"])
	}
	if result["alwaysThinkingEnabled"] != true {
		t.Errorf("alwaysThinkingEnabled = %v, want true (must not be wiped)", result["alwaysThinkingEnabled"])
	}
}

func TestWriteClaudeSettingsPythonScriptHandlesMissingFile(t *testing.T) {
	dir := t.TempDir()
	claudeDir := filepath.Join(dir, ".claude")
	os.MkdirAll(claudeDir, 0o755)
	settingsPath := filepath.Join(claudeDir, "settings.json")

	patch := `{"autoCompactEnabled":true}`
	py := "import json,sys\npath=sys.argv[1]\npatch=json.loads(sys.argv[2])\ntry:\n data=json.load(open(path))\nexcept (FileNotFoundError,ValueError):\n data={}\ndata.update(patch)\nopen(path,'w').write(json.dumps(data,indent=2)+'\\n')"
	cmd := exec.Command("python3", "-c", py, settingsPath, patch)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("python3: %v: %s", err, out)
	}

	result, _ := ReadClaudeSettings(dir)
	if result["autoCompactEnabled"] != true {
		t.Errorf("autoCompactEnabled = %v, want true", result["autoCompactEnabled"])
	}
}
