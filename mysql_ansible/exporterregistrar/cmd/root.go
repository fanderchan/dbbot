/*
Copyright © 2024 dbbot contributors
*/
package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var verbose bool

// rootCmd represents the base command when called without any subcommands
var rootCmd = &cobra.Command{
	Use:   "exporterregistrar",
	Short: "A tool to register exporters in Prometheus",
	Long: `ExporterRegistrar is a CLI tool to register node_exporter and mysqld_exporter in fanderchan/dbbot Prometheus configuration.
You can specify the type of exporter, IP, port, and other parameters to automate the registration process.`,
	Run: func(cmd *cobra.Command, args []string) {
		cmd.Help()
	},
}

// Execute adds all child commands to the root command and sets flags appropriately.
// This is called by main.main(). It only needs to happen once to the rootCmd.
func Execute() {
	err := rootCmd.Execute()
	if err != nil {
		fmt.Printf("Command execution failed: %v\n", err)
		os.Exit(1)
	}
}

func init() {
	rootCmd.PersistentFlags().BoolVarP(&verbose, "verbose", "v", false, "enable verbose output")
}
