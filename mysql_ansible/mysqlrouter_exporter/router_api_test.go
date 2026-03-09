package main

import (
	"encoding/json"
	"testing"
)

func TestDecodeRouterStatus(t *testing.T) {
	payload := []byte(`{"processId":15043,"productEdition":"MySQL Community - GPL","timeStarted":"2025-12-19T17:03:27.585717Z","version":"8.4.7","hostname":"192-168-199-151"}`)
	var status routerStatus
	if err := json.Unmarshal(payload, &status); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if status.Version != "8.4.7" {
		t.Fatalf("unexpected version: %s", status.Version)
	}
}

func TestDecodeRoutes(t *testing.T) {
	payload := []byte(`{"items":[{"name":"bootstrap_rw"}]}`)
	var routes routeList
	if err := json.Unmarshal(payload, &routes); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(routes.Items) != 1 || routes.Items[0].Name != "bootstrap_rw" {
		t.Fatalf("unexpected routes: %+v", routes.Items)
	}
}

func TestDecodeRouteStatus(t *testing.T) {
	payload := []byte(`{"activeConnections":1,"totalConnections":13956,"blockedHosts":0}`)
	var status routeStatus
	if err := json.Unmarshal(payload, &status); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if status.ActiveConnections != 1 || status.TotalConnections != 13956 {
		t.Fatalf("unexpected status: %+v", status)
	}
}

func TestDecodeMetadataStatus(t *testing.T) {
	payload := []byte(`{"refreshFailed":2,"refreshSucceeded":698,"timeLastRefreshSucceeded":"2025-12-20T04:51:54.499189Z","lastRefreshHostname":"192.0.2.131","lastRefreshPort":3306,"timeLastRefreshFailed":"2025-12-19T20:17:46.669200Z"}`)
	var status metadataStatus
	if err := json.Unmarshal(payload, &status); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if status.RefreshSucceeded != 698 || status.LastRefreshPort != 3306 {
		t.Fatalf("unexpected metadata status: %+v", status)
	}
}

func TestParseTimeToUnix(t *testing.T) {
	value := "2025-12-20T04:51:54.499189Z"
	if _, ok := parseTimeToUnix(value); !ok {
		t.Fatalf("expected parse to succeed")
	}
}
