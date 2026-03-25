/*
Copyright © 2024 dbbot contributors
*/
package cmd

import (
	"fmt"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/spf13/cobra"
	"golang.org/x/crypto/ssh"
	"gopkg.in/yaml.v2"
)

var (
	exporterType              string
	ip                        string
	port                      string
	force                     bool
	prometheusServer          string
	sshUser                   string
	sshPassword               string
	sshPort                   string
	configPath                string
	nodeExporterTargetsPath   = "/usr/local/prometheus/node_exporter_targets.yml"
	mysqldExporterTargetsPath = "/usr/local/prometheus/mysqld_exporter_targets.yml"
	routerExporterTargetsPath = "/usr/local/prometheus/mysqlrouter_exporter_targets.yml"
	dbPort                    string
	routerAPIPort             string
	region                    string
	cluster                   string
	replicationSet            string
	nodeName                  string
	topology                  string
)

type TargetGroup struct {
	Targets []string          `yaml:"targets"`
	Labels  map[string]string `yaml:"labels,omitempty"` // If the map is empty, it will not be output
}

type TargetGroups []TargetGroup

// registerCmd represents the register command
var registerCmd = &cobra.Command{
	Use:   "register",
	Short: "Register an exporter in Prometheus",
	Long: `Register an exporter such as node_exporter or mysqld_exporter to Prometheus' targets configuration.

Examples:
  mysql server: 192.0.2.131
  prometheus server: 198.51.100.161
  prometheus server ssh user: root
  prometheus server ssh password: <your_ssh_password>

  # Register a MySQL exporter
  ./exporterregistrar register -t mysql -H 192.0.2.131 -s 198.51.100.161 -p <your_ssh_password>

  # Register a MySQL exporter for MySQL 3307, metrics port auto-derived as 9105
  ./exporterregistrar register -t mysql -H 192.0.2.131 --db-port 3307 -s 198.51.100.161 -p <your_ssh_password>

  # Register a Node exporter
  ./exporterregistrar register -t node -H 192.0.2.131 -s 198.51.100.161 -p <your_ssh_password>

  # Register a MySQL exporter with custom labels
  ./exporterregistrar register -t mysql -H 192.0.2.131 -s 198.51.100.161 -p <your_ssh_password> -f --region cn-sz
 
  # force update a MySQL exporter with custom labels
  ./exporterregistrar register -t mysql -H 192.0.2.131 -s 198.51.100.161 -p <your_ssh_password> -f --region cn-bj --node-name node1
  `,
	Run: func(cmd *cobra.Command, args []string) {
		err := registerExporter(exporterType, ip, port, prometheusServer, sshUser, sshPassword, sshPort, force)
		if err != nil {
			fmt.Println("Error:", err)
			os.Exit(1)
		}
	},
}

func init() {
	rootCmd.AddCommand(registerCmd)

	registerCmd.Flags().StringVarP(&exporterType, "type", "t", "", "Exporter type (node, mysql/mysqld, router) [required]")
	registerCmd.MarkFlagRequired("type")

	registerCmd.Flags().StringVarP(&ip, "host", "H", "", "Hostname or IP address of the target exporter [required]")
	registerCmd.MarkFlagRequired("host")

	registerCmd.Flags().StringVarP(&port, "port", "P", "", "Port of the target exporter (default: 9100 for node, auto-derived from --db-port for mysql/mysqld, 9165 for router)")
	registerCmd.Flags().BoolVarP(&force, "force", "f", false, "Force update if target already exists (default false)")
	registerCmd.Flags().StringVarP(&sshUser, "user", "u", "root", "SSH username for Prometheus server")
	registerCmd.Flags().StringVarP(&sshPassword, "password", "p", "", "SSH password for Prometheus server [required]")
	registerCmd.MarkFlagRequired("password")
	registerCmd.Flags().StringVarP(&prometheusServer, "server", "s", "", "IP address of the Prometheus server [required]")
	registerCmd.MarkFlagRequired("server")
	registerCmd.Flags().StringVarP(&sshPort, "ssh-port", "", "22", "SSH port for Prometheus server")
	registerCmd.Flags().StringVarP(&configPath, "config-path", "", "",
		"Custom path for Prometheus configuration file.\n"+
			"Default paths based on exporter type:\n"+
			"  - node_exporter: "+nodeExporterTargetsPath+"\n"+
			"  - mysqld_exporter: "+mysqldExporterTargetsPath+"\n"+
			"  - mysqlrouter_exporter: "+routerExporterTargetsPath)
	registerCmd.Flags().StringVarP(&dbPort, "db-port", "", "3306", "Database port for labeling (mysql/mysqld) and cluster labels. MySQL exporter port defaults to 9104 + (db-port - 3306)")
	registerCmd.Flags().StringVarP(&routerAPIPort, "router-api-port", "", "8443", "Router REST API port for router instance/service_name labels")
	registerCmd.Flags().StringVarP(&region, "region", "", "cn", "Region label")
	registerCmd.Flags().StringVarP(&cluster, "cluster", "", "", "Cluster label (default: mysql{$dbPort})")
	registerCmd.Flags().StringVarP(&replicationSet, "replication-set", "", "", "Replication set label (default: mysql{$dbPort})")
	registerCmd.Flags().StringVar(&nodeName, "node-name", "", "Node name for labeling (default: same as host)")
	registerCmd.Flags().StringVar(&topology, "topology", "", "Topology label (e.g. ms, mgr)")

	registerCmd.PreRun = func(cmd *cobra.Command, args []string) {
		if nodeName == "" {
			nodeName = ip
		}
	}
}

func buildTargetLabels(exporterType, ip string) map[string]string {
	switch exporterType {
	case "mysql", "mysqld":
		labels := map[string]string{
			"instance":        fmt.Sprintf("%s:%s", ip, dbPort),
			"service_name":    fmt.Sprintf("%s:%s", ip, dbPort),
			"environment":     "production",
			"region":          region,
			"cluster":         cluster,
			"replication_set": replicationSet,
		}
		if nodeName != "" {
			labels["node_name"] = nodeName
		}
		if topology != "" {
			labels["topology"] = topology
		}
		return labels
	case "router":
		labels := map[string]string{
			"instance":        fmt.Sprintf("%s:%s", ip, routerAPIPort),
			"service_name":    fmt.Sprintf("%s:%s", ip, routerAPIPort),
			"environment":     "production",
			"region":          region,
			"cluster":         cluster,
			"replication_set": replicationSet,
		}
		if nodeName != "" {
			labels["node_name"] = nodeName
		}
		if topology != "" {
			labels["topology"] = topology
		}
		return labels
	default:
		return nil
	}
}

// registerExporter handles the logic for registering the exporter in Prometheus' configuration file.
func registerExporter(exporterType, ip, port, prometheusServer, sshUser, sshPassword, sshPort string, force bool) error {
	if port == "" {
		switch exporterType {
		case "node":
			port = "9100"
		case "mysqld":
			port = deriveMySQLExporterPort(dbPort)
		case "mysql":
			port = deriveMySQLExporterPort(dbPort)
		case "router":
			port = "9165"
		}
	}
	targetConfigPath := ""
	// Use custom configuration path (if provided)
	if configPath != "" {
		switch exporterType {
		case "node":
			targetConfigPath = configPath
		case "mysqld", "mysql":
			targetConfigPath = configPath
		case "router":
			targetConfigPath = configPath
		}
	}

	// Choose configuration file path based on exporter type
	if targetConfigPath == "" {
		switch exporterType {
		case "node":
			targetConfigPath = nodeExporterTargetsPath
		case "mysqld":
			targetConfigPath = mysqldExporterTargetsPath
		case "mysql":
			targetConfigPath = mysqldExporterTargetsPath
		case "router":
			targetConfigPath = routerExporterTargetsPath
		default:
			return fmt.Errorf("unsupported exporter type: %s", exporterType)
		}
	}

	// Check if the Exporter is alive
	err := checkExporterAlive(ip, port)
	if err != nil {
		return fmt.Errorf("exporter is not alive: %v", err)
	}

	// Establish SSH connection
	client, err := connectToSSH(prometheusServer, sshUser, sshPassword, sshPort)
	if err != nil {
		return fmt.Errorf("failed to connect to SSH server: %v", err)
	}
	defer client.Close()

	// Download Prometheus configuration file
	remoteYAMLContent, err := downloadFile(client, targetConfigPath)
	if err != nil {
		return fmt.Errorf("failed to download Prometheus config file: %v", err)
	}

	// Print remoteYAMLContent for debugging YAML content
	//fmt.Println("YAML Content from Prometheus Server:")
	//fmt.Println(string(remoteYAMLContent))

	// Parse YAML content
	var targetGroups TargetGroups
	err = yaml.Unmarshal(remoteYAMLContent, &targetGroups)
	if err != nil || len(targetGroups) == 0 {
		// If parsing fails or targetGroups is empty, initialize a new targetGroups
		fmt.Println("Failed to parse YAML or no target groups found, initializing new target group")
		targetGroups = TargetGroups{
			TargetGroup{
				Targets: []string{},
			},
		}
	}

	// Set default values for cluster and replicationSet if they are empty
	if cluster == "" {
		cluster = fmt.Sprintf("mysql%s", dbPort)
	}
	if replicationSet == "" {
		replicationSet = fmt.Sprintf("mysql%s", dbPort)
	}

	// Check if the same target already exists
	newTarget := fmt.Sprintf("%s:%s", ip, port)
	targetExists := false
	for i, group := range targetGroups {
		for j, existingTarget := range group.Targets {
			if existingTarget == newTarget {
				if force {
					targetGroups[i].Targets[j] = newTarget
					if labels := buildTargetLabels(exporterType, ip); labels != nil {
						targetGroups[i].Labels = labels
					}
					targetExists = true
					fmt.Printf("Target %s already exists. Updating labels.\n", newTarget)
				} else {
					return fmt.Errorf("target %s already exists. Use --force to update", newTarget)
				}
			}
		}
	}

	// If the target doesn't exist, or if force is used but no match was found, add a new target
	if !targetExists {
		newTargetGroup := TargetGroup{
			Targets: []string{newTarget},
		}
		newTargetGroup.Labels = buildTargetLabels(exporterType, ip)
		targetGroups = append(targetGroups, newTargetGroup)
		fmt.Printf("Adding new target: %s\n", newTarget)
	}

	// Serialize the updated content to YAML
	updatedYAMLContent, err := yaml.Marshal(&targetGroups)
	if err != nil {
		return fmt.Errorf("failed to serialize updated config: %v", err)
	}

	// Upload the updated configuration file
	err = uploadFile(client, targetConfigPath, updatedYAMLContent)
	if err != nil {
		return fmt.Errorf("failed to upload updated config file: %v", err)
	}

	fmt.Println("Exporter registered successfully.")
	return nil
}

func connectToSSH(server, user, password, port string) (*ssh.Client, error) {
	config := &ssh.ClientConfig{
		User: user,
		Auth: []ssh.AuthMethod{
			ssh.Password(password),
		},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
	}
	client, err := ssh.Dial("tcp", fmt.Sprintf("%s:%s", server, port), config)
	if err != nil {
		return nil, err
	}
	return client, nil
}

func downloadFile(client *ssh.Client, path string) ([]byte, error) {
	session, err := client.NewSession()
	if err != nil {
		return nil, fmt.Errorf("failed to create SSH session: %v", err)
	}
	defer session.Close()

	output, err := session.Output(fmt.Sprintf("cat %s", path))
	if err != nil {
		return nil, fmt.Errorf("failed to read remote file %s: %v", path, err)
	}

	return output, nil
}

func uploadFile(client *ssh.Client, path string, content []byte) error {
	session, err := client.NewSession()
	if err != nil {
		return fmt.Errorf("failed to create SSH session: %v", err)
	}
	defer session.Close()

	err = session.Run(fmt.Sprintf("echo '%s' > %s", string(content), path))
	if err != nil {
		return fmt.Errorf("failed to write remote file %s: %v", path, err)
	}

	return nil
}

// checkExporterAlive verifies that the exporter is reachable and returns a valid response
func checkExporterAlive(ip, port string) error {
	url := fmt.Sprintf("http://%s:%s/metrics", ip, port)
	client := http.Client{
		Timeout: 5 * time.Second, // Set timeout
	}

	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("failed to reach exporter at %s: %v", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("exporter at %s returned non-200 status: %d", url, resp.StatusCode)
	}

	return nil
}

func deriveMySQLExporterPort(dbPort string) string {
	dbPortInt, err := strconv.Atoi(dbPort)
	if err != nil {
		return "9104"
	}

	return strconv.Itoa(9104 + (dbPortInt - 3306))
}
