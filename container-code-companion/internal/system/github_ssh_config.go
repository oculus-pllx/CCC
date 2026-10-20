package system

import "strings"

// An account's ~/.ssh/config holds more than the GitHub machine key (deploy aliases for other
// hosts, for one). Writing the GitHub block must replace only that block, never the whole file.

func githubSSHConfigBlock(keyPath string) string {
	return "Host github.com\n  HostName github.com\n  User git\n  IdentityFile " + keyPath + "\n  IdentitiesOnly yes\n"
}

// Drops any existing `Host github.com` block (up to the next Host/Match line) and leading blank
// lines, keeping everything else. Must stay in step with mergeGitHubSSHConfig.
const stripGitHubSSHBlockAwk = `{ k = tolower($1) }
(k == "host" || k == "match") { skip = (k == "host" && NF == 2 && $2 == "github.com") }
skip { next }
!started && NF == 0 { next }
{ started = 1; print }`

// mergeGitHubSSHConfig puts the GitHub block first (ssh takes the first value it finds for each
// option) and keeps every other entry of the existing config.
func mergeGitHubSSHConfig(existing, keyPath string) string {
	var kept []string
	skip, started := false, false
	for _, line := range strings.Split(existing, "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 {
			if keyword := strings.ToLower(fields[0]); keyword == "host" || keyword == "match" {
				skip = keyword == "host" && len(fields) == 2 && fields[1] == "github.com"
			}
		}
		if skip || (!started && len(fields) == 0) {
			continue
		}
		started = true
		kept = append(kept, line)
	}
	rest := strings.TrimRight(strings.Join(kept, "\n"), "\n")
	if rest == "" {
		return githubSSHConfigBlock(keyPath)
	}
	return githubSSHConfigBlock(keyPath) + "\n" + rest + "\n"
}

// githubSSHConfigWriteCommand is the sudo shell form of mergeGitHubSSHConfig, for accounts whose
// ~/.ssh/config the web UI user cannot read directly. The caller sets ownership and mode.
func githubSSHConfigWriteCommand(configPath, keyPath string) string {
	return "sudo touch " + shellQuote(configPath) +
		" && rest=$(sudo cat " + shellQuote(configPath) + " | awk " + shellQuote(stripGitHubSSHBlockAwk) + ")" +
		" && { printf %s " + shellQuote(githubSSHConfigBlock(keyPath)) + "; if [ -n \"$rest\" ]; then printf '\\n%s\\n' \"$rest\"; fi; }" +
		" | sudo tee " + shellQuote(configPath) + " >/dev/null"
}
