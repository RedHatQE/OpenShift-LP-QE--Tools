package analyzer

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestNewAnalyzer(t *testing.T) {
	mcpURL := "https://example.com/mcp"
	token := "test-token"
	template := "Analyze {job_url}"

	analyzer := NewAnalyzer(mcpURL, token, template)

	if analyzer.mcpURL != mcpURL {
		t.Errorf("Expected mcpURL %s, got %s", mcpURL, analyzer.mcpURL)
	}
	if analyzer.token != token {
		t.Errorf("Expected token %s, got %s", token, analyzer.token)
	}
	if analyzer.template != template {
		t.Errorf("Expected template %s, got %s", template, analyzer.template)
	}
	if analyzer.client == nil {
		t.Error("Expected client to be initialized")
	}
	if analyzer.client.Timeout != 240*time.Second {
		t.Errorf("Expected timeout 240s, got %v", analyzer.client.Timeout)
	}
}

func TestExtractProwURL(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "plain URL",
			input:    "Check this: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/123",
			expected: "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/123",
		},
		{
			name:     "Slack formatted URL",
			input:    "<https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/456>",
			expected: "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/456",
		},
		{
			name:     "URL with trailing punctuation",
			input:    "Failed: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/789)",
			expected: "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/789",
		},
		{
			name:     "Slack link with label",
			input:    "Check <https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/abc|this link>",
			expected: "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/abc",
		},
		{
			name:     "no URL",
			input:    "No Prow URL here",
			expected: "",
		},
		{
			name:     "deck-internal URL",
			input:    "https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/view/job/123",
			expected: "https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/view/job/123",
		},
		{
			name:     "prow PR URL",
			input:    "https://prow.ci.openshift.org/?pr=12345",
			expected: "https://prow.ci.openshift.org/?pr=12345",
		},
		{
			name:     "multiple trailing punctuation",
			input:    "URL: https://prow.ci.openshift.org/view/gs/test/job/1>.",
			expected: "https://prow.ci.openshift.org/view/gs/test/job/1",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ExtractProwURL(tt.input)
			if result != tt.expected {
				t.Errorf("Expected %q, got %q", tt.expected, result)
			}
		})
	}
}

func TestContainsProwURL(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected bool
	}{
		{
			name:     "contains URL",
			input:    "Check https://prow.ci.openshift.org/view/gs/test/job/1",
			expected: true,
		},
		{
			name:     "no URL",
			input:    "Just some text",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ContainsProwURL(tt.input)
			if result != tt.expected {
				t.Errorf("Expected %v, got %v", tt.expected, result)
			}
		})
	}
}

func TestIsWhitespace(t *testing.T) {
	tests := []struct {
		char     byte
		expected bool
	}{
		{' ', true},
		{'\t', true},
		{'\n', true},
		{'\r', true},
		{'a', false},
		{'1', false},
	}

	for _, tt := range tests {
		result := isWhitespace(tt.char)
		if result != tt.expected {
			t.Errorf("For char %q: expected %v, got %v", tt.char, tt.expected, result)
		}
	}
}

func TestFormatSlackResponse(t *testing.T) {
	t.Run("valid result", func(t *testing.T) {
		result := &AnalysisResult{
			JobURL:   "https://prow.ci.openshift.org/view/gs/test/job/1",
			Analysis: "Root cause: test failure",
			Duration: 78600 * time.Millisecond,
		}

		response := FormatSlackResponse(result)

		if !strings.Contains(response, "🔍 *Prow Analyzer Analysis*") {
			t.Error("Expected header in response")
		}
		if !strings.Contains(response, "Root cause: test failure") {
			t.Error("Expected analysis in response")
		}
		if !strings.Contains(response, "78.6s") {
			t.Error("Expected duration in response")
		}
		if !strings.Contains(response, "Powered by ship-help MCP") {
			t.Error("Expected footer in response")
		}
	})

	t.Run("nil result", func(t *testing.T) {
		response := FormatSlackResponse(nil)
		if !strings.Contains(response, "❌ Error") {
			t.Error("Expected error message for nil result")
		}
	})
}

func TestParseSSEMessage(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "valid SSE",
			input:    "event: message\ndata: {\"result\":\"success\"}\n\n",
			expected: "{\"result\":\"success\"}",
		},
		{
			name:     "no data line",
			input:    "event: message\n\n",
			expected: "",
		},
		{
			name:     "multiple lines",
			input:    "event: message\nid: 1\ndata: test\n\n",
			expected: "test",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := parseSSEMessage(tt.input)
			if result != tt.expected {
				t.Errorf("Expected %q, got %q", tt.expected, result)
			}
		})
	}
}

func TestAnalyzeFailure_InitializeSession(t *testing.T) {
	sessionID := "test-session-123"
	analysisText := "Test analysis result"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("Expected POST, got %s", r.Method)
		}

		// Check authorization header
		authHeader := r.Header.Get("Authorization")
		if authHeader != "Bearer test-token" {
			t.Errorf("Expected Bearer token, got %s", authHeader)
		}

		// Parse request body
		var req MCPRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("Failed to decode request: %v", err)
		}

		// Handle initialize vs tools/call
		if req.Method == "initialize" {
			// Return session ID
			w.Header().Set("Mcp-Session-Id", sessionID)
			resp := MCPResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
			}
			json.NewEncoder(w).Encode(resp)
		} else if req.Method == "tools/call" {
			// Return analysis
			w.Header().Set("Content-Type", "text/event-stream")
			resp := MCPResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
			}
			resp.Result.Content = []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}{
				{Type: "text", Text: analysisText},
			}
			jsonData, _ := json.Marshal(resp)
			w.Write([]byte("event: message\ndata: " + string(jsonData) + "\n\n"))
		}
	}))
	defer server.Close()

	analyzer := NewAnalyzer(server.URL, "test-token", "Analyze {job_url}")
	ctx := context.Background()

	result, err := analyzer.AnalyzeFailure(ctx, "https://prow.ci.openshift.org/view/test")
	if err != nil {
		t.Fatalf("AnalyzeFailure failed: %v", err)
	}

	if result.Analysis != analysisText {
		t.Errorf("Expected analysis %q, got %q", analysisText, result.Analysis)
	}
	if result.JobURL != "https://prow.ci.openshift.org/view/test" {
		t.Errorf("Expected job URL, got %q", result.JobURL)
	}
	if result.Duration == 0 {
		t.Error("Expected non-zero duration")
	}
}

func TestAnalyzeFailure_SessionReuse(t *testing.T) {
	callCount := 0
	sessionID := "reuse-session"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req MCPRequest
		json.NewDecoder(r.Body).Decode(&req)

		if req.Method == "initialize" {
			callCount++
			w.Header().Set("Mcp-Session-Id", sessionID)
			json.NewEncoder(w).Encode(MCPResponse{JSONRPC: "2.0", ID: req.ID})
		} else {
			resp := MCPResponse{JSONRPC: "2.0", ID: req.ID}
			resp.Result.Content = []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}{{Type: "text", Text: "analysis"}}
			jsonData, _ := json.Marshal(resp)
			w.Write([]byte("data: " + string(jsonData) + "\n"))
		}
	}))
	defer server.Close()

	analyzer := NewAnalyzer(server.URL, "token", "template")
	ctx := context.Background()

	// First call - should initialize
	analyzer.AnalyzeFailure(ctx, "url1")
	// Second call - should reuse session
	analyzer.AnalyzeFailure(ctx, "url2")

	if callCount != 1 {
		t.Errorf("Expected 1 initialize call, got %d", callCount)
	}
}

func TestAnalyzeFailure_Errors(t *testing.T) {
	t.Run("initialize error - no session ID", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Don't set session ID header
			json.NewEncoder(w).Encode(MCPResponse{})
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "no session ID") {
			t.Errorf("Expected session ID error, got: %v", err)
		}
	})

	t.Run("MCP error response", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				resp := MCPResponse{
					JSONRPC: "2.0",
					ID:      req.ID,
					Error: &struct {
						Code    int    `json:"code"`
						Message string `json:"message"`
					}{Code: -32600, Message: "Invalid request"},
				}
				jsonData, _ := json.Marshal(resp)
				w.Write([]byte("data: " + string(jsonData) + "\n"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "MCP error") {
			t.Errorf("Expected MCP error, got: %v", err)
		}
	})

	t.Run("HTTP error status", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				w.WriteHeader(http.StatusInternalServerError)
				w.Write([]byte("Server error"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "HTTP 500") {
			t.Errorf("Expected HTTP error, got: %v", err)
		}
	})

	t.Run("no content in response", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				resp := MCPResponse{JSONRPC: "2.0", ID: req.ID}
				// Empty content
				jsonData, _ := json.Marshal(resp)
				w.Write([]byte("data: " + string(jsonData) + "\n"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "no content") {
			t.Errorf("Expected no content error, got: %v", err)
		}
	})

	t.Run("empty SSE response", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				// No SSE data line
				w.Write([]byte("event: message\n\n"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "no JSON data") {
			t.Errorf("Expected SSE parse error, got: %v", err)
		}
	})

	t.Run("context canceled", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			time.Sleep(100 * time.Millisecond)
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		_, err := analyzer.AnalyzeFailure(ctx, "url")
		if err == nil {
			t.Error("Expected context canceled error")
		}
	})

	t.Run("invalid JSON in SSE", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				// Invalid JSON in data field
				w.Write([]byte("data: {invalid json\n"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "parse response") {
			t.Errorf("Expected JSON parse error, got: %v", err)
		}
	})

	t.Run("init HTTP error 500", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte("Init failed"))
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "no session ID") {
			t.Errorf("Expected session ID error, got: %v", err)
		}
	})
}
