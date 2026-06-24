package handler

import (
	"context"
	"log/slog"

	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
)

// PartialHandler processes Slack events
type PartialHandler interface {
	Handle(callback *slackevents.EventsAPIEvent, logger *slog.Logger) (handled bool, err error)
	Identifier() string
}

type handler struct {
	client            *slack.Client
	analyzer          *analyzer.Analyzer
	monitoredChannels map[string]bool
	semaphore         chan struct{} // Limit concurrent analyses
}

func (h *handler) Handle(callback *slackevents.EventsAPIEvent, logger *slog.Logger) (handled bool, err error) {
	if callback.Type != slackevents.CallbackEvent {
		return false, nil
	}

	event, ok := callback.InnerEvent.Data.(*slackevents.MessageEvent)
	if !ok {
		return false, nil
	}

	// Ignore bot messages to prevent loops
	if event.BotID != "" {
		return false, nil
	}

	// Only monitor configured channels
	if !h.monitoredChannels[event.Channel] {
		return false, nil
	}

	// Check for Prow URL
	prowURL := analyzer.ExtractProwURL(event.Text)
	if prowURL == "" {
		return false, nil
	}

	logger = logger.With("channel", event.Channel, "url", prowURL)

	// Acquire semaphore before spawning goroutine to prevent unbounded buildup
	select {
	case h.semaphore <- struct{}{}:
		// Analyze async (can take 30-60s)
		go h.analyzeAndRespond(event, prowURL, logger)
	default:
		logger.Info("Prow analyzer queue full, dropping request")
		// Inform the requester via Slack that the queue is full
		_, _, postErr := h.client.PostMessage(
			event.Channel,
			slack.MsgOptionText("⚠️ Analysis queue is currently full. Please retry in a moment.", false),
			slack.MsgOptionTS(event.TimeStamp),
		)
		if postErr != nil {
			logger.Error("Failed to post error message to user", "error", postErr)
		}
	}

	return true, nil
}

func (h *handler) Identifier() string {
	return "prow-analyzer"
}

func (h *handler) analyzeAndRespond(event *slackevents.MessageEvent, prowURL string, logger *slog.Logger) {
	// Release semaphore slot when done
	defer func() { <-h.semaphore }()

	result, err := h.analyzer.AnalyzeFailure(context.Background(), prowURL)
	if err != nil {
		logger.Error("Prow analyzer analysis failed", "error", err)
		// Reply to user with error message (don't expose internal error details)
		_, _, postErr := h.client.PostMessage(
			event.Channel,
			slack.MsgOptionText("❌ Analysis failed. Please retry shortly or contact maintainers if this persists.", false),
			slack.MsgOptionTS(event.TimeStamp),
		)
		if postErr != nil {
			logger.Error("Failed to post error message to user", "error", postErr)
		}
		return
	}

	message := analyzer.FormatSlackResponse(result)

	_, _, err = h.client.PostMessage(
		event.Channel,
		slack.MsgOptionText(message, false),
		slack.MsgOptionTS(event.TimeStamp),
	)

	if err != nil {
		logger.Error("Failed to post prow analyzer response", "error", err)
	} else {
		logger.Info("Prow analyzer analysis posted successfully", "duration", result.Duration)
	}
}

// New creates a new prow analyzer event handler
func New(client *slack.Client, analyzer *analyzer.Analyzer, monitoredChannels []string) PartialHandler {
	channelMap := make(map[string]bool)
	for _, ch := range monitoredChannels {
		channelMap[ch] = true
	}

	return &handler{
		client:            client,
		analyzer:          analyzer,
		monitoredChannels: channelMap,
		semaphore:         make(chan struct{}, 5), // Limit to 5 concurrent analyses
	}
}
