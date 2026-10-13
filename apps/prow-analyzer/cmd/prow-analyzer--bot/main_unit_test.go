//go:build unit

package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestBotEnvironmentFlagDefaults(t *testing.T) {
	if os.Getenv("PROW_ANALYZER_TEST_HELPER") == "true" {
		flag.CommandLine = flag.NewFlagSet("prow-analyzer--bot", flag.ExitOnError)
		flag.CommandLine.Usage = func() {
			for _, name := range []string{"mcp-url", "mcp-token", "mcp-debug", "channels", "allowed-bots", "mcp-timeout"} {
				fmt.Printf("%s=%s\n", name, flag.Lookup(name).Value.String())
			}
			os.Exit(0)
		}
		os.Args = append([]string{"prow-analyzer--bot"}, strings.Fields(os.Getenv("PROW_ANALYZER_TEST_ARGS"))...)
		main()
		return
	}

	for _, key := range []string{
		"PROW_AN__MCP__URL__SHIP_HELP", "PROW_AN__MCP__TOKEN__SHIP_HELP", "PROW_AN__MCP__SHIP_HELP__DEBUG",
		"PROW_AN__MONITORED_CHANNELS", "PROW_AN__ALLOWED_BOT_IDS", "PROW_AN__MCP__TIMEOUT_SEC",
		"SHIP_HELP_MCP_URL", "SHIP_HELP_MCP_TOKEN", "MCP_DEBUG", "MCP_TIMEOUT_SECONDS",
	} {
		t.Setenv(key, "")
	}

	for _, testCase := range []struct {
		name string
		env  map[string]string
		args string
		want string
	}{
		{
			name: "unset defaults",
			args: "-h",
			want: "mcp-url=\nmcp-token=\nmcp-debug=false\nchannels=\nallowed-bots=\nmcp-timeout=1200\n",
		},
		{
			name: "renamed environment defaults",
			env: map[string]string{
				"PROW_AN__MCP__URL__SHIP_HELP":   "https://example.com/mcp",
				"PROW_AN__MCP__TOKEN__SHIP_HELP": "test-token",
				"PROW_AN__MCP__SHIP_HELP__DEBUG": "true",
				"PROW_AN__MONITORED_CHANNELS":    "C123,C456",
				"PROW_AN__ALLOWED_BOT_IDS":       "B123,B456",
				"PROW_AN__MCP__TIMEOUT_SEC":      "1800",
			},
			args: "-h",
			want: "mcp-url=https://example.com/mcp\nmcp-token=test-token\nmcp-debug=true\nchannels=C123,C456\nallowed-bots=B123,B456\nmcp-timeout=1800\n",
		},
		{
			name: "flags override environment defaults",
			env: map[string]string{
				"PROW_AN__MCP__URL__SHIP_HELP":   "https://example.com/mcp",
				"PROW_AN__MCP__TOKEN__SHIP_HELP": "test-token",
				"PROW_AN__MCP__SHIP_HELP__DEBUG": "true",
				"PROW_AN__MONITORED_CHANNELS":    "C123,C456",
				"PROW_AN__ALLOWED_BOT_IDS":       "B123,B456",
				"PROW_AN__MCP__TIMEOUT_SEC":      "1800",
			},
			args: "-mcp-url https://override.example.com/mcp -mcp-token override-token -mcp-debug=false -channels C789 -allowed-bots B789 -mcp-timeout 2400 -h",
			want: "mcp-url=https://override.example.com/mcp\nmcp-token=override-token\nmcp-debug=false\nchannels=C789\nallowed-bots=B789\nmcp-timeout=2400\n",
		},
		{
			name: "CLI environment does not configure bot",
			env: map[string]string{
				"SHIP_HELP_MCP_URL": "https://cli.example.com/mcp", "SHIP_HELP_MCP_TOKEN": "cli-token",
				"MCP_DEBUG": "true", "MCP_TIMEOUT_SECONDS": "2400",
			},
			args: "-h",
			want: "mcp-url=\nmcp-token=\nmcp-debug=false\nchannels=\nallowed-bots=\nmcp-timeout=1200\n",
		},
		{
			name: "invalid boolean and timeout retain defaults",
			env: map[string]string{
				"PROW_AN__MCP__SHIP_HELP__DEBUG": "invalid", "PROW_AN__MCP__TIMEOUT_SEC": "invalid",
			},
			args: "-h",
			want: "mcp-url=\nmcp-token=\nmcp-debug=false\nchannels=\nallowed-bots=\nmcp-timeout=1200\n",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			for key, value := range testCase.env {
				t.Setenv(key, value)
			}
			command := exec.Command(os.Args[0], "-test.run=^TestBotEnvironmentFlagDefaults$")
			command.Env = append(os.Environ(), "PROW_ANALYZER_TEST_HELPER=true", "PROW_ANALYZER_TEST_ARGS="+testCase.args)
			output, err := command.CombinedOutput()
			if err != nil {
				t.Fatalf("bot flag parsing failed: %v\n%s", err, output)
			}
			if string(output) != testCase.want {
				t.Errorf("bot flags = %q, want %q", output, testCase.want)
			}
		})
	}
}
