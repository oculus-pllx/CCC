package system

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
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
		"sudo chgrp 'ccc' '/home/work-id'",
		"sudo chmod g+rx '/home/work-id'",
		"sudo ln -sfn '/srv/ccc/projects' '/home/work-id/projects'",
		"sudo mkdir -p '/home/work-id/.claude' '/home/work-id/.codex' '/home/work-id/.gemini'",
		"Direct Agent Config Sync",
		"check_file \"$home/.claude/settings.json\"",
		"check_exec \"$home/.claude/bin/statusline-command.sh\"",
		"check_file \"$home/.codex/AGENTS.md\"",
		"check_dir \"$home/.codex/skills\"",
		"check_file \"$home/.gemini/GEMINI.md\"",
		"check_dir \"$home/.gemini/skills\"",
		"sudo test -x '/home/work-id/.local/bin/codex'",
		"sudo test -x '/home/work-id/.local/bin/gemini'",
		"sudo chgrp -R 'ccc' '/srv/ccc/projects'",
		"if [ -L \"$entry\" ] && [ -d \"$entry\" ]; then sudo chgrp -R 'ccc' \"$entry\"/",
		"CCC shell projects login",
		"cd ~/projects",
		"CCC shell environment",
		"export PATH=\"$HOME/.local/bin:$HOME/.claude/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH\"",
		"npm install -g --prefix '/home/work-id/.local' @anthropic-ai/claude-code @openai/codex @google/gemini-cli",
		"IdentityFile /etc/ccc/ssh/github_ed25519",
	} {
		if !strings.Contains(command, want) {
			t.Fatalf("setup command missing %q:\n%s", want, command)
		}
	}
}

func TestAgentConfigSyncCommandValidatesExpectedFilesAndSkills(t *testing.T) {
	command := agentConfigSyncCommand("work-id")
	for _, want := range []string{
		"Direct Agent Config Sync",
		"copy_file \"$src/claude/CLAUDE.md\" \"$home/.claude/CLAUDE.md\"",
		"copy_optional_dir \"$src/claude/plugins\" \"$home/.claude/plugins\" \"Claude default plugins\"",
		"copy_optional_dir \"$src/claude/skills\" \"$home/.claude/skills\" \"Claude default skills\"",
		"copy_optional_dir \"$src/claude/commands\" \"$home/.claude/commands\" \"Claude default commands\"",
		"copy_dir \"$src/codex/skills\" \"$home/.codex/skills\"",
		"copy_optional_dir \"$src/codex/plugins\" \"$home/.codex/plugins\" \"Codex default plugins\"",
		"copy_dir \"$src/gemini/skills\" \"$home/.gemini/skills\"",
		"copy_dir \"$src/templates\" \"$home/Templates\"",
		"mirror_provider_profile \".claude\" \"Claude\"",
		"mirror_provider_profile \".codex\" \"Codex\"",
		"mirror_provider_profile \".gemini\" \"Gemini\"",
		"--exclude=.credentials.json",
		"--exclude=auth.json",
		"--exclude=sessions/",
		"--exclude=cache/",
		"write_claude_baseline \"$home\"",
		"chgrp \"$shared_group\" \"$home\"",
		"chmod g+rx \"$home\"",
		"chown -R \"$target_user:$target_user\"",
		"check_file \"$home/.claude/CLAUDE.md\"",
		"check_file \"$home/.claude/settings.json\"",
		"check_exec \"$home/.claude/bin/statusline-command.sh\"",
		"check_dir \"$home/.codex/skills\"",
		"find \"$home/.claude\" \"$home/.codex\" \"$home/.gemini\"",
	} {
		if !strings.Contains(command, want) {
			t.Fatalf("agent sync command missing %q:\n%s", want, command)
		}
	}
}

func TestSelfUpdateRunsAgentConfigSyncForCurrentUser(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "install", "ccc-provision-workstation.sh"))
	if err != nil {
		t.Fatalf("read provisioner: %v", err)
	}
	text := string(data)
	applyIndex := strings.Index(text, `bash "$SRC/install/ccc-provision-workstation.sh"`)
	syncIndex := -1
	if applyIndex >= 0 {
		nextSync := strings.Index(text[applyIndex:], `ccc-sync-agent-configs`)
		if nextSync >= 0 {
			syncIndex = applyIndex + nextSync
		}
	}
	finalIndex := strings.Index(text, `Finalizing update`)
	if applyIndex < 0 || syncIndex < 0 || finalIndex < 0 {
		t.Fatalf("expected self-update apply, sync, and final markers")
	}
	if !(applyIndex < syncIndex && syncIndex < finalIndex) {
		t.Fatalf("expected ccc-sync-agent-configs to run after updateable apply and before finalizing")
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
		"getent passwd | awk",
		"sync_one \"$user\"",
		"Direct Agent Config Sync",
		"copy_file \"$src/claude/CLAUDE.md\"",
	} {
		if !strings.Contains(command, want) {
			t.Fatalf("allAgentConfigSyncCommand() missing %q:\n%s", want, command)
		}
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

func TestExplainProjectGitFailureSanitizesCredentialedHTTPSOutput(t *testing.T) {
	result := explainProjectGitFailure(CommandResult{
		Output: "fatal: https://user:secret@git.example.test/owner/repo.git authentication failed",
	}, "")
	if strings.Contains(result.Output, "user:secret") {
		t.Fatalf("expected credentialed remote to be sanitized, got %q", result.Output)
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

func TestProviderNPMToolsInstallToUserPrefix(t *testing.T) {
	for _, tool := range []string{"claude", "gemini"} {
		command, err := toolInstallCommand(tool)
		if err != nil {
			t.Fatalf("expected %s install command: %v", tool, err)
		}
		if !strings.Contains(command, `--prefix "$HOME/.local"`) {
			t.Fatalf("expected %s to install under user npm prefix, got %q", tool, command)
		}
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
