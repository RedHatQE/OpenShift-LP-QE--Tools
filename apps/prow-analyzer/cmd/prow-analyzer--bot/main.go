package main

import (
	"flag"
	"fmt"
	"log/slog"
	"os"
	"strings"

	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/slack/handler"
)

func main() {
	var (
		slackToken = flag.String("slack-token", os.Getenv("SLACK_BOT_TOKEN"), "Slack bot token")
		appToken   = flag.String("app-token", os.Getenv("SLACK_APP_TOKEN"), "Slack app token (for socket mode)")
		mcpURL     = flag.String("mcp-url", os.Getenv("SHIP_HELP_MCP_URL"), "Ship-help MCP URL")
		mcpToken   = flag.String("mcp-token", os.Getenv("SHIP_HELP_MCP_TOKEN"), "Ship-help MCP token")
		channels   = flag.String("channels", os.Getenv("MONITORED_CHANNELS"), "Comma-separated list of channel IDs to monitor")
		prompt     = flag.String("prompt", "Analyze this Prow CI failure in detail. Provide: (1) Root cause, (2) Related Jira issues, (3) Recurring pattern analysis, (4) Recommended actions. URL: {job_url}", "Analysis prompt template")
	)

	flag.Parse()

	// Validate required flags
	if *slackToken == "" {
		slog.Error("--slack-token is required (or set SLACK_BOT_TOKEN)")
		os.Exit(1)
	}
	if *appToken == "" {
		slog.Error("--app-token is required (or set SLACK_APP_TOKEN)")
		os.Exit(1)
	}
	if *mcpURL == "" || *mcpToken == "" {
		slog.Error("Both --mcp-url and --mcp-token are required (or set SHIP_HELP_MCP_URL and SHIP_HELP_MCP_TOKEN)")
		os.Exit(1)
	}
	if *channels == "" {
		slog.Error("--channels is required (or set MONITORED_CHANNELS)")
		os.Exit(1)
	}

	// Parse monitored channels
	monitoredChannels := strings.Split(*channels, ",")
	for i := range monitoredChannels {
		monitoredChannels[i] = strings.TrimSpace(monitoredChannels[i])
	}

	slog.Info("Starting prow-analyzer-bot")
	slog.Info("Monitoring channels", "channels", monitoredChannels)

	// Create Slack client
	slackClient := slack.New(
		*slackToken,
		slack.OptionAppLevelToken(*appToken),
	)

	// Create analyzer
	a := analyzer.NewAnalyzer(*mcpURL, *mcpToken, *prompt)

	// Create handler
	h := handler.New(slackClient, a, monitoredChannels)

	// Create socket mode client
	socketClient := socketmode.New(
		slackClient,
	)

	// Handle events
	go func() {
		for evt := range socketClient.Events {
			switch evt.Type {
			case socketmode.EventTypeEventsAPI:
				eventsAPIEvent, ok := evt.Data.(slackevents.EventsAPIEvent)
				if !ok {
					slog.Warn("Ignored event", "event", evt)
					continue
				}

				socketClient.Ack(*evt.Request)

				logger := slog.With("type", eventsAPIEvent.Type)
				handled, err := h.Handle(&eventsAPIEvent, logger)
				if err != nil {
					logger.Error("Failed to handle event", "error", err)
				} else if handled {
					logger.Info("Event handled")
				}
			}
		}
	}()

	fmt.Println("Prow analyzer bot is running...")
	if err := socketClient.Run(); err != nil {
		slog.Error("Socket mode error", "error", err)
		os.Exit(1)
	}
}
