package domain

// Config holds the fields for a configuration record.
type Config struct {
	ID       string `json:"id"`
	Host     string `json:"host"`
	Port     int    `json:"port"`
	AppName  string `json:"app_name"`
	LogLevel string `json:"log_level"`
}
