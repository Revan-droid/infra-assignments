package config

import (
	"strings"

	"github.com/spf13/viper"
)

// Config holds all application configuration loaded via Viper.
// Precedence: env vars > config.yaml > defaults.
type Config struct {
	Port          string   `mapstructure:"PORT"`
	LogLevel      string   `mapstructure:"LOG_LEVEL"`
	DatabaseURL   string   `mapstructure:"DATABASE_URL"`
	KafkaBrokers  []string `mapstructure:"KAFKA_BROKERS"`
	EnableKafka   bool     `mapstructure:"ENABLE_KAFKA"`
	EnableMetrics bool     `mapstructure:"ENABLE_METRICS"`
	OTLPEndpoint  string   `mapstructure:"OTLP_ENDPOINT"`
}

// Load reads configuration using Viper with fallback to defaults.
func Load() (*Config, error) {
	v := viper.New()

	v.SetDefault("PORT", "8080")
	v.SetDefault("LOG_LEVEL", "info")
	v.SetDefault("DATABASE_URL", "postgres://configuser:configpass@localhost:5432/configdb?sslmode=disable")
	v.SetDefault("KAFKA_BROKERS", []string{"localhost:9092"})
	v.SetDefault("ENABLE_KAFKA", false)
	v.SetDefault("ENABLE_METRICS", true)
	v.SetDefault("OTLP_ENDPOINT", "")

	v.SetConfigName("config")
	v.SetConfigType("yaml")
	v.AddConfigPath(".")
	v.AddConfigPath("/etc/config-service/")
	_ = v.ReadInConfig()

	v.AutomaticEnv()
	v.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))

	var cfg Config
	if err := v.Unmarshal(&cfg); err != nil {
		return nil, err
	}

	if raw := strings.TrimSpace(v.GetString("KAFKA_BROKERS")); raw != "" && !strings.Contains(raw, "[") {
		cfg.KafkaBrokers = cfg.KafkaBrokers[:0]
		for _, part := range strings.Split(raw, ",") {
			part = strings.TrimSpace(part)
			if part != "" {
				cfg.KafkaBrokers = append(cfg.KafkaBrokers, part)
			}
		}
	}

	return &cfg, nil
}
