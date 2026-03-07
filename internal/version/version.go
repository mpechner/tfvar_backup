// Package version holds build-time version information injected via ldflags.
//
// The release workflow sets these with:
//
//	-ldflags "-X github.com/mpechner/tfvar_backup/internal/version.Version=v1.2.3
//	          -X github.com/mpechner/tfvar_backup/internal/version.Commit=abc1234
//	          -X github.com/mpechner/tfvar_backup/internal/version.Date=2026-03-06"
package version

import "fmt"

// These are set at build time via -ldflags. They default to "dev" so a
// locally built binary always reports something meaningful.
var (
	Version = "dev"
	Commit  = "none"
	Date    = "unknown"
)

// String returns a human-readable version string.
func String() string {
	return fmt.Sprintf("%s (commit %s, built %s)", Version, Commit, Date)
}
