package server

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/oculus-pllx/ccc/container-code-companion/internal/system"
)

func TestHealthReturnsContainerCodeCompanionStatus(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/health", nil)
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", res.Code)
	}

	var body map[string]any
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatalf("health response is not JSON: %v", err)
	}
	if body["ok"] != true {
		t.Fatalf("expected ok=true, got %#v", body["ok"])
	}
	if body["name"] != "Container Code Companion" {
		t.Fatalf("expected Container Code Companion name, got %#v", body["name"])
	}
}

func TestRootServesIndexHTML(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", res.Code)
	}
	if !strings.Contains(res.Body.String(), "Container Code Companion") {
		t.Fatalf("expected index HTML to contain Container Code Companion, got %q", res.Body.String())
	}
}

func TestProtectedAPIReturnsUnauthorizedWithoutSession(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/overview", nil)
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusUnauthorized {
		t.Fatalf("expected status 401, got %d", res.Code)
	}
}

func TestLoginSetsSessionCookieForValidUserPassword(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"username":"oculus","password":"secret"}`))
	req.Header.Set("Content-Type", "application/json")
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	cookie := findCookie(res.Result().Cookies(), SessionCookieName)
	if cookie == nil {
		t.Fatalf("expected %s cookie to be set", SessionCookieName)
	}
	if cookie.Value != "test-token" {
		t.Fatalf("expected session token cookie, got %q", cookie.Value)
	}
	if !cookie.HttpOnly {
		t.Fatalf("expected session cookie to be HttpOnly")
	}
	if cookie.SameSite != http.SameSiteStrictMode {
		t.Fatalf("expected SameSite strict, got %v", cookie.SameSite)
	}
}

func TestLoginRejectsInvalidPassword(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"username":"oculus","password":"wrong"}`))
	req.Header.Set("Content-Type", "application/json")
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusUnauthorized {
		t.Fatalf("expected status 401, got %d", res.Code)
	}
}

func TestLoginRejectsInvalidUsername(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"username":"wrong","password":"secret"}`))
	req.Header.Set("Content-Type", "application/json")
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusUnauthorized {
		t.Fatalf("expected status 401, got %d", res.Code)
	}
}

func TestLogoutClearsSessionCookie(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/logout", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", res.Code)
	}
	cookie := findCookie(res.Result().Cookies(), SessionCookieName)
	if cookie == nil {
		t.Fatalf("expected %s cookie to be cleared", SessionCookieName)
	}
	if cookie.MaxAge >= 0 {
		t.Fatalf("expected cookie MaxAge < 0, got %d", cookie.MaxAge)
	}
}

func TestProtectedAPIAllowsValidSessionCookie(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/overview", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if !strings.Contains(res.Body.String(), "test-host") {
		t.Fatalf("expected overview body to contain hostname, got %q", res.Body.String())
	}
}

func TestProtectedManagementSnapshotReturnsNativeSections(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/workstation", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	var body system.ManagementSnapshot
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatalf("snapshot response is not JSON: %v", err)
	}
	if len(body.Services) == 0 || body.Services[0].Name != "container-code-companion.service" {
		t.Fatalf("expected service status in snapshot, got %#v", body.Services)
	}
	if len(body.Projects) == 0 || body.Projects[0].Name != "demo" {
		t.Fatalf("expected projects in snapshot, got %#v", body.Projects)
	}
	if body.OculusConfigs.Path != "/opt/oculus-configs" {
		t.Fatalf("expected oculus-configs status, got %#v", body.OculusConfigs)
	}
}

func TestProtectedCommandRunsThroughConfiguredRunner(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/terminal", strings.NewReader(`{"command":"pwd","cwd":"/home/oculus/projects"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	var body system.CommandResult
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatalf("terminal response is not JSON: %v", err)
	}
	if body.Output != "ran pwd in /home/oculus/projects" {
		t.Fatalf("expected configured runner output, got %#v", body)
	}
}

func TestProtectedActionRunsAllowlistedAction(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/action", strings.NewReader(`{"action":"sync-oculus-configs"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if !strings.Contains(res.Body.String(), "sync ok") {
		t.Fatalf("expected action output, got %q", res.Body.String())
	}
}

func TestProtectedFileListReturnsDirectoryEntries(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/files?path=/home/oculus/projects", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if !strings.Contains(res.Body.String(), "README.md") {
		t.Fatalf("expected file listing, got %q", res.Body.String())
	}
}

func TestProtectedFileReadReturnsContent(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/file?path=/home/oculus/projects/README.md", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if !strings.Contains(res.Body.String(), "hello file") {
		t.Fatalf("expected file content, got %q", res.Body.String())
	}
}

func TestProtectedFileWriteSavesContent(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPut, "/api/file", strings.NewReader(`{"path":"/home/oculus/projects/README.md","content":"updated"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if !strings.Contains(res.Body.String(), "saved") {
		t.Fatalf("expected save response, got %q", res.Body.String())
	}
}

func TestProtectedFileUploadWritesMultipartFile(t *testing.T) {
	root := t.TempDir()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "upload.txt")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	if _, err := part.Write([]byte("uploaded content")); err != nil {
		t.Fatalf("write form file: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart writer: %v", err)
	}
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/file-upload?path="+root, &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	content, err := os.ReadFile(filepath.Join(root, "upload.txt"))
	if err != nil {
		t.Fatalf("expected uploaded file: %v", err)
	}
	if string(content) != "uploaded content" {
		t.Fatalf("expected uploaded content, got %q", string(content))
	}
}

func TestProtectedFileUploadRejectsTraversalFilename(t *testing.T) {
	root := t.TempDir()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "../escape.txt")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	_, _ = part.Write([]byte("nope"))
	_ = writer.Close()
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/file-upload?path="+root, &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusBadRequest {
		t.Fatalf("expected status 400, got %d with body %q", res.Code, res.Body.String())
	}
	if _, err := os.Stat(filepath.Join(root, "escape.txt")); !os.IsNotExist(err) {
		t.Fatalf("expected traversal upload not to create file, stat err=%v", err)
	}
}

func TestProtectedFileDownloadReturnsAttachment(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "download.txt")
	if err := os.WriteFile(path, []byte("download content"), 0o644); err != nil {
		t.Fatalf("write download fixture: %v", err)
	}
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/file-download?path="+path, nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if res.Header().Get("Content-Disposition") != `attachment; filename="download.txt"` {
		t.Fatalf("expected attachment disposition, got %q", res.Header().Get("Content-Disposition"))
	}
	if res.Body.String() != "download content" {
		t.Fatalf("expected downloaded content, got %q", res.Body.String())
	}
}

func TestProtectedFileDownloadRejectsDirectory(t *testing.T) {
	root := t.TempDir()
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/file-download?path="+root, nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusBadRequest {
		t.Fatalf("expected status 400, got %d with body %q", res.Code, res.Body.String())
	}
}

func TestProtectedServiceControlRunsConfiguredController(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/service", strings.NewReader(`{"service":"redis-server.service","operation":"restart"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if !strings.Contains(res.Body.String(), "restart redis-server.service") {
		t.Fatalf("expected service control output, got %q", res.Body.String())
	}
}

func TestProtectedFileOperationRunsConfiguredOperator(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/file-op", strings.NewReader(`{"operation":"rename","path":"/home/oculus/projects/old.md","target":"/home/oculus/projects/new.md"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if !strings.Contains(res.Body.String(), "renamed") {
		t.Fatalf("expected file operation response, got %q", res.Body.String())
	}
}

func TestProtectedProjectOperationRunsConfiguredOperator(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/project", strings.NewReader(`{"operation":"create","name":"new-project","template":"blank"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if !strings.Contains(res.Body.String(), "created new-project") {
		t.Fatalf("expected project operation response, got %q", res.Body.String())
	}
}

func TestProtectedAccountOperationAcceptsSetupCCCProfile(t *testing.T) {
	var received system.AccountOperation
	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		AccountOperation: func(operation system.AccountOperation) (system.CommandResult, error) {
			received = operation
			return system.CommandResult{Command: operation.Operation, Output: "profile ready"}, nil
		},
	})
	req := httptest.NewRequest(http.MethodPost, "/api/account", strings.NewReader(`{"operation":"setup-ccc-profile","username":"work-id"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if received.Operation != "setup-ccc-profile" || received.Username != "work-id" {
		t.Fatalf("expected setup profile operation, got %#v", received)
	}
}

func TestProtectedProjectOperationAcceptsExistingDirectoryPath(t *testing.T) {
	var received system.ProjectOperation
	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		ProjectOperation: func(operation system.ProjectOperation) (system.CommandResult, error) {
			received = operation
			return system.CommandResult{Command: operation.Operation, Output: "added existing-project"}, nil
		},
	})
	req := httptest.NewRequest(http.MethodPost, "/api/project", strings.NewReader(`{"operation":"add-existing","name":"existing-project","path":"/srv/work/existing-project"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if received.Operation != "add-existing" || received.Name != "existing-project" || received.Path != "/srv/work/existing-project" {
		t.Fatalf("expected existing project operation with path, got %#v", received)
	}
	if !strings.Contains(res.Body.String(), "added existing-project") {
		t.Fatalf("expected add existing response, got %q", res.Body.String())
	}
}

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

func TestProtectedProjectOperationReturnsCommandOutputOnFailure(t *testing.T) {
	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		ProjectOperation: func(operation system.ProjectOperation) (system.CommandResult, error) {
			return system.CommandResult{Command: operation.Operation, Output: "SSH auth note: authorize key"}, errors.New("Git clone failed")
		},
	})
	req := httptest.NewRequest(http.MethodPost, "/api/project", strings.NewReader(`{"operation":"clone","remote":"git@github.com:owner/demo.git"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusBadRequest || !strings.Contains(res.Body.String(), "SSH auth note") {
		t.Fatalf("expected project failure output, got status %d and body %q", res.Code, res.Body.String())
	}
}

func TestProtectedAccountOperationRunsConfiguredOperator(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/account", strings.NewReader(`{"operation":"create","username":"newuser","shell":"/bin/bash"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if !strings.Contains(res.Body.String(), "account create newuser") {
		t.Fatalf("expected account operation response, got %q", res.Body.String())
	}
}

func TestProtectedNetworkActivityReturnsCounters(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/network-activity", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if !strings.Contains(res.Body.String(), "eth0") {
		t.Fatalf("expected network interface counters, got %q", res.Body.String())
	}
}

func TestProtectedTimeSettingsReturnsAndUpdatesTimezone(t *testing.T) {
	timezone := "UTC"
	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		TimeSettings: func() (system.TimeSettings, error) {
			return system.TimeSettings{Timezone: timezone, LocalTime: "2026-05-21 12:00:00"}, nil
		},
		SetTimezone: func(next string) (system.CommandResult, error) {
			timezone = next
			return system.CommandResult{Command: "timedatectl set-timezone " + next, Output: "timezone updated"}, nil
		},
	})

	getReq := httptest.NewRequest(http.MethodGet, "/api/time-settings", nil)
	getReq.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	getRes := httptest.NewRecorder()
	srv.ServeHTTP(getRes, getReq)

	if getRes.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", getRes.Code, getRes.Body.String())
	}
	if !strings.Contains(getRes.Body.String(), "UTC") {
		t.Fatalf("expected timezone in response, got %q", getRes.Body.String())
	}

	postReq := httptest.NewRequest(http.MethodPost, "/api/time-settings", strings.NewReader(`{"timezone":"America/New_York"}`))
	postReq.Header.Set("Content-Type", "application/json")
	postReq.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	postRes := httptest.NewRecorder()
	srv.ServeHTTP(postRes, postReq)

	if postRes.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", postRes.Code, postRes.Body.String())
	}
	if timezone != "America/New_York" {
		t.Fatalf("expected timezone update, got %q", timezone)
	}
}

func TestProtectedToolsReturnsStatusAndRunsInstall(t *testing.T) {
	installedTool := ""
	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		ToolStatuses: func() []system.ToolStatus {
			return []system.ToolStatus{{Name: "bubblewrap", Label: "Bubblewrap", Installed: false}}
		},
		ToolOperation: func(operation system.ToolOperation) (system.CommandResult, error) {
			installedTool = operation.Tool
			return system.CommandResult{Command: "install " + operation.Tool, Output: "install queued"}, nil
		},
	})

	getReq := httptest.NewRequest(http.MethodGet, "/api/tools", nil)
	getReq.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	getRes := httptest.NewRecorder()
	srv.ServeHTTP(getRes, getReq)

	if getRes.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", getRes.Code, getRes.Body.String())
	}
	if !strings.Contains(getRes.Body.String(), "bubblewrap") {
		t.Fatalf("expected tool status, got %q", getRes.Body.String())
	}

	postReq := httptest.NewRequest(http.MethodPost, "/api/tools", strings.NewReader(`{"operation":"install","tool":"bubblewrap"}`))
	postReq.Header.Set("Content-Type", "application/json")
	postReq.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	postRes := httptest.NewRecorder()
	srv.ServeHTTP(postRes, postReq)

	if postRes.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", postRes.Code, postRes.Body.String())
	}
	if installedTool != "bubblewrap" {
		t.Fatalf("expected bubblewrap install, got %q", installedTool)
	}
}

func TestProtectedDriveOperationRunsConfiguredOperator(t *testing.T) {
	var received system.DriveOperation
	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		DriveOperation: func(operation system.DriveOperation) (system.CommandResult, error) {
			received = operation
			return system.CommandResult{Command: "mount", Output: "mounted"}, nil
		},
	})
	req := httptest.NewRequest(http.MethodPost, "/api/drive", strings.NewReader(`{"operation":"mount-cifs","name":"share","remote":"//server/share","mountPoint":"/mnt/share"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d with body %q", res.Code, res.Body.String())
	}
	if received.Name != "share" || received.Remote != "//server/share" {
		t.Fatalf("expected drive operation payload, got %#v", received)
	}
}

func TestProtectedNotesLifecycleUsesConfiguredStore(t *testing.T) {
	notes := []system.Note{}
	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		ListNotes: func() ([]system.Note, error) {
			return notes, nil
		},
		SaveNote: func(note system.Note) (system.Note, error) {
			if note.ID == "" {
				note.ID = "note-1"
			}
			updated := false
			for index := range notes {
				if notes[index].ID == note.ID {
					notes[index] = note
					updated = true
					break
				}
			}
			if !updated {
				notes = append(notes, note)
			}
			return note, nil
		},
		DeleteNote: func(id string) error {
			filtered := notes[:0]
			for _, note := range notes {
				if note.ID != id {
					filtered = append(filtered, note)
				}
			}
			notes = filtered
			return nil
		},
	})

	createReq := httptest.NewRequest(http.MethodPost, "/api/notes", strings.NewReader(`{"title":"Scratch","content":"first draft"}`))
	createReq.Header.Set("Content-Type", "application/json")
	createReq.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	createRes := httptest.NewRecorder()
	srv.ServeHTTP(createRes, createReq)

	if createRes.Code != http.StatusOK {
		t.Fatalf("expected create status 200, got %d with body %q", createRes.Code, createRes.Body.String())
	}
	var created system.Note
	if err := json.Unmarshal(createRes.Body.Bytes(), &created); err != nil {
		t.Fatalf("create response is not a note: %v", err)
	}
	if created.ID != "note-1" || created.Title != "Scratch" || created.Content != "first draft" {
		t.Fatalf("expected created note, got %#v", created)
	}

	updateReq := httptest.NewRequest(http.MethodPut, "/api/notes", strings.NewReader(`{"id":"note-1","title":"Renamed","content":"saved content"}`))
	updateReq.Header.Set("Content-Type", "application/json")
	updateReq.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	updateRes := httptest.NewRecorder()
	srv.ServeHTTP(updateRes, updateReq)

	if updateRes.Code != http.StatusOK {
		t.Fatalf("expected update status 200, got %d with body %q", updateRes.Code, updateRes.Body.String())
	}

	listReq := httptest.NewRequest(http.MethodGet, "/api/notes", nil)
	listReq.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	listRes := httptest.NewRecorder()
	srv.ServeHTTP(listRes, listReq)

	if listRes.Code != http.StatusOK {
		t.Fatalf("expected list status 200, got %d with body %q", listRes.Code, listRes.Body.String())
	}
	var listBody struct {
		Notes []system.Note `json:"notes"`
	}
	if err := json.Unmarshal(listRes.Body.Bytes(), &listBody); err != nil {
		t.Fatalf("list response is not JSON: %v", err)
	}
	if len(listBody.Notes) != 1 || listBody.Notes[0].Title != "Renamed" || listBody.Notes[0].Content != "saved content" {
		t.Fatalf("expected updated note in list, got %#v", listBody.Notes)
	}

	deleteReq := httptest.NewRequest(http.MethodDelete, "/api/notes?id=note-1", nil)
	deleteReq.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	deleteRes := httptest.NewRecorder()
	srv.ServeHTTP(deleteRes, deleteReq)

	if deleteRes.Code != http.StatusOK {
		t.Fatalf("expected delete status 200, got %d with body %q", deleteRes.Code, deleteRes.Body.String())
	}
	if len(notes) != 0 {
		t.Fatalf("expected notes to be deleted, got %#v", notes)
	}
}

func TestOverviewRejectsNonGetMethod(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/overview", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", res.Code)
	}
}

func TestSelfUpdateActionReturnsMonitorStartedMessage(t *testing.T) {
	started := false
	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		RunAction: func(action string) (system.CommandResult, error) {
			if action == "self-update" {
				started = true
				return system.CommandResult{
					Command:  "ccc-self-update",
					Output:   "Container Code Companion self-update monitor started.",
					ExitCode: 0,
				}, nil
			}
			return system.CommandResult{}, fmt.Errorf("unknown action: %s", action)
		},
	})
	req := httptest.NewRequest(http.MethodPost, "/api/action", strings.NewReader(`{"action":"self-update"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", res.Code, res.Body.String())
	}
	if !started {
		t.Fatal("expected RunAction to be called with self-update")
	}
	if !strings.Contains(res.Body.String(), "monitor started") {
		t.Fatalf("expected monitor started message, got %q", res.Body.String())
	}
}

func newTestServer() *Server {
	return New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		Overview: func() (system.Overview, error) {
			return system.Overview{Hostname: "test-host", IPs: []string{"192.0.2.10"}}, nil
		},
		Snapshot: func() (system.ManagementSnapshot, error) {
			return system.ManagementSnapshot{
				Services:      []system.ServiceStatus{{Name: "container-code-companion.service", Active: "active"}},
				Projects:      []system.ProjectStatus{{Name: "demo", Path: "/home/oculus/projects/demo"}},
				OculusConfigs: system.RepoStatus{Path: "/opt/oculus-configs", Branch: "main"},
			}, nil
		},
		RunCommand: func(command string, cwd string) (system.CommandResult, error) {
			return system.CommandResult{Command: command, Cwd: cwd, Output: "ran " + command + " in " + cwd}, nil
		},
		RunAction: func(action string) (system.CommandResult, error) {
			return system.CommandResult{Command: action, Output: "sync ok"}, nil
		},
		ListFiles: func(path string) (system.FileListing, error) {
			return system.FileListing{Path: path, Entries: []system.FileEntry{{Name: "README.md", Path: path + "/README.md", Type: "file"}}}, nil
		},
		ReadFile: func(path string) (system.FileContent, error) {
			return system.FileContent{Path: path, Content: "hello file"}, nil
		},
		WriteFile: func(path string, content string) error {
			return nil
		},
		ControlService: func(service string, operation string) (system.CommandResult, error) {
			return system.CommandResult{Command: operation + " " + service, Output: operation + " " + service}, nil
		},
		FileOperation: func(operation system.FileOperation) (system.CommandResult, error) {
			return system.CommandResult{Command: operation.Operation, Output: "renamed"}, nil
		},
		ProjectOperation: func(operation system.ProjectOperation) (system.CommandResult, error) {
			return system.CommandResult{Command: operation.Operation, Output: "created " + operation.Name}, nil
		},
		AccountOperation: func(operation system.AccountOperation) (system.CommandResult, error) {
			return system.CommandResult{Command: operation.Operation, Output: "account " + operation.Operation + " " + operation.Username}, nil
		},
		NetworkActivity: func() (system.NetworkActivity, error) {
			return system.NetworkActivity{Interfaces: []system.NetworkInterfaceActivity{{Name: "eth0", RXBytes: 1000, TXBytes: 500}}}, nil
		},
	})
}

func findCookie(cookies []*http.Cookie, name string) *http.Cookie {
	for _, cookie := range cookies {
		if cookie.Name == name {
			return cookie
		}
	}
	return nil
}

func TestProtectedFileUploadBatchWritesMultipleFiles(t *testing.T) {
	root := t.TempDir()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	for _, name := range []string{"first.txt", "second.txt"} {
		part, err := writer.CreateFormFile("file", name)
		if err != nil {
			t.Fatalf("create form file: %v", err)
		}
		_, _ = part.Write([]byte("content of " + name))
		_ = writer.WriteField("relpath", name)
	}
	_ = writer.Close()

	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/file-upload-batch?path="+root, &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", res.Code, res.Body.String())
	}
	var result map[string]any
	if err := json.Unmarshal(res.Body.Bytes(), &result); err != nil {
		t.Fatalf("response not JSON: %v", err)
	}
	if result["count"].(float64) != 2 {
		t.Fatalf("expected count 2, got %v", result["count"])
	}
	for _, name := range []string{"first.txt", "second.txt"} {
		content, err := os.ReadFile(filepath.Join(root, name))
		if err != nil {
			t.Fatalf("expected file %s: %v", name, err)
		}
		if string(content) != "content of "+name {
			t.Fatalf("wrong content for %s: %q", name, content)
		}
	}
}

func TestProtectedFileUploadBatchPreservesSubdirectories(t *testing.T) {
	root := t.TempDir()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "helpers.js")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	_, _ = part.Write([]byte("// helpers"))
	_ = writer.WriteField("relpath", "src/utils/helpers.js")
	_ = writer.Close()

	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/file-upload-batch?path="+root, &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", res.Code, res.Body.String())
	}
	content, err := os.ReadFile(filepath.Join(root, "src/utils/helpers.js"))
	if err != nil {
		t.Fatalf("expected nested file: %v", err)
	}
	if string(content) != "// helpers" {
		t.Fatalf("wrong content: %q", content)
	}
}

func TestProtectedFileUploadBatchRejectsTraversalRelPath(t *testing.T) {
	root := t.TempDir()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, _ := writer.CreateFormFile("file", "escape.txt")
	_, _ = part.Write([]byte("nope"))
	_ = writer.WriteField("relpath", "../escape.txt")
	_ = writer.Close()

	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/file-upload-batch?path="+root, &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)

	if res.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", res.Code)
	}
}

func TestProtectedFileDownloadZipReturnsZipForDirectory(t *testing.T) {
	root := t.TempDir()
	_ = os.WriteFile(filepath.Join(root, "hello.txt"), []byte("hello"), 0o644)

	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/file-download-zip?path="+root, nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", res.Code, res.Body.String())
	}
	if res.Header().Get("Content-Type") != "application/zip" {
		t.Fatalf("expected application/zip, got %q", res.Header().Get("Content-Type"))
	}
	expectedName := filepath.Base(root) + ".zip"
	if !strings.Contains(res.Header().Get("Content-Disposition"), expectedName) {
		t.Fatalf("expected filename %q in Content-Disposition, got %q", expectedName, res.Header().Get("Content-Disposition"))
	}
	body := res.Body.Bytes()
	zr, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		t.Fatalf("response is not a valid zip: %v", err)
	}
	// addDirToZip names entries as <dirname>/filename relative to the parent dir
	wantName := filepath.Base(root) + "/hello.txt"
	if len(zr.File) != 1 || zr.File[0].Name != wantName {
		names := make([]string, len(zr.File))
		for i, f := range zr.File {
			names[i] = f.Name
		}
		t.Fatalf("expected zip to contain exactly [%q], got %v", wantName, names)
	}
	rc, err := zr.File[0].Open()
	if err != nil {
		t.Fatalf("open zip entry: %v", err)
	}
	defer rc.Close()
	content, err := io.ReadAll(rc)
	if err != nil {
		t.Fatalf("read zip entry: %v", err)
	}
	if string(content) != "hello" {
		t.Fatalf("expected zip entry content %q, got %q", "hello", string(content))
	}
}

func TestProtectedFileDownloadZipReturnsZipForMultiplePaths(t *testing.T) {
	root := t.TempDir()
	fileA := filepath.Join(root, "a.txt")
	fileB := filepath.Join(root, "b.txt")
	_ = os.WriteFile(fileA, []byte("aaa"), 0o644)
	_ = os.WriteFile(fileB, []byte("bbb"), 0o644)

	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/file-download-zip?path="+fileA+"&path="+fileB, nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", res.Code, res.Body.String())
	}
	if !strings.Contains(res.Header().Get("Content-Disposition"), "download.zip") {
		t.Fatalf("expected download.zip in Content-Disposition, got %q", res.Header().Get("Content-Disposition"))
	}
	body := res.Body.Bytes()
	zr, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		t.Fatalf("response is not a valid zip: %v", err)
	}
	// addFileToZip stores plain files by basename
	if len(zr.File) != 2 {
		names := make([]string, len(zr.File))
		for i, f := range zr.File {
			names[i] = f.Name
		}
		t.Fatalf("expected exactly 2 files in zip, got %v", names)
	}
	wantNames := map[string]bool{"a.txt": true, "b.txt": true}
	for _, f := range zr.File {
		if !wantNames[f.Name] {
			t.Fatalf("unexpected zip entry %q, expected a.txt and b.txt", f.Name)
		}
	}
}

func TestProtectedFileDownloadZipRequiresAtLeastOnePath(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/file-download-zip", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)

	if res.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", res.Code)
	}
}

func TestClaudeSettingsRejectsGetWithoutUsername(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodGet, "/api/claude-settings", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", res.Code, res.Body.String())
	}
}

func TestClaudeSettingsPostCallsWriterAndReturnOutput(t *testing.T) {
	var capturedUsername, capturedHome string
	var capturedPatch map[string]any

	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		WriteClaudeSettings: func(username, home string, patch map[string]any) (system.CommandResult, error) {
			capturedUsername = username
			capturedHome = home
			capturedPatch = patch
			return system.CommandResult{Output: "settings updated"}, nil
		},
		ListAccounts: func() []system.AccountStatus {
			return []system.AccountStatus{{Username: "prime", Home: "/home/prime"}}
		},
	})

	body := `{"username":"prime","settings":{"autoCompactEnabled":true}}`
	req := httptest.NewRequest(http.MethodPost, "/api/claude-settings", strings.NewReader(body))
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()

	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", res.Code, res.Body.String())
	}
	if capturedUsername != "prime" {
		t.Errorf("username = %q, want prime", capturedUsername)
	}
	if capturedHome != "/home/prime" {
		t.Errorf("home = %q, want /home/prime", capturedHome)
	}
	if capturedPatch["autoCompactEnabled"] != true {
		t.Errorf("patch[autoCompactEnabled] = %v, want true", capturedPatch["autoCompactEnabled"])
	}
	var result map[string]any
	json.Unmarshal(res.Body.Bytes(), &result)
	if result["output"] != "settings updated" {
		t.Errorf("output = %v, want 'settings updated'", result["output"])
	}
}

func TestClaudeSettingsPostAllAccountsCallsWriterForEach(t *testing.T) {
	var written []string
	srv := New(Config{
		SessionToken: "test-token",
		Username:     "oculus",
		Password:     "secret",
		WebDir:       "../../web",
		WriteClaudeSettings: func(username, home string, patch map[string]any) (system.CommandResult, error) {
			written = append(written, username)
			return system.CommandResult{Output: "ok " + username}, nil
		},
		ListAccounts: func() []system.AccountStatus {
			return []system.AccountStatus{
				{Username: "prime", Home: "/home/prime"},
				{Username: "work", Home: "/home/work"},
			}
		},
	})

	body := `{"username":"prime","settings":{"autoCompactEnabled":true},"allAccounts":true}`
	req := httptest.NewRequest(http.MethodPost, "/api/claude-settings", strings.NewReader(body))
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", res.Code, res.Body.String())
	}
	if len(written) != 2 {
		t.Errorf("expected 2 write calls, got %d: %v", len(written), written)
	}
	if written[0] != "prime" || written[1] != "work" {
		t.Errorf("unexpected order: %v", written)
	}
}
