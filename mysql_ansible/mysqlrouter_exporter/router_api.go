package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"
)

type APIClient struct {
	baseURL  string
	user     string
	password string
	client   *http.Client
	timeout  time.Duration
}

func NewAPIClient(cfg Config) *APIClient {
	transport := &http.Transport{}
	if cfg.InsecureSkipVerify {
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	}

	return &APIClient{
		baseURL:  cfg.APIBaseURL,
		user:     cfg.APIUser,
		password: cfg.APIPassword,
		client: &http.Client{
			Transport: transport,
			Timeout:   time.Duration(cfg.TimeoutSeconds) * time.Second,
		},
		timeout: time.Duration(cfg.TimeoutSeconds) * time.Second,
	}
}

func (c *APIClient) getJSON(path string, out interface{}) error {
	ctx, cancel := context.WithTimeout(context.Background(), c.timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+path, nil)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.SetBasicAuth(c.user, c.password)

	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status: %s", resp.Status)
	}

	dec := json.NewDecoder(resp.Body)
	if err := dec.Decode(out); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	return nil
}

type routerStatus struct {
	ProcessID      int    `json:"processId"`
	ProductEdition string `json:"productEdition"`
	TimeStarted    string `json:"timeStarted"`
	Version        string `json:"version"`
	Hostname       string `json:"hostname"`
}

type routeList struct {
	Items []routeItem `json:"items"`
}

type routeItem struct {
	Name string `json:"name"`
}

type routeStatus struct {
	ActiveConnections int64 `json:"activeConnections"`
	TotalConnections  int64 `json:"totalConnections"`
	BlockedHosts      int64 `json:"blockedHosts"`
}

type routeHealth struct {
	IsAlive bool `json:"isAlive"`
}

type routeDestinations struct {
	Items []routeDestination `json:"items"`
}

type routeDestination struct {
	Address string `json:"address"`
	Port    int    `json:"port"`
}

type routeConnections struct {
	Items []routeConnection `json:"items"`
}

type routeConnection struct {
	BytesFromServer int64 `json:"bytesFromServer"`
	BytesToServer   int64 `json:"bytesToServer"`
}

type metadataList struct {
	Items []metadataItem `json:"items"`
}

type metadataItem struct {
	Name string `json:"name"`
}

type metadataStatus struct {
	RefreshFailed            int64  `json:"refreshFailed"`
	RefreshSucceeded         int64  `json:"refreshSucceeded"`
	TimeLastRefreshSucceeded string `json:"timeLastRefreshSucceeded"`
	LastRefreshHostname      string `json:"lastRefreshHostname"`
	LastRefreshPort          int    `json:"lastRefreshPort"`
	TimeLastRefreshFailed    string `json:"timeLastRefreshFailed"`
}

func (c *APIClient) RouterStatus() (routerStatus, error) {
	var resp routerStatus
	if err := c.getJSON("/router/status", &resp); err != nil {
		return routerStatus{}, err
	}
	return resp, nil
}

func (c *APIClient) Routes() ([]string, error) {
	var resp routeList
	if err := c.getJSON("/routes", &resp); err != nil {
		return nil, err
	}

	out := make([]string, 0, len(resp.Items))
	for _, item := range resp.Items {
		if item.Name != "" {
			out = append(out, item.Name)
		}
	}
	return out, nil
}

func (c *APIClient) RouteStatus(route string) (routeStatus, error) {
	var resp routeStatus
	path := "/routes/" + url.PathEscape(route) + "/status"
	if err := c.getJSON(path, &resp); err != nil {
		return routeStatus{}, err
	}
	return resp, nil
}

func (c *APIClient) RouteHealth(route string) (routeHealth, error) {
	var resp routeHealth
	path := "/routes/" + url.PathEscape(route) + "/health"
	if err := c.getJSON(path, &resp); err != nil {
		return routeHealth{}, err
	}
	return resp, nil
}

func (c *APIClient) RouteDestinations(route string) ([]routeDestination, error) {
	var resp routeDestinations
	path := "/routes/" + url.PathEscape(route) + "/destinations"
	if err := c.getJSON(path, &resp); err != nil {
		return nil, err
	}
	return resp.Items, nil
}

func (c *APIClient) RouteConnections(route string) ([]routeConnection, error) {
	var resp routeConnections
	path := "/routes/" + url.PathEscape(route) + "/connections"
	if err := c.getJSON(path, &resp); err != nil {
		return nil, err
	}
	return resp.Items, nil
}

func (c *APIClient) Metadata() ([]string, error) {
	var resp metadataList
	if err := c.getJSON("/metadata", &resp); err != nil {
		return nil, err
	}

	out := make([]string, 0, len(resp.Items))
	for _, item := range resp.Items {
		if item.Name != "" {
			out = append(out, item.Name)
		}
	}
	return out, nil
}

func (c *APIClient) MetadataStatus(name string) (metadataStatus, error) {
	var resp metadataStatus
	path := "/metadata/" + url.PathEscape(name) + "/status"
	if err := c.getJSON(path, &resp); err != nil {
		return metadataStatus{}, err
	}
	return resp, nil
}
