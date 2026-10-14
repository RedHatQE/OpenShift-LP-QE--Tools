//go:build unit

package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/slack/handler"
)

func TestBotEnvironmentFlagDefaults(t *testing.T) {
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
			prepareBotMain(t, strings.Fields(testCase.args))
			for key, value := range testCase.env {
				t.Setenv(key, value)
			}
			var output bytes.Buffer
			flag.CommandLine.Usage = func() {
				for _, name := range []string{"mcp-url", "mcp-token", "mcp-debug", "channels", "allowed-bots", "mcp-timeout"} {
					fmt.Fprintf(&output, "%s=%s\n", name, flag.Lookup(name).Value.String())
				}
				panic(botExit(0))
			}
			if status := callBotMain(t); status != 0 {
				t.Fatalf("help status = %d", status)
			}
			if output.String() != testCase.want {
				t.Errorf("bot flags = %q, want %q", output.String(), testCase.want)
			}
		})
	}
}

type botExit int

func prepareBotMain(t *testing.T, args []string) {
	t.Helper()
	oldFlags, oldArgs, oldExit := flag.CommandLine, os.Args, exit
	oldStdout := stdout
	stdout = &bytes.Buffer{}
	t.Cleanup(func() { flag.CommandLine, os.Args, exit = oldFlags, oldArgs, oldExit; stdout = oldStdout })
	flag.CommandLine = flag.NewFlagSet("bot", flag.ContinueOnError)
	os.Args = append([]string{"bot"}, args...)
	exit = func(status int) { panic(botExit(status)) }
	for _, key := range []string{
		"PROW_AN__SLACK__BOT_TOKEN", "PROW_AN__SLACK__APP_TOKEN", "PROW_AN__MCP__URL__SHIP_HELP",
		"PROW_AN__MCP__TOKEN__SHIP_HELP", "PROW_AN__MONITORED_CHANNELS", "PROW_AN__ALLOWED_BOT_IDS",
		"PROW_AN__PROMPT__TEMPLATE", "PROW_AN__MONITOR__ALL", "PROW_AN__SLACK__DEBUG",
		"PROW_AN__MCP__SHIP_HELP__DEBUG", "PROW_AN__MCP__TIMEOUT_SEC", "TLS_INSECURE_SKIP_VERIFY",
	} {
		t.Setenv(key, "")
	}
}

func callBotMain(t *testing.T) (status int) {
	t.Helper()
	defer func() {
		if recovered := recover(); recovered != nil {
			value, ok := recovered.(botExit)
			if !ok {
				panic(recovered)
			}
			status = int(value)
		}
	}()
	main()
	return 0
}

type stubHandler struct {
	handler.PartialHandler
	handle func(*slackevents.EventsAPIEvent, *slog.Logger) (bool, error)
}

func (stub *stubHandler) Handle(event *slackevents.EventsAPIEvent, logger *slog.Logger) (bool, error) {
	return stub.handle(event, logger)
}

func TestMainValidation(t *testing.T) {
	for _, testCase := range []struct {
		name    string
		args    []string
		message string
	}{
		{"missing slack token", nil, "--slack-token is required"},
		{"missing app token", []string{"-slack-token", "bot"}, "--app-token is required"},
		{"missing MCP URL", []string{"-slack-token", "bot", "-app-token", "app", "-mcp-token", "token"}, "Both --mcp-url and --mcp-token"},
		{"missing MCP token", []string{"-slack-token", "bot", "-app-token", "app", "-mcp-url", "url"}, "Both --mcp-url and --mcp-token"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			prepareBotMain(t, testCase.args)
			var logs bytes.Buffer
			oldLogger := slog.Default()
			slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
			t.Cleanup(func() { slog.SetDefault(oldLogger) })
			oldSlack := newSlackClient
			newSlackClient = func(string, ...slack.Option) *slack.Client {
				t.Fatal("external construction before validation")
				return nil
			}
			t.Cleanup(func() { newSlackClient = oldSlack })
			if status := callBotMain(t); status != 1 {
				t.Errorf("status=%d", status)
			}
			if !strings.Contains(logs.String(), testCase.message) {
				t.Errorf("logs=%q", logs.String())
			}
		})
	}
}

func TestMainRuntime(t *testing.T) {
	for _, testCase := range []struct {
		name            string
		args            []string
		channels        []string
		allowedBots     bool
		authErr, runErr error
		message         string
	}{
		{name: "fail closed", message: "fail-closed"},
		{name: "monitor all", args: []string{"-monitor-all"}, message: "monitoring EVERY channel"},
		{name: "allowlists", args: []string{"-channels", " C123, ,C456, ", "-allowed-bots", " B123, ,B456, "}, channels: []string{"C123", "C456"}, allowedBots: true, message: "Analyzing Prow URLs from allow-listed bots"},
		{name: "auth failure", authErr: errors.New("auth unavailable"), message: "self bot ID unknown"},
		{name: "socket failure", runErr: errors.New("socket stopped"), message: "Socket mode error"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			args := append([]string{"-slack-token", "bot-token", "-app-token", "app-token", "-mcp-url", "url", "-mcp-token", "mcp-token", "-prompt", "prompt", "-mcp-timeout", "42", "-mcp-debug", "-slack-debug", "-tls-insecure"}, testCase.args...)
			prepareBotMain(t, args)
			var logs bytes.Buffer
			oldLogger := slog.Default()
			slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
			t.Cleanup(func() { slog.SetDefault(oldLogger) })
			oldSlack, oldAuth, oldAnalyzer, oldHandler := newSlackClient, authTest, newAnalyzer, newHandler
			oldSocket, oldRun, oldAck := newSocketClient, runSocket, ackSocket
			oldDispatch, oldLaunch := dispatchEvent, launchWorker
			t.Cleanup(func() {
				newSlackClient, authTest, newAnalyzer, newHandler = oldSlack, oldAuth, oldAnalyzer, oldHandler
				newSocketClient, runSocket, ackSocket = oldSocket, oldRun, oldAck
				dispatchEvent, launchWorker = oldDispatch, oldLaunch
			})
			client := &slack.Client{}
			calls := []string{}
			newSlackClient = func(token string, opts ...slack.Option) *slack.Client {
				calls = append(calls, "slack")
				if token != "bot-token" || len(opts) != 3 {
					t.Errorf("Slack constructor token/options=%q/%d", token, len(opts))
				}
				return client
			}
			authTest = func(actual *slack.Client) (*slack.AuthTestResponse, error) {
				calls = append(calls, "auth")
				if actual != client {
					t.Error("auth client mismatch")
				}
				return &slack.AuthTestResponse{BotID: "SELF"}, testCase.authErr
			}
			var analysis *analyzer.Analyzer
			newAnalyzer = func(url, token, prompt string, opts ...analyzer.AnalyzerOption) *analyzer.Analyzer {
				calls = append(calls, "analyzer")
				if url != "url" || token != "mcp-token" || prompt != "prompt" || len(opts) != 3 {
					t.Errorf("analyzer arguments=%q/%q/%q/%d", url, token, prompt, len(opts))
				}
				analysis = &analyzer.Analyzer{}
				for _, option := range opts {
					option(analysis)
				}
				if analysis.Timeout() != 42*time.Second {
					t.Errorf("timeout=%s", analysis.Timeout())
				}
				return analysis
			}
			eventHandler := &stubHandler{handle: func(event *slackevents.EventsAPIEvent, logger *slog.Logger) (bool, error) {
				t.Error("main unit invoked real event handling instead of mocked dispatch")
				return false, nil
			}}
			newHandler = func(actual *slack.Client, actualAnalysis *analyzer.Analyzer, channels []string, opts ...handler.Option) handler.PartialHandler {
				calls = append(calls, "handler")
				wantOpts := 3
				if testCase.authErr != nil {
					wantOpts = 2
				}
				if actual != client || actualAnalysis != analysis || !reflect.DeepEqual(channels, testCase.channels) || len(opts) != wantOpts {
					t.Errorf("handler inputs channels=%v options=%d", channels, len(opts))
				}
				return eventHandler
			}
			socket := &socketmode.Client{Events: make(chan socketmode.Event, 2)}
			newSocketClient = func(actual *slack.Client, opts ...socketmode.Option) *socketmode.Client {
				calls = append(calls, "socket")
				if actual != client || len(opts) != 2 {
					t.Error("socket constructor mismatch")
				}
				return socket
			}
			ackSocket = func(actual *socketmode.Client, request socketmode.Request, payload ...interface{}) {
				t.Error("main unit invoked external ack")
			}
			dispatches := 0
			dispatchEvent = func(event socketmode.Event, actual handler.PartialHandler, actualSocket *socketmode.Client) {
				dispatches++
				if actual != eventHandler || actualSocket != socket || event.Type != socketmode.EventTypeConnected {
					t.Error("dispatch arguments changed")
				}
			}
			var worker func()
			launchWorker = func(actual func()) { worker = actual }
			workerCompleted := false
			runSocket = func(actual *socketmode.Client) error {
				calls = append(calls, "run")
				if actual != socket {
					t.Error("run client mismatch")
				}
				actual.Events <- socketmode.Event{Type: socketmode.EventTypeConnected}
				actual.Events <- socketmode.Event{Type: socketmode.EventTypeConnected}
				close(actual.Events)
				if worker == nil {
					t.Fatal("worker not launched before Run")
				}
				worker()
				workerCompleted = true
				return testCase.runErr
			}
			wantStatus := 0
			if testCase.runErr != nil {
				wantStatus = 1
			}
			if status := callBotMain(t); status != wantStatus {
				t.Errorf("status=%d want=%d", status, wantStatus)
			}
			if !reflect.DeepEqual(calls, []string{"slack", "auth", "analyzer", "handler", "socket", "run"}) || dispatches != 2 || !workerCompleted {
				t.Errorf("calls=%v dispatches=%d workerCompleted=%v", calls, dispatches, workerCompleted)
			}
			if !strings.Contains(logs.String(), testCase.message) {
				t.Errorf("logs=%q", logs.String())
			}
			if strings.Contains(logs.String(), "bot-token") || strings.Contains(logs.String(), "mcp-token") {
				t.Error("credentials leaked")
			}
		})
	}
}

func TestLaunchWorker(t *testing.T) {
	completed := make(chan struct{})
	launchWorker(func() { close(completed) })
	<-completed
}

func TestHandleSocketEvent(t *testing.T) {
	for _, testCase := range []struct {
		name    string
		event   socketmode.Event
		handled bool
		err     error
		calls   int
		message string
	}{
		{"connecting", socketmode.Event{Type: socketmode.EventTypeConnecting}, false, nil, 0, "Connecting to Slack"},
		{"connected", socketmode.Event{Type: socketmode.EventTypeConnected}, false, nil, 0, "Connected to Slack"},
		{"connection error", socketmode.Event{Type: socketmode.EventTypeConnectionError, Data: "disconnected"}, false, nil, 0, "Connection error"},
		{"invalid event", socketmode.Event{Type: socketmode.EventTypeEventsAPI, Data: "invalid"}, false, nil, 0, "Ignored event"},
		{"handler error", socketmode.Event{Type: socketmode.EventTypeEventsAPI, Data: slackevents.EventsAPIEvent{Type: "callback"}, Request: &socketmode.Request{}}, false, errors.New("handle failed"), 1, "Failed to handle event"},
		{"handled", socketmode.Event{Type: socketmode.EventTypeEventsAPI, Data: slackevents.EventsAPIEvent{Type: "callback"}, Request: &socketmode.Request{}}, true, nil, 1, "Event handled"},
		{"not handled", socketmode.Event{Type: socketmode.EventTypeEventsAPI, Data: slackevents.EventsAPIEvent{Type: "callback"}, Request: &socketmode.Request{}}, false, nil, 1, "Received socket mode event"},
		{"unknown", socketmode.Event{Type: socketmode.EventType("unknown")}, false, nil, 0, "Unhandled event type"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			var logs bytes.Buffer
			oldLogger, oldAck := slog.Default(), ackSocket
			slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
			t.Cleanup(func() { slog.SetDefault(oldLogger); ackSocket = oldAck })
			acks, handles := 0, 0
			socket := &socketmode.Client{}
			ackSocket = func(actual *socketmode.Client, request socketmode.Request, payload ...interface{}) {
				if actual != socket {
					t.Error("ack socket mismatch")
				}
				acks++
			}
			eventHandler := &stubHandler{handle: func(event *slackevents.EventsAPIEvent, logger *slog.Logger) (bool, error) {
				handles++
				if event.Type != "callback" || acks != 1 {
					t.Error("callback changed or handled before ack")
				}
				return testCase.handled, testCase.err
			}}
			handleSocketEvent(testCase.event, eventHandler, socket)
			if acks != testCase.calls || handles != testCase.calls || !strings.Contains(logs.String(), testCase.message) {
				t.Errorf("acks=%d handles=%d logs=%q", acks, handles, logs.String())
			}
		})
	}
}
