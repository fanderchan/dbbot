package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var version = "dev"

func main() {
	configPath := flag.String("config", "/etc/mysqlrouter_exporter/config.yml", "Path to configuration file")
	showVersion := flag.Bool("version", false, "Print version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Println(version)
		return
	}

	cfg, err := LoadConfig(*configPath)
	if err != nil {
		log.Printf("failed to load config: %v", err)
		os.Exit(1)
	}

	exporter := NewExporter(cfg)
	registry := prometheus.NewRegistry()
	registry.MustRegister(exporter)
	registry.MustRegister(prometheus.NewGoCollector())
	registry.MustRegister(prometheus.NewProcessCollector(prometheus.ProcessCollectorOpts{}))

	mux := http.NewServeMux()
	mux.Handle(cfg.MetricsPath, promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = fmt.Fprintf(w, "mysqlrouter_exporter is running. Metrics at %s\n", cfg.MetricsPath)
	})

	server := &http.Server{
		Addr:              cfg.ListenAddress,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("mysqlrouter_exporter listening on %s", cfg.ListenAddress)
	if err := server.ListenAndServe(); err != nil {
		log.Printf("http server stopped: %v", err)
		os.Exit(1)
	}
}
