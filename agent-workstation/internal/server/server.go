package server

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"

	"github.com/oculus-pllx/ccc/agent-workstation/internal/system"
)

const SessionCookieName = "aw_session"

type Config struct {
	SessionToken   string
	Username       string
	Password       string
	WebDir         string
	Overview       func() (system.Overview, error)
	Snapshot       func() (system.ManagementSnapshot, error)
	RunCommand     func(command string, cwd string) (system.CommandResult, error)
	RunAction      func(action string) (system.CommandResult, error)
	ListFiles      func(path string) (system.FileListing, error)
	ReadFile       func(path string) (system.FileContent, error)
	WriteFile      func(path string, content string) error
	ControlService func(service string, operation string) (system.CommandResult, error)
}

type Server struct {
	mux            *http.ServeMux
	sessionToken   string
	username       string
	password       string
	webDir         string
	overview       func() (system.Overview, error)
	snapshot       func() (system.ManagementSnapshot, error)
	runCommand     func(command string, cwd string) (system.CommandResult, error)
	runAction      func(action string) (system.CommandResult, error)
	listFiles      func(path string) (system.FileListing, error)
	readFile       func(path string) (system.FileContent, error)
	writeFile      func(path string, content string) error
	controlService func(service string, operation string) (system.CommandResult, error)
}

func New(config Config) *Server {
	s := &Server{
		mux:            http.NewServeMux(),
		sessionToken:   config.SessionToken,
		username:       config.Username,
		password:       config.Password,
		webDir:         config.WebDir,
		overview:       config.Overview,
		snapshot:       config.Snapshot,
		runCommand:     config.RunCommand,
		runAction:      config.RunAction,
		listFiles:      config.ListFiles,
		readFile:       config.ReadFile,
		writeFile:      config.WriteFile,
		controlService: config.ControlService,
	}
	if s.overview == nil {
		s.overview = system.CollectOverview
	}
	if s.snapshot == nil {
		s.snapshot = system.CollectManagementSnapshot
	}
	if s.runCommand == nil {
		s.runCommand = system.RunShellCommand
	}
	if s.runAction == nil {
		s.runAction = system.RunWorkstationAction
	}
	if s.listFiles == nil {
		s.listFiles = system.BrowseFiles
	}
	if s.readFile == nil {
		s.readFile = system.ReadTextFile
	}
	if s.writeFile == nil {
		s.writeFile = system.WriteTextFile
	}
	if s.controlService == nil {
		s.controlService = system.ControlService
	}
	s.routes()
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mux.ServeHTTP(w, r)
}

func (s *Server) routes() {
	s.mux.HandleFunc("/api/health", s.handleHealth)
	s.mux.HandleFunc("/api/login", s.handleLogin)
	s.mux.Handle("/api/logout", s.requireSession(http.HandlerFunc(s.handleLogout)))
	s.mux.Handle("/api/overview", s.requireSession(http.HandlerFunc(s.handleOverview)))
	s.mux.Handle("/api/workstation", s.requireSession(http.HandlerFunc(s.handleWorkstation)))
	s.mux.Handle("/api/terminal", s.requireSession(http.HandlerFunc(s.handleTerminal)))
	s.mux.Handle("/api/action", s.requireSession(http.HandlerFunc(s.handleAction)))
	s.mux.Handle("/api/files", s.requireSession(http.HandlerFunc(s.handleFiles)))
	s.mux.Handle("/api/file", s.requireSession(http.HandlerFunc(s.handleFile)))
	s.mux.Handle("/api/service", s.requireSession(http.HandlerFunc(s.handleService)))
	s.mux.Handle("/", s.staticHandler())
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":   true,
		"name": "Agent Workstation",
	})
}

func (s *Server) handleOverview(w http.ResponseWriter, _ *http.Request) {
	overview, err := s.overview()
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, overview)
}

func (s *Server) handleWorkstation(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	snapshot, err := s.snapshot()
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, snapshot)
}

func (s *Server) handleTerminal(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Command string `json:"command"`
		Cwd     string `json:"cwd"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid terminal request", http.StatusBadRequest)
		return
	}
	result, err := s.runCommand(body.Command, body.Cwd)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Action string `json:"action"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid action request", http.StatusBadRequest)
		return
	}
	result, err := s.runAction(body.Action)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleFiles(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	listing, err := s.listFiles(r.URL.Query().Get("path"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, listing)
}

func (s *Server) handleFile(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		content, err := s.readFile(r.URL.Query().Get("path"))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, content)
	case http.MethodPut:
		var body struct {
			Path    string `json:"path"`
			Content string `json:"content"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid file request", http.StatusBadRequest)
			return
		}
		if err := s.writeFile(body.Path, body.Content); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "status": "saved"})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleService(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Service   string `json:"service"`
		Operation string `json:"operation"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid service request", http.StatusBadRequest)
		return
	}
	result, err := s.controlService(body.Service, body.Operation)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.username == "" || s.password == "" || s.sessionToken == "" {
		http.Error(w, "login is not configured", http.StatusInternalServerError)
		return
	}
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid login request", http.StatusBadRequest)
		return
	}
	if body.Username != s.username || body.Password != s.password {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	http.SetCookie(w, sessionCookie(s.sessionToken, 0))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleLogout(w http.ResponseWriter, _ *http.Request) {
	http.SetCookie(w, sessionCookie("", -1))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) requireSession(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.sessionToken == "" {
			http.Error(w, "session token is not configured", http.StatusInternalServerError)
			return
		}
		cookie, err := r.Cookie(SessionCookieName)
		if err != nil || cookie.Value != s.sessionToken {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func sessionCookie(value string, maxAge int) *http.Cookie {
	return &http.Cookie{
		Name:     SessionCookieName,
		Value:    value,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   maxAge,
	}
}

func (s *Server) staticHandler() http.Handler {
	webDir := "web"
	if s.webDir != "" {
		webDir = s.webDir
	}
	if configured, ok := os.LookupEnv("AGENT_WORKSTATION_WEB_DIR"); ok && configured != "" {
		webDir = configured
	}
	fileServer := http.FileServer(http.Dir(webDir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			http.NotFound(w, r)
			return
		}
		if r.URL.Path == "/" {
			http.ServeFile(w, r, webDir+"/index.html")
			return
		}
		fileServer.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
