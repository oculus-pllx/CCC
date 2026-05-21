package system

import "testing"

func TestValidTimezoneName(t *testing.T) {
	valid := []string{"UTC", "America/New_York", "Europe/London", "Etc/UTC"}
	for _, timezone := range valid {
		if !validTimezoneName(timezone) {
			t.Fatalf("expected %q to be valid", timezone)
		}
	}

	invalid := []string{"", "../UTC", "America New_York", "America/New_York;reboot", "/UTC", "America//New_York"}
	for _, timezone := range invalid {
		if validTimezoneName(timezone) {
			t.Fatalf("expected %q to be invalid", timezone)
		}
	}
}
