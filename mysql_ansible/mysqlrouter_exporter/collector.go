package main

import (
	"log"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

type Exporter struct {
	client                   *APIClient
	collectRouteConnections  bool
	routerConfigFile         string
	listenerCheckEnabled     bool
	listenerCheckTimeout     time.Duration
	logger                   *log.Logger
	upDesc                   *prometheus.Desc
	scrapeDurationDesc       *prometheus.Desc
	scrapeErrorDesc          *prometheus.Desc
	buildInfoDesc            *prometheus.Desc
	startTimeDesc            *prometheus.Desc
	routeActiveConnDesc      *prometheus.Desc
	routeTotalConnDesc       *prometheus.Desc
	routeBlockedHostsDesc    *prometheus.Desc
	routeHealthDesc          *prometheus.Desc
	routeDestinationDesc     *prometheus.Desc
	metadataRefreshOKDesc    *prometheus.Desc
	metadataRefreshFailDesc  *prometheus.Desc
	metadataLastOKDesc       *prometheus.Desc
	metadataLastFailDesc     *prometheus.Desc
	metadataLastInfoDesc     *prometheus.Desc
	routeConnBytesFromDesc   *prometheus.Desc
	routeConnBytesToDesc     *prometheus.Desc
	routeConnCountDesc       *prometheus.Desc
	listenerUpDesc           *prometheus.Desc
	listenerAllUpDesc        *prometheus.Desc
	listenerCheckEnabledDesc *prometheus.Desc
	listenerCheckErrorDesc   *prometheus.Desc
}

func NewExporter(cfg Config) *Exporter {
	return &Exporter{
		client:                  NewAPIClient(cfg),
		collectRouteConnections: cfg.CollectRouteConnections,
		routerConfigFile:        cfg.RouterConfigFile,
		listenerCheckEnabled:    cfg.ListenerCheckEnabled,
		listenerCheckTimeout:    time.Duration(cfg.ListenerCheckTimeout) * time.Second,
		logger:                  log.Default(),
		upDesc: prometheus.NewDesc(
			"mysqlrouter_up",
			"Whether the MySQL Router REST API is reachable",
			nil,
			nil,
		),
		scrapeDurationDesc: prometheus.NewDesc(
			"mysqlrouter_scrape_duration_seconds",
			"Duration of a scrape of MySQL Router REST API",
			nil,
			nil,
		),
		scrapeErrorDesc: prometheus.NewDesc(
			"mysqlrouter_scrape_error",
			"Whether the last scrape resulted in an error (1 = error)",
			nil,
			nil,
		),
		buildInfoDesc: prometheus.NewDesc(
			"mysqlrouter_build_info",
			"MySQL Router build information",
			[]string{"version", "product_edition", "hostname"},
			nil,
		),
		startTimeDesc: prometheus.NewDesc(
			"mysqlrouter_start_time_seconds",
			"MySQL Router process start time in seconds since Unix epoch",
			nil,
			nil,
		),
		routeActiveConnDesc: prometheus.NewDesc(
			"mysqlrouter_route_active_connections",
			"Active connections per route",
			[]string{"route"},
			nil,
		),
		routeTotalConnDesc: prometheus.NewDesc(
			"mysqlrouter_route_total_connections",
			"Total connections handled per route",
			[]string{"route"},
			nil,
		),
		routeBlockedHostsDesc: prometheus.NewDesc(
			"mysqlrouter_route_blocked_hosts",
			"Blocked hosts count per route",
			[]string{"route"},
			nil,
		),
		routeHealthDesc: prometheus.NewDesc(
			"mysqlrouter_route_health",
			"Route health status (1 = alive)",
			[]string{"route"},
			nil,
		),
		routeDestinationDesc: prometheus.NewDesc(
			"mysqlrouter_route_destination",
			"Route destination presence",
			[]string{"route", "address", "port"},
			nil,
		),
		metadataRefreshOKDesc: prometheus.NewDesc(
			"mysqlrouter_metadata_refresh_succeeded",
			"Metadata refresh success count",
			[]string{"metadata"},
			nil,
		),
		metadataRefreshFailDesc: prometheus.NewDesc(
			"mysqlrouter_metadata_refresh_failed",
			"Metadata refresh failure count",
			[]string{"metadata"},
			nil,
		),
		metadataLastOKDesc: prometheus.NewDesc(
			"mysqlrouter_metadata_last_refresh_success_timestamp_seconds",
			"Last successful metadata refresh timestamp",
			[]string{"metadata"},
			nil,
		),
		metadataLastFailDesc: prometheus.NewDesc(
			"mysqlrouter_metadata_last_refresh_failure_timestamp_seconds",
			"Last failed metadata refresh timestamp",
			[]string{"metadata"},
			nil,
		),
		metadataLastInfoDesc: prometheus.NewDesc(
			"mysqlrouter_metadata_last_refresh_info",
			"Last metadata refresh endpoint info",
			[]string{"metadata", "host", "port"},
			nil,
		),
		routeConnBytesFromDesc: prometheus.NewDesc(
			"mysqlrouter_route_connection_bytes_from_server",
			"Sum of bytes received from server for active connections",
			[]string{"route"},
			nil,
		),
		routeConnBytesToDesc: prometheus.NewDesc(
			"mysqlrouter_route_connection_bytes_to_server",
			"Sum of bytes sent to server for active connections",
			[]string{"route"},
			nil,
		),
		routeConnCountDesc: prometheus.NewDesc(
			"mysqlrouter_route_connection_count",
			"Active connection count from route connections endpoint",
			[]string{"route"},
			nil,
		),
		listenerUpDesc: prometheus.NewDesc(
			"mysqlrouter_listener_up",
			"Listener port status (1 = listening)",
			[]string{"route", "bind_address", "port"},
			nil,
		),
		listenerAllUpDesc: prometheus.NewDesc(
			"mysqlrouter_listener_all_up",
			"Whether all expected listeners are up (1 = all up)",
			nil,
			nil,
		),
		listenerCheckEnabledDesc: prometheus.NewDesc(
			"mysqlrouter_listener_check_enabled",
			"Whether listener checks are enabled (1 = enabled)",
			nil,
			nil,
		),
		listenerCheckErrorDesc: prometheus.NewDesc(
			"mysqlrouter_listener_check_error",
			"Whether listener checks encountered an error (1 = error)",
			nil,
			nil,
		),
	}
}

func (e *Exporter) Describe(ch chan<- *prometheus.Desc) {
	ch <- e.upDesc
	ch <- e.scrapeDurationDesc
	ch <- e.scrapeErrorDesc
	ch <- e.buildInfoDesc
	ch <- e.startTimeDesc
	ch <- e.routeActiveConnDesc
	ch <- e.routeTotalConnDesc
	ch <- e.routeBlockedHostsDesc
	ch <- e.routeHealthDesc
	ch <- e.routeDestinationDesc
	ch <- e.metadataRefreshOKDesc
	ch <- e.metadataRefreshFailDesc
	ch <- e.metadataLastOKDesc
	ch <- e.metadataLastFailDesc
	ch <- e.metadataLastInfoDesc
	ch <- e.routeConnBytesFromDesc
	ch <- e.routeConnBytesToDesc
	ch <- e.routeConnCountDesc
	ch <- e.listenerUpDesc
	ch <- e.listenerAllUpDesc
	ch <- e.listenerCheckEnabledDesc
	ch <- e.listenerCheckErrorDesc
}

func (e *Exporter) Collect(ch chan<- prometheus.Metric) {
	start := time.Now()
	scrapeErrors := 0

	status, err := e.client.RouterStatus()
	up := 0.0
	if err != nil {
		scrapeErrors++
		e.logger.Printf("router status error: %v", err)
	} else {
		up = 1
		ch <- prometheus.MustNewConstMetric(
			e.buildInfoDesc,
			prometheus.GaugeValue,
			1,
			status.Version,
			status.ProductEdition,
			status.Hostname,
		)
		if ts, ok := parseTimeToUnix(status.TimeStarted); ok {
			ch <- prometheus.MustNewConstMetric(
				e.startTimeDesc,
				prometheus.GaugeValue,
				float64(ts),
			)
		}
	}

	if up == 1 {
		scrapeErrors += e.collectRoutes(ch)
		scrapeErrors += e.collectMetadata(ch)
	}

	scrapeErrors += e.collectListeners(ch)

	ch <- prometheus.MustNewConstMetric(e.upDesc, prometheus.GaugeValue, up)
	ch <- prometheus.MustNewConstMetric(e.scrapeErrorDesc, prometheus.GaugeValue, boolToFloat(scrapeErrors > 0))
	ch <- prometheus.MustNewConstMetric(e.scrapeDurationDesc, prometheus.GaugeValue, time.Since(start).Seconds())
}

func (e *Exporter) collectRoutes(ch chan<- prometheus.Metric) int {
	routes, err := e.client.Routes()
	if err != nil {
		e.logger.Printf("routes list error: %v", err)
		return 1
	}

	errs := 0
	for _, route := range routes {
		status, err := e.client.RouteStatus(route)
		if err != nil {
			e.logger.Printf("route status error (%s): %v", route, err)
			errs++
		} else {
			ch <- prometheus.MustNewConstMetric(e.routeActiveConnDesc, prometheus.GaugeValue, float64(status.ActiveConnections), route)
			ch <- prometheus.MustNewConstMetric(e.routeTotalConnDesc, prometheus.GaugeValue, float64(status.TotalConnections), route)
			ch <- prometheus.MustNewConstMetric(e.routeBlockedHostsDesc, prometheus.GaugeValue, float64(status.BlockedHosts), route)
		}

		health, err := e.client.RouteHealth(route)
		if err != nil {
			e.logger.Printf("route health error (%s): %v", route, err)
			errs++
		} else {
			ch <- prometheus.MustNewConstMetric(e.routeHealthDesc, prometheus.GaugeValue, boolToFloat(health.IsAlive), route)
		}

		dests, err := e.client.RouteDestinations(route)
		if err != nil {
			e.logger.Printf("route destinations error (%s): %v", route, err)
			errs++
		} else {
			for _, dest := range dests {
				ch <- prometheus.MustNewConstMetric(
					e.routeDestinationDesc,
					prometheus.GaugeValue,
					1,
					route,
					dest.Address,
					strconv.Itoa(dest.Port),
				)
			}
		}

		if e.collectRouteConnections {
			connections, err := e.client.RouteConnections(route)
			if err != nil {
				e.logger.Printf("route connections error (%s): %v", route, err)
				errs++
			} else {
				var fromSum int64
				var toSum int64
				for _, conn := range connections {
					fromSum += conn.BytesFromServer
					toSum += conn.BytesToServer
				}
				ch <- prometheus.MustNewConstMetric(e.routeConnBytesFromDesc, prometheus.GaugeValue, float64(fromSum), route)
				ch <- prometheus.MustNewConstMetric(e.routeConnBytesToDesc, prometheus.GaugeValue, float64(toSum), route)
				ch <- prometheus.MustNewConstMetric(e.routeConnCountDesc, prometheus.GaugeValue, float64(len(connections)), route)
			}
		}
	}

	return errs
}

func (e *Exporter) collectMetadata(ch chan<- prometheus.Metric) int {
	items, err := e.client.Metadata()
	if err != nil {
		e.logger.Printf("metadata list error: %v", err)
		return 1
	}

	errs := 0
	for _, name := range items {
		status, err := e.client.MetadataStatus(name)
		if err != nil {
			e.logger.Printf("metadata status error (%s): %v", name, err)
			errs++
			continue
		}

		ch <- prometheus.MustNewConstMetric(e.metadataRefreshOKDesc, prometheus.GaugeValue, float64(status.RefreshSucceeded), name)
		ch <- prometheus.MustNewConstMetric(e.metadataRefreshFailDesc, prometheus.GaugeValue, float64(status.RefreshFailed), name)

		if ts, ok := parseTimeToUnix(status.TimeLastRefreshSucceeded); ok {
			ch <- prometheus.MustNewConstMetric(e.metadataLastOKDesc, prometheus.GaugeValue, float64(ts), name)
		}
		if ts, ok := parseTimeToUnix(status.TimeLastRefreshFailed); ok {
			ch <- prometheus.MustNewConstMetric(e.metadataLastFailDesc, prometheus.GaugeValue, float64(ts), name)
		}

		if status.LastRefreshHostname != "" && status.LastRefreshPort != 0 {
			ch <- prometheus.MustNewConstMetric(
				e.metadataLastInfoDesc,
				prometheus.GaugeValue,
				1,
				name,
				status.LastRefreshHostname,
				strconv.Itoa(status.LastRefreshPort),
			)
		}
	}

	return errs
}

func (e *Exporter) collectListeners(ch chan<- prometheus.Metric) int {
	if !e.listenerCheckEnabled {
		ch <- prometheus.MustNewConstMetric(e.listenerCheckEnabledDesc, prometheus.GaugeValue, 0)
		return 0
	}

	ch <- prometheus.MustNewConstMetric(e.listenerCheckEnabledDesc, prometheus.GaugeValue, 1)

	listeners, err := parseRouterConfig(e.routerConfigFile)
	if err != nil {
		e.logger.Printf("listener check error: %v", err)
		ch <- prometheus.MustNewConstMetric(e.listenerCheckErrorDesc, prometheus.GaugeValue, 1)
		ch <- prometheus.MustNewConstMetric(e.listenerAllUpDesc, prometheus.GaugeValue, 0)
		return 1
	}

	allUp := true
	for _, listener := range listeners {
		isUp := checkListener(listener.bindAddress, listener.port, e.listenerCheckTimeout)
		if !isUp {
			allUp = false
		}
		ch <- prometheus.MustNewConstMetric(
			e.listenerUpDesc,
			prometheus.GaugeValue,
			boolToFloat(isUp),
			listener.route,
			listener.bindAddress,
			strconv.Itoa(listener.port),
		)
	}

	ch <- prometheus.MustNewConstMetric(e.listenerCheckErrorDesc, prometheus.GaugeValue, 0)
	ch <- prometheus.MustNewConstMetric(e.listenerAllUpDesc, prometheus.GaugeValue, boolToFloat(allUp))
	return 0
}

func parseTimeToUnix(value string) (int64, bool) {
	if value == "" {
		return 0, false
	}

	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		parsed, err = time.Parse(time.RFC3339, value)
		if err != nil {
			return 0, false
		}
	}
	return parsed.Unix(), true
}

func boolToFloat(value bool) float64 {
	if value {
		return 1
	}
	return 0
}
