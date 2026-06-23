#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset mcpURL='https://ship-help-mcp-continuous-release-tooling--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp'
export SHIP_HELP_MCP_URL="${mcpURL}"

# Load token securely without exposing in xtrace
set +x
export SHIP_HELP_MCP_TOKEN="$(tr -d '\n' < /tmp/ship-help-token.txt)"
typeset tokenLength="${#SHIP_HELP_MCP_TOKEN}"
set -x

: '╔════════════════════════════════════════════════════════════════╗'
: '║           PROW ANALYZER - COMPREHENSIVE TEST SUITE             ║'
: '╚════════════════════════════════════════════════════════════════╝'
: "MCP URL: ${mcpURL}"
: "Token length: ${tokenLength} chars"

# Test 1: Valid Prow URL - Full Analysis
: '════════════════════════════════════════════════════════════════'
: 'TEST 1: Valid Prow URL - Verify ship-help MCP Integration'
: '════════════════════════════════════════════════════════════════'
typeset testURL='https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-stolostron-policy-collection-main-ocp4.22-interop-opp-aws/2066255424226594816'
: "URL: ${testURL}"
: '⏱️  Starting analysis (expect ~2 minutes)...'

typeset -i startTime endTime duration exitCode
startTime=$(date +%s)
./prow-analyzer--cli analyze "${testURL}" > /tmp/test1-output.txt 2>&1 || exitCode=$?
endTime=$(date +%s)
duration=$((endTime - startTime))

: "✅ Exit Code: ${exitCode:-0}"
: "⏱️  Duration: ${duration}s"
: '📊 Output Preview (first 40 lines):'
head -40 /tmp/test1-output.txt
: '... (output truncated, full output in /tmp/test1-output.txt)'

# Verify ship-help was called
if grep -qi 'analysis completed' /tmp/test1-output.txt; then
    : '✅ PASS: Analysis completed successfully'
else
    : '❌ FAIL: Analysis did not complete'
    exit 1
fi

if grep -qi 'root cause\|jira\|recommendation' /tmp/test1-output.txt; then
    : '✅ PASS: Ship-help MCP returned structured analysis'
else
    : '❌ FAIL: No structured analysis found'
    exit 1
fi

# Test 2: URL Extraction
: '════════════════════════════════════════════════════════════════'
: 'TEST 2: URL Extraction from Different Formats'
: '════════════════════════════════════════════════════════════════'

cat > system-test/test-url-extraction.go <<'GOEOF'
package main

import (
    "fmt"
    "os"
    "github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
)

func main() {
    testCases := []struct {
        input    string
        expected bool
        desc     string
    }{
        {
            "Check this: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/123",
            true,
            "Plain URL in text",
        },
        {
            "<https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/456>",
            true,
            "Slack-formatted URL",
        },
        {
            "Failure at https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/789)",
            true,
            "URL with trailing punctuation",
        },
        {
            "No Prow URL here, just text",
            false,
            "No URL present",
        },
    }

    passed := 0
    failed := 0

    for i, tc := range testCases {
        url := analyzer.ExtractProwURL(tc.input)
        hasURL := url != ""

        if hasURL == tc.expected {
            fmt.Printf("✅ Test %d PASS: %s\n", i+1, tc.desc)
            if hasURL {
                fmt.Printf("   Extracted: %s\n", url)
            }
            passed++
        } else {
            fmt.Printf("❌ Test %d FAIL: %s\n", i+1, tc.desc)
            fmt.Printf("   Expected URL: %v, Got: %s\n", tc.expected, url)
            failed++
        }
    }

    fmt.Printf("\n📊 URL Extraction: %d passed, %d failed\n\n", passed, failed)
    if failed > 0 {
        os.Exit(1)
    }
}
GOEOF

go run system-test/test-url-extraction.go
rm -f system-test/test-url-extraction.go
cd "$(dirname "$0")/.."

# Test 3: Error Handling - Invalid URL
: '════════════════════════════════════════════════════════════════'
: 'TEST 3: Error Handling - Invalid URL'
: '════════════════════════════════════════════════════════════════'
typeset invalidURL='https://invalid-url.com/not-prow'
: "URL: ${invalidURL}"

typeset -i test3ExitCode=0
./prow-analyzer--cli analyze "${invalidURL}" > /tmp/test3-output.txt 2>&1 || test3ExitCode=$?

: "Exit Code: ${test3ExitCode} (expected non-zero)"
if ((test3ExitCode != 0)); then
    : '✅ PASS: Correctly failed on invalid URL'
else
    : '❌ FAIL: Should have failed on invalid URL'
    exit 1
fi
: 'Error output:'
cat /tmp/test3-output.txt

# Test 4: Help/Usage
: '════════════════════════════════════════════════════════════════'
: 'TEST 4: CLI Help & Usage'
: '════════════════════════════════════════════════════════════════'
./prow-analyzer--cli --help > /tmp/test4-output.txt 2>&1 || true
if grep -qi 'usage\|flag' /tmp/test4-output.txt; then
    : '✅ PASS: Help output displayed'
else
    : '❌ FAIL: Help output missing'
    exit 1
fi
cat /tmp/test4-output.txt

# Test 5: Binary Info
: '════════════════════════════════════════════════════════════════'
: 'TEST 5: Binary Information'
: '════════════════════════════════════════════════════════════════'
: 'CLI Binary:'
ls -lh ./prow-analyzer--cli
: 'Slack Bot Binary:'
ls -lh ./prow-analyzer--bot
file ./prow-analyzer--cli

# Summary
: '════════════════════════════════════════════════════════════════'
: '                       TEST SUMMARY'
: '════════════════════════════════════════════════════════════════'
: "✅ Test 1: Valid Prow URL Analysis (${duration}s)"
: '✅ Test 2: URL Extraction'
: '✅ Test 3: Error Handling'
: '✅ Test 4: Help Output'
: '✅ Test 5: Binary Info'
: '📁 Full outputs saved in:'
: '   - /tmp/test1-output.txt (full analysis)'
: '   - /tmp/test3-output.txt (error handling)'
: '   - /tmp/test4-output.txt (help output)'
: '🔍 Verify ship-help MCP integration:'
: "   cat /tmp/test1-output.txt | grep -A 5 'Root Cause\|Jira\|Recommendation'"
: '════════════════════════════════════════════════════════════════'

true
