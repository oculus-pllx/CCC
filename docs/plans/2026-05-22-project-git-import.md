# Project Git Import Implementation Plan

> Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let CCC users clone Git SSH/HTTPS repositories into Projects and pull fast-forward updates for existing Git projects from the Projects page.

**Architecture:** Extend the existing `ProjectOperation` and `/api/project` flow with clone and pull operations rather than adding a separate Git API. Keep remote validation, name derivation, credential sanitization, and managed Projects-root path checks in the system layer, then expose Git repo metadata and UI controls through the existing snapshot/project renderer.

**Tech Stack:** Go system/server code, browser JavaScript/CSS-free existing form components, Git CLI execution through existing command runner, static shell/UI checks.

---

## File Map

- Modify `container-code-companion/internal/system/management.go`: project Git metadata, remote validation/name derivation, clone/pull operations, sanitized Git failure guidance.
- Modify `container-code-companion/internal/system/management_test.go`: system tests for remote validation, clone target collision, pull validation, metadata, and pull command output.
- Modify `container-code-companion/internal/server/server_test.go`: `/api/project` clone/pull payload coverage.
- Modify `container-code-companion/web/app.js`: Clone Repository form, Pull Latest button, and project actions.
- Modify `tests/container-code-companion-static.sh`: static assertions for UI and backend clone/pull markers.
- Modify `README.md` and `PROJECT_STATUS.md`: document Projects Git clone/pull capability.

### Task 1: Validate Git Remotes And Derive Project Names

**Files:**
- Modify: `container-code-companion/internal/system/management.go`
- Test: `container-code-companion/internal/system/management_test.go`

- [x] **Step 1: Write failing tests for SSH/HTTPS project-name derivation**

Add these tests to `container-code-companion/internal/system/management_test.go`:

```go
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
```

- [x] **Step 2: Write failing tests for unsafe remotes**

Add:

```go
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
```

- [x] **Step 3: Run focused tests and confirm helpers are missing**

Run:

```bash
(cd container-code-companion && go test ./internal/system -run 'Test(ProjectNameFromGitRemote|ValidateGitRemote)' -v)
```

Expected: build failure because `projectNameFromGitRemote` and
`validateGitRemote` do not exist.

- [x] **Step 4: Implement remote validation helpers**

Add to `management.go` near `safeProjectName`:

```go
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
```

Add imports and pattern:

```go
import "net/url"
import "regexp"

var scpGitRemotePattern = regexp.MustCompile(`^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+(?:\.git)?$`)
```

- [x] **Step 5: Run focused tests green**

Run:

```bash
(cd container-code-companion && go test ./internal/system -run 'Test(ProjectNameFromGitRemote|ValidateGitRemote)' -v)
```

Expected: both new tests pass.

- [x] **Step 6: Commit Git remote validation**

```bash
git add container-code-companion/internal/system/management.go container-code-companion/internal/system/management_test.go
git commit -m "feat(projects): validate git remotes"
```

### Task 2: Add Clone And Pull Project Operations

**Files:**
- Modify: `container-code-companion/internal/system/management.go`
- Test: `container-code-companion/internal/system/management_test.go`

- [x] **Step 1: Write failing clone target collision test**

Add:

```go
func TestRunProjectOperationRejectsCloneTargetCollision(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
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
```

- [x] **Step 2: Write failing pull tests**

Add:

```go
func TestRunProjectOperationRejectsPullForNonGitProject(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.MkdirAll(filepath.Join(home, "projects", "plain"), 0o755); err != nil {
		t.Fatalf("create plain project: %v", err)
	}
	if _, err := RunProjectOperation(ProjectOperation{Operation: "pull", Name: "plain"}); err == nil {
		t.Fatal("expected non-Git project pull to fail")
	}
}
```

Use a temporary local Git remote for the command-path test:

```go
func TestRunProjectOperationPullsFastForwardGitProject(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	project := filepath.Join(home, "projects", "demo")
	if err := os.MkdirAll(project, 0o755); err != nil {
		t.Fatalf("create project: %v", err)
	}
	runGitTestCommand(t, project, "init")
	result, err := RunProjectOperation(ProjectOperation{Operation: "pull", Name: "demo"})
	if err != nil {
		t.Fatalf("pull project command path: %v", err)
	}
	if !strings.Contains(result.Command, "git pull --ff-only") {
		t.Fatalf("expected fast-forward pull command, got %#v", result)
	}
}
```

Add the test setup helper:

```go
// Add os/exec to the test imports before this helper.
func runGitTestCommand(t *testing.T, cwd string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = cwd
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, output)
	}
}
```

- [x] **Step 3: Run project-operation tests red**

Run:

```bash
(cd container-code-companion && go test ./internal/system -run 'TestRunProjectOperation(RejectsCloneTargetCollision|RejectsPullForNonGitProject|PullsFastForwardGitProject)' -v)
```

Expected: failures because `clone` and `pull` operations are not allowed.

- [x] **Step 4: Implement clone and pull operations**

Extend `RunProjectOperation`:

```go
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
```

Add managed helper functions:

```go
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
```

- [x] **Step 5: Add sanitized Git failure guidance**

Add a helper that replaces credentialed output with sanitized output and appends
guidance:

```go
func explainProjectGitFailure(result CommandResult, remote string) CommandResult {
	result.Output = sanitizeGitOutput(result.Output)
	lower := strings.ToLower(result.Output)
	if strings.Contains(lower, "permission denied (publickey)") && strings.Contains(remote, "github.com") {
		result.Output += "\n\nSSH auth note: authorize this workstation public key in Settings > GitHub before cloning GitHub SSH repositories."
	}
	if strings.Contains(lower, "authentication failed") || strings.Contains(lower, "could not read username") {
		result.Output += "\n\nHTTPS auth note: configure Git HTTPS credentials on this host or use an SSH remote."
	}
	return result
}
```

Sanitize URLs with parsed-userinfo removal before output reaches the UI.

```go
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
```

- [x] **Step 6: Run system tests green**

Run:

```bash
(cd container-code-companion && go test ./internal/system -run 'Test(ProjectNameFromGitRemote|ValidateGitRemote|RunProjectOperation)' -v)
```

Expected: project operation tests pass.

- [x] **Step 7: Commit clone/pull operations**

```bash
git add container-code-companion/internal/system/management.go container-code-companion/internal/system/management_test.go
git commit -m "feat(projects): clone and pull git repos"
```

### Task 3: Expose Git Metadata For Project Rows

**Files:**
- Modify: `container-code-companion/internal/system/management.go`
- Test: `container-code-companion/internal/system/management_test.go`

- [x] **Step 1: Write failing metadata test**

Add:

```go
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
```

- [x] **Step 2: Run metadata test red**

Run:

```bash
(cd container-code-companion && go test ./internal/system -run TestCollectProjectsMarksGitProjects -v)
```

Expected: build failure because `GitRepo` does not exist.

- [x] **Step 3: Add Git repo and remote metadata**

Extend `ProjectStatus`:

```go
GitRepo   bool   `json:"gitRepo"`
GitRemote string `json:"gitRemote"`
```

Extend `collectProjects`:

```go
gitRemote := sanitizeGitRemote(gitText(path, "remote", "get-url", "origin"))
projects = append(projects, ProjectStatus{
	Name:      entry.Name(),
	Path:      path,
	GitRepo:   isGitWorktree(path),
	GitBranch: gitText(path, "branch", "--show-current"),
	GitRemote: gitRemote,
	GitStatus: gitText(path, "status", "--short", "--branch"),
})
```

- [x] **Step 4: Run metadata and full system tests**

Run:

```bash
(cd container-code-companion && go test ./internal/system -v)
```

Expected: system tests pass.

- [x] **Step 5: Commit project Git metadata**

```bash
git add container-code-companion/internal/system/management.go container-code-companion/internal/system/management_test.go
git commit -m "feat(projects): expose git project metadata"
```

### Task 4: Cover Clone And Pull API Payloads

**Files:**
- Modify: `container-code-companion/internal/server/server_test.go`

- [x] **Step 1: Write failing clone payload server test**

Add near existing project handler tests:

```go
func TestProtectedProjectOperationAcceptsCloneRemote(t *testing.T) {
	var received system.ProjectOperation
	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		ProjectOperation: func(operation system.ProjectOperation) (system.CommandResult, error) {
			received = operation
			return system.CommandResult{Command: operation.Operation, Output: "cloned demo"}, nil
		},
	})
	req := httptest.NewRequest(http.MethodPost, "/api/project", strings.NewReader(`{"operation":"clone","name":"demo","remote":"git@github.com:owner/demo.git"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)
	if res.Code != http.StatusOK || received.Remote != "git@github.com:owner/demo.git" {
		t.Fatalf("expected clone remote payload, got status %d and operation %#v", res.Code, received)
	}
}
```

- [x] **Step 2: Write pull payload server test**

Add:

```go
func TestProtectedProjectOperationAcceptsPullName(t *testing.T) {
	var received system.ProjectOperation
	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		ProjectOperation: func(operation system.ProjectOperation) (system.CommandResult, error) {
			received = operation
			return system.CommandResult{Command: operation.Operation, Output: "pulled demo"}, nil
		},
	})
	req := httptest.NewRequest(http.MethodPost, "/api/project", strings.NewReader(`{"operation":"pull","name":"demo"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)
	if res.Code != http.StatusOK || received.Operation != "pull" || received.Name != "demo" {
		t.Fatalf("expected pull project payload, got status %d and operation %#v", res.Code, received)
	}
}
```

- [x] **Step 3: Run server tests**

Run:

```bash
(cd container-code-companion && go test ./internal/server -run 'TestProtectedProjectOperationAccepts(CloneRemote|PullName)' -v)
```

Expected: tests pass because the existing JSON struct already carries operation,
name, and remote fields.

- [ ] **Step 4: Commit server coverage**

```bash
git add container-code-companion/internal/server/server_test.go
git commit -m "test(projects): cover git project api payloads"
```

### Task 5: Add Clone And Pull Controls To Projects UI

**Files:**
- Modify: `container-code-companion/web/app.js`
- Modify: `tests/container-code-companion-static.sh`

- [ ] **Step 1: Add failing UI static checks**

Add:

```bash
require_file_contains container-code-companion/web/app.js "Clone Repository"
require_file_contains container-code-companion/web/app.js "project-clone-remote"
require_file_contains container-code-companion/web/app.js "cloneProject"
require_file_contains container-code-companion/web/app.js "data-project-pull"
require_file_contains container-code-companion/web/app.js "pullProject"
require_file_contains container-code-companion/internal/system/management.go 'case "clone"'
require_file_contains container-code-companion/internal/system/management.go 'case "pull"'
```

- [ ] **Step 2: Run static checks red**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: failure because Projects UI has no Clone Repository form yet.

- [ ] **Step 3: Render clone form and Git-aware pull button**

Add before the project list in `renderProjects()`:

```js
<div class="project-create project-clone">
  <strong>Clone Repository</strong>
  <input id="project-clone-remote" type="text" placeholder="git@github.com:owner/repo.git or https://host/owner/repo.git">
  <input id="project-clone-name" type="text" placeholder="optional-project-name">
  <button id="clone-project-button" class="small-button">Clone</button>
</div>
```

Add to project row actions:

```js
${project.gitRepo ? `<button class="small-button" data-project-pull="${escapeAttribute(project.name)}">Pull Latest</button>` : ''}
```

- [ ] **Step 4: Bind clone and pull actions**

Add:

```js
document.getElementById('clone-project-button')?.addEventListener('click', cloneProject);
document.querySelectorAll('[data-project-pull]').forEach(button => {
  button.addEventListener('click', () => pullProject(button.dataset.projectPull));
});

async function cloneProject() {
  const remote = document.getElementById('project-clone-remote').value.trim();
  const name = document.getElementById('project-clone-name').value.trim();
  await runProjectOperation({ operation: 'clone', remote, name });
}

async function pullProject(name) {
  await runProjectOperation({ operation: 'pull', name });
}
```

- [ ] **Step 5: Run JS and static checks**

Run:

```bash
node --check container-code-companion/web/app.js
bash tests/container-code-companion-static.sh
```

Expected: both commands exit `0`.

- [ ] **Step 6: Commit Projects UI controls**

```bash
git add container-code-companion/web/app.js tests/container-code-companion-static.sh
git commit -m "feat(projects): add git clone and pull controls"
```

### Task 6: Document Projects Git Actions

**Files:**
- Modify: `README.md`
- Modify: `PROJECT_STATUS.md`
- Modify: `tests/container-code-companion-static.sh`

- [ ] **Step 1: Add failing documentation assertions**

Add:

```bash
require_file_contains README.md "clone SSH or HTTPS Git repos"
require_file_contains README.md "pull fast-forward Git updates"
```

- [ ] **Step 2: Run static checks red**

Run:

```bash
bash tests/container-code-companion-static.sh
```

Expected: README Git Projects text is missing.

- [ ] **Step 3: Update docs**

Add to the README GUI/Projects capability text:

```markdown
- **Projects Git actions** — clone SSH or HTTPS Git repos into Projects and pull fast-forward Git updates for existing Git projects
```

Add to `PROJECT_STATUS.md` recent work:

```markdown
- Added Projects Git clone/import and fast-forward pull actions for SSH and HTTPS remotes.
```

- [ ] **Step 4: Verify docs and commit**

Run:

```bash
bash tests/container-code-companion-static.sh
git diff --check
```

Expected: both commands exit `0`.

Commit:

```bash
git add README.md PROJECT_STATUS.md tests/container-code-companion-static.sh
git commit -m "docs: explain project git actions"
```

### Task 7: Verify The Git Import Feature

**Files:**
- Verify: all changed Go, JS, docs, and static-check files

- [ ] **Step 1: Run full local verification**

Run:

```bash
bash tests/container-code-companion-static.sh
node --check container-code-companion/web/app.js
(cd container-code-companion && go test ./...)
(cd container-code-companion && go build -buildvcs=false -o /tmp/container-code-companion-test ./cmd/server)
git diff --check
```

Expected: all commands exit `0`.

- [ ] **Step 2: Inspect the feature diff**

Run:

```bash
git grep -n -E 'git clone|git pull --ff-only|GitRepo|project-clone-remote|data-project-pull' -- container-code-companion tests README.md
git status --short
```

Expected: clone/pull markers exist in system/UI/tests/docs, with no unexpected
working-tree changes.

- [ ] **Step 3: Field-test manually after deployment**

Manual cases:

```text
1. Projects > Clone Repository with a public HTTPS remote.
2. Projects > Clone Repository with a GitHub SSH remote after SSH key registration.
3. Pull Latest on a project whose remote has a fast-forward commit.
4. Observe SSH/private HTTPS auth failure guidance without exposing credentials.
```
