package server

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"

	"github.com/creack/pty"
	"github.com/gorilla/websocket"
)

var ptyUpgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}

type ptyMessage struct {
	Type string `json:"type"`
	Data string `json:"data"`
	Cols uint16 `json:"cols"`
	Rows uint16 `json:"rows"`
}

func (s *Server) handlePTY(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	conn, err := ptyUpgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()

	home := os.Getenv("HOME")
	if home == "" {
		home = "/home/" + s.username
	}
	cwd := filepath.Join(home, "projects")
	if _, err := os.Stat(cwd); err != nil {
		cwd = home
	}

	cmd := exec.Command("bash", "-l")
	cmd.Dir = cwd
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")
	terminal, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 30, Cols: 100})
	if err != nil {
		_ = conn.WriteMessage(websocket.TextMessage, []byte(err.Error()))
		return
	}
	defer terminal.Close()
	defer cmd.Process.Kill()

	var writeMu sync.Mutex
	done := make(chan struct{})
	go func() {
		defer close(done)
		buffer := make([]byte, 8192)
		for {
			n, err := terminal.Read(buffer)
			if n > 0 {
				writeMu.Lock()
				_ = conn.WriteMessage(websocket.TextMessage, buffer[:n])
				writeMu.Unlock()
			}
			if err != nil {
				if err != io.EOF {
					writeMu.Lock()
					_ = conn.WriteMessage(websocket.TextMessage, []byte("\r\n[terminal closed]\r\n"))
					writeMu.Unlock()
				}
				return
			}
		}
	}()

	for {
		_, payload, err := conn.ReadMessage()
		if err != nil {
			return
		}
		var message ptyMessage
		if err := json.Unmarshal(payload, &message); err != nil {
			continue
		}
		switch message.Type {
		case "input":
			_, _ = terminal.Write([]byte(message.Data))
		case "resize":
			if message.Cols > 0 && message.Rows > 0 {
				_ = pty.Setsize(terminal, &pty.Winsize{Rows: message.Rows, Cols: message.Cols})
			}
		}
		select {
		case <-done:
			return
		default:
		}
	}
}
