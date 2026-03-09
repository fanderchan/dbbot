package main

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v2"
)

type Config struct {
	ListenAddress           string `yaml:"listen_address"`
	MetricsPath             string `yaml:"metrics_path"`
	APIBaseURL              string `yaml:"api_base_url"`
	APIUser                 string `yaml:"api_user"`
	APIPassword             string `yaml:"api_password"`
	TimeoutSeconds          int    `yaml:"timeout_seconds"`
	InsecureSkipVerify      bool   `yaml:"insecure_skip_verify"`
	CollectRouteConnections bool   `yaml:"collect_route_connections"`
	RouterConfigFile        string `yaml:"router_config_file"`
	ListenerCheckEnabled    bool   `yaml:"listener_check_enabled"`
	ListenerCheckTimeout    int    `yaml:"listener_check_timeout_seconds"`
}

func defaultConfig() Config {
	return Config{
		ListenAddress:           ":9165",
		MetricsPath:             "/metrics",
		APIBaseURL:              "https://127.0.0.1:8443/api/20190715",
		APIUser:                 "router_api_user",
		APIPassword:             "Dbbot_router_api_user@8888",
		TimeoutSeconds:          5,
		InsecureSkipVerify:      true,
		CollectRouteConnections: false,
		RouterConfigFile:        "/var/lib/mysqlrouter/mysqlrouter.conf",
		ListenerCheckEnabled:    true,
		ListenerCheckTimeout:    1,
	}
}

func LoadConfig(path string) (Config, error) {
	cfg := defaultConfig()

	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}

	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}

	cfg.normalize()
	if err := cfg.validate(); err != nil {
		return Config{}, err
	}

	return cfg, nil
}

func (c *Config) normalize() {
	c.APIBaseURL = strings.TrimRight(c.APIBaseURL, "/")
	if c.MetricsPath == "" {
		c.MetricsPath = "/metrics"
	} else if !strings.HasPrefix(c.MetricsPath, "/") {
		c.MetricsPath = "/" + c.MetricsPath
	}
	if c.ListenAddress == "" {
		c.ListenAddress = ":9165"
	}
	if c.TimeoutSeconds <= 0 {
		c.TimeoutSeconds = 5
	}
	if c.RouterConfigFile == "" {
		c.RouterConfigFile = "/var/lib/mysqlrouter/mysqlrouter.conf"
	}
	if c.ListenerCheckTimeout <= 0 {
		c.ListenerCheckTimeout = 1
	}
}

func (c Config) validate() error {
	if c.APIBaseURL == "" {
		return fmt.Errorf("api_base_url is required")
	}
	if c.APIUser == "" {
		return fmt.Errorf("api_user is required")
	}
	if c.APIPassword == "" {
		return fmt.Errorf("api_password is required")
	}
	return nil
}
