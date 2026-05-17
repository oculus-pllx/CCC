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

func newTestServer() *Server {
	return New(Config{
		SessionToken: "test-token",
		WebDir:       "../../web",
		Overview: func() (system.Overview, error) {
			return system.Overview{Hostname: "test-host", IPs: []string{"192.0.2.10"}}, nil
		},
	})
}
