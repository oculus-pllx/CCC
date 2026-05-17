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
	SessionToken string
	WebDir       string
	Overview     func() (system.Overview, error)
}

type Server struct {
	mux          *http.ServeMux
	sessionToken string
	webDir       string
	overview     func() (system.Overview, error)
}

func New(config Config) *Server {
	s := &Server{
		mux:          http.NewServeMux(),
		sessionToken: config.SessionToken,
		webDir:       config.WebDir,
		overview:     config.Overview,
	}
	if s.overview == nil {
		s.overview = system.CollectOverview
	}
	s.routes()
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mux.ServeHTTP(w, r)
}

func (s *Server) routes() {
	s.mux.HandleFunc("/api/health", s.handleHealth)
	s.mux.Handle("/api/overview", s.requireSession(http.HandlerFunc(s.handleOverview)))
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
