//go:build integration

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

// These tests exercise AnalyzeFailure against real net/http/httptest servers,
// verifying the full MCP round-trip (initialize + tools/call, headers, SSE
// streaming) over an actual socket. They run under -race with no coverage
// threshold; the equivalent branch coverage is provided by the in-memory unit
// tests in analyzer_unit_test.go.

func TestAnalyzeFailure_InitializeSession(t *testing.T) {
	sessionID := "test-session-123"
	analysisText := "Test analysis result"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("Expected POST, got %s", r.Method)
		}
		authHeader := r.Header.Get("Authorization")
		if authHeader != "Bearer test-token" {
			t.Errorf("Expected Bearer token, got %s", authHeader)
		}

		var req MCPRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("Failed to decode request: %v", err)
		}

		if req.Method == "initialize" {
			w.Header().Set("Mcp-Session-Id", sessionID)
			json.NewEncoder(w).Encode(MCPResponse{JSONRPC: "2.0", ID: req.ID})
		} else if req.Method == "tools/call" {
			w.Header().Set("Content-Type", "text/event-stream")
			resp := MCPResponse{JSONRPC: "2.0", ID: req.ID}
			resp.Result.Content = []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}{{Type: "text", Text: analysisText}}
			jsonData, _ := json.Marshal(resp)
			w.Write([]byte("event: message\ndata: " + string(jsonData) + "\n\n"))
		}
	}))
	defer server.Close()

	analyzer := NewAnalyzer(server.URL, "test-token", "Analyze {job_url}")
	result, err := analyzer.AnalyzeFailure(context.Background(), "https://prow.ci.openshift.org/view/test")
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
	if _, err := analyzer.AnalyzeFailure(context.Background(), "url1"); err != nil {
		t.Fatalf("First AnalyzeFailure failed: %v", err)
	}
	if _, err := analyzer.AnalyzeFailure(context.Background(), "url2"); err != nil {
		t.Fatalf("Second AnalyzeFailure failed: %v", err)
	}
	if callCount != 1 {
		t.Errorf("Expected 1 initialize call, got %d", callCount)
	}
}

func TestAnalyzeFailure_Errors(t *testing.T) {
	t.Run("initialize error - no session ID", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
		cancel()
		if _, err := analyzer.AnalyzeFailure(ctx, "url"); err == nil {
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
		if err == nil || !strings.Contains(err.Error(), "init request failed") {
			t.Errorf("Expected init request failed error, got: %v", err)
		}
	})
}
