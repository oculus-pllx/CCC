package server

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/oculus-pllx/ccc/container-code-companion/internal/system"
)

const SessionCookieName = "aw_session"

type Config struct {
	SessionToken     string
	Username         string
	Password         string
	WebDir           string
	Overview         func() (system.Overview, error)
	Snapshot         func() (system.ManagementSnapshot, error)
	RunCommand       func(command string, cwd string) (system.CommandResult, error)
	RunAction        func(action string) (system.CommandResult, error)
	ListFiles        func(path string) (system.FileListing, error)
	ReadFile         func(path string) (system.FileContent, error)
	WriteFile        func(path string, content string) error
	UploadFile       func(dir string, filename string, source io.Reader) (system.UploadedFile, error)
	DownloadFile     func(path string) (system.DownloadFile, error)
	UploadFiles      func(destDir string, entries []system.BatchUploadEntry) ([]string, error)
	DownloadZip      func(w io.Writer, paths []string) error
	ControlService   func(service string, operation string) (system.CommandResult, error)
	FileOperation    func(operation system.FileOperation) (system.CommandResult, error)
	ProjectOperation func(operation system.ProjectOperation) (system.CommandResult, error)
	AccountOperation    func(operation system.AccountOperation) (system.CommandResult, error)
	WriteClaudeSettings func(username, home string, patch map[string]any) (system.CommandResult, error)
	ListAccounts        func() []system.AccountStatus
	NetworkActivity     func() (system.NetworkActivity, error)
	ListNotes        func() ([]system.Note, error)
	SaveNote         func(note system.Note) (system.Note, error)
	DeleteNote       func(id string) error
	TimeSettings     func() (system.TimeSettings, error)
	SetTimezone      func(timezone string) (system.CommandResult, error)
	ToolStatuses     func() []system.ToolStatus
	ToolOperation    func(operation system.ToolOperation) (system.CommandResult, error)
	DriveOperation   func(operation system.DriveOperation) (system.CommandResult, error)
	SecureCookies    bool // set true when serving behind HTTPS
}

type Server struct {
	mux              *http.ServeMux
	sessionToken     string
	username         string
	password         string
	webDir           string
	overview         func() (system.Overview, error)
	snapshot         func() (system.ManagementSnapshot, error)
	runCommand       func(command string, cwd string) (system.CommandResult, error)
	runAction        func(action string) (system.CommandResult, error)
	listFiles        func(path string) (system.FileListing, error)
	readFile         func(path string) (system.FileContent, error)
	writeFile        func(path string, content string) error
	uploadFile       func(dir string, filename string, source io.Reader) (system.UploadedFile, error)
	downloadFile     func(path string) (system.DownloadFile, error)
	uploadFiles      func(destDir string, entries []system.BatchUploadEntry) ([]string, error)
	downloadZip      func(w io.Writer, paths []string) error
	controlService   func(service string, operation string) (system.CommandResult, error)
	fileOperation    func(operation system.FileOperation) (system.CommandResult, error)
	projectOperation func(operation system.ProjectOperation) (system.CommandResult, error)
	accountOperation    func(operation system.AccountOperation) (system.CommandResult, error)
	writeClaudeSettings func(username, home string, patch map[string]any) (system.CommandResult, error)
	listAccounts        func() []system.AccountStatus
	networkActivity     func() (system.NetworkActivity, error)
	listNotes        func() ([]system.Note, error)
	saveNote         func(note system.Note) (system.Note, error)
	deleteNote       func(id string) error
	timeSettings     func() (system.TimeSettings, error)
	setTimezone      func(timezone string) (system.CommandResult, error)
	toolStatuses     func() []system.ToolStatus
	toolOperation    func(operation system.ToolOperation) (system.CommandResult, error)
	driveOperation   func(operation system.DriveOperation) (system.CommandResult, error)
	secureCookies    bool
}

func New(config Config) *Server {
	s := &Server{
		mux:              http.NewServeMux(),
		sessionToken:     config.SessionToken,
		username:         config.Username,
		password:         config.Password,
		webDir:           config.WebDir,
		overview:         config.Overview,
		snapshot:         config.Snapshot,
		runCommand:       config.RunCommand,
		runAction:        config.RunAction,
		listFiles:        config.ListFiles,
		readFile:         config.ReadFile,
		writeFile:        config.WriteFile,
		uploadFile:       config.UploadFile,
		downloadFile:     config.DownloadFile,
		uploadFiles:      config.UploadFiles,
		downloadZip:      config.DownloadZip,
		controlService:   config.ControlService,
		fileOperation:    config.FileOperation,
		projectOperation: config.ProjectOperation,
		accountOperation:    config.AccountOperation,
		writeClaudeSettings: config.WriteClaudeSettings,
		listAccounts:        config.ListAccounts,
		networkActivity:     config.NetworkActivity,
		listNotes:        config.ListNotes,
		saveNote:         config.SaveNote,
		deleteNote:       config.DeleteNote,
		timeSettings:     config.TimeSettings,
		setTimezone:      config.SetTimezone,
		toolStatuses:     config.ToolStatuses,
		toolOperation:    config.ToolOperation,
		driveOperation:   config.DriveOperation,
		secureCookies:    config.SecureCookies,
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
	if s.uploadFile == nil {
		s.uploadFile = system.SaveUploadedFile
	}
	if s.downloadFile == nil {
		s.downloadFile = system.PrepareFileDownload
	}
	if s.uploadFiles == nil {
		s.uploadFiles = system.SaveUploadedFiles
	}
	if s.downloadZip == nil {
		s.downloadZip = system.StreamZipDownload
	}
	if s.controlService == nil {
		s.controlService = system.ControlService
	}
	if s.fileOperation == nil {
		s.fileOperation = system.RunFileOperation
	}
	if s.projectOperation == nil {
		s.projectOperation = system.RunProjectOperation
	}
	if s.accountOperation == nil {
		s.accountOperation = system.RunAccountOperation
	}
	if s.writeClaudeSettings == nil {
		s.writeClaudeSettings = system.WriteClaudeSettings
	}
	if s.listAccounts == nil {
		s.listAccounts = system.ListAccounts
	}
	if s.networkActivity == nil {
		s.networkActivity = system.CollectNetworkActivity
	}
	if s.listNotes == nil {
		s.listNotes = system.ListNotes
	}
	if s.saveNote == nil {
		s.saveNote = system.SaveNote
	}
	if s.deleteNote == nil {
		s.deleteNote = system.DeleteNote
	}
	if s.timeSettings == nil {
		s.timeSettings = system.CollectTimeSettings
	}
	if s.setTimezone == nil {
		s.setTimezone = system.SetTimezone
	}
	if s.toolStatuses == nil {
		s.toolStatuses = system.CollectToolStatuses
	}
	if s.toolOperation == nil {
		s.toolOperation = system.RunToolOperation
	}
	if s.driveOperation == nil {
		s.driveOperation = system.RunDriveOperation
	}
	system.StartUpdateStatusPoller(4 * time.Hour)
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
	s.mux.Handle("/api/self-update", s.requireSession(http.HandlerFunc(s.handleSelfUpdate)))
	s.mux.Handle("/api/self-update-log", s.requireSession(http.HandlerFunc(s.handleSelfUpdateLog)))
	s.mux.Handle("/api/files", s.requireSession(http.HandlerFunc(s.handleFiles)))
	s.mux.Handle("/api/file", s.requireSession(http.HandlerFunc(s.handleFile)))
	s.mux.Handle("/api/file-upload", s.requireSession(http.HandlerFunc(s.handleFileUpload)))
	s.mux.Handle("/api/file-download", s.requireSession(http.HandlerFunc(s.handleFileDownload)))
	s.mux.Handle("/api/file-upload-batch", s.requireSession(http.HandlerFunc(s.handleFileUploadBatch)))
	s.mux.Handle("/api/file-download-zip", s.requireSession(http.HandlerFunc(s.handleFileDownloadZip)))
	s.mux.Handle("/api/file-op", s.requireSession(http.HandlerFunc(s.handleFileOperation)))
	s.mux.Handle("/api/service", s.requireSession(http.HandlerFunc(s.handleService)))
	s.mux.Handle("/api/project", s.requireSession(http.HandlerFunc(s.handleProject)))
	s.mux.Handle("/api/account", s.requireSession(http.HandlerFunc(s.handleAccount)))
	s.mux.Handle("/api/claude-settings", s.requireSession(http.HandlerFunc(s.handleClaudeSettings)))
	s.mux.Handle("/api/github", s.requireSession(http.HandlerFunc(s.handleGitHub)))
	s.mux.Handle("/api/network-activity", s.requireSession(http.HandlerFunc(s.handleNetworkActivity)))
	s.mux.Handle("/api/notes", s.requireSession(http.HandlerFunc(s.handleNotes)))
	s.mux.Handle("/api/time-settings", s.requireSession(http.HandlerFunc(s.handleTimeSettings)))
	s.mux.Handle("/api/tools", s.requireSession(http.HandlerFunc(s.handleTools)))
	s.mux.Handle("/api/drive", s.requireSession(http.HandlerFunc(s.handleDrive)))
	s.mux.Handle("/api/pty", s.requireSession(http.HandlerFunc(s.handlePTY)))
	s.mux.Handle("/", s.staticHandler())
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":   true,
		"name": "Container Code Companion",
	})
}

func (s *Server) handleOverview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
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

// handleSelfUpdate launches ccc-self-update as a detached background process
// and returns immediately. The client then polls /api/self-update-log to
// stream progress. This survives the systemd service restart that occurs at
// step 4 of the update because the child process runs outside the service
// cgroup (via setsid) and writes to /var/log/ccc-self-update.log.
func (s *Server) handleSelfUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	result, err := s.runAction("self-update")
	if err != nil {
		writeJSON(w, http.StatusOK, result)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

// handleSelfUpdateLog returns the current contents of the self-update log and
// whether ccc-self-update is still running. The client polls this every two
// seconds to stream update progress, including after a service restart.
func (s *Server) handleSelfUpdateLog(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	log, _ := os.ReadFile("/var/log/ccc-self-update.log")
	writeJSON(w, http.StatusOK, map[string]any{
		"log":     string(log),
		"running": system.IsSelfUpdateRunning(),
	})
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

func (s *Server) handleFileUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseMultipartForm(64 * 1024 * 1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid upload request"})
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "upload file is required"})
		return
	}
	defer file.Close()
	filename, err := safeUploadFilename(header)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	uploaded, err := s.uploadFile(r.URL.Query().Get("path"), filename, file)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "file": uploaded})
}

func (s *Server) handleFileDownload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	download, err := s.downloadFile(r.URL.Query().Get("path"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", download.Name))
	w.Header().Set("Content-Length", fmt.Sprintf("%d", download.Size))
	http.ServeFile(w, r, download.Path)
}

func (s *Server) handleFileUploadBatch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseMultipartForm(64 * 1024 * 1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid upload request"})
		return
	}
	form := r.MultipartForm
	fileHeaders := form.File["file"]
	relPaths := form.Value["relpath"]
	if len(fileHeaders) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "at least one file is required"})
		return
	}
	entries := make([]system.BatchUploadEntry, 0, len(fileHeaders))
	files := make([]multipart.File, 0, len(fileHeaders))
	for i, header := range fileHeaders {
		relPath := header.Filename
		if i < len(relPaths) {
			relPath = relPaths[i]
		}
		file, err := header.Open()
		if err != nil {
			for _, f := range files {
				f.Close()
			}
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "could not read uploaded file"})
			return
		}
		files = append(files, file)
		entries = append(entries, system.BatchUploadEntry{RelPath: relPath, Reader: file})
	}
	written, err := s.uploadFiles(r.URL.Query().Get("path"), entries)
	for _, f := range files {
		f.Close()
	}
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "count": len(written), "files": written})
}

func (s *Server) handleFileDownloadZip(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	paths := r.URL.Query()["path"]
	if len(paths) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "at least one path is required"})
		return
	}
	zipName := "download.zip"
	if len(paths) == 1 {
		base := filepath.Base(paths[0])
		if base != "" && base != "." && base != ".." && base != "/" {
			zipName = base + ".zip"
		}
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", zipName))
	if err := s.downloadZip(w, paths); err != nil {
		log.Printf("downloadZip error: %v", err)
	}
}

func safeUploadFilename(header *multipart.FileHeader) (string, error) {
	_, params, err := mime.ParseMediaType(header.Header.Get("Content-Disposition"))
	if err != nil {
		return "", fmt.Errorf("invalid upload filename")
	}
	raw := params["filename"]
	if strings.TrimSpace(raw) == "" || strings.ContainsAny(raw, `/\`) {
		return "", fmt.Errorf("valid upload filename is required")
	}
	return header.Filename, nil
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

func (s *Server) handleFileOperation(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var body system.FileOperation
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid file operation request", http.StatusBadRequest)
		return
	}
	result, err := s.fileOperation(body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleProject(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var body system.ProjectOperation
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid project request", http.StatusBadRequest)
		return
	}
	result, err := s.projectOperation(body)
	if err != nil {
		message := err.Error()
		if strings.TrimSpace(result.Output) != "" {
			message += "\n\n" + strings.TrimSpace(result.Output)
		}
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": message})
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleAccount(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var body system.AccountOperation
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid account request", http.StatusBadRequest)
		return
	}
	result, err := s.accountOperation(body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleClaudeSettings(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		username := strings.TrimSpace(r.URL.Query().Get("username"))
		if username == "" {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "username is required"})
			return
		}
		settings, _ := system.ReadClaudeSettings("/home/" + username)
		writeJSON(w, http.StatusOK, map[string]any{"settings": settings})
	case http.MethodPost:
		var body struct {
			Username    string         `json:"username"`
			Settings    map[string]any `json:"settings"`
			AllAccounts bool           `json:"allAccounts"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		if body.AllAccounts {
			accounts := s.listAccounts()
			var lines []string
			for _, acc := range accounts {
				result, _ := s.writeClaudeSettings(acc.Username, acc.Home, body.Settings)
				lines = append(lines, result.Output)
			}
			writeJSON(w, http.StatusOK, system.CommandResult{Output: strings.Join(lines, "\n")})
			return
		}
		result, err := s.writeClaudeSettings(body.Username, "/home/"+body.Username, body.Settings)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, result)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleNetworkActivity(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	activity, err := s.networkActivity()
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, activity)
}

func (s *Server) handleNotes(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		notes, err := s.listNotes()
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"notes": notes})
	case http.MethodPost, http.MethodPut:
		var note system.Note
		if err := json.NewDecoder(r.Body).Decode(&note); err != nil {
			http.Error(w, "invalid note request", http.StatusBadRequest)
			return
		}
		saved, err := s.saveNote(note)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, saved)
	case http.MethodDelete:
		id := strings.TrimSpace(r.URL.Query().Get("id"))
		if id == "" {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "note id is required"})
			return
		}
		if err := s.deleteNote(id); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleTimeSettings(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		settings, err := s.timeSettings()
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, settings)
	case http.MethodPost:
		var body struct {
			Timezone string `json:"timezone"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid time settings request", http.StatusBadRequest)
			return
		}
		result, err := s.setTimezone(body.Timezone)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "output": result.Output})
			return
		}
		writeJSON(w, http.StatusOK, result)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleTools(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]any{"tools": s.toolStatuses()})
	case http.MethodPost:
		var body system.ToolOperation
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid tool request", http.StatusBadRequest)
			return
		}
		result, err := s.toolOperation(body)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "output": result.Output})
			return
		}
		writeJSON(w, http.StatusOK, result)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleDrive(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var body system.DriveOperation
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid drive request", http.StatusBadRequest)
		return
	}
	result, err := s.driveOperation(body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "output": result.Output})
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleGitHub(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		status, err := system.CollectGitHubStatus()
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, status)
	case http.MethodPost:
		var body struct {
			Action    string   `json:"action"`
			Usernames []string `json:"usernames"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		result, err := system.RunGitHubOperation(body.Action, body.Usernames...)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "output": result.Output})
			return
		}
		writeJSON(w, http.StatusOK, result)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
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
	http.SetCookie(w, s.sessionCookie(s.sessionToken, 0))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleLogout(w http.ResponseWriter, _ *http.Request) {
	http.SetCookie(w, s.sessionCookie("", -1))
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

func (s *Server) sessionCookie(value string, maxAge int) *http.Cookie {
	return &http.Cookie{
		Name:     SessionCookieName,
		Value:    value,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   s.secureCookies,
		MaxAge:   maxAge,
	}
}

func (s *Server) staticHandler() http.Handler {
	webDir := "web"
	if s.webDir != "" {
		webDir = s.webDir
	}
	if configured, ok := os.LookupEnv("CONTAINER_CODE_COMPANION_WEB_DIR"); ok && configured != "" {
		webDir = configured
	}
	fileServer := http.FileServer(http.Dir(webDir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
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
