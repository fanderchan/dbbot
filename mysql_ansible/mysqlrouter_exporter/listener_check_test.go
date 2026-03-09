package main

import (
	"os"
	"testing"
)

func TestParseRouterConfig(t *testing.T) {
	content := `# sample
[routing:bootstrap_rw]
bind_address=0.0.0.0
bind_port=6446
`
	file, err := os.CreateTemp("", "mysqlrouter.conf")
	if err != nil {
		t.Fatalf("create temp file: %v", err)
	}
	defer os.Remove(file.Name())
	if _, err := file.WriteString(content); err != nil {
		_ = file.Close()
		t.Fatalf("write temp file: %v", err)
	}
	_ = file.Close()

	listeners, err := parseRouterConfig(file.Name())
	if err != nil {
		t.Fatalf("parse config: %v", err)
	}
	if len(listeners) != 1 {
		t.Fatalf("expected 1 listener, got %d", len(listeners))
	}
	if listeners[0].route != "bootstrap_rw" || listeners[0].port != 6446 {
		t.Fatalf("unexpected listener: %+v", listeners[0])
	}
}
