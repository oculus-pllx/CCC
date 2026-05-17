package main

import (
	"crypto/rand"
	"encoding/hex"
	"log"
	"net/http"
	"os"

	"github.com/oculus-pllx/ccc/agent-workstation/internal/server"
)

func main() {
	addr := envDefault("AGENT_WORKSTATION_ADDR", ":9090")
	token := os.Getenv("AGENT_WORKSTATION_SESSION_TOKEN")
	username := envDefault("AGENT_WORKSTATION_USERNAME", "claude-code")
	password := os.Getenv("AGENT_WORKSTATION_PASSWORD")
	if token == "" {
		token = randomToken()
		log.Printf("generated session token for this process")
	}
	if password == "" {
		password = token
		log.Printf("generated login password for this process")
	}

	srv := server.New(server.Config{SessionToken: token, Username: username, Password: password})
	log.Printf("Agent Workstation listening on %s", addr)
	if err := http.ListenAndServe(addr, srv); err != nil {
		log.Fatal(err)
	}
}

func envDefault(name, fallback string) string {
	value := os.Getenv(name)
	if value == "" {
		return fallback
	}
	return value
}

func randomToken() string {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		log.Fatal(err)
	}
	return hex.EncodeToString(buf)
}
