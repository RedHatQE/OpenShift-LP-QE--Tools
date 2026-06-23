package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
)

func main() {
	var (
		mcpURL  = flag.String("mcp-url", os.Getenv("SHIP_HELP_MCP_URL"), "Ship-help MCP URL")
		token   = flag.String("token", os.Getenv("SHIP_HELP_MCP_TOKEN"), "Ship-help MCP token")
		prompt  = flag.String("prompt", "Analyze this Prow CI failure: {job_url}", "Analysis prompt template")
	)

	defaultUsage := flag.Usage
	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), "Usage: %s [flags] analyze <prow-url>\n\n", os.Args[0])
		defaultUsage()
		fmt.Fprintf(flag.CommandLine.Output(), "\n\nEnvironment variables:\n")
		fmt.Fprintf(flag.CommandLine.Output(), "  SHIP_HELP_MCP_URL    Ship-help MCP endpoint\n")
		fmt.Fprintf(flag.CommandLine.Output(), "  SHIP_HELP_MCP_TOKEN  Authentication token\n")
	}

	flag.CommandLine.SetOutput(os.Stdout)
	flag.Parse()

	if len(flag.Args()) < 2 {
		flag.CommandLine.SetOutput(os.Stderr)
		flag.Usage()
		os.Exit(1)
	}

	var i int
	command := flag.Args()[i]; i++
	jobURL  := flag.Args()[i]; i++

	if command != "analyze" {
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", command)
		os.Exit(1)
	}

	if *mcpURL == "" || *token == "" {
		fmt.Fprintf(os.Stderr, "Error: Both --mcp-url and --token are required (or set SHIP_HELP_MCP_URL and SHIP_HELP_MCP_TOKEN)\n")
		os.Exit(1)
	}

	a := analyzer.NewAnalyzer(*mcpURL, *token, *prompt)

	fmt.Printf("🔍 Analyzing Prow failure...\n")
	fmt.Printf("URL: %s\n\n", jobURL)

	result, err := a.AnalyzeFailure(context.Background(), jobURL)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("%s\n", result.Analysis)
	fmt.Printf("\n---\n")
	fmt.Printf("Analysis completed in %.1fs\n", result.Duration.Seconds())
}
