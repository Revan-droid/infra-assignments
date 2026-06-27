// Package migrations exposes the embedded SQL migration files.
// The embed.FS is used by internal/database to run migrations at startup
// without requiring external SQL files on the filesystem.
package migrations

import "embed"

// FS contains all *.sql migration files embedded at compile time.
//
//go:embed *.sql
var FS embed.FS
