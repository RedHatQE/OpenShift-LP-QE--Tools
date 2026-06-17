package handler

import (
	"context"

	"github.com/sirupsen/logrus"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"

	"github.com/oramraz/prow-analyzer/pkg/analyzer"
)

// PartialHandler processes Slack events
type PartialHandler interface {
	Handle(callback *slackevents.EventsAPIEvent, logger *logrus.Entry) (handled bool, err error)
	Identifier() string
}

type handler struct {
	client            *slack.Client
	analyzer          *analyzer.Analyzer
	monitoredChannels map[string]bool
	semaphore         chan struct{} // Limit concurrent analyses
}

func (h *handler) Handle(callback *slackevents.EventsAPIEvent, logger *logrus.Entry) (handled bool, err error) {
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

	logger = logger.WithFields(logrus.Fields{
		"channel": event.Channel,
		"url":     prowURL,
	})
	logger.Info("Prow analyzer detected failure URL")

	// Acquire semaphore before spawning goroutine to prevent unbounded buildup
	select {
	case h.semaphore <- struct{}{}:
		// Analyze async (can take 30-60s)
		go h.analyzeAndRespond(event, prowURL, logger)
	default:
		logger.Warn("Prow analyzer queue full, dropping request")
	}

	return true, nil
}

func (h *handler) Identifier() string {
	return "prow-analyzer"
}

func (h *handler) analyzeAndRespond(event *slackevents.MessageEvent, prowURL string, logger *logrus.Entry) {
	// Release semaphore slot when done
	defer func() { <-h.semaphore }()

	result, err := h.analyzer.AnalyzeFailure(context.Background(), prowURL)
	if err != nil {
		logger.WithError(err).Error("Prow analyzer analysis failed")
		return
	}

	message := analyzer.FormatSlackResponse(result)

	_, _, err = h.client.PostMessage(
		event.Channel,
		slack.MsgOptionText(message, false),
		slack.MsgOptionTS(event.TimeStamp),
	)

	if err != nil {
		logger.WithError(err).Error("Failed to post prow analyzer response")
	} else {
		logger.WithField("duration", result.Duration).Info("Prow analyzer analysis posted successfully")
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
