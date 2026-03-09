package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

type listenerSpec struct {
	route       string
	bindAddress string
	port        int
}

func parseRouterConfig(path string) ([]listenerSpec, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open config: %w", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	var currentRoute string
	var bindAddress string
	var bindPort int
	var haveAddress bool
	var havePort bool
	var appended bool
	listeners := make([]listenerSpec, 0)

	resetRoute := func(route string) {
		currentRoute = route
		bindAddress = ""
		bindPort = 0
		haveAddress = false
		havePort = false
		appended = false
	}

	resetRoute("")

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}

		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section := strings.TrimSuffix(strings.TrimPrefix(line, "["), "]")
			if strings.HasPrefix(section, "routing:") {
				resetRoute(strings.TrimPrefix(section, "routing:"))
			} else {
				resetRoute("")
			}
			continue
		}

		if currentRoute == "" {
			continue
		}

		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)

		switch key {
		case "bind_address":
			bindAddress = value
			haveAddress = true
		case "bind_port":
			port, err := strconv.Atoi(value)
			if err != nil {
				continue
			}
			bindPort = port
			havePort = true
		}

		if !appended && haveAddress && havePort {
			listeners = append(listeners, listenerSpec{
				route:       currentRoute,
				bindAddress: bindAddress,
				port:        bindPort,
			})
			appended = true
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan config: %w", err)
	}

	if len(listeners) == 0 {
		return nil, fmt.Errorf("no routing listeners found in config")
	}

	return listeners, nil
}

func checkListener(address string, port int, timeout time.Duration) bool {
	address = normalizeBindAddress(address)
	target := fmt.Sprintf("%s:%d", address, port)
	conn, err := net.DialTimeout("tcp", target, timeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func normalizeBindAddress(address string) string {
	switch address {
	case "", "0.0.0.0":
		return "127.0.0.1"
	case "::", "::0":
		return "::1"
	default:
		return address
	}
}
