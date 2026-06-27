package models

import (
	"strings"
	"time"
)

// Config represents a configuration record in the system.
type Config struct {
	ID        string    `json:"id" db:"id"`
	Host      string    `json:"host" db:"host"`
	Port      int       `json:"port" db:"port"`
	AppName   string    `json:"app_name" db:"app_name"`
	LogLevel  string    `json:"log_level" db:"log_level"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
	UpdatedAt time.Time `json:"updated_at" db:"updated_at"`
}

// UpsertRequest is the HTTP request body for POST /configs.
type UpsertRequest struct {
	ID       string `json:"id"`
	Host     string `json:"host"`
	Port     int    `json:"port"`
	AppName  string `json:"app_name"`
	LogLevel string `json:"log_level"`
}

// Validate returns an error string if required fields are missing.
func (r *UpsertRequest) Validate() string {
	if strings.TrimSpace(r.ID) == "" {
		return "id is required"
	}
	if strings.TrimSpace(r.Host) == "" {
		return "host is required"
	}
	if r.Port <= 0 || r.Port > 65535 {
		return "port must be between 1 and 65535"
	}
	if strings.TrimSpace(r.AppName) == "" {
		return "app_name is required"
	}
	if strings.TrimSpace(r.LogLevel) == "" {
		return "log_level is required"
	}

	switch strings.ToLower(strings.TrimSpace(r.LogLevel)) {
	case "debug", "info", "warn", "error":
		return ""
	default:
		return "log_level must be one of debug, info, warn, error"
	}
}

// ErrorResponse is the standard JSON error body.
type ErrorResponse struct {
	Error   string `json:"error"`
	Code    int    `json:"code"`
	TraceID string `json:"trace_id,omitempty"`
}
