# mysqlrouter_exporter

A Prometheus exporter for MySQL Router's REST API.

## Status

The standalone, productized project now lives at:

- `/usr/local/mysqlrouter_exporter`
- `https://github.com/fanderchan/mysqlrouter_exporter`

`dbbot` keeps a compatibility copy and deployment role for integrated delivery.

The `mysqlrouter_exporter` Ansible role now resolves the binary in this order:

1. `/usr/local/bin/mysqlrouter_exporter`
2. `/usr/local/mysqlrouter_exporter/dist/mysqlrouter_exporter-linux-amd64`
3. `/usr/local/mysqlrouter_exporter/build/mysqlrouter_exporter`
4. bundled fallback: `roles/mysqlrouter_exporter/files/mysqlrouter_exporter`

This keeps existing `dbbot` usage available while allowing the standalone project
to become the primary build and release source.

## Build

```bash
./build.sh
```

The binary is created at `build/mysqlrouter_exporter`.

## Run

```bash
./build/mysqlrouter_exporter --config /etc/mysqlrouter_exporter/config.yml
```

## Configuration

Example configuration:

```yaml
listen_address: ":9165"
metrics_path: "/metrics"
api_base_url: "https://127.0.0.1:8443/api/20190715"
api_user: "router_api_user"
api_password: "Dbbot_router_api_user@8888"
timeout_seconds: 5
insecure_skip_verify: true
collect_route_connections: false
router_config_file: "/var/lib/mysqlrouter/mysqlrouter.conf"
listener_check_enabled: true
listener_check_timeout_seconds: 1
```

`collect_route_connections` is disabled by default to avoid high-cardinality metrics.
`listener_check_enabled` reads `router_config_file` and checks whether each configured routing port is listening.

## Metrics (core)

- `mysqlrouter_up`
- `mysqlrouter_build_info{version,product_edition,hostname}`
- `mysqlrouter_start_time_seconds`
- `mysqlrouter_route_active_connections{route}`
- `mysqlrouter_route_total_connections{route}`
- `mysqlrouter_route_blocked_hosts{route}`
- `mysqlrouter_route_health{route}`
- `mysqlrouter_route_destination{route,address,port}`
- `mysqlrouter_metadata_refresh_succeeded{metadata}`
- `mysqlrouter_metadata_refresh_failed{metadata}`
- `mysqlrouter_metadata_last_refresh_success_timestamp_seconds{metadata}`
- `mysqlrouter_metadata_last_refresh_failure_timestamp_seconds{metadata}`
- `mysqlrouter_metadata_last_refresh_info{metadata,host,port}`
- `mysqlrouter_listener_up{route,bind_address,port}`
- `mysqlrouter_listener_all_up`
- `mysqlrouter_listener_check_enabled`
- `mysqlrouter_listener_check_error`
- `mysqlrouter_scrape_duration_seconds`
- `mysqlrouter_scrape_error`

Optional (when `collect_route_connections` is enabled):

- `mysqlrouter_route_connection_bytes_from_server{route}`
- `mysqlrouter_route_connection_bytes_to_server{route}`
- `mysqlrouter_route_connection_count{route}`
