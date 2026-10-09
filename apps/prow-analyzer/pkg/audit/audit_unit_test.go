//go:build unit

package audit

import (
	"context"
	"errors"
	"testing"
)

// TestWithInteractionID verifies WithInteractionID stores the ID and that
// InteractionID reads it back (present branch).
func TestWithInteractionID(t *testing.T) {
	ctx := WithInteractionID(context.Background(), "C123/456.789")
	if got := InteractionID(ctx); got != "C123/456.789" {
		t.Errorf("InteractionID = %q, want %q", got, "C123/456.789")
	}
}

// TestInteractionID_Absent covers the missing-value branch of InteractionID.
func TestInteractionID_Absent(t *testing.T) {
	if got := InteractionID(context.Background()); got != "" {
		t.Errorf("InteractionID on empty ctx = %q, want empty", got)
	}
}

// TestHash covers Hash: determinism, distinctness and fixed length.
func TestHash(t *testing.T) {
	a := Hash("some analysis text")
	b := Hash("some analysis text")
	c := Hash("different text")
	if a != b {
		t.Errorf("Hash not deterministic: %q vs %q", a, b)
	}
	if a == c {
		t.Error("Hash collision on different inputs")
	}
	if len(a) != 16 {
		t.Errorf("Hash length = %d, want 16", len(a))
	}
}

// TestRedactError covers every category branch of RedactError, ensuring raw
// error content is mapped to a coarse, payload-free label (and nil -> "").
func TestRedactError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want string
	}{
		{name: "nil", err: nil, want: ""},
		{name: "session not found", err: errors.New("MCP error: Session not found"), want: "session_not_found"},
		{name: "context deadline", err: context.DeadlineExceeded, want: "timeout"},
		{name: "client timeout", err: errors.New("send request: Client.Timeout exceeded"), want: "timeout"},
		{name: "generic timeout", err: errors.New("dial tcp: i/o timeout"), want: "timeout"},
		{name: "mcp protocol error", err: errors.New("MCP error 42: bad tool"), want: "mcp_protocol_error"},
		{name: "http error with body", err: errors.New("HTTP 500: <internal body>"), want: "mcp_http_error"},
		{name: "no content", err: errors.New("no content in response"), want: "empty_response"},
		{name: "no json data", err: errors.New("no JSON data found in SSE stream (read 3 lines)"), want: "empty_response"},
		{name: "fallback", err: errors.New("marshal request: boom"), want: "analysis_error"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := RedactError(tt.err); got != tt.want {
				t.Errorf("RedactError(%v) = %q, want %q", tt.err, got, tt.want)
			}
		})
	}
}

// TestReceived covers the Received emitter (lifecycle event 1/3).
func TestReceived(t *testing.T) {
	ctx := WithInteractionID(context.Background(), "test-id")
	Received(ctx, "slack", "U1", "C1", "https://prow.ci.openshift.org/view/x")
}

// TestToolQuery covers the ToolQuery emitter (lifecycle event 2/3), including the
// variadic attrs append.
func TestToolQuery(t *testing.T) {
	ctx := WithInteractionID(context.Background(), "test-id")
	ToolQuery(ctx, "ship-help-mcp", "tools/call", "tool", "ask_persona", "persona", "ship_public")
}

// TestOutcome covers the Outcome emitter (lifecycle event 3/3), including the
// variadic attrs append.
func TestOutcome(t *testing.T) {
	ctx := WithInteractionID(context.Background(), "test-id")
	Outcome(ctx, "success", "duration_ms", int64(1234), "response_chars", 42)
}
