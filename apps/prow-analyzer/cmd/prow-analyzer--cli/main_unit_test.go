//go:build unit

package main

import (
	"context"
	"errors"
	"flag"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
)

type stubAnalyzer struct {
	outcome analyzer.JobOutcome
	result  *analyzer.AnalysisResult
	err     error
	calls   []string
}

func (stub *stubAnalyzer) JobOutcomeFor(ctx context.Context, jobURL string) analyzer.JobOutcome {
	stub.calls = append(stub.calls, "outcome:"+jobURL)
	return stub.outcome
}

func (stub *stubAnalyzer) AnalyzeFailure(ctx context.Context, jobURL string) (*analyzer.AnalysisResult, error) {
	stub.calls = append(stub.calls, "analysis:"+jobURL)
	return stub.result, stub.err
}

type cliExit int

func TestMain(t *testing.T) {
	for _, testCase := range []struct {
		name           string
		args           []string
		url, token     string
		outcome        analyzer.JobOutcome
		err            error
		status         int
		stdout, stderr string
		calls          int
	}{
		{name: "usage", stderr: "Environment variables:", status: 1},
		{name: "unknown command", args: []string{"unknown", "job"}, stderr: "Unknown command: unknown", status: 1},
		{name: "missing URL", args: []string{"analyze", "job"}, token: "token", stderr: "Both --mcp-url and --token", status: 1},
		{name: "missing token", args: []string{"analyze", "job"}, url: "url", stderr: "Both --mcp-url and --token", status: 1},
		{name: "passing job", args: []string{"analyze", "job"}, url: "url", token: "token", outcome: analyzer.OutcomePassed, stdout: "This Prow job passed", calls: 1},
		{name: "analysis error", args: []string{"analyze", "job"}, url: "url", token: "token", err: errors.New("redacted backend failure"), stderr: "Error: redacted backend failure", status: 1, calls: 2},
		{name: "analysis success", args: []string{"analyze", "job"}, url: "url", token: "token", stdout: "Analysis completed in 1.5s", calls: 2},
		{name: "flags override env", args: []string{"-mcp-url", "url", "-token", "token", "-prompt", "custom {job_url}", "analyze", "job"}, url: "env-url", token: "env-token", stdout: "test analysis", calls: 2},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Setenv("SHIP_HELP_MCP_URL", testCase.url)
			t.Setenv("SHIP_HELP_MCP_TOKEN", testCase.token)
			t.Setenv("USER", "unit-user")
			oldFlags, oldUsage, oldArgs := flag.CommandLine, flag.Usage, os.Args
			oldFactory, oldExit := newAnalyzer, exit
			oldStdout, oldStderr := os.Stdout, os.Stderr
			t.Cleanup(func() {
				flag.CommandLine, flag.Usage, os.Args = oldFlags, oldUsage, oldArgs
				newAnalyzer, exit = oldFactory, oldExit
				os.Stdout, os.Stderr = oldStdout, oldStderr
			})
			flag.CommandLine = flag.NewFlagSet("cli", flag.ContinueOnError)
			flag.Usage = func() { flag.CommandLine.PrintDefaults() }
			os.Args = append([]string{"cli"}, testCase.args...)
			stdoutRead, stdoutWrite, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			stderrRead, stderrWrite, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { stdoutRead.Close(); stdoutWrite.Close(); stderrRead.Close(); stderrWrite.Close() })
			os.Stdout, os.Stderr = stdoutWrite, stderrWrite
			stub := &stubAnalyzer{outcome: testCase.outcome, err: testCase.err, result: &analyzer.AnalysisResult{Analysis: "test analysis", Duration: 1500 * time.Millisecond}}
			factoryCalls := 0
			newAnalyzer = func(url, token, prompt string) failureAnalyzer {
				factoryCalls++
				if url != "url" || token != "token" {
					t.Errorf("constructor credentials = %q %q", url, token)
				}
				wantPrompt := "Analyze this Prow CI failure: {job_url}"
				if testCase.name == "flags override env" {
					wantPrompt = "custom {job_url}"
				}
				if prompt != wantPrompt {
					t.Errorf("prompt = %q", prompt)
				}
				return stub
			}
			exit = func(status int) { panic(cliExit(status)) }
			status := 0
			func() {
				defer func() {
					if recovered := recover(); recovered != nil {
						value, ok := recovered.(cliExit)
						if !ok {
							panic(recovered)
						}
						status = int(value)
					}
				}()
				main()
			}()
			stdoutWrite.Close()
			stderrWrite.Close()
			stdout, err := io.ReadAll(stdoutRead)
			if err != nil {
				t.Fatal(err)
			}
			stderr, err := io.ReadAll(stderrRead)
			if err != nil {
				t.Fatal(err)
			}
			if status != testCase.status {
				t.Errorf("status = %d, want %d", status, testCase.status)
			}
			if !strings.Contains(string(stdout), testCase.stdout) || !strings.Contains(string(stderr), testCase.stderr) {
				t.Errorf("stdout=%q stderr=%q", stdout, stderr)
			}
			if len(stub.calls) != testCase.calls {
				t.Errorf("boundary calls = %v", stub.calls)
			}
			if testCase.calls == 0 && factoryCalls != 0 {
				t.Error("constructed analyzer before validation")
			}
			if testCase.calls > 0 {
				if factoryCalls != 1 || stub.calls[0] != "outcome:job" {
					t.Errorf("factory=%d calls=%v", factoryCalls, stub.calls)
				}
				for _, notice := range []string{analyzer.Disclaimer, analyzer.ReviewNotice, "URL: job"} {
					if !strings.Contains(string(stdout), notice) {
						t.Errorf("missing output notice %q", notice)
					}
				}
			}
			if testCase.calls == 2 && testCase.err == nil && strings.Count(string(stdout), analyzer.AILabel) != 2 {
				t.Error("AI output labels missing")
			}
		})
	}
}

func TestNewAnalyzer(t *testing.T) {
	client := newAnalyzer("https://example.invalid/mcp", "token", "prompt")
	if _, ok := client.(*analyzer.Analyzer); !ok {
		t.Fatalf("constructor result %T", client)
	}
}
