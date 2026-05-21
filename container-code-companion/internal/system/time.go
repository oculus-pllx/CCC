package system

import (
	"errors"
	"strings"
	"time"
)

type TimeSettings struct {
	Timezone  string `json:"timezone"`
	LocalTime string `json:"localTime"`
	UTC       string `json:"utc"`
}

func CollectTimeSettings() (TimeSettings, error) {
	now := time.Now()
	zone, _ := now.Zone()
	timezone := strings.TrimSpace(runText("timedatectl", "show", "-p", "Timezone", "--value"))
	if timezone == "" {
		timezone = zone
	}
	return TimeSettings{
		Timezone:  timezone,
		LocalTime: now.Format("2006-01-02 15:04:05 MST"),
		UTC:       now.UTC().Format("2006-01-02 15:04:05 UTC"),
	}, nil
}

func SetTimezone(timezone string) (CommandResult, error) {
	timezone = strings.TrimSpace(timezone)
	if !validTimezoneName(timezone) {
		return CommandResult{}, errors.New("valid timezone is required")
	}
	return RunShellCommand("sudo timedatectl set-timezone "+shellQuote(timezone), workstationHome())
}

func validTimezoneName(timezone string) bool {
	if timezone == "" || len(timezone) > 80 || strings.Contains(timezone, "..") || strings.Contains(timezone, "//") {
		return false
	}
	for _, char := range timezone {
		if (char >= 'A' && char <= 'Z') || (char >= 'a' && char <= 'z') || (char >= '0' && char <= '9') || char == '/' || char == '_' || char == '-' || char == '+' {
			continue
		}
		return false
	}
	if strings.HasPrefix(timezone, "/") || strings.HasSuffix(timezone, "/") {
		return false
	}
	return true
}
