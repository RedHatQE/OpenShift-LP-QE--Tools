package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/sirupsen/logrus"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"

	"github.com/oramraz/prow-analyzer/pkg/analyzer"
	"github.com/oramraz/prow-analyzer/pkg/slack/handler"
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
		logrus.Fatal("--slack-token is required (or set SLACK_BOT_TOKEN)")
	}
	if *appToken == "" {
		logrus.Fatal("--app-token is required (or set SLACK_APP_TOKEN)")
	}
	if *mcpURL == "" || *mcpToken == "" {
		logrus.Fatal("Both --mcp-url and --mcp-token are required (or set SHIP_HELP_MCP_URL and SHIP_HELP_MCP_TOKEN)")
	}
	if *channels == "" {
		logrus.Fatal("--channels is required (or set MONITORED_CHANNELS)")
	}

	// Parse monitored channels
	monitoredChannels := strings.Split(*channels, ",")
	for i := range monitoredChannels {
		monitoredChannels[i] = strings.TrimSpace(monitoredChannels[i])
	}

	logrus.Infof("Starting prow-analyzer-bot")
	logrus.Infof("Monitoring channels: %v", monitoredChannels)

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
					logrus.Warnf("Ignored %+v", evt)
					continue
				}

				socketClient.Ack(*evt.Request)

				logger := logrus.WithField("type", eventsAPIEvent.Type)
				handled, err := h.Handle(&eventsAPIEvent, logger)
				if err != nil {
					logger.WithError(err).Error("Failed to handle event")
				} else if handled {
					logger.Info("Event handled")
				}
			}
		}
	}()

	fmt.Println("Prow analyzer bot is running...")
	if err := socketClient.Run(); err != nil {
		logrus.Fatalf("Socket mode error: %v", err)
	}
}
