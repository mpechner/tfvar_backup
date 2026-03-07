// Package gitutil provides helpers for extracting git repository metadata.
package gitutil

import (
	"os/exec"
	"path/filepath"
	"strings"
)

// RepoName returns the repository name derived from the git remote "origin"
// URL of the repo rooted at dir.  The host, org, and ".git" suffix are all
// stripped so that both SSH and HTTPS remotes yield the same result:
//
//	git@github.com:org/tf_foobar.git  →  tf_foobar
//	https://github.com/org/tf_foobar  →  tf_foobar
//
// If no remote is configured, or dir is not a git repository, the basename
// of dir is returned as a fallback.
func RepoName(dir string) string {
	out, err := exec.Command("git", "-C", dir, "remote", "get-url", "origin").Output()
	if err == nil {
		raw := strings.TrimSpace(string(out))
		// strip everything up to and including the last / or :
		if idx := strings.LastIndexAny(raw, "/:"); idx >= 0 {
			raw = raw[idx+1:]
		}
		raw = strings.TrimSuffix(raw, ".git")
		if raw != "" {
			return raw
		}
	}

	// fallback: basename of the resolved directory
	return filepath.Base(dir)
}
