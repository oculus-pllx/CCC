package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/oculus-pllx/ccc/agent-workstation/internal/system"
)

func TestHealthReturnsAgentWorkstationStatus(t *testing.T) {
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
	if body["name"] != "Agent Workstation" {
		t.Fatalf("expected Agent Workstation name, got %#v", body["name"])
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
	if !strings.Contains(res.Body.String(), "Agent Workstation") {
		t.Fatalf("expected index HTML to contain Agent Workstation, got %q", res.Body.String())
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
	if len(body.Services) == 0 || body.Services[0].Name != "agent-workstation.service" {
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
				Services:      []system.ServiceStatus{{Name: "agent-workstation.service", Active: "active"}},
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
